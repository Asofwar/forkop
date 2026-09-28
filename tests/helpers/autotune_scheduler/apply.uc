// Stand-in for autotune/apply.uc status: $STUB_APPLY_STATUS or a clean state.
let fs = require("fs");
if (ARGV[0] != "status") exit(1);
let data = fs.readfile(getenv("STUB_APPLY_STATUS"));
print(data != null ? data : sprintf("%J\n", { state: null, guards: [], snapshot_operation: false,
    service_action: null, autotune_lock_held: false }));
