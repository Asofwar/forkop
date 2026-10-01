#!/usr/bin/env ucode
// Persistent VPN policy. The offline DNS responder is dnsmasq, not sing-box.
let fs = require("fs");
let common = require("core.common");
let uci = require("core.uci");
const TABLE = "ForkopVpnGuard";
const DIR = getenv("FORKOP_GUARD_DIR") || "/etc/forkop/vpn-guard";
const TMP = getenv("FORKOP_GUARD_TMP") || "/tmp/forkop-vpn-guard";
const MARK_BASE = 0x28010000;
const PORT_BASE = 18053;
let arr = function(v) { return v == null ? [] : type(v) == "array" ? v : [v]; };
let quote = function(v) { return "'" + replace("" + v, /'/g, "'\\''") + "'"; };
let run = function(args) { return system(join(" ", map(args, quote))) == 0; };
function output(args, soft) {
    let p = fs.popen(join(" ", map(args, quote)), "r");
    if (p == null) die("Cannot execute command: " + join(" ", map(args, quote)) + "\n");
    let s = p.read("all");
    if (p.close() != 0) {
        if (soft) return null;
        die("Command failed: " + args[0] + "\n");
    }
    return s;
}
function jsonfile(path) {
    let s = fs.readfile(path);
    if (s == null) die("Missing guard input: " + path + "\n");
    return json(s);
}
function mkdir(path) {
    if (fs.stat(path) != null) return;
    let pos = rindex(path, "/");
    if (pos > 0) mkdir(substr(path, 0, pos));
    if (!fs.mkdir(path, 0700)) die("Cannot create " + path + "\n");
}
function write(path, data) {
    // Avoid flash writes when the policy has not changed.
    if (fs.readfile(path) == data) return;
    if (fs.writefile(path + ".new", data) == null || !fs.rename(path + ".new", path))
        die("Cannot save guard policy\n");
}
function protects(section) {
    return common.bool_option(section, "enabled", true) &&
        index(["connection", "vpn", "proxy", "outbound"], section.action) >= 0;
}
function protect_outbounds(config, sections) {
    let nodes = {};
    for (let node in config.outbounds) nodes[node.tag] = node;
    let interfaces = [];
    let visiting = {};
    let guarded_nodes = {};
    function visit(tag) {
        if (visiting[tag]) die("VPN guard: cyclic outbound graph\n");
        let node = nodes[tag];
        if (node == null) die("VPN guard: missing outbound " + tag + "\n");
        visiting[tag] = true;
        if (node.type == "selector" || node.type == "urltest") {
            for (let child in arr(node.outbounds)) visit(child);
        }
        else if (node.type == "direct") {
            if (!node.bind_interface || node.detour)
                die("VPN guard: direct WAN path in " + tag + "\n");
            if (index(interfaces, node.bind_interface) < 0) push(interfaces, node.bind_interface);
            guarded_nodes[tag] = true;
        }
        else if (node.detour) visit(node.detour);
        visiting[tag] = false;
    }
    for (let s in sections) if (protects(s)) visit(s[".name"] + "-out");
    sort(interfaces);
    if (length(interfaces) > 255) die("Too many guarded interfaces\n");
    let marks = [];
    for (let node in config.outbounds) {
        let i = index(interfaces, node.bind_interface);
        if (node.type != "direct" || i < 0 || !guarded_nodes[node.tag]) continue;
        node.routing_mark = MARK_BASE + i;
        push(marks, {mark: node.routing_mark, interface: node.bind_interface});
    }
    return marks;
}
function expand_ruleset(config, tag, cache) {
    if (cache[tag] != null) return cache[tag];
    for (let rs in arr(config.route.rule_set)) {
        if (rs.tag != tag) continue;
        if (rs.type != "local" || !rs.path) die("VPN guard requires cached local rule-sets\n");
        let data;
        if (rs.format == "source") data = jsonfile(rs.path);
        else {
            mkdir(TMP);
            let dest = TMP + "/decompile.json";
            if (!run([getenv("SING_BOX_BIN") || "/usr/bin/sing-box", "rule-set", "decompile", rs.path, "-o", dest]))
                die("Cannot read guard rule-set " + tag + "\n");
            data = jsonfile(dest);
            fs.unlink(dest);
        }
        cache[tag] = arr(data.rules);
        return cache[tag];
    }
    die("Unknown guard rule-set " + tag + "\n");
}
function dns_policy(config, sections, resolver_lines) {
    let protected_tags = {};
    for (let s in sections) if (protects(s)) protected_tags[s[".name"] + "-out"] = true;
    let rules = [];
    let candidates = {};
    let groups = [];
    let cache = {};
    function add(rule, target, inherited) {
        let predicates = inherited == null ? [] : [...inherited];
        if (rule.source_ip_cidr != null) {
            let cidrs = arr(rule.source_ip_cidr);
            let id = join(",", cidrs);
            let group = index(map(groups, function(g) { return g.id; }), id);
            if (group < 0) { group = length(groups); push(groups, {id, cidrs}); }
            push(predicates, {group, invert: !!rule.invert});
        }
        if (rule.type == "logical") {
            if (rule.mode != "and" || rule.invert) die("VPN guard: unsupported logical DNS policy\n");
            let domain_rule = null;
            for (let child in arr(rule.rules)) {
                if (child.source_ip_cidr != null) {
                    for (let key in keys(child))
                        if (index(["source_ip_cidr", "invert", "type"], key) < 0)
                            die("VPN guard: unsupported source condition " + key + "\n");
                    let cidrs = arr(child.source_ip_cidr), id = join(",", cidrs);
                    let group = index(map(groups, function(g) { return g.id; }), id);
                    if (group < 0) { group = length(groups); push(groups, {id, cidrs}); }
                    push(predicates, {group, invert: !!child.invert});
                }
                else if (domain_rule == null) domain_rule = child;
                else die("VPN guard: unsupported compound domain policy\n");
            }
            if (domain_rule != null) add(domain_rule, target, predicates);
            return;
        }
        if (length(arr(rule.domain_regex)) || length(arr(rule.domain_keyword)))
            die("VPN guard: regex/keyword DNS matchers cannot be represented by dnsmasq\n");
        let domains = arr(rule.domain), suffixes = arr(rule.domain_suffix);
        if (length(domains) || length(suffixes)) {
            // sing-box combines domain and destination IP through OR, not AND.
            // The IP branch is retained independently in the nft guard.
            let allowed = ["type", "domain", "domain_suffix", "ip_cidr", "source_ip_cidr", "inbound", "action", "outbound", "rule_set"];
            for (let key in keys(rule))
                if (index(allowed, key) < 0 && rule[key] != null && rule[key] !== false)
                    die("VPN guard: domain policy for " + target + " has unsupported extra condition " + key + "\n");
            if (rule.port != null || rule.port_range != null || rule.invert)
                die("VPN guard: domain policy has unsupported extra conditions\n");
            for (let d in [...domains, ...suffixes]) {
                let base = substr(d, 0, 1) == "." ? substr(d, 1) : d;
                if (!match(base, /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/)) die("Invalid guard domain: " + d + "\n");
                candidates[lc(base)] = true;
            }
            let exact = {}, suffix = {};
            for (let d in domains) exact[lc(d)] = true;
            for (let d in suffixes) suffix[lc(d)] = true;
            push(rules, {exact, suffix, target, predicates});
        }
        for (let tag in arr(rule.rule_set))
            for (let child in expand_ruleset(config, tag, cache)) add(child, target, predicates);
    }
    for (let rule in config.route.rules) {
        if (rule.action != "route") continue;
        let inbound = arr(rule.inbound);
        if (length(inbound) && index(inbound, "tproxy-in") < 0 && index(inbound, "tproxy6-in") < 0) continue;
        if (rule.outbound == null) continue;
        // Resolve/sniff actions are not terminal policy decisions.
        add(rule, !!protected_tags[rule.outbound], []);
    }
    if (length(groups) > 4) die("VPN guard supports at most four independent source groups\n");
    function verdict(name, mask) {
        for (let rule in rules) {
            let applies = true;
            for (let p in rule.predicates)
                if (!!(mask & (1 << p.group)) == p.invert) applies = false;
            if (!applies) continue;
            if (rule.exact[name] || rule.suffix[name]) return rule.target;
            let tail = name, pos;
            while ((pos = index(tail, ".")) >= 0) {
                tail = substr(tail, pos + 1);
                if (rule.suffix[tail] || rule.suffix["." + tail]) return rule.target;
            }
        }
        return null;
    }
    let profiles = [];
    for (let mask = 0; mask < (1 << length(groups)); mask++) {
        let lines = ["no-hosts", "cache-size=0", "bind-dynamic", "strict-order", "local=/forkop-vpn-guard.invalid/",
            ...(resolver_lines || ["resolv-file=/tmp/resolv.conf.d/resolv.conf.auto"])];
        for (let d in sort(keys(candidates))) {
            let exact = verdict(d, mask), below = verdict("forkop-guard-child." + d, mask);
            push(lines, "server=/" + d + "/" + (exact ? "" : "#"));
            if (below != exact) push(lines, "server=/*." + d + "/" + (below ? "" : "#"));
            // Explicit DPI/bypass DNS answers exempt their real IP addresses
            // for the same source profile, including shared VPN CDN ranges.
            let sets = "4#inet#" + TABLE + "#dns_except_" + mask + "4,6#inet#" + TABLE + "#dns_except_" + mask + "6";
            if (exact === false) push(lines, "nftset=/" + d + "/" + sets);
            if (below === false && exact !== false) push(lines, "nftset=/*." + d + "/" + sets);
        }
        push(profiles, {mask, config: join("\n", lines) + "\n"});
    }
    return {groups, profiles, domains: length(candidates)};
}
function block(text, label) {
    let start = index(text, label + " {");
    if (start < 0) die("Missing nft policy block " + label + "\n");
    let open = start + length(label) + 1, depth = 1;
    for (let end = open + 1; end < length(text); end++) {
        let c = substr(text, end, 1);
        if (c == "{") depth++;
        if (c == "}" && --depth == 0) return substr(text, start, end - start + 1);
    }
    die("Unbalanced nft policy\n");
}
function source_clauses(dns, mask, family) {
    let clauses = [];
    for (let i = 0; i < length(dns.groups); i++) {
        let cidrs = filter(dns.groups[i].cidrs, function(c) { return (index(c, ":") >= 0) == (family == 6); });
        let yes = !!(mask & (1 << i));
        if (!length(cidrs)) { if (yes) return null; continue; }
        push(clauses, (family == 4 ? "ip" : "ip6") + " saddr " + (yes ? "" : "!= ") + "{ " + join(", ", cidrs) + " }");
    }
    return join(" ", clauses);
}
function nft_policy(text, sections, marks, dns, interfaces) {
    let actions = {};
    for (let s in sections) actions[s[".name"]] = protects(s);
    let sets = [];
    for (let line in split(text, "\n")) {
        let m = match(line, /^[ \t]*set ([A-Za-z0-9_]+) \{/);
        if (m) push(sets, block(text, "set " + m[1]));
    }
    let rules = [];
    let body = block(text, "chain priority_rules");
    for (let line in split(body, "\n")) {
        let section = null;
        for (let name in keys(actions))
            if (index(line, "@forkop_rule_" + name + "_") >= 0 &&
                (section == null || length(name) > length(section))) section = name;
        if (section == null) {
            if (index(line, "@forkop_rule_") >= 0) die("Unknown guard section in nft rule\n");
            continue;
        }
        line = replace(line, /counter packets [0-9]+ bytes [0-9]+/g, "counter");
        line = replace(line, /meta mark set 0x[0-9a-fA-F]+[ \t]*/, "");
        line = replace(line, /accept[ \t]*$/, actions[section] ? "reject" : "return");
        push(rules, trim(line));
    }
    let exceptions = [];
    for (let profile in dns.profiles) {
        for (let family in [4, 6]) {
            let name = "dns_except_" + profile.mask + family;
            push(sets, "set " + name + " { type ipv" + family + "_addr; flags timeout; timeout 1d; size 65536; }");
            let source = source_clauses(dns, profile.mask, family);
            if (source != null) push(exceptions, "iifname @forkop_interfaces meta nfproto ipv" + family + " " + source + " " +
                (family == 4 ? "ip" : "ip6") + " daddr @" + name + " counter return");
        }
    }
    let forward = ["type filter hook forward priority -10; policy accept;", ...exceptions, ...rules,
        "iifname @forkop_interfaces ip daddr 198.18.0.0/15 counter reject",
        "iifname @forkop_interfaces ip6 daddr fc00::/18 counter reject"];
    let out = ["type filter hook output priority -10; policy accept;"];
    let seen = {};
    for (let m in marks) {
        if (seen[m.mark]) continue;
        seen[m.mark] = true;
        if (!match(m.interface, /^[A-Za-z0-9_.:-]+$/)) die("Invalid guard interface\n");
        push(out, sprintf("meta mark 0x%08x oifname != \"%s\" counter reject", m.mark, m.interface));
    }
    let input = ["type filter hook input priority -10; policy accept;",
        sprintf("iifname != \"lo\" iifname != @forkop_interfaces udp dport %d-%d counter drop", PORT_BASE, PORT_BASE + length(dns.profiles) - 1),
        sprintf("iifname != \"lo\" iifname != @forkop_interfaces tcp dport %d-%d counter drop", PORT_BASE, PORT_BASE + length(dns.profiles) - 1)];
    return "table inet " + TABLE + " {\n" + join("\n", sets) +
        "\nchain forward {\n" + join("\n", forward) + "\n}\nchain output {\n" + join("\n", out) +
        "\n}\nchain input {\n" + join("\n", input) + "\n}\nchain dns { type nat hook prerouting priority -102; policy accept; }\n}\n";
}
function compile(config, sections, text, interfaces, resolver_lines) {
    let marks = protect_outbounds(config, sections);
    let dns = dns_policy(config, sections, resolver_lines);
    return {version: 1, marks, dns, interfaces, nft: nft_policy(text, sections, marks, dns, interfaces)};
}
function restored_exceptions(policy, saved, now) {
    let body = policy.nft;
    if (saved == null || saved.time > now || sprintf("%J", saved.dns) != sprintf("%J", policy.dns)) return body;
    for (let profile in policy.dns.profiles)
        for (let family in [4, 6]) {
            let name = "dns_except_" + profile.mask + family, elements = [];
            for (let entry in saved.sets?.[name] || []) {
                let remaining = int(entry.until) - now;
                if (remaining <= 0 || remaining > 86400 || !match(entry.ip || "", /^[0-9a-fA-F:.]+$/)) continue;
                push(elements, entry.ip + " timeout " + remaining + "s");
            }
            if (length(elements)) {
                let original = block(body, "set " + name);
                body = replace(body, original, substr(original, 0, length(original) - 1) +
                    " elements = { " + join(", ", elements) + " }; }");
            }
        }
    return body;
}
function checkpoint(policy) {
    let saved = {time: time(), dns: policy.dns, sets: {}};
    for (let profile in policy.dns.profiles)
        for (let family in [4, 6]) {
            let name = "dns_except_" + profile.mask + family;
            let data = output(["nft", "-j", "list", "set", "inet", TABLE, name], true);
            if (data == null) die("Cannot checkpoint VPN guard exceptions\n");
            saved.sets[name] = [];
            for (let item in json(data).nftables || [])
                for (let entry in item.set?.elem || [])
                    if (entry.elem?.expires > 0)
                        push(saved.sets[name], {ip: entry.elem.val, until: saved.time + int(entry.elem.expires)});
        }
    // ponytail: checkpoint only on controlled shutdown; power loss requires fresh DNS.
    write(DIR + "/exceptions.json", sprintf("%J\n", saved));
}
function dns_redirect_rules(policy) {
    let rules = ["flush chain inet " + TABLE + " dns"];
    for (let profile in policy.dns.profiles)
        for (let family in [4, 6]) {
            let clauses = source_clauses(policy.dns, profile.mask, family);
            if (clauses == null) continue;
            for (let protocol in ["tcp", "udp"])
                push(rules, sprintf("add rule inet %s dns iifname @forkop_interfaces meta nfproto ipv%d %s %s dport 53 redirect to :%d",
                    TABLE, family, clauses, protocol, PORT_BASE + profile.mask));
        }
    return rules;
}
function clear_dns_connections() {
    if (fs.stat("/usr/sbin/conntrack") == null) die("VPN guard requires conntrack\n");
    // Remove only DNS flows so pre-existing DNAT cannot retain the old port.
    for (let protocol in ["tcp", "udp"])
        system("/usr/sbin/conntrack -D -p " + protocol + " --dport 53 >/dev/null 2>&1");
}
function apply(policy, preserve) {
    mkdir(TMP);
    fs.unlink(TMP + "/online");
    let path = TMP + "/apply.nft";
    let present = system("nft list table inet " + TABLE + " >/dev/null 2>&1") == 0;
    let body = !present && preserve !== false && fs.stat(DIR + "/exceptions.json") != null
        ? restored_exceptions(policy, jsonfile(DIR + "/exceptions.json"), time()) : policy.nft;
    if (present && preserve !== false) {
        for (let profile in policy.dns.profiles)
            for (let family in [4, 6]) {
                let name = "dns_except_" + profile.mask + family;
                let current = output(["nft", "list", "set", "inet", TABLE, name], true);
                if (current != null) body = replace(body, block(body, "set " + name), block(current, "set " + name));
            }
    }
    // Install offline DNS in the same transaction: no direct-DNS gap during restore.
    body += join("\n", dns_redirect_rules(policy)) + "\n";
    if (fs.writefile(path, (present ? "delete table inet " + TABLE + "\n" : "") + body) == null ||
        !run(["nft", "-c", "-f", path]) || !run(["nft", "-f", path])) die("VPN guard nft apply failed\n");
    fs.unlink(path);
    clear_dns_connections();
}
function offline(policy) {
    mkdir(TMP);
    fs.unlink(TMP + "/online");
    let rules = dns_redirect_rules(policy);
    let path = TMP + "/offline.nft";
    fs.writefile(path, join("\n", rules) + "\n");
    if (!run(["nft", "-f", path])) die("Cannot enable guard DNS\n");
    fs.unlink(path);
    clear_dns_connections();
}
function online() {
    let policy = jsonfile(DIR + "/policy.json");
    for (let profile in policy.dns.profiles) {
        let ready = false;
        for (let attempt = 0; attempt < 4; attempt++) {
            let result = output(["dig", "@127.0.0.1", "-p", PORT_BASE + profile.mask,
                "forkop-vpn-guard.invalid", "A", "+time=1", "+tries=1", "+comments"], true);
            if (result != null && index(result, "status: NXDOMAIN") >= 0) { ready = true; break; }
        }
        if (!ready) die("VPN guard: DNS responder is not ready\n");
    }
    if (!run(["nft", "flush", "chain", "inet", TABLE, "dns"])) die("Cannot switch guard DNS\n");
    clear_dns_connections();
    fs.unlink(TMP + "/hold");
    write(TMP + "/online", "1\n");
}
let policy_lock;
function lock_policy() {
    mkdir(TMP);
    policy_lock = fs.open(TMP + "/policy.lock", "a");
    if (policy_lock == null || !policy_lock.lock("x")) die("Cannot lock VPN guard policy\n");
}
function materialize(policy) {
    mkdir(TMP);
    // Persist exactly one atomic file. Runtime DNS files can always be rebuilt.
    for (let entry in fs.lsdir(TMP) || [])
        if (match(entry, /^dns-[0-9]+\.conf$/)) fs.unlink(TMP + "/" + entry);
    for (let profile in policy.dns.profiles) {
        let data = profile.config + "port=" + (PORT_BASE + profile.mask) + "\n";
        for (let iface in policy.interfaces) {
            if (!match(iface, /^[A-Za-z0-9_.:-]+$/)) die("Invalid DNS guard interface\n");
            data += "interface=" + iface + "\n";
        }
        write(TMP + "/dns-" + profile.mask + ".conf", data);
        if (!run(["/usr/sbin/dnsmasq", "--test", "--conf-file=" + TMP + "/dns-" + profile.mask + ".conf"]))
            die("VPN guard: invalid DNS responder configuration\n");
    }
}
function disable_offload() {
    // Flowtable forwarding bypasses forward hooks, including this guard.
    let changed = false;
    if (!uci.exists("firewall.forkop_vpn_guard") && !uci.set_section("firewall.forkop_vpn_guard", "include"))
        die("Cannot create guard firewall state\n");
    if (!uci.set("firewall.forkop_vpn_guard.type", "script") ||
        !uci.set("firewall.forkop_vpn_guard.path", "/usr/share/forkop/vpn-guard-firewall.sh") ||
        !uci.set("firewall.forkop_vpn_guard.fw4_compatible", "1"))
        die("Cannot configure guard firewall restore\n");
    for (let key in ["flow_offloading", "flow_offloading_hw"]) {
        let path = "firewall.@defaults[0]." + key;
        if (uci.get(path) != "1") continue;
        if (!uci.set(path, "0")) die("Cannot disable flow offload\n");
        changed = true;
    }
    if (changed && (!uci.commit("firewall") || !run(["/etc/init.d/firewall", "reload"])))
        die("VPN guard: flow offload disable failed\n");
}
function check_ports(policy) {
    if (fs.stat(DIR + "/policy.json") != null) return;
    for (let name in ["tcp", "tcp6", "udp", "udp6"]) {
        for (let line in split(fs.readfile("/proc/net/" + name) || "", "\n")) {
            let fields = split(trim(line), /[ \t]+/);
            if (length(fields) < 4 || (substr(name, 0, 3) == "tcp" && fields[3] != "0A")) continue;
            let endpoint = fields[1], pos = rindex(endpoint, ":");
            let port = int("0x" + substr(endpoint, pos + 1));
            if (port >= PORT_BASE && port < PORT_BASE + length(policy.dns.profiles))
                die("VPN guard: DNS port already in use: " + port + "\n");
        }
    }
}
function check_dnsmasq() {
    let version = output(["/usr/sbin/dnsmasq", "--version"]);
    if (index(version, "no-nftset") >= 0 || index(version, "nftset") < 0)
        die("VPN guard requires dnsmasq-full with nftset support\n");
}
function resolver_options() {
    let dhcp = uci.get_all("dhcp", "@dnsmasq[0]") || {};
    let servers = arr(dhcp.forkop_server || dhcp.server);
    let lines = [];
    for (let server in servers) {
        if (server == "127.0.0.42") continue;
        if (match(server, /[\r\n]/)) die("Invalid guard DNS server\n");
        push(lines, "server=" + server);
    }
    let noresolv = dhcp.forkop_noresolv || (dhcp.forkop_noresolv === "0" ? "0" : dhcp.noresolv);
    // Forkop forces noresolv=1 while running. An absent backup means the
    // original dnsmasq used the ordinary OpenWrt resolv file.
    if (index(servers, "127.0.0.42") >= 0 && dhcp.forkop_noresolv == null) noresolv = "0";
    if (noresolv == "1") {
        if (!length(lines)) die("VPN guard: no independent DNS upstream configured\n");
        push(lines, "no-resolv");
    }
    else {
        let path = dhcp.resolvfile || "/tmp/resolv.conf.d/resolv.conf.auto";
        if (!match(path, /^\/[A-Za-z0-9_./-]+$/)) die("Invalid guard resolv file\n");
        push(lines, "resolv-file=" + path);
    }
    return lines;
}
if (sourcepath(1)) return {protect_outbounds, compile, dns_policy, restored_exceptions, dns_redirect_rules};
let mode = ARGV[0];
if (mode == "watch") {
    let loop = require("uloop"), bus = require("ubus").connect();
    let identity = require("core.process_identity");
    if (bus == null || !loop.init()) die("VPN guard watch cannot connect to ubus\n");
    let previous = null;
    let timer;
    timer = loop.timer(1000, function() {
        let service = bus.call("service", "list", {name: "sing-box"});
        let records = [];
        for (let instance in values(service?.["sing-box"]?.instances || {}))
            if (instance.running && instance.pid)
                push(records, instance.pid + ":" + identity.start_ticks(instance.pid));
        // PID and process start time identify recovery; changing CPU counters
        // must not cause continuous policy reloads.
        let signature = join(",", sort(records));
        if (signature != previous || (signature != "" && fs.stat(TMP + "/online") == null && fs.stat(TMP + "/hold") == null)) {
            let action = signature == "" ? "offline-auto" : "restore";
            if (!run(["ucode", "-L", "/usr/lib/forkop", "/usr/lib/forkop/nft/fail_closed.uc", action])) exit(1);
            previous = signature;
        }
        timer.set(1000);
    });
    loop.run();
    exit(1);
}
if (mode != "compile-fixture" && mode != "check-live" && mode != "refresh") lock_policy();
if (mode == "compile-fixture") {
    let input = jsonfile(ARGV[1]);
    let policy = compile(input.config, input.sections, input.nft, input.interfaces || ["br-lan"]);
    if (input.learned != null) policy.nft = restored_exceptions(policy, input.learned, input.now);
    policy.nft += join("\n", dns_redirect_rules(policy)) + "\n";
    print(sprintf("%J\n", policy));
}
else if (mode == "validate-config") {
    check_dnsmasq();
    dns_policy(jsonfile(ARGV[1]), uci.section_objects("forkop", "section"), resolver_options());
}
else if (mode == "refresh" || mode == "check-live") {
    if (mode == "refresh" && !common.bool_option(uci.get_all("forkop", "settings"), "vpn_fail_closed", false) &&
        fs.stat(DIR + "/policy.json") == null) exit(0);
    let config = jsonfile(uci.get("forkop.settings.config_path") || "/etc/sing-box/config.json");
    let sections = uci.section_objects("forkop", "section");
    let settings = uci.get_all("forkop", "settings");
    let interfaces = arr(settings.source_network_interfaces);
    if (!length(interfaces)) interfaces = ["br-lan"];
    let policy = compile(config, sections, output(["nft", "list", "table", "inet", "ForkopTable"]), interfaces, resolver_options());
    check_dnsmasq();
    check_ports(policy);
    if (mode == "check-live") {
        mkdir(TMP);
        fs.writefile(TMP + "/policy.json", sprintf("%J\n", policy));
        print(sprintf("%J\n", {domains: policy.dns.domains, profiles: length(policy.dns.profiles), marks: policy.marks}));
        exit(0);
    }
    mkdir(DIR);
    let previous = fs.stat(DIR + "/policy.json") != null ? jsonfile(DIR + "/policy.json") : {};
    policy.saved_offload = previous.saved_offload || {};
    for (let key in ["flow_offloading", "flow_offloading_hw"]) {
        if (policy.saved_offload[key] == null)
            policy.saved_offload[key] = uci.get("firewall.forkop_vpn_guard.saved_" + key) || uci.get("firewall.@defaults[0]." + key);
        uci.delete("firewall.forkop_vpn_guard.saved_" + key);
    }
    if (!uci.commit("firewall")) die("Cannot save firewall settings\n");
    // firewall reload calls restore, so it must happen before taking our lock.
    disable_offload();
    lock_policy();
    materialize(policy);
    write(DIR + "/policy.json", sprintf("%J\n", policy));
    apply(policy, sprintf("%J", previous.dns) == sprintf("%J", policy.dns));
}
else if (mode == "load") { let policy = jsonfile(DIR + "/policy.json"); materialize(policy); apply(policy); offline(policy); }
else if (mode == "register-firewall") {
    if (!uci.set_section("firewall.forkop_vpn_guard", "include") ||
        !uci.set("firewall.forkop_vpn_guard.type", "script") ||
        !uci.set("firewall.forkop_vpn_guard.path", "/usr/share/forkop/vpn-guard-firewall.sh") ||
        !uci.set("firewall.forkop_vpn_guard.fw4_compatible", "1") ||
        !uci.commit("firewall")) die("Cannot register guard firewall restore\n");
}
else if (mode == "restore") {
    let policy = jsonfile(DIR + "/policy.json");
    apply(policy);
    offline(policy);
    // The managed-process check is shared with Forkop's existing lifecycle.
    if (fs.stat(TMP + "/hold") == null && run(["ucode", "-L", getenv("FORKOP_LIB") || "/usr/lib/forkop",
        (getenv("FORKOP_LIB") || "/usr/lib/forkop") + "/service/state.uc",
        "wait-forkop-stable-start", "forkop", "ForkopTable", "0x04000000", "2", "5"])) online();
}
else if (mode == "offline" || mode == "offline-auto") {
    // A graceful Forkop stop holds offline DNS until its explicit successful start.
    if (mode == "offline") write(TMP + "/hold", "1\n");
    offline(jsonfile(DIR + "/policy.json"));
}
else if (mode == "checkpoint") checkpoint(jsonfile(DIR + "/policy.json"));
else if (mode == "online") online();
else if (mode == "remove") {
    if (system("nft list table inet " + TABLE + " >/dev/null 2>&1") == 0 && !run(["nft", "delete", "table", "inet", TABLE])) exit(1);
    let policy = fs.stat(DIR + "/policy.json") != null ? jsonfile(DIR + "/policy.json") : {};
    for (let key in ["flow_offloading", "flow_offloading_hw"]) {
        let saved = policy.saved_offload?.[key] || uci.get("firewall.forkop_vpn_guard.saved_" + key);
        if (saved == "1") {
            uci.set("firewall.@defaults[0]." + key, saved);
        }
    }
    uci.delete("firewall.forkop_vpn_guard");
    if (!uci.commit("firewall")) exit(1);
    fs.unlink(DIR + "/policy.json");
    fs.unlink(DIR + "/exceptions.json");
    fs.unlink(TMP + "/hold");
    fs.unlink(TMP + "/online");
    policy_lock.close();
    if (!run(["/etc/init.d/firewall", "reload"])) exit(1);
}
else die("Usage: nft/fail_closed.uc <refresh|load|offline|online|remove|compile-fixture>\n");
