#!/usr/bin/env ucode

let fs = require("fs");
let ip = require("core.ip");
let constants = require("core.constants");
let uci_core = require("core.uci");
let route_owner = require("core.route_owner");
let dpi_strategy = require("core.dpi_strategy");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constants.FORKOP_CONFIG_NAME || "forkop";
const LEGACY_CONNECTION_ACTIONS = [ "proxy", "outbound", "vpn" ];

function value(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(value(v), /'/g, "'\\''") + "'"; }
function command(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    // stderr (e.g. "RTNETLINK answers: Network unreachable") is not part of the result.
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return "";
    let data = pipe.read("all");
    return pipe.close() == 0 && data != null ? data : "";
}
function valid_domain(v) {
    if (length(v) > 253 || match(v, /^[A-Za-z0-9.-]+$/) == null)
        return false;
    let labels = split(v, ".");
    if (length(labels) < 2 || match(labels[length(labels) - 1], /^[A-Za-z]{2,63}$/) == null)
        return false;
    for (let label in labels)
        if (length(label) < 1 || length(label) > 63 ||
            match(label, /^[A-Za-z0-9]/) == null || match(label, /[A-Za-z0-9]$/) == null)
            return false;
    return true;
}
function valid_target(v) {
    return length(v) <= 253 && (ip.valid_ip(v) || valid_domain(v));
}
function valid_port(v) {
    return v == "" || (match(v, /^[0-9]{1,5}$/) != null && int(v) >= 1 && int(v) <= 65535);
}
function parse_address(text) {
    for (let line in split(text, "\n")) {
        line = trim(line);
        if (ip.valid_ip(line)) return line;
    }
    return "";
}
function route_interface(text) {
    let matched = match(" " + text, /[ \t]dev[ \t]+([A-Za-z0-9_.:-]+)/);
    return matched != null && length(matched[1]) <= 32 ? matched[1] : "";
}
function read_json(path) {
    let data = path == "" ? null : fs.readfile(path);
    try { return data == null ? null : json(data); } catch (e) { return null; }
}

// The Forkop rule, action, outbound and DPI strategy the generated sing-box
// config assigns to this connection. Calculated, not observed: Monitoring
// shows what real connections did.
function config_route(target, address, source, protocol, port) {
    let unknown = (reason) => ({
        rule: { value: null, provenance: "unknown", reason },
        action: { value: null, provenance: "unknown" },
        outbound: { value: null, provenance: "unknown" },
        dpi: { value: null, provenance: "unknown" }
    });
    if (!uci_core.available()) return unknown("config_unavailable");
    let sections = uci_core.section_objects(CONFIG_NAME, "section") || [];
    let config_path = value(uci_core.get(CONFIG_NAME + ".settings.config_path")) || "/etc/sing-box/config.json";
    let literal = ip.valid_ip(target);
    let owner = route_owner.resolve(read_json(config_path), filter(sections, (s) => value(s.enabled) != "0"), {
        host: literal ? "" : lc(target),
        ip: literal ? target : address,
        fakeip: address != "" && route_owner.is_fakeip(address),
        network: lc(protocol),
        port: port == "" ? 443 : int(port),
        source
    }, {
        tproxy_inbound: constants.SB_TPROXY_INBOUND_TAG || "tproxy-in",
        direct: constants.SB_DIRECT_OUTBOUND_TAG || "direct-out",
        bypass: constants.SB_BYPASS_OUTBOUND_TAG || "bypass-out"
    });
    if (!owner.decided) return unknown(owner.reason);

    let result = unknown(null);
    let calculated = (v) => ({ value: v, provenance: "simulated" });
    result.outbound = calculated(owner.outbound || null);
    if (owner.kind == "rule") {
        let action = value(owner.section.action);
        if (index(LEGACY_CONNECTION_ACTIONS, action) >= 0) action = "connection";
        result.rule = { value: value(owner.section.label) || owner.section[".name"],
            section: owner.section[".name"], provenance: "simulated" };
        result.action = calculated(action);
        if (dpi_strategy.is_dpi_action(action)) {
            let view = dpi_strategy.view(owner.section);
            result.dpi = { value: view.dpi_provider, strategy: view.dpi_strategy,
                strategy_custom: view.dpi_strategy_custom, provenance: "configured" };
        }
    }
    else {
        // No Forkop rule of its own: bypass list, block, or no rule matched.
        result.rule = { value: null, provenance: "simulated", reason: owner.kind == "direct" ? "no_rule_matched" : owner.kind };
        result.action = calculated(owner.kind);
    }
    return result;
}

function trace(target, source, protocol, port, resolve, route) {
    target = value(target); source = value(source); protocol = value(protocol); port = value(port);
    if (!valid_target(target) || (source != "" && !ip.valid_ip(source)) ||
        index([ "TCP", "UDP" ], protocol) < 0 || !valid_port(port))
        return { error: "invalid_input" };
    let address = ip.valid_ip(target) ? target : parse_address(resolve(target));
    let interface_name = address == "" ? "" : route(address);
    let routed = config_route(target, address, source, protocol, port);
    return {
        // A source address narrows source-scoped rules (source_ip_cidr).
        target: { value: target, source, source_applied: source != "", protocol, port, provenance: "simulated" },
        dns: { address: address || null, provenance: !address ? "unknown" : ip.valid_ip(target) ? "simulated" : "observed" },
        rule: routed.rule,
        action: routed.action,
        outbound: routed.outbound,
        dpi: routed.dpi,
        interface: { value: interface_name || null, provenance: interface_name ? "observed" : "unknown", context: "router" },
        runtime: { value: null, provenance: "unknown" }
    };
}

let mode = ARGV[0] || "";
let target = value(ARGV[1]);
let source = value(ARGV[2]);
let protocol = value(ARGV[3]);
let port = value(ARGV[4]);
let result = trace(target, source, protocol, port,
    function(host) {
        if (mode == "fixture") return value(ARGV[5]);
        let a = capture([ "dig", "+short", "+time=2", "+tries=1", host, "A" ]);
        return a != "" ? a : capture([ "dig", "+short", "+time=2", "+tries=1", host, "AAAA" ]);
    },
    function(address) {
        if (mode == "fixture") return route_interface(value(ARGV[6]));
        return route_interface(capture([ "ip", ip.valid_ipv6(address) ? "-6" : "-4", "route", "get", address ]));
    });
print(sprintf("%J\n", result));
exit(result.error != null ? 1 : 0);
