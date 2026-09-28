#!/usr/bin/env ucode

// Which Forkop rule handles a connection, calculated from the generated
// sing-box config: the first route rule a connection to (host, ip) takes.
// The answer is static (no traffic is sent) and says "undecided" with a
// reason when the config cannot answer it: remote or binary lists, regexes,
// logical rules, source-scoped rules without a source, unknown fields and,
// for FakeIP, resolve actions above the owner.
//
// autotune/apply.uc carries the same TCP/443 logic for its own safety
// checks; moving it onto this module belongs to the autotune backend stage.

function as_string(v) { return v == null ? "" : "" + v; }
function list_of(v) { return v == null ? [] : type(v) == "array" ? v : [ v ]; }

function ipv4_number(text) {
    let m = match(as_string(text), /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
    if (m == null) return null;
    return ((int(m[1]) * 256 + int(m[2])) * 256 + int(m[3])) * 256 + int(m[4]);
}

function in_prefix(ip, prefix, len) {
    let a = ipv4_number(ip), b = ipv4_number(prefix);
    if (a == null || b == null) return false;
    let size = 1;
    for (let i = 0; i < 32 - len; i++) size *= 2;
    return int(a / size) == int(b / size);
}

function cidr_contains(cidr, ip) {
    let m = match(as_string(cidr), /^([0-9.]+)(\/([0-9]+))?$/);
    return m != null && in_prefix(ip, m[1], m[3] ? int(m[3]) : 32);
}

// sing-box FakeIP range: such an answer reaches sing-box as the domain name.
function is_fakeip(ip) {
    return in_prefix(ip, "198.18.0.0", 15);
}

function port_matches(rule, port) {
    if (rule.port == null && rule.port_range == null) return true;
    for (let p in list_of(rule.port)) if (int(p) == port) return true;
    for (let r in list_of(rule.port_range)) {
        let m = match(as_string(r), /^([0-9]*):([0-9]*)$/);
        if (m && (m[1] == "" || port >= int(m[1])) && (m[2] == "" || port <= int(m[2]))) return true;
    }
    return false;
}

const RULE_KEYS = [ "action", "outbound", "inbound", "domain", "domain_suffix", "domain_keyword", "domain_regex",
    "ip_cidr", "rule_set", "source_ip_cidr", "port", "port_range", "network", "protocol" ];
// Sniffed protocols a TCP connection can never have (disable_quic adds a
// protocol=quic reject rule in front of every section rule).
const UDP_ONLY_PROTOCOLS = [ "quic", "dtls", "stun" ];
const RESOLVE_KEYS = [ "action", "server", "strategy", "disable_cache", "rewrite_ttl", "client_subnet" ];

function filter_keys(r, drop) {
    let copy = {};
    for (let k, v in r) if (index(drop, k) < 0) copy[k] = v;
    return copy;
}

// "match", "no", or { reason } when it cannot be decided statically.
// target: { host, ip, fakeip, network: "tcp"|"udp", port, source }.
function rule_matches(r, target) {
    if (r.type == "logical" || r.invert) return { reason: "logical_rule" };
    for (let key in keys(r)) if (index(RULE_KEYS, key) < 0) return { reason: "unknown_rule_field" };
    if (r.network != null && index(list_of(r.network), target.network) < 0) return "no";
    if (!port_matches(r, target.port)) return "no";
    if (r.protocol != null) {
        if (target.network != "tcp") return { reason: "protocol_matcher" };
        let tcp_possible = filter(list_of(r.protocol), (p) => index(UDP_ONLY_PROTOCOLS, p) < 0);
        if (length(tcp_possible) == 0) return "no";
        return { reason: "protocol_matcher" };
    }
    let host = target.host, dest_fields = 0, dest = "no";
    let hit = () => { dest = "match"; };
    let unknown = () => { if (dest != "match") dest = "unknown"; };
    for (let d in list_of(r.domain)) { dest_fields++; if (host != "" && lc(d) == host) hit(); }
    for (let d in list_of(r.domain_suffix)) {
        dest_fields++;
        if (host == "") continue;
        // sing-box: ".example.com" matches subdomains only, "example.com"
        // the domain itself and its subdomains.
        let s = lc(d), sub_only = substr(s, 0, 1) == ".";
        if (sub_only) s = substr(s, 1);
        if ((!sub_only && host == s) || (length(host) > length(s) + 1 && substr(host, length(host) - length(s) - 1) == "." + s)) hit();
    }
    for (let d in list_of(r.domain_keyword)) { dest_fields++; if (host != "" && index(host, lc(d)) >= 0) hit(); }
    for (let d in list_of(r.domain_regex)) { dest_fields++; unknown(); }
    for (let c in list_of(r.ip_cidr)) { dest_fields++; if (!target.fakeip && cidr_contains(c, target.ip)) hit(); }
    for (let t in list_of(r.rule_set)) { dest_fields++; unknown(); }
    if (dest_fields > 0 && dest == "no") return "no";
    if (dest == "unknown") return { reason: "list_not_checkable" };
    if (r.source_ip_cidr != null) {
        if (target.source == "") return { reason: "source_scoped_rule" };
        let inside = false;
        for (let c in list_of(r.source_ip_cidr)) if (cidr_contains(c, target.source)) inside = true;
        if (!inside) return "no";
    }
    return "match";
}

// First route rule the connection takes: { decided, kind: outbound|reject|
// final, outbound, rule, reason }.
function route_owner(config, target, tproxy_inbound) {
    let rules = type(config) == "object" && type(config.route) == "object" && type(config.route.rules) == "array" ? config.route.rules : null;
    if (rules == null) return { decided: false, reason: "singbox_config_unavailable" };
    for (let i = 0; i < length(rules); i++) {
        let r = rules[i];
        if (type(r) != "object") continue;
        if (r.inbound != null && index(list_of(r.inbound), tproxy_inbound) < 0) continue;
        let action = r.action || "route";
        if (action == "resolve") {
            if (!target.fakeip) continue;
            if (rule_matches(filter_keys(r, RESOLVE_KEYS), target) != "no") return { decided: false, reason: "resolve_rule", rule: i };
            continue;
        }
        if (action != "route" && action != "reject") continue;
        let m = rule_matches(r, target);
        if (m == "no") continue;
        if (type(m) == "object") return { decided: false, reason: m.reason, rule: i };
        if (action == "reject") return { decided: true, kind: "reject", rule: i };
        return { decided: true, kind: "outbound", outbound: r.outbound, rule: i };
    }
    return { decided: true, kind: "final", outbound: config.route.final || null, rule: null };
}

// The Forkop rule (config section) behind an outbound tag: <name>-out,
// <name>-out-<n>, <name>-urltest[-<id>]-out, <name>-<n>-out, ...
function section_for_outbound(sections, tag) {
    tag = as_string(tag);
    let best = null;
    for (let s in sections) {
        let name = as_string(s[".name"]);
        if (name == "" || substr(tag, 0, length(name) + 1) != name + "-") continue;
        if (match(tag, /-out(-[0-9]+)?$/) == null) continue;
        if (best == null || length(name) > length(as_string(best[".name"]))) best = s;
    }
    return best;
}

// { decided, kind: rule|bypass|block|direct|outbound, section, outbound, reason }
function resolve(config, sections, target, tags) {
    let route = route_owner(config, target, tags.tproxy_inbound);
    if (!route.decided) return { decided: false, reason: route.reason };
    if (route.kind == "reject") return { decided: true, kind: "block" };
    let outbound = as_string(route.outbound);
    if (outbound == tags.bypass) return { decided: true, kind: "bypass", outbound };
    if (route.kind == "final" && (outbound == "" || outbound == tags.direct))
        return { decided: true, kind: "direct", outbound: outbound || null };
    let section = section_for_outbound(sections, outbound);
    if (section != null) return { decided: true, kind: "rule", section, outbound };
    return { decided: true, kind: outbound == tags.direct ? "direct" : "outbound", outbound };
}

return { is_fakeip, rule_matches, route_owner, section_for_outbound, resolve };
