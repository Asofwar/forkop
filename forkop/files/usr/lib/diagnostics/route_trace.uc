#!/usr/bin/env ucode

let fs = require("fs");
let ip = require("core.ip");

function value(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(value(v), /'/g, "'\\''") + "'"; }
function command(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    let pipe = fs.popen(command(args), "r");
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
function trace(target, source, protocol, port, resolve, route) {
    target = value(target); source = value(source); protocol = value(protocol); port = value(port);
    if (!valid_target(target) || (source != "" && !ip.valid_ip(source)) ||
        index([ "TCP", "UDP" ], protocol) < 0 || !valid_port(port))
        return { error: "invalid_input" };
    let address = ip.valid_ip(target) ? target : parse_address(resolve(target));
    let interface_name = address == "" ? "" : route(address);
    return {
        target: { value: target, source, source_applied: false, protocol, port, provenance: "simulated" },
        dns: { address: address || null, provenance: !address ? "unknown" : ip.valid_ip(target) ? "simulated" : "observed" },
        rule: { value: null, provenance: "unknown" },
        action: { value: null, provenance: "unknown" },
        outbound: { value: null, provenance: "unknown" },
        dpi: { value: null, provenance: "unknown" },
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
