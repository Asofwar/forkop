#!/usr/bin/env ucode

let ip = require("core.ip");
let fs = require("fs");
function value(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(value(v), /'/g, "'\\''") + "'"; }
function command(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    let pipe = fs.popen(command(args), "r");
    if (!pipe) return { status: 1, output: "" };
    let output = pipe.read("all");
    let status = int(pipe.close());
    return { status: status > 255 ? int(status / 256) : status, output: value(output) };
}
function valid_host(host) {
    if (length(host) > 253 || host == "") return false;
    if (ip.valid_ip(host)) return true;
    if (match(host, /^[A-Za-z0-9.-]+$/) == null) return false;
    let labels = split(host, ".");
    if (length(labels) < 2) return false;
    for (let part in labels)
        if (length(part) < 1 || length(part) > 63 ||
            match(part, /^[A-Za-z0-9]/) == null || match(part, /[A-Za-z0-9]$/) == null)
            return false;
    return true;
}
function run(host, test_type, port, runner) {
    host = value(host); test_type = value(test_type); port = value(port);
    if (!valid_host(host) || index([ "DNS", "TCP", "TLS", "HTTP" ], test_type) < 0 ||
        (test_type != "DNS" && (match(port, /^[0-9]{1,5}$/) == null || int(port) < 1 || int(port) > 65535)))
        return { error: "invalid_input" };
    let started = clock();
    let args = test_type == "DNS" ? [ "timeout", "5", "nslookup", host ] :
        test_type == "TCP" ? [ "timeout", "5", "nc", "-z", "-w", "3", host, port ] :
        [ "timeout", "7", "curl", "-fsS", "--max-time", "5", "--output", "/dev/null",
            (test_type == "TLS" ? "https://" : "http://") + host + ":" + port + "/" ];
    let result = runner(args);
    let elapsed = clock();
    return { host, type: test_type, port: test_type == "DNS" ? null : int(port),
        status: result.status == 0 ? "ok" : result.status == 124 ? "timeout" : "error",
        latency_ms: int((elapsed[0] - started[0]) * 1000 + (elapsed[1] - started[1]) / 1000000),
        origin: "router" };
}
let mode = value(ARGV[0]);
if (mode != "test" && mode != "fixture") exit(1);
let response = run(ARGV[1], ARGV[2], ARGV[3], function(args) {
    return mode == "fixture" ? { status: int(ARGV[4] || 0) } : capture(args);
});
print(sprintf("%J\n", response));
exit(response.error != null ? 1 : 0);
