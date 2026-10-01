// Read-only validation against the router's installed nftables and dnsmasq.
let fs = require("fs");
let dir = fs.popen("mktemp -d /tmp/forkop-vpn-check.XXXXXX", "r");
let path = trim(dir.read("all")) + "/";
if (dir.close() != 0) exit(1);
let p = json(fs.readfile("/etc/forkop/vpn-guard/policy.json"));
fs.writefile(path + "check.nft", p.nft);
if (system("nft -c -f " + path + "check.nft") != 0) exit(1);
for (let d in p.dns.profiles) {
    let conf = path + "dns-" + d.mask + ".conf";
    fs.writefile(conf, d.config + "port=" + (18053 + d.mask) + "\nlisten-address=127.0.0.1\n");
    if (system("dnsmasq --test --conf-file=" + conf) != 0) exit(1);
}
for (let name in fs.lsdir(path)) fs.unlink(path + name);
fs.rmdir(path);
print("PASS: router kernel nft parser and installed dnsmasq\n");
