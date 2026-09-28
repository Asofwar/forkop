// Stand-in for autotune/apply.uc:
//   status          $STUB_APPLY_STATUS or a clean state;
//   plan <sel> <r>  $STUB_TUNE_DIR/plan.json or a ready plan for the
//                   selection, owned by $STUB_PLAN_OWNER (default youtube);
//   apply <plan> <r> $STUB_TUNE_DIR/apply.json or "applied".
// plan and apply calls are logged to $STUB_TUNE_DIR/apply.log.
let fs = require("fs");
let dir = getenv("STUB_TUNE_DIR");
let read_json = (path) => { let d = fs.readfile(path); try { return d == null ? null : json(d); } catch (e) { return null; } };
let log = (line) => { let f = fs.open(dir + "/apply.log", "a"); f.write(line + "\n"); f.close(); };
let mode = ARGV[0];
if (mode == "status") {
    let data = fs.readfile(getenv("STUB_APPLY_STATUS"));
    print(data != null ? data : sprintf("%J\n", { state: null, guards: [], snapshot_operation: false,
        service_action: null, autotune_lock_held: false }));
}
else if (mode == "plan") {
    let sel = read_json(ARGV[1]);
    log(sprintf("plan %s %s %s", sel ? sel.target.host : "-", sel ? sel.selected : "-", ARGV[2]));
    let data = fs.readfile(dir + "/plan.json");
    print(data != null ? data : sprintf("%J\n", { status: "ready", selected: sel.selected, target: sel.target,
        owner: { decided: true, kind: "zapret", section: getenv("STUB_PLAN_OWNER") || "youtube" } }));
}
else if (mode == "apply") {
    let plan = read_json(ARGV[1]);
    log(sprintf("apply %s %s %s", plan ? plan.owner.section : "-", plan ? plan.selected : "-", ARGV[2]));
    let data = fs.readfile(dir + "/apply.json");
    print(data != null ? data : sprintf("%J\n", { status: "applied", reason: null, applied: true }));
}
else exit(1);
