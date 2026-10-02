// Writes the record singbox/ruleset_cache.uc keeps next to a binary list it
// stored and decompiled ("<list>.validated": stat signature and shape, see
// singbox/rulesets.uc), so a resolver test can use a binary list the way the
// cache leaves it. tests/routing_resolve_rule_set_shape.sh checks that the
// cache itself writes this record.
//
//   ucode -L <lib> rule_set_record.uc <list> [<source json>]
//
// The rules are read from <source json> (the list a real .srs was compiled
// from), else from the list itself in the stand-in's binary format
// (helpers/sing_box_rule_set_stub.uc: "SRS\n" + source JSON).
let fs = require("fs");
let rulesets = require("singbox.rulesets");

let list = ARGV[0];
let text = ARGV[1] != null ? fs.readfile(ARGV[1]) : substr(fs.readfile(list) || "", 4);
let value = null;
try { value = json(text); } catch (e) { value = null; }
if (fs.writefile(rulesets.binary_validation_path(list), rulesets.stat_signature(list) + "\n" + rulesets.list_shape(value) + "\n") == null)
    exit(1);
