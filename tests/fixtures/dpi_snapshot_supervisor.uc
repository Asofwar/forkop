let fs = require("fs");
let child_pidfile = ARGV[4];
if (ARGV[0] != "supervisor" || child_pidfile == null)
    exit(2);
let command = "sleep 300 & echo $! > '" + child_pidfile + "'; wait";
system("sh -c '" + command + "'");
