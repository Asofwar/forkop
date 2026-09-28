# Ultracode audit: карточки находок

Приложение к [ULTRACODE_MASTER_PLAN.md](ULTRACODE_MASTER_PLAN.md). Исходный коммит аудита: `078720844608ef4bd9e6971231bacc5870fc9b98`. Каждая каноническая находка объединяет дубликаты из разных направлений аудита; поля первичной записи приведены полностью, для остальных — доказательства и заметки проверки. Поля карточек оставлены в исходной формулировке аудиторов (английский), заголовки — на русском.

Проверка: каждая находка P1/P2 перепроверена отдельным агентом, который пытался её опровергнуть и, где возможно, воспроизводил её локально (WSL, ucode, изолированный test runner). Вердикт и итоговая severity — в блоке «Verification». Пути `scratch/…` указывают на одноразовые скрипты воспроизведения вне репозитория.

<a id="uc-001"></a>

## UC-001 · P1 · S1 — rpcd file.exec принимает окружение от вызывающего: read-only роль через FORKOP_* запускает бинарники и читает/пишет файлы от root

**Severity:** P1<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** security<br>
**Sources:** security#0<br>
**Original title:** rpcd file.exec env table is caller-controlled and unfiltered; read-only role gains root file read/write/exec via FORKOP_* env overrides<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** rpcd file.c rpc_file_exec_run applies the env table with `setenv(blobmsg_name(cur), blobmsg_data(cur), 1)` and no name filtering (confirmed from upstream source). ACL grants file.exec of e.g. `/usr/bin/forkop get_ui_capabilities`, `global_check masked`, `get_system_info` to the read role (luci-app-forkop.json:5-75). The backend trusts env for both binary paths and file paths: service/ui.uc:25 `SING_BOX_BIN_PATH = getenv("FORKOP_UI_SING_BOX_BIN_PATH") || "/usr/bin/sing-box"` is then executed at :1012 `bounded_command_output_from_args([ SING_BOX_BIN_PATH, "version" ], ...)`; :22 `SING_BOX_VERSION_CACHE_FILE = getenv(...)` is written at :1013-1019. diagnostics/runtime.uc:14 `FORKOP_CONFIG = getenv("FORKOP_CONFIG") || ...` is printed by show_config (:860 masked branch) via global_check; :19 `SYSTEM_INFO_CACHE_FILE = getenv("FORKOP_SYSTEM_INFO_CACHE_FILE")` is written by get_system_info (write_system_info_cache:962).


**Reproduction:** scratch/audit-acl-secrets/env_exec_repro.sh (exec+write via ui capabilities), env_read_repro.sh (read /etc/shadow-shaped file via global_check masked), env_write_repro.sh (overwrite via get_system_info). All run under WSL ucode as the unprivileged user and print the executed marker / leaked contents / overwritten file.


**Expected:** A read-only session can only read the sanitized data the command was designed to expose; it cannot influence which binary runs or which file is read/written, and cannot reach files outside the intended set.


**Actual:** The read-only role, which must never mutate state or read secrets, can execute arbitrary root binaries, overwrite arbitrary root-owned files, and read arbitrary files (including /etc/shadow, raw sing-box config with credentials) by supplying FORKOP_*/PATH env vars to an allowed read command.


**Impact:** Full breach of the read-only boundary and of safety invariants 1 and 2: a low-privilege delegated LuCI reader (or anything that can reach the file ubus object with these command patterns) gets root arbitrary file read (secret leak), arbitrary file write (persistence/privilege escalation via crontab, init scripts, LKG/snapshot corruption) and arbitrary existing-binary execution. This also lets a caller point the recovery/LKG machinery at attacker paths, threatening invariants 3 and 6.


**Root cause:** rpcd's file.exec passes an unfiltered caller-supplied environment to the child, and the backend derives executable paths and read/write file paths from that same environment (getenv fallbacks intended only for tests/packaging) without distinguishing a trusted invocation from an rpcd-delegated one. The ACL's per-command argument allow-list controls argv but not envp.


**Affected files:** `forkop/files/usr/bin/forkop`, `forkop/files/usr/lib/service/ui.uc`, `forkop/files/usr/lib/diagnostics/runtime.uc`, `luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json`

**Dependencies:** Interacts with every RO-reachable command; the safest scoping is at the CLI entry (forkop/files/usr/bin/forkop run_spec) so all delegated commands are covered at once.


**Proposed fix:** Do not trust the process environment for security-relevant paths on rpcd-reachable entry points. Either (a) have the forkop CLI/wrappers scrub or ignore FORKOP_*/TMP_*/PATH overrides for the read-facing commands (e.g. only honour them when an explicit FORKOP_TEST/dev marker is set, which rpcd cannot pass because the ACL command patterns are fixed), or (b) hard-code production paths in a non-overridable constants layer for the diagnostics/ui read commands and keep env overrides only in test harness code. Minimal fix: strip the env in the file.exec-invoked commands (re-exec with a fixed environment) before loading any module. product_decision on which override-suppression strategy, but the boundary breach itself is a defect.


**Tests needed:** A test that runs an allowed read command with a hostile env (FORKOP_UI_SING_BOX_BIN_PATH / FORKOP_CONFIG / FORKOP_SYSTEM_INFO_CACHE_FILE pointing at a marker path) and asserts the marker binary is NOT executed and the marker file is NOT read or written. Ideally an rpcd session-level test with a real read-only role confirming file.exec strips or ignores env.


**Risk:** Suppressing env overrides could break the backend test harness or packaging steps that rely on them; the fix must keep an explicit, rpcd-unreachable opt-in for those.


**Verification:** confirmed → P1

**Verification evidence:**

The whole chain holds on commit 07872084, and each link was checked.
1. rpcd (upstream openwrt/rpcd file.c, master) declares `[RPC_E_ENV] = { .name = "env", .type = BLOBMSG_TYPE_TABLE }`. The ACL check in rpc_file_exec_run first tries `rpc_file_access(sid, executable, "exec")`. If that fails it builds `cmdstr` from the executable and its params and checks that string. The child then runs `setenv(blobmsg_name(cur), blobmsg_data(cur), 1)` for every string in env. Env names are never filtered and the ACL never looks at env.
2. The ACL (luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json:4-73) grants the read role `"ubus": {"file": ["exec"]}` plus per-argv patterns, including `/usr/bin/forkop get_ui_capabilities` (:12), `/usr/bin/forkop get_system_info` (:11) and `/usr/bin/forkop global_check masked` (:71). The per-argv narrowing was the F-001 fix, which means the read role is a deliberate security boundary.
3. The dispatcher forkop/files/usr/bin/forkop:10 has `LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop"`. run_spec (:241-254) runs `system("ucode -L LIB_DIR module ...")`, so the whole env, PATH included, passes to the module and the dispatcher does no scrubbing. Routes: :188 get_system_info -> diagnostics/runtime.uc, :189 get_ui_capabilities -> service/ui.uc, :214 global_check -> runtime.uc global-check.
4. service/ui.uc:25 `SING_BOX_BIN_PATH = getenv("FORKOP_UI_SING_BOX_BIN_PATH") || "/usr/bin/sing-box"` is executed at :1012 `bounded_command_output_from_args([ SING_BOX_BIN_PATH, "version" ], ...)`. The result is written to :22 `SING_BOX_VERSION_CACHE_FILE = getenv("FORKOP_UI_SING_BOX_VERSION_CACHE_FILE")` via write_state_file at :1014.
5. diagnostics/runtime.uc:14 `FORKOP_CONFIG = getenv("FORKOP_CONFIG") || ...`. global_check (:2041) calls show_config(visibility) at :2091, which prints `status_output([ "forkop-config-masked", FORKOP_CONFIG ])` (:863). forkop_config_masked (diagnostics/status.uc:406-437) masks only known UCI option/list tokens and prints every other line verbatim, so a non-UCI file such as /etc/shadow comes out unmasked.
6. runtime.uc:19 `SYSTEM_INFO_CACHE_FILE = getenv("FORKOP_SYSTEM_INFO_CACHE_FILE")`. write_system_info_cache (:962-973) writes a tmp file next to that path, runs remove_file(target) and then fs.rename, which replaces any path with the system-info JSON.
No guard, dev marker or env allow-list exists anywhere between rpcd and these getenv calls.


**Verification reproduction:**

I wrote scratch/audit-verify-rpcd-env/repro.sh and ran it in WSL as uid 1000 with a private mktemp -d, using the real CLI `ucode forkop/files/usr/bin/forkop <cmd>` with FORKOP_LIB pointing at the worktree lib. Observed output:
(1) get_ui_capabilities with FORKOP_UI_SING_BOX_BIN_PATH=$T/evil and FORKOP_UI_SING_BOX_VERSION_CACHE_FILE=$T/victim_cron gave rc=0 and "evil.ran: EVIL_EXECUTED args=version". The victim file's original content was replaced by `{ "signature": ..., "success": true, "version": "1.12.0", ... }`.
(2) global_check masked with FORKOP_CONFIG=$T/shadow gave rc=0 and output line 37 was `root:$6$SECRETHASH$abc:19000:0:99999:7:::`, printed verbatim.
(3) get_system_info with FORKOP_SYSTEM_INFO_CACHE_FILE=$T/passwd gave rc=0 and the file was replaced with `{ "forkop_version": ..., ... }`.
I confirmed the rpcd env passthrough and the argv-only ACL check against upstream rpcd file.c (quoted above). No real rpcd session was run, because that needs a router. The rpcd link is proven statically from its source. LuCI's own fs.exec(command, params, environ) API also exposes this env parameter to clients.


**Verification notes:**

Severity P1 stands. It breaks the read-role boundary the project set up in F-001 and invariants 1 (the RO role mutates files) and 2 (arbitrary secret read, including raw /etc/config/forkop via FORKOP_CONFIG=/etc/config/forkop and /etc/shadow). Precondition: an authenticated LuCI/rpcd session holding the luci-app-forkop read grant but not write. The default root-only OpenWrt install has no such user, so exposure depends on delegated accounts, the same threat model as F-001.

Corrections and narrowing:
- The write primitive only drops Forkop-generated JSON (a version cache or system info). The attacker picks the path but not the content. "Persistence/privilege escalation via crontab" is therefore overstated. The real impact is arbitrary root-file clobber/corruption: /etc/crontabs/root, /etc/passwd, /etc/config/*, LKG/snapshot files. That means DoS, broken recovery and a possible lockout, still P1 (corrupt persistent state, recovery failure).
- The exec primitive runs any existing binary with the single argument "version" (e.g. /sbin/reboot version is likely a DoS). It is not arbitrary code unless a file is planted.
- The finding understates the surface. FORKOP_LIB in the dispatcher (usr/bin/forkop:10) and PATH (run_spec calls system("ucode ...") via sh) also move module/interpreter lookup, and dozens of other getenv path overrides exist (e.g. ui.uc:13 FORKOP_UI_STATE_DIR, runtime.uc:18 FORKOP_RUNTIME_STATE_DIR, SECTION_CACHE_DIR, TMP_SING_BOX_FOLDER). All of them are reachable from every RO-allowed command.
- LD_PRELOAD through the same rpcd env is an upstream rpcd property that affects every exec grant. It needs a planted .so and is out of scope here, but no Forkop-level fix can fully close it.

Better minimal fix, instead of an env-marker opt-in: rpcd can set any env name, so an env-based "test mode" marker is not safe. Choose one of these:
(a) Point the read-role ACL entries at a tiny RO wrapper, e.g. /usr/libexec/forkop-ro with the same argv allow-list. It execs `env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/forkop "$@"`. rpcd authorizes by executable path, so the RO role can only reach the scrubbed entry. Tests keep calling /usr/bin/forkop with overrides. The write role is root-equivalent anyway.
(b) Have the dispatcher ignore FORKOP_*/TMP_* overrides unless a root-owned file marker exists (e.g. under the test harness root), and run modules via `env -i` with a fixed PATH.
Option (a) is the smallest change and keeps the test harness intact. Add a regression test that invokes the RO entry with hostile FORKOP_CONFIG, FORKOP_UI_SING_BOX_BIN_PATH and FORKOP_SYSTEM_INFO_CACHE_FILE and asserts that nothing is executed, read or written. Also add an ACL test that every read-role file.exec entry targets the scrubbing wrapper. No existing test pins the current behaviour. The overrides are used heavily by tests/*.sh via direct CLI calls, so these fixes do not break them.

Correct line refs: ui.uc:13/22/25/1012/1014; runtime.uc:14/19/863/962-973/2091; status.uc:406-437; forkop CLI :10, :188-189, :214, :241-254; ACL :4-73.


---

<a id="uc-002"></a>

## UC-002 · P1 · S1 — global_check masked (доступен read-only) раскрывает list outbound_jsons, WAN-учётки l2tp/pptp и токены в URL списков

**Severity:** P1<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** uci-global<br>
**Sources:** uci-global#0, security#1, uci-rules#2<br>
**Original title:** global_check masked (read-only ACL) leaks proxy credentials from 'list outbound_jsons', and token URLs from list options<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** luci-app-forkop.json:74 "/usr/bin/forkop global_check masked": ["exec"] (read ACL); readonlyCommandGuard.ts:53 allows it for RO. diagnostics/runtime.uc:2091 show_config(visibility) -> status.uc forkop-config-masked. status.uc:351-404 is a denylist; its only JSON token is status.uc:358 `mask_after_token_space(line, "option outbound_json")`, and 'list outbound_jsons' (the live storage: section.js:7193, connections.uc:334) is never masked. The frontend mirror maskDiagnostics.ts:32-80 has the same gap. Migration moves secrets from masked into unmasked fields: migration.uc:848 outbound_json -> outbound_jsons, and migration.uc:1249-1255/1303 converts http://user:pass@ links (masked selector_proxy_links) into outbound_jsons with username/password.


**Reproduction:** wsl bash scratch/audit-a3/masked_config.sh


**Expected:** No credential, token or private path reaches the RO role or masked diagnostics.


**Actual:** Scratch repro (audit-a3/masked_config.sh) prints SECRET-OUTBOUND-PASS, SECRET-RULESET, SECRET-LIST-TOKEN and SECRET-RESOLVER unmasked. yacd_secret_key, selector_proxy_links and url are masked.


**Impact:** Invariant 2 violation. A read-only LuCI user (or anyone the admin sends a 'masked' diagnostic to) sees JSON outbound passwords, UUIDs and keys, credentials inside list URLs, and private DoH paths. Raw DPI strategies are also shown, which contradicts core/dpi_strategy.uc ('raw option text never leaves the admin role').


**Root cause:** The denylist of option names was written for the legacy single 'option outbound_json' and was not extended when storage moved to 'list outbound_jsons'. URL-valued list options were never considered.


**Affected files:** `forkop/files/usr/lib/diagnostics/status.uc`, `fe-app-forkop/src/forkop/tabs/diagnostic/helpers/maskDiagnostics.ts`, `luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json`, `tests/diagnostics_status.sh`

**Dependencies:** Probably overlaps with the ACL/secrets auditor; consolidate there.


**Proposed fix:** Minimal fix: in both status.uc forkop_config_masked_line and maskDiagnostics.ts, mask 'list outbound_jsons' like 'option outbound_json' (including the multi-line continuation handling at status.uc:432). Mask the userinfo and query of URL values in list rule_set/rule_set_with_subnets/remote_domain_lists/remote_subnet_lists/domain_ip_lists, and mask domain_resolver_dns_server paths. Better: switch the masked config to an allowlist of safe option names (as snapshots.uc safe_value does) so new secret-bearing options fail closed.


**Tests needed:** Extend tests/diagnostics_status.sh (and the maskDiagnostics tests) with list outbound_jsons carrying password/uuid/private_key, a multi-line JSON value, rule_set with userinfo, remote list with ?token=, and domain_resolver_dns_server with a path. Assert that no secret substring appears.


**Risk:** Low: masking only affects diagnostic text.


**Verification:** confirmed → P1

**Verification evidence:**

- The read-only boundary is real. The read ACL gives RO users `"/usr/bin/forkop global_check masked": ["exec"]` (luci-app-forkop.json:74). The same ACL does NOT give RO users uci read on `forkop`: the `uci: ["forkop"]` grant sits only under `write` and under the separate `luci-app-forkop-admin` role. So the masked global check is the only way an RO user sees the config, and the RO user can call it directly through ubus `file exec`. That means the frontend mask is not a boundary; the backend masking is.
- Call path: runtime.uc:2042-2044 picks visibility, runtime.uc:2091 calls `show_config(visibility)`, and runtime.uc:863 runs `status_output([ "forkop-config-masked", FORKOP_CONFIG ])`. That lands in status.uc:1727 `forkop_config_masked`, which calls `forkop_config_masked_line` (status.uc:351-404).
- The masking is a denylist. Its only JSON entry is status.uc:358 `mask_after_token_space(line, "option outbound_json")`. The token `option outbound_json` never appears inside a `list outbound_jsons ...` line, so these lines pass through unchanged. The multi-line continuation skip at status.uc:432 (`index(line, "option outbound_json")`) has the same gap, so continuation lines of a multi-line `list outbound_jsons` JSON value are printed too.
- `list outbound_jsons` is the live storage: connections.uc:334 `outbound_jsons(section)`, generator.uc:2213, validator.uc:1275, section.js:7193, and migration.uc:848 `normalize_connections_list(ctx, section, "outbound_json", "outbound_jsons")`.
- Migration moves credentials out of a masked field into this unmasked one. migration.uc:1249-1255 copies the `user:pass` part of http links into `outbound.username` / `outbound.password`. migration.uc:1303 then writes them to `outbound_jsons` and deletes them from `selector_proxy_links`, which is masked at status.uc:357.
- No mask covers `list rule_set`, `rule_set_with_subnets`, `remote_domain_lists`, `remote_subnet_lists`, `domain_ip_lists`, `option domain_resolver_dns_server` or `nfqws_opt`.
- The frontend helper maskDiagnostics.ts has the same gaps: FORKOP_MASK_AFTER_TOKEN_SPACE lists only 'option outbound_json'.
- No test pins masking of `outbound_jsons`: tests/diagnostics_status.sh:72 exercises forkop-config-masked but never with `outbound_jsons`.


**Verification reproduction:**

I wrote scratch/audit-verify-masked-outbound-jsons/repro.sh, which uses a private mktemp -d config. It runs `ucode -L $LIB $LIB/diagnostics/status.uc forkop-config-masked <cfg>` in WSL, the same entry point show_config("masked") uses.

Output:
- Masked correctly: yacd_secret_key, selector_proxy_links and legacy `option outbound_json`.
- Printed unmasked:
  - SECRET-UUID-1111 and SECRET-PBK (single-line `list outbound_jsons`)
  - SECRET-MULTILINE-PASS (continuation line of a multi-line `list outbound_jsons`)
  - SECRET-RULESET (`list rule_set 'https://user:SECRET@...'`)
  - SECRET-LIST-TOKEN (`list remote_domain_lists '...?token=...'`)
  - SECRET-RESOLVER (`option domain_resolver_dns_server 'https://doh.example/SECRET'`)
  - SECRET-NFQWS-MARKER (`option nfqws_opt`)

This is a static plus local-runtime proof. No router was needed, because the RO ACL grant and the dispatch into this function are fixed in the code.


**Verification notes:**

The finding is confirmed as stated, and all cited line refs are accurate (status.uc:358 and :432, ACL line 74, readonlyCommandGuard.ts:53, migration.uc:848/1249-1255/1303). P1 stands under invariant 2 (a secret reaches the RO role). The main leak is outbound_jsons: passwords, UUIDs, reality keys and any credentials that migration moved in from http links.

Corrections and scope:
1. The frontend maskDiagnostics.ts gap matters only for the admin "mask values" toggle, i.e. when an admin shares diagnostics. It is not part of the RO boundary: RO receives text the backend already masked and can call the command directly. The backend fix is the one that closes the boundary.
2. The URL-list items (rule_set, remote_*_lists, domain_ip_lists, domain_resolver_dns_server) are secrets only when the user embeds userinfo or tokens. They are weaker than outbound_jsons, but still under invariant 2.
3. nfqws_opt / zapret2 / byedpi_cmd_opts are not credentials. They only contradict the design claim in core/dpi_strategy.uc:5 ("raw option text never leaves the admin role"). That part is P3-level on its own.
4. Other RO paths that expose outbound_jsons, such as config_snapshot_diff and get_readonly_config_sections, were not checked here and belong with the ACL/secrets auditor.

Minimal fix, in status.uc:
- Add `line = mask_after_token_space(line, "list outbound_jsons");`. The exact token plus the required-space check will not collide with other names.
- Extend the multi-line guard at status.uc:432 to also trigger on `list outbound_jsons`.
- Mask the userinfo and query parts of URL values in the listed rule_set/remote list options and domain_resolver_dns_server. `mask_option_path` can be reused for the path.
- Mirror the same changes in maskDiagnostics.ts.
- Add cases to tests/diagnostics_status.sh (single-line and multi-line outbound_jsons, rule_set userinfo, list ?token=, resolver path) and to the maskDiagnostics tests.

The longer-term move to an allowlist (as snapshots.uc safe_value does) would fail closed per invariant 18, but it is a larger change.


### Also reported as security#1 (P1): global_check masked leaks JSON outbound secrets and l2tp/pptp WAN credentials to read-only and masked-view users

**Evidence:** ACL grants `/usr/bin/forkop global_check masked` to the read role (luci-app-forkop.json:74). global_check(masked) calls show_config(masked) -> forkop-config-masked (diagnostics/runtime.uc:2091,854-863) and wan-config-masked (:2109). forkop_config_masked_line (diagnostics/status.uc:351-405) masks `option outbound_json` (single, :358) but there is NO token for `list outbound_jsons`; the multiline follow-up handler at :430-436 only arms on `option outbound_json`. So a `list outbound_jsons` value (the shape the current LuCI UI and migration write - section.js:7193, config/connections.uc:334-343) is printed verbatim. wan_config_masked (status.uc:258-300) only masks proto static/pppoe/wireguard; for proto l2tp/pptp/3g/wwan the username/password lines fall through the final `else print(line)`.


**Proposed fix:** Add `mask_after_token_space(line, "list outbound_jsons")` plus multiline arming for it, mirroring `option outbound_json`, in both diagnostics/status.uc forkop_config_masked_line and fe-app-forkop maskDiagnostics.ts FORKOP_MASK_AFTER_TOKEN_SPACE. For WAN, mask username/password/private_key for any proto (or add l2tp/pptp/pppoe/3g/wwan/modemmanager) rather than an allow-list of three. Prefer masking JSON structurally (reuse mask_sing_box_value keys) over line prefixes.


**Verification:** confirmed → P1

**Verification notes:**

The finding is confirmed and I found no guard that refutes it.

**Severity: P1 stands.** It breaks invariant 2 (secrets must not reach the read-only path), and the ACL makes it reachable by the read-only role.

**Precision on the WAN half:**
- In the LuCI read-only modal, initialMaskValues defaults to true (renderModal.ts:37). maskGlobalCheckText then applies the generic 'option username' / 'option password' tokens, so the WAN credentials are hidden on screen.
- The backend is the real boundary, though. A read-only session can call file.exec `/usr/bin/forkop global_check masked` directly over ubus/JSON-RPC and gets cleartext.
- For outbound_jsons there is no mitigation at all: the secrets also show up in the read-only UI.
- maskSupportReportText (maskDiagnostics.ts:241) reuses maskGlobalCheckText, so any support-report path that includes the config probably has the same outbound_jsons gap. This is inferred; I did not trace that caller.

**Line refs:** accurate. The multiline arming is at status.uc:432; the finding cites 430-436, which is fine.

**Minimal fix:**
1. In status.uc, add `line = mask_after_token_space(line, "list outbound_jsons");` next to :358, and arm multiline when `index(line, "list outbound_jsons") >= 0` at :432. Pretty-printed JSON in a list value spans several lines, so its continuation lines must be masked too.
2. Mirror both changes in maskDiagnostics.ts: add the token to the list and add the check at :228.
3. For wan_config_masked, mask username/password/private_key/key/pincode for any proto instead of the three-proto allow-list, or at least add l2tp/pptp/pppoa/3g/qmi/ncm/modemmanager. 'option pincode' for modem protos is also unmasked in both layers; that is a minor variant.
4. Add regression cases to tests/diagnostics_status.sh: a `list outbound_jsons` entry carrying uuid and private_key, and an l2tp WAN interface.

**Non-issue:** the risk note about hiding the tag/type is minor. The option 'outbound_json' form is already masked whole, and the UI reads dashboard names from other RPCs, not from the global_check text.

**product_decision:** false.


### Also reported as uci-rules#2 (P1): list outbound_jsons credentials unmasked in 'global_check masked' / 'show_config' (read-only role) and in the frontend mask

**Evidence:** forkop/files/usr/lib/diagnostics/status.uc:351-404 forkop_config_masked_line masks `option outbound_json` (358) but has no rule for `list outbound_jsons`. fe-app-forkop/src/forkop/tabs/diagnostic/helpers/maskDiagnostics.ts:53 has only 'option outbound_json'. diagnostics/runtime.uc:2089-2091 global_check prints show_config(visibility), which is status_output forkop-config-masked (runtime.uc:854-865). The ACL read (read-only) group grants "/usr/bin/forkop global_check masked" (luci-app-forkop.json read.file). initController.ts:563-585 offers Global check in read-only mode. migration.uc:1231-1307 migrate_http_connection_urls moves user:pass from selector_proxy_links (masked by `list selector_proxy_links`) into outbound_jsons username/password.


**Proposed fix:** Add `list outbound_jsons` (whole value) to forkop_config_masked_line and to FORKOP_MASK_AFTER_TOKEN_SPACE in maskDiagnostics.ts. Prefer turning the forkop-config mask into an allowlist, like snapshots.uc safe_value. Also consider masking `option domain` / `option ip_cidr` text: only the list forms are masked today, although the current UI writes option text.


**Verification:** confirmed → P1

**Verification notes:**

The line references are accurate. Severity stays P1: this is a secret leak across the read-only boundary and breaks invariant 2. The only real fix is in the backend. The frontend maskDiagnostics.ts change only affects the admin 'masked' view and the support-report copy, because the read-only RPC response already contains the secret. Minimal fix:
1. In status.uc forkop_config_masked_line, add `line = mask_after_token_space(line, "list outbound_jsons");`.
2. In forkop_config_masked, extend the multiline check to `index(line, "outbound_json") >= 0` (or check both tokens). A pretty-printed JSON value pasted into the DynamicList textarea is stored with embedded newlines, so without this its continuation lines would still leak after fix 1.
3. Mirror both changes in maskDiagnostics.ts: add FORKOP_MASK_AFTER_TOKEN_SPACE 'list outbound_jsons' and extend the `line.includes('option outbound_json')` multiline trigger.
4. Add tests: diagnostics_status.sh with single-line and multiline `list outbound_jsons` secrets, and a vitest for maskGlobalCheckText.
Turning the whole list into an allowlist is a sound hardening, but it is not required for this fix. The suggestion to mask `option domain`/`option ip_cidr` is a separate privacy item (not credentials) and should be verified separately, not merged into this P1. Variant worth checking separately: the read group also grants `show_sing_box_config masked`, and the generated sing-box config contains these same outbounds. It is out of scope for this verification.


---

<a id="uc-003"></a>

## UC-003 · P1 · S2 — Редактор правила стирает фильтр устройств (source_ip_cidr), если условия заданы только Built-in rule sets #2 или legacy remote lists

**Severity:** P1<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#0<br>
**Original title:** Rule editor erases Device filter (source_ip_cidr) when conditions come only from Built-in rule sets #2 or legacy remote lists; rule widens to all devices<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** luci-app-forkop/.../forkop/section.js:155-163 `const routingConditions = ["domain","ip_cidr","community_lists","rule_set","domain_ip_lists","ports"]` has no "secondary_rule_sets". section.js:7781-7788 `const sourceIpOption = addLocalDeviceSubnetDynamicField(...); dependsOnRuleConditions(sourceIpOption);` has no retain. addLocalDeviceSubnetDynamicField (section.js:6492-6535) has no custom remove, so LuCI's `else if (!this.retain) return this.remove(section_id)` applies (luci-base form.js AbstractValue.parse). getCustomRulesetReferences (section.js:6680-6690) strips b4geoip URLs out of the rule_set widget and into secondary_rule_sets. The secondary widget was added in c06cfc97 (2026-08-26), after b95aaf02 introduced the dependency. Backend honours the filter: generator.uc:2987 `let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr")` feeds rule_set_rule.source_ip_cidr (generator.uc:3070-3077), and nft/apply.uc:707-717 adds `ip saddr @sources`.


**Reproduction:** LuCI: rule with Built-in rule set #2 = Valve and Device filter 192.168.1.50 (set before 1.1.2, via CLI, or as a custom b4geoip URL). Open the rule, change the label, Save, then Save & Apply. The grid 'Devices' column changes from 'Only: 1' to 'All devices'. Scratch: node rt_rule.js secondary_only_device_filter.


**Expected:** Saving a rule without touching the device fields keeps source_ip_cidr. The Device filter is available whenever the rule has any destination condition the backend honours.


**Actual:** Harness scratch/audit-a3/rt_rule.js runs the real section.js. An unchanged modal save of {action:connection, rule_set_with_subnets:[mirror .../b4geoip-forkop/srs/valve.srs], source_ip_cidr:[192.168.1.50]} gives `source_ip_cidr: ["192.168.1.50"] -> undefined`. The same happens with google.srs, remote_domain_lists (action block) and remote_subnet_lists. gen_check.sh block_secondary_device emits a reject rule with source_ip_cidr [192.168.1.50]; after the loss the same rule has no source_ip_cidr and applies to all clients.


**Impact:** A per-device rule silently becomes a rule for every LAN device after any modal save (rename, enable toggle in the modal, domain edit). For example, 'route Valve via VPN only for the gaming PC' or 'block for kids' tablet' turns into VPN/block for everyone. The Device filter is also unavailable in the UI for rules that use only Built-in rule sets #2, even though the backend supports it.


**Root cause:** The visibility dependency list was not updated when the Built-in rule sets #2 widget took b4geoip URLs out of the rule_set widget. Conditionally hidden options without retain are erased by LuCI parse().


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `tests/dns_action_ui.sh`, `tests/luci_hidden_rule_options.sh`

**Proposed fix:** In dependsOnRuleConditions add "secondary_rule_sets" to routingConditions. Also set `sourceIpOption.retain = true` as defense in depth, so a hidden device filter is never erased (the backend ignores source_ip_cidr without destination matchers). Consider also treating legacy remote_domain_lists/remote_subnet_lists as a condition, or showing them.


**Tests needed:** Extend luci_hidden_rule_options-style round trip: rule with only secondary b4geoip set + source_ip_cidr, and with only remote_domain_lists + source_ip_cidr, modal save keeps source_ip_cidr. dns_action_ui.sh: dependency list includes secondary_rule_sets.


**Risk:** Low. retain only keeps a stored value. Showing the field for secondary-only rules is a UI addition.


**Verification:** confirmed → P1

**Verification evidence:**

Checked in worktree 07872084 (<tree>).

1. luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js:155-178. The list `const routingConditions = ["domain","ip_cidr","community_lists","rule_set","domain_ip_lists","ports"]` does not include "secondary_rule_sets". There is also no key for remote_domain_lists or remote_subnet_lists, because those have no UI option.

2. section.js:7781-7788. `const sourceIpOption = addLocalDeviceSubnetDynamicField(...); dependsOnRuleConditions(sourceIpOption);` sets no `retain`. Neither addLocalDeviceSubnetDynamicField (section.js:6492-6535) nor makeDeviceOptionsExclusive (section.js:3891) defines `remove`. That means the default AbstractValue.remove runs and unsets `source_ip_cidr`. Compare the neighbouring options: ruleSetOption, domainIpListsOption, dnsRuleSetOption and dnsDomainListsOption all set `retain = true`.

3. The `rule_set` dependency is evaluated against the formvalue of the custom rule_set widget. Its load is getCustomRulesetReferences (section.js:6725-6734). That function drops every `rule_set_with_subnets` entry for which `secondaryRulesetId(value)` is truthy. So for a rule whose only condition is a b4geoip set, the formvalue is [].

4. I checked LuCI form.js (luci-base copy in scratch/audit-a3/form.js):
   - isEqual (line 1287): `y.test(x)` on [] becomes "", which fails /\S/.
   - isDependencySatisfied (lines 751-781) therefore returns false for every entry, so the field gets the hidden class and isActive() is false.
   - AbstractValue.parse (lines 2075-2076): `else if (!this.retain) return Promise.resolve(this.remove(section_id));`
   - GridSection.cloneOptions (line 3517) clones modalonly options into the modal map, so the modal save parses sourceIpOption.

5. The backend honours the filter. forkop/files/usr/lib/singbox/generator.uc:2988 has `let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr")`. For b4geoip refs (via connections.rule_sets_with_subnets) and for remote_domain_lists/remote_subnet_lists (via add_remote_list_rulesets), generator.uc:3060-3078 builds rule_set_rule with `rule_set_rule.source_ip_cidr = source_ip_cidr`. nft/apply.uc:707-717 (nft_source_match_args) adds `ip saddr @sources`, and nft/apply.uc:633-637 counts remote_subnet_lists and rule_sets_with_subnets as nft IP matchers. Once the value is erased, the rule matches every LAN client.

6. History: `git log -S dependsOnRuleConditions` points to b95aaf02 (2026-07-18). `git log -S secondaryRulesetId` points to c06cfc97 (2026-08-26, "Prepare release 1.1.2"), which is when the stripping out of the rule_set widget was added. The dependency list was never updated after that.

7. No test covers this. tests/luci_hidden_rule_options.sh and tests/dns_action_ui.sh never mention secondary_rule_sets, and `rg secondary_rule_sets tests` returns nothing.


**Verification reproduction:**

I ran the auditor's harness myself, read-only, with Windows node: `WT=<tree> node scratch/audit-a3/rt_rule.js <case>`. It loads the real section.js and the generated main.js. It emulates the LuCI modal load, then parses with the Map.isDependencySatisfied, isEqual and AbstractValue.parse semantics. I compared those semantics against the luci-base form.js copy.

Results:
- secondary_only_device_filter (connection, valve.srs in rule_set_with_subnets, source_ip_cidr 192.168.1.50): `source_ip_cidr: ["192.168.1.50"] -> undefined`.
- secondary_only_excluded_devices (google.srs): source_ip_cidr erased.
- remote_list_device_filter (block, remote_domain_lists): source_ip_cidr erased.
- remote_subnet_device_filter: source_ip_cidr erased.
- Control community_device_filter (community_lists youtube): unchanged.
- Control fully_routed_only_with_source (custom non-b4geoip rule_set_with_subnets): source_ip_cidr kept.
- secondary_only_device_filter_bypass: excluded_source_ip_cidr kept, because excludedSourcesOption depends only on the action.

I did not do a LuCI browser run on a real router. The static proof against form.js together with the harness is enough, since no router-side code is involved in the loss.

There is also a realistic trigger that uses only the current UI:
1. Add a b4geoip URL as a custom rule set with "include subnets" and set a Device filter. The first save keeps it, because the rule_set widget still holds the value.
2. On the next open, secondaryRulesetId moves the URL into the "Built-in rule sets #2" widget. The rule_set widget is now empty and the Device filter is hidden.
3. Any later modal save erases source_ip_cidr.

Rules from before 1.1.2 with a b4geoip URL and a device filter, and legacy remote_*_lists rules, hit the same path on their first modal save after upgrade.


**Verification notes:**

Verdict: confirmed. I keep P1. A saved user setting is silently lost, and the result changes network behaviour for other LAN devices: a device-scoped block or VPN route becomes global, and a block can cut traffic for everyone. The trigger is narrow, though: it needs a device filter on a rule whose only destination conditions are b4geoip secondary sets or legacy remote_*_lists. If you weight reachability heavily, P2 would also be defensible.

Corrections:
- The backend path is forkop/files/usr/lib/singbox/generator.uc, not sing-box/. The source_ip_cidr line is 2988 (the finding says 2987). rule_set_rule.source_ip_cidr is at 3075-3076.
- The line ranges given for dependsOnRuleConditions (155-178) and getCustomRulesetReferences (6725-6734) are slightly off. The substance is correct.

Minimal fix:
(a) Add "secondary_rule_sets" to routingConditions in dependsOnRuleConditions. lookupOption resolves it, because the option is named secondary_rule_sets (section.js:7655) and has no depends of its own, so it is always active.
(b) Set `sourceIpOption.retain = true`. This is required for remote_domain_lists/remote_subnet_lists, which have no UI option to depend on, and it guards against future widget splits.

With retain, a device filter hidden because the user removed every destination condition stays stored but is harmless. The generator emits no route rule without matchers (has_route_matchers is false and rule_set_tags is empty). nft_source_match_args only extends destination-matched rules. makeDeviceOptionsExclusive still works on the hidden live widget.

Optional: show legacy remote_*_lists in the UI (display only).

Tests:
- Round-trip in luci_hidden_rule_options.sh style: a rule with only a b4geoip secondary set plus source_ip_cidr, and a rule with only remote_domain_lists or remote_subnet_lists plus source_ip_cidr. An unchanged modal save must keep source_ip_cidr.
- A check in dns_action_ui.sh that secondary_rule_sets is in the dependency list.

product_decision=false. hardware_required=false.


---

<a id="uc-004"></a>

## UC-004 · P1 · S2 — Модалка настроек rule set («Включить IP и подсети») удаляет из правила все Built-in rule sets #2

**Severity:** P1<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#1<br>
**Original title:** Rule-set settings modal ('Include IP addresses and subnets') deletes all Built-in rule sets #2 from the rule<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** section.js:3620-3644 showRuleSetSettingsModal save: `const refs = uniqueDynamicListItems(widget.getValue() : getCustomRulesetReferences(section_id))`, then `const subnets = new Set(getConfigListValues(section_id, "rule_set_with_subnets").filter((ref) => refs.includes(ref)))`, then `writeListOption(section_id, "rule_set_with_subnets", [...subnets]);`. refs are custom refs only (getCustomRulesetReferences excludes secondaryRulesetId URLs, section.js:6680-6690), so b4geoip mirror URLs are dropped. secondaryRulesetOption (section.js:7650-7673) compares its load-time cfgvalue with an unchanged widget value, so parse() does not rewrite them. LuCI modal maps share parent.data (form.js renderMoreOptionsModal `m.data = parent.data`), and handleModalCancel only removes an added section, so Dismiss does not revert.


**Reproduction:** Rule editor > What: add a custom rule set URL and select Built-in rule sets #2 = Valve, then save and apply. Reopen, click the settings gear of the custom rule set, toggle 'Include IP addresses and subnets', save both modals, Save & Apply. The Valve URL is gone from /etc/config/forkop.


**Expected:** Toggling subnet extraction for one custom rule set changes only that rule set's membership.


**Actual:** scratch/audit-a3/rt_ruleset_modal.js runs the real section.js with only the stacked-modal renderer stubbed. Before: rule_set=[custom.srs], rule_set_with_subnets=[.../valve.srs]. After enabling subnets for custom.srs: rule_set_with_subnets=[custom.srs] and valve.srs is gone. After the main modal save it is still gone.


**Impact:** A normal UI action silently removes routing conditions: Valve/Riot/Epic/etc. IP sets disappear from the rule. Traffic that was tunnelled or blocked goes direct or is allowed. The secondary widget keeps showing the sets until the page reloads, so the user has no hint.


**Root cause:** The item-modal writer rebuilds the whole rule_set_with_subnets list from the custom widget view, which by design excludes the secondary (b4geoip) entries stored in the same option.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `tests/luci_builtin_rulesets.sh`

**Proposed fix:** In the onSave callback keep the secondary refs: `const secondary = getConfigListValues(section_id, "rule_set_with_subnets").filter((ref) => secondaryRulesetId(ref)); writeListOption(section_id, "rule_set_with_subnets", [...secondary, ...subnets]);`.


**Tests needed:** Round-trip test: rule with custom rule set + secondary set; call showRuleSetSettingsModal save with include_subnets 1 and 0; rule_set_with_subnets still contains the secondary URL.


**Risk:** Minimal. One-line preservation of an unrelated subset.


**Verification:** confirmed → P1

**Verification evidence:** section.js:3622-3644 (showRuleSetSettingsModal onSave): `const refs = uniqueDynamicListItems(widget && typeof widget.getValue === "function" ? widget.getValue() : getCustomRulesetReferences(section_id));` then `getConfigListValues(section_id, "rule_set_with_subnets").filter((ref) => refs.includes(ref))` and `writeListOption(section_id, "rule_set_with_subnets", [...subnets]);`. refs come from the custom "Rule sets" widget, whose load (section.js:7689-7691 -> getCustomRulesetReferences, 6725-6734) filters out secondary b4geoip URLs with `!secondaryRulesetId(value)`. So every b4geoip URL (SECONDARY_RULESET_MIRROR_PREFIX https://mirror.infotechtg.ru/.../b4geoip-forkop/srs/, section.js:6614) in rule_set_with_subnets is dropped. Every other writer of this option keeps them: writeCustomRulesetReferences (6768-6786 `...secondaryRefs, ...subnetRefs`), ruleSetOption.remove (7697-7703 keeps `secondaryRulesetId(value)`), writeSecondaryRulesetReferences (6743-6759 keeps custom). The gear modal is the only writer that does not. Nothing puts them back later: secondaryRulesetOption (7650-7673) is parsed with an unchanged form value equal to its load-time cfgvalue, so LuCI AbstractValue.parse does not call write(). ruleSetOption also sees an equal value (the gear handler calls setValue(refs) with the same refs). The backend reads rule_set_with_subnets for routing (config/connections.uc:419), and migration.uc:1324-1374 / tests/own_mirror_migration.sh confirm that b4geoip URLs live in this option. No test covers showRuleSetSettingsModal. tests/luci_builtin_rulesets.sh only checks the catalogue and integration strings, and tests/luci_interface_settings.sh only checks the interface modal wiring.


**Verification reproduction:**

I ran the auditor's harness scratch/audit-a3/rt_ruleset_modal.js under WSL node (`wsl.exe -e bash -lc 'cd ...scratch/audit-a3 && node rt_ruleset_modal.js'`). It loads the real worktree section.js and main.js with a LuCI form.js copy. Only renderStackedJsonSettingsModal is short-circuited so it calls onSave with {include_subnets:"1"}. Output:
before: rule_set=[https://example.com/custom.srs], rule_set_with_subnets=[https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs/valve.srs]
after item modal: rule_set_with_subnets=[https://example.com/custom.srs] (valve.srs gone, rule_set removed)
after rule save: rule_set_with_subnets=[https://example.com/custom.srs] (valve.srs still gone, and the main modal parse did not restore it).
Reading the code shows the same result for include_subnets "0", and even when the gear modal is saved without changing the flag: the list is always rebuilt from refs only. I did not reproduce this on a router, and that is not needed: the loss happens in the LuCI uci staging before save.


**Verification notes:**

Line refs are correct: the modal is at section.js:3595-3650, the filtering helper at 6725-6734 (not 6680-6690, which is validateFileReference), and the secondary option at 7650-7673.

Refinements:
(1) The trigger is any save of the gear modal on a custom rule set, not only a toggle. With include_subnets "0" the result is also rule_set=[custom], rule_set_with_subnets=[] and every Built-in #2 set is lost.
(2) The loss is undone only if the user edits the "Built-in rule sets #2" widget in the same modal session. Then writeSecondaryRulesetReferences rewrites from the widget, which still shows the sets. Otherwise the widget keeps showing stale sets until the page reloads, so the user gets no hint.
(3) Severity stays P1. It is silent loss of persistent routing config from a normal UI action. Traffic meant for the tunnel (or a block rule) falls back to direct/allowed, which is a routing/security boundary regression for a VPN-routing product. P2 is defensible only because it needs the specific combination of a custom rule set plus Built-in #2 sets on the same rule.

Minimal fix: mirror writeCustomRulesetReferences in the onSave callback:
`const secondary = getConfigListValues(section_id, "rule_set_with_subnets").filter((ref) => secondaryRulesetId(ref)); ... writeListOption(section_id, "rule_set_with_subnets", [...secondary, ...subnets]);`
Also make sure `subnets` itself can never contain a secondary URL. It cannot today, because refs exclude them.

Test to add: a node/vm test in the style of the harness that loads section.js, calls showRuleSetSettingsModal with include_subnets "1" and then "0" on a rule that has a custom rule set plus valve.srs, and asserts that valve.srs stays in rule_set_with_subnets. product_decision=false.


---

<a id="uc-005"></a>

## UC-005 · P1 · S4a — Восстановление снимка при reload, поставленном в очередь, объявляет успех, переносит LKG и снимает restore guard

**Severity:** P1<br>
**Stage:** S4a (Аварийный этап: fail-closed restore при reload в очереди (P1))<br>
**Area:** config/snapshots.uc restore transaction<br>
**Sources:** snapshots#0, cli-contract#0, process-locks#1<br>
**Original title:** Restore treats a queued reload as applied: LKG moved to an unverified target, restore guard released, success reported<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** snapshots.uc:314-318 `function reload_ran(detect_queued) { ... return !detect_queued || pending_stamp() == null || ...` ; snapshots.uc:324 `let detect_queued = apply_mode;` (do_restore:359 passes no apply_mode) ; snapshots.uc:336-338 `if (valid && reload_ran(detect_queued)) { if (!restore_guard(true)) ... else result = on_success();` ; snapshots.uc:360 `atomic(LKG, id + "\n")` ; initd.uc:712-715 `if (!acquire_runtime_dir_lock(RELOAD_LOCK_DIR, ...)) { mark_pending_reload(PENDING_RELOAD_FILE, reason || "reload_busy"); return { action: "skip" ...` and initd.uc:746-756 reload_service returns 0 for skip. do_restore (351-363) has no reload-lock/pending pre-check, unlike apply.uc:243-251 service_action(). The comments at snapshots.uc:307-309 and 321-322 accept this: 'A restore keeps its established behaviour'.


**Reproduction:** scratch/audit-a10\restore_queued.sh (run with wsl bash)


**Expected:** A restore whose reload was only queued never reports success, never moves LKG and never releases the guard on that basis. Better, it is refused before any mutation while a lifecycle action owns the reload lock.


**Actual:** Reproduced with the real initd.uc reload-service while reload.lock was held by a live pid: restore -> {status:'success', started:true}, LKG == target id, ForkopConfigRestoreDpiGuard removed, reload.pending left behind, 0 runtime reloads executed, events 'snapshot_create success, guard+, guard-, restore success'.


**Impact:** Whenever another lifecycle action owns /var/run/forkop.reload.lock (list-content or subscription update, WAN-up reload, start, pending reload, or an autotune rollback_to started because verify saw no_service_action=false), a restore's target becomes LKG without ever being loaded. If the queued reload later fails at runtime (for example the target is an unproven 'before-reload' snapshot), LKG names a failing configuration (invariant 3), and the 'Last known good' badge sends the next emergency recovery to it. The restore guard is released without proof of a coherent runtime (invariant 4). History records 'restore success' and the UI says 'Configuration restored and reloaded' for something not yet done (invariants 5/15).


**Root cause:** reload_ran() trusts exit status 0 from /etc/init.d/forkop reload, but initd.uc returns 0 when it merely queues the request. Queued detection was implemented only for autotune apply_mode.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `forkop/files/usr/lib/service/initd.uc`, `fe-app-forkop/src/forkop/tabs/history/initController.ts`, `tests/config_snapshots.sh`, `tests/config_restore_guard.sh`

**Proposed fix:** 1) In do_restore, before the pre-restore snapshot, refuse with {status:'busy', reason:'service_action_in_progress'|'reload_pending'} when the reload lock has a live owner pid or reload.pending exists. This is the same check as apply.uc service_action(), and the UI already shows the busy toast. 2) Split guarded_replace's detect flag from the apply-only concurrent-change check and enable queued detection for restore too. 3) Make the pending marker unique per write (see the P3 on second-resolution stamps).


**Tests needed:** config_restore_guard.sh / config_snapshots.sh: a reload stub emulating initd queueing (exit 0 plus a marker in the production 'reason=..\nupdated_at=<sec>' format) must not yield success, and LKG must stay unchanged. A busy pre-check case with a live reload.lock owner. An integration test with the real initd.uc reload-service, as in the scratch repro.


**Risk:** The pre-check adds 'busy' refusals during long list updates; the user retries. Detection without the pre-check could turn a queued double reload into needs_attention with the guard kept (fail closed).


**Verification:** confirmed → P1

**Verification evidence:**

Checked against the code at 07872084.

- snapshots.uc:314-318: `reload_ran(detect_queued)` returns true after `[RELOAD, "reload"]` exits 0 whenever detect_queued is false.
- snapshots.uc:323-324: in `guarded_replace(before, content, pre, on_success, apply_mode)`, `let detect_queued = apply_mode;`.
- snapshots.uc:359-362: do_restore calls guarded_replace without apply_mode, so detect_queued is undefined and falsy. The success callback then does `atomic(LKG, id + "\n")` and returns status 'success'.
- snapshots.uc:336-338: after a 0 exit, `restore_guard(true)` removes the ForkopConfigRestore DPI guard before on_success runs.
- initd.uc:712-715: when the reload lock cannot be taken, it calls `mark_pending_reload(PENDING_RELOAD_FILE, reason || "reload_busy"); return { action: "skip" ...}`. Lines 703-706 do the same for the config-change queue path.
- initd.uc:746-755: reload_service returns 0 on skip and prints "queued" only when the reason is 'list-content'. The restore call passes no reason, so it gets exit 0 with no marker on stdout.
- init.d/forkop:68-89: reload_service passes that status through unchanged.
- do_restore (351-363) has no busy or pending pre-check. do_apply has one (line 377, `reload_pending`), and so does autotune/apply.uc:243-249 `service_action()`. Its comment explicitly warns that "a queued reload after the guard is gone would confirm LKG unverified".
- The CLI dispatch (usr/bin/forkop:197) runs snapshots.uc restore directly. The UI (initController.ts:242-284) calls snapshotRestore with no busy check, and on 'success' shows "Configuration restored and reloaded".
- No test covers restore while a reload is queued. config_restore_guard.sh and config_snapshots.sh never set FORKOP_PENDING_RELOAD_FILE. Only autotune_apply.sh covers the queued case, and only for apply.
- Wider impact: autotune/apply.uc:575 uses `lkg_fingerprint()` as a precondition (config_not_last_known_good). Once LKG points at the unverified target, a later autotune apply accepts it as a proven base.


**Verification reproduction:**

I re-ran the auditor's script in WSL: scratch/audit-a10/restore_queued.sh. I read it first. It uses mktemp -d and reads the worktree without modifying it. Parts that are real: the initd.uc reload-service code path, snapshots.uc and core/*. Parts that are modelled: the nft guard, the validator and the health recorder. The reload lock is held by a live `sleep 60` pid.

Observed output:
- restore result: {status:'success', started:true, changes:[dns_server 8.8.8.8->1.1.1.1]}
- LKG before: none; LKG after: equal to the target id
- guard still installed: no
- pending reload marker: 'reason=reload_busy updated_at=<sec>'
- runtime reloads executed (forkop reload calls): 0
- events: snapshot_create success, guard+, guard-, restore success

So the restore reported success, moved LKG and released the guard even though no runtime reload ran. The run needs no router: the code path is fully local, and only the later runtime outcome of the queued reload needs hardware.


**Verification notes:**

The line references are accurate. Keeping P1: the guard is removed without proof of a coherent runtime (invariant 4), and LKG is set to an unverified config, which becomes a failed LKG if the queued reload fails (invariant 3). History and the UI report success for work that has not run (invariants 5/15). One mitigating point: the target passes validator.uc validate-runtime first, so only runtime failures are exposed. The trigger is realistic, because the reload lock is held during scheduled list and subscription updates, WAN-up reloads, start, and a pending reload drain.

Where the pending reload goes after the restore: an in-flight lifecycle reload that holds the lock ends in finish_reload_status (lifecycle.uc:400-408). There the fingerprint check stops confirm-working and marks a pending reload. The pending reload then runs the target after the guard is already gone. If it succeeds, confirm-working makes a proper LKG and no harm is done. If it fails, LKG still names the target.

The fix needs both parts, not either one:
(1) A pre-check in do_restore, before create(pre-restore): return {status:'busy', reason:'service_action_in_progress'|'reload_pending'}, copied from apply.uc service_action(). This check alone is TOCTOU: a lifecycle action can take reload.lock between the check and the reload.
(2) Queued detection inside guarded_replace for restore too (detect_queued = true for both modes). Keep the concurrent_change sha check only for apply_mode. With detection on, a queued target reload falls into the rollback branch. Its second reload is also queued, so the result is needs_attention/runtime_rollback_failed with the guard kept active. That is fail-closed and acceptable.
(3) pending_stamp compares mtime, size and content at second resolution. The production marker is 'reason=..\nupdated_at=<sec>', so if a marker already exists and is rewritten in the same second with the same reason, the stamp is unchanged and the queued reload is mistaken for a completed one. Make the marker unique per write (for example a nanosecond or pid nonce), or have snapshots.uc delete or compare an inode or nonce.

An alternative to (2)+(3): have snapshots.uc pass a dedicated reason and treat a 'queued' stdout token as not-ran, generalising the list-content handling in initd.uc:748-753. That changes the initd output contract for one more reason, so it needs a matching update to the init.d case statement.

Tests to add in config_restore_guard.sh:
- a reload stub that exits 0 and writes a production-format marker: expect no success and LKG unchanged
- a live reload.lock owner: expect busy before any mutation, with no pre-restore snapshot created

product_decision stays false. affected_files are correct. initController.ts only needs 'busy' already handled; the backend fix adds reasons that the UI already covers through the busy toast.


### Also reported as cli-contract#0 (P1): Snapshot restore reports success, drops the restore guard and moves LKG when the init.d reload was only queued

**Evidence:** service/initd.uc:712-715 `if (!acquire_runtime_dir_lock(RELOAD_LOCK_DIR, ...)) { mark_pending_reload(...); return { action: "skip" ...` and :746-754 `if (plan.action != "run") { ... return 0; }` (init.d reload exits 0 when merely queued). config/snapshots.uc:304-308 comment: "A reload that was only queued ... returns success without touching the runtime"; :314-317 `function reload_ran(detect_queued) { ... return !detect_queued || ...`; :323-324 `let detect_queued = apply_mode;`; :361 do_restore calls `guarded_replace(before, target.content, pre, () => { if (!atomic(LKG, id + "\n")) ...` without apply_mode, so a queued reload counts as success; :336-338 then `restore_guard(true)` and on_success. Unlike do_apply (:376 `if (fs.stat(PENDING_RELOAD) != null) return { status: "stale" ...`), do_restore has no pending/lock pre-check. Reload-lock holders: components/updates.uc:3944 (list update, whole download), :4342 (subscription update), diagnostics/runtime.uc:1925 (automatic latency test batches), initd.uc:604/712 (start/reload).


**Proposed fix:** Minimal: in do_restore, refuse before touching the config when a reload is pending or the reload lock has a live owner, returning {status:'busy', reason:'reload_in_progress'}, as do_apply already does for pending. Also pass apply_mode/detect_queued=true from do_restore so that a reload queued between the check and the call counts as not run. The rollback then runs; if the rollback reload is also queued, the result is needs_attention with the guard kept (fail closed). The FE already renders busy.


**Verification:** confirmed → P1

**Verification notes:**

The line refs are accurate (the do_apply pending check is at :377, not :376).

Impact:
- The immediate effect is a false success, an early guard release and an LKG move to an unverified config (invariants 3, 4 and 5 in spirit).
- The concrete damage needs the queued reload to fail later, for example sing-box fails at runtime even though validate-runtime passed. Then no automatic rollback happens, the broken config stays in /etc/config/forkop and LKG names it. Manual recovery via 'restore LKG' no longer returns to the last working config: the previous LKG is still a snapshot, but it is no longer marked. That is a recovery failure, so P1 stands. If you count only the common case where the queued reload succeeds, this is a P2 misleading-state issue.

Related path: autotune/apply.uc:601 rollback_to() uses the same restore. There the damage is partly mitigated because it re-verifies the production runtime with verify_production afterwards.

Better minimal fix, in addition to the proposed one:
1. In do_restore, before create(pre-restore), refuse with {status:'busy', reason:'reload_in_progress'} when PENDING_RELOAD exists or RELOAD_LOCK_DIR has a live pid. This mirrors do_apply:377.
2. Do not rely only on pending_stamp detection. It is racy: the lock holder can consume reload.pending (run_pending_reload_if_requested) between our reload returning and the pending_stamp() re-check, and the stamp has only 1-second resolution. More robust is an explicit acknowledgement from init.d. Have snapshots.uc call `RELOAD reload <reason>` with a dedicated reason (e.g. config-restore). Make initd.uc reload_service print "queued" for that reason too, as it already does for list-content. Treat "queued" as not run.
3. With queued treated as not run, the rollback branch also gets 'queued', which ends in needs_attention with the guard active. That is fail closed and acceptable; the pre-check makes it rare.

Tests to add in tests/config_restore_guard.sh:
- A reload stub that marks pending and exits 0: expect not success, guard kept, LKG unchanged.
- A pre-existing reload.pending or a live reload-lock owner: expect busy with the config untouched.


### Also reported as process-locks#1 (P2): Snapshot restore reports success, moves LKG and removes the restore guard when its reload was only queued

**Evidence:** config/snapshots.uc:314-318 `function reload_ran(detect_queued) { ... if (!success([ RELOAD, "reload" ])) return false; return !detect_queued || ... }`; :324 `let detect_queued = apply_mode;` (restore passes no apply_mode, :359); :336-338 `if (valid && reload_ran(detect_queued)) { if (!restore_guard(true)) ... else result = on_success(); }`; :360 on_success writes LKG. service/initd.uc:712-715 a busy reload.lock gives `mark_pending_reload(...); return { action: "skip" }` and reload_service returns 0 (746-756). Long-lived reload.lock holders outside init.d: components/updates.uc:3944 (list update, held across the DNS probe and downloads), :4342 (subscription update, held across downloads), diagnostics/runtime.uc:1924 (latency test). autotune/apply.uc:245 already notes that "a queued reload after the guard is gone would confirm LKG unverified". Only apply mode guards against this, via snapshots.uc:377 and the pending stamp. Repro: scratch/audit-a6a7/repro_restore_queued_reload.sh printed `restore exit=0 {status: success}`, `LKG: <restored id>`, `runtime reloads performed: 0`, `reload.pending: reason=reload_busy`, `guard calls: ensure ... remove`.


**Proposed fix:** Before any mutation in do_restore, refuse with {status:'busy'} when reload.pending exists or reload.lock has a live owner, as do_apply/stale_reason already do. Call guarded_replace with detect_queued=true for restore as well. If a queue still appears mid-transaction, return needs_attention with the guard kept instead of success.


**Verification:** confirmed → P2

**Verification notes:**

Verdict and severity:
- Confirmed, P2 kept. The status is misleading, LKG moves without proof, and restore's promised automatic rollback ("If the reload fails, the previous configuration is restored automatically") is lost. Invariants 3, 4 and 5 are violated in the race.
- Not P1: the runtime keeps running the old, coherent config. The config file is the validated snapshot. The pre-restore snapshot is kept. The later queued reload runs under lifecycle's own DPI transition guard (lifecycle.uc:1225), so the early guard removal causes no traffic leak. Nothing auto-restores from LKG, and the next successful reload re-confirms it (lifecycle.uc:400-404).

Corrections to the finding:
1. Additional lock holders: initd.uc start_service :604-616 (the whole start) and lifecycle.uc dns_failover_apply :1621-1666.
2. The latency test final release (runtime.uc:2007, plus :1934/:1951/:1964) and lifecycle.uc:1666 do not drain reload.pending. The window can therefore last until the next drain point, not just until the holder finishes.
3. apply.uc:773-779 uses LKG only as a fingerprint-checked fallback when the pre-apply snapshot is missing. Autotune rollback also refuses under service_action() (apply.uc:769-770) and verifies the runtime itself, so autotune is barely affected.

The proposed fix is insufficient and partly harmful as written. "Call guarded_replace with detect_queued=true for restore" relies on pending_stamp. The marker is written with 1-second resolution (initd.uc:249 writes updated_at in epoch seconds, and stat mtime is in seconds). When both the target reload and the rollback reload are queued, the second queue looks like "ran". The result is "recovered", guard removed, and LKG moved to the pre-restore config that was never reloaded, which may be the broken config the user was escaping (repro E, 3 of 3). The same weakness already exists in apply mode (repro D, 3 of 3). It is benign there only because the pre-apply config was already LKG and running.

Minimal fix instead:
- (a) In do_restore, before creating the pre-restore snapshot, refuse with status busy (reason service_action_in_progress or reload_pending) when reload.lock/pid is a live PID or reload.pending exists. This mirrors apply.uc service_action(). Give the UI a reason-specific message, because snapshotBusyMessage says "Another snapshot operation…".
- (b) Close the TOCTOU with a deterministic signal. Let initd.uc reload_service print "queued" for this caller too (today only list-content gets it, :753; the init.d wrapper :84-86 already forwards the token). snapshots.uc should capture stdout and treat "queued" as not-ran in both restore and apply mode. Alternatively, make the marker unique per write.
- (c) Once a queue is detected mid-transaction, return needs_attention with the guard kept and LKG untouched, never success or recovered.

Tests needed: config_snapshots.sh cases driven by the real initd.uc reload-service with a live lock holder, covering the restore target reload queued, both reloads queued, and a pre-existing reload.pending. Also adjust the autotune_apply.sh stub (:140) to write a same-second marker the way initd.uc does.


---

<a id="uc-006"></a>

## UC-006 · P2 · S1 — Маскированный конфиг sing-box оставляет секретные поля (pre_shared_key, auth, headers, path, plugin_opts, токены URL)

**Severity:** P2<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** security<br>
**Sources:** security#2<br>
**Original title:** Masked sing-box config keeps many secret-bearing fields (pre_shared_key, ssh passphrase, hysteria auth/obfs, auth headers, ws path, plugin_opts, DoH path, rule_set URL token)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** ACL grants `/usr/bin/forkop show_sing_box_config masked` to the read role (luci-app-forkop.json:75); mask-sing-box-config is also used by check_proxy and global_check. masked_sing_box_keys (diagnostics/status.uc:1501-1523) lists auth_key/uuid/password/private_key/public_key/short_id/secret/server/etc but NOT pre_shared_key, peer_public_key, private_key_passphrase, auth_str, obfs (hysteria1 password/obfs), path (ws/DoH path), headers (transport Host/Authorization), plugin/plugin_opts, url (rule_set/urltest url). mask_sing_box_value only masks exact key names, recursing into everything else.


**Reproduction:** scratch/audit-acl-secrets/sb_mask_repro.sh.


**Expected:** All credential-equivalent fields are masked in the masked view.


**Actual:** The masked sing-box config exposes wireguard PSK, ssh key passphrase, hysteria auth/obfs secrets, HTTP auth headers, ws/DoH url paths (which can be bearer-style tokens), shadowsocks plugin options, and rule_set/testing url tokens to a read-only viewer.


**Impact:** Invariant 2 leak for a subset of outbound types and DoH/rule_set setups. Lower than the outbound_jsons finding because it needs those specific field types configured, but the same RO command exposes it.


**Root cause:** masked_sing_box_keys is an incomplete deny-list that has not tracked sing-box's full outbound/transport/dns schema.


**Affected files:** `forkop/files/usr/lib/diagnostics/status.uc`, `fe-app-forkop/src/forkop/tabs/diagnostic/helpers/maskDiagnostics.ts`

**Dependencies:** Keep the ucode key set and the TS SING_BOX_MASKED_KEYS identical (there is a maskDiagnostics.test.ts that should be extended).


**Proposed fix:** Add the missing keys to masked_sing_box_keys (and the TS SING_BOX_MASKED_KEYS): pre_shared_key, peer_public_key, private_key_passphrase, auth_str, obfs (or its password subfield), path, headers, plugin, plugin_opts, url, host. Consider masking url query strings rather than dropping them wholesale so the endpoint host still shows.


**Tests needed:** A mask-sing-box-config fixture in tests/diagnostics_status.sh covering wireguard PSK, ssh passphrase, hysteria auth_str/obfs, ws path, transport headers, plugin_opts, DoH path and rule_set url token, asserting each value is replaced by MASKED.


**Risk:** Masking `path`/`url`/`host` broadly could hide non-secret routing info; mask query/userinfo portions where feasible instead of the whole value.


**Verification:** confirmed → P2

**Verification evidence:**

Denylist: forkop/files/usr/lib/diagnostics/status.uc:1502-1529 (`let masked_sing_box_keys = { auth_key ... excluded_source_ip_cidr }`). It masks exact key names only, and :1542 (`result[key] = masked_sing_box_keys[key] ? "MASKED" : mask_sing_box_value(item)`) recurses into every other key. The TS copy SING_BOX_MASKED_KEYS in fe-app-forkop/src/forkop/tabs/diagnostic/helpers/maskDiagnostics.ts:3-30 has the same set.

How the read-only role reaches it:
- The ACL grants `"/usr/bin/forkop show_sing_box_config masked"` (luci-app-forkop.json:75) and `"/usr/bin/forkop check_proxy"` (:29) in the read section. readonlyCommandGuard.ts:32,54 mirrors both.
- runtime.uc:806 (show_sing_box_config) and runtime.uc:651 (check_proxy) print `status_output(["mask-sing-box-config", ...])`.

Leaking fields that Forkop itself generates, with no user JSON:
- DoH `path`: singbox/dns.uc:117-122 (`result.path = path`).
- ws/httpupgrade `transport.path` and `transport.headers = { Host: ... }`: generator.uc:1779-1796 and 1981-1989.
- shadowsocks `plugin_opts`: generator.uc:1891.
- remote rule_set `url: reference`: generator.uc:378-382.
- urltest `url`: generator.uc:1326.

Arbitrary sing-box fields also pass through untouched:
- JSON outbounds (generator.uc:2212-2248). ensure_explicit_outbound_supported (:526-529) only checks XHTTP.
- sing-box JSON subscriptions (parser.uc:2705-2768).
- So wireguard pre_shared_key/peer_public_key, ssh user/private_key_passphrase, hysteria1 auth_str/obfs and http `headers.Authorization` all reach the config. The target is sing-box >=1.12 (constants.uc:70), where all of these outbound types still exist.

The project's own policy is inconsistent here. The UCI masked view (status.uc:351-404) masks `option dns_server` in full (:368,:370) and DoH paths (mask_option_path :399-400), plus transport_host/transport_hosts (:384-385), outbound_json (:358) and hysteria2_obfs_password (:390). The sing-box masked view then shows the same DoH path and Host header in clear.

No backend test covers mask-sing-box-config (no hits in tests/). maskDiagnostics.test.ts only checks server/uuid/server_name/domain_suffix/listen.


**Verification reproduction:**

I wrote a fresh repro under scratch/audit-verify-sb-mask (config.json + repro.sh) and ran it in WSL with a private mktemp dir. It runs `ucode -L <wt>/forkop/files/usr/lib <wt>/.../diagnostics/status.uc mask-sing-box-config config.json` on the worktree at 07872084. Exit was 0.

Values that came through in clear:
- NEXTDNSPROFILE (dns.servers[].path)
- WSPATHTOKEN (transport.path)
- WSHOSTHEADER (transport.headers.Host)
- PLUGINHOST and PLUGINPATH (plugin_opts)
- WGPEERPUB and WGPSKSECRET (legacy wireguard outbound)
- EPWGPSKSECRET (endpoints[].peers[].pre_shared_key), plus the peer `address` 1.2.3.4, the server IP
- SSHUSERSECRET and SSHPASSPHRASESECRET
- HY1AUTHSECRET and HY1OBFSSECRET (hysteria v1)
- HEADERSECRET (http outbound headers.Authorization)
- URLTESTTOKEN (urltest url)
- RULESETTOKEN (rule_set url)

Correctly masked: uuid, server_name/server/server_port, ss password, hy2 password, and hy2 obfs.password (obfs is an object, so the recursion masks its `password`). Also masked: all private_key values, endpoint peers[].public_key, and clash_api secret. The TS helper uses the same key set, so the client-side "mask" toggle has the same holes. That toggle is not a boundary anyway, because the read-only role can call file.exec directly.

No router is needed: the masking is pure ucode over a JSON file.


**Verification notes:**

Corrections to the finding:
1. global_check does NOT print the sing-box config. global_check (runtime.uc:2041-2167) prints only the UCI view through show_config → forkop-config-masked. The only read-only-reachable commands that expose this are `show_sing_box_config masked` (acl:75, runtime.uc:795-807) and `check_proxy` (acl:29, runtime.uc:651, which prints the masked config before its connectivity test).
2. The hysteria2 obfs password is already masked: Forkop's generator and link parser build `obfs: {type, password}` (generator.uc:2042-2043, parser.uc:995-998), and the recursion masks the inner `password`. Only hysteria v1 (`auth_str`, plus sing-box's `auth` and a string `obfs`) leaks, and that only via a JSON outbound or a sing-box JSON subscription.
3. Split the leaks by how they arise:
   - Forkop-generated, no custom JSON: DoH `path`, transport `path` and `headers.Host`, `plugin_opts`, and user-provided rule_set `url`. These are identifiers and server identity rather than full credentials, but they defeat the existing masking of server/server_name and contradict the UCI view, which masks dns_server and transport_host.
   - Full credentials, which need a JSON outbound or sing-box JSON subscription: wireguard `pre_shared_key`, ssh `private_key_passphrase`, hysteria1 `auth_str`/`auth`/`obfs`, http `headers.Authorization`. The PSK and passphrase are only partially usable while private_key stays masked. The hysteria1 auth and Authorization header are full proxy credentials.
4. Extra leaks the finding does not mention: the wireguard endpoint `peers[].address`/`port` (the real server address, while `server` is masked elsewhere), `local_address`/`address`, and ssh `user`. `peer_public_key` should be masked for consistency, since `public_key` already is.
5. The rule_set url is a product decision (product_decision=true for that item only). The UCI masked view (forkop_config_masked_line) does not mask `list rule_set` either, so the same URL already reaches the read-only role through `global_check masked`. Masking it only in the sing-box view closes nothing. Decide whether rule_set URLs count as secret, then change both views, or mask only the query/userinfo part. The urltest `url` is Forkop's urltest_testing_url (a non-secret default), so it is low priority.

Severity: I keep P2. Invariant 2 is violated, but only for DoH users, ws/plugin transports, or less common JSON/subscription outbound types, and most leaked items lack their masked companion (server or private key). This is not a default-config full-credential leak. Default dns_type is udp (etc/config/forkop:12).

Minimal fix (no product decision needed for these): add `pre_shared_key`, `peer_public_key`, `private_key_passphrase`, `user`, `auth`, `auth_str`, `obfs`, `path`, `headers`, `plugin_opts`, `address`, `local_address`, `port` (the last two only where they identify the server; masking them wholesale is acceptable) to both status.uc:1502 and maskDiagnostics.ts:3.
- Over-masking cost: `path` also hides the local rule_set/cache_file paths. That only reduces diagnostic value, it has no safety impact.
- If that is too broad, mask `path`/`headers` only under `transport` and `dns.servers`.

Tests: add a backend fixture (for example in tests/diagnostics_status.sh) running mask-sing-box-config over a config like scratch/audit-verify-sb-mask/config.json, and assert that no sentinel survives. Extend maskDiagnostics.test.ts with the same cases, plus a parity test that the TS set equals the ucode set.


---

<a id="uc-007"></a>

## UC-007 · P2 · S1 — Clash API по умолчанию слушает LAN-адрес без секрета: любой хост LAN и read-only пользователь управляют прокси и видят соединения

**Severity:** P2<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** security<br>
**Sources:** security#3<br>
**Original title:** Clash API (YACD) listens on the LAN IP with no secret by default; any LAN host or read-only LuCI user can control proxies and read all connections<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-1

**Evidence:** clash_api_config (singbox/generator.uc:397-412) sets external_controller to service_address:9090 (the LAN IP, from service_listen_address_value in singbox/runtime.uc:571-593) whenever enable_yacd is off too, and only adds a `secret` when enable_yacd is on AND yacd_secret_key is non-empty. Default config ships enable_yacd '0' (etc/config/forkop:29) and no secret. The RO ACL exposes clash_api get_proxies/get_connections/get_proxy_latency(ies)/get_group_latency (luci-app-forkop.json:35-44) and the backend clash_api() only sends Authorization when enable_yacd_wan_access is set (diagnostics/runtime.uc:1582-1587), so the controller normally has no auth. set_group_proxy/close_connection use PUT/DELETE to the same unauthenticated controller (:1841-1873).


**Reproduction:** Static: generator.uc:397-412 + default config; not executed against a router.


**Expected:** Either the controller binds to 127.0.0.1 unless WAN access is explicitly enabled, or it always requires a secret; RO users can observe but selector switching / connection closing is an admin action.


**Actual:** The proxy control/observability API is reachable unauthenticated from the whole LAN by default, and mutating selector/connection operations are effectively available to unauthenticated LAN clients and to RO LuCI users.


**Impact:** LAN-local breach of confidentiality (all clients' connection metadata) and integrity (anyone can repoint the proxy group or kill connections), plus RO users performing what are effectively mutations via the Clash path. Whether this is acceptable is a product decision (YACD LAN convenience vs. exposure), hence product_decision=true, but the current default is unsafe.


**Root cause:** external_controller is set to the LAN listen address unconditionally and the secret is only attached under enable_yacd; there is no default-deny for the Clash controller.


**Affected files:** `forkop/files/usr/lib/singbox/generator.uc`, `forkop/files/etc/config/forkop`, `luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json`

**Dependencies:** Frontend getClashHttpUrl()/getClashWsUrl() assume host:9090; loopback-only would require the direct-fetch path to fall back to rpcd (it already does).


**Proposed fix:** Bind external_controller to 127.0.0.1:9090 unless enable_yacd_wan_access is set; require a non-empty yacd_secret_key whenever the controller is not loopback (fail closed). Reconsider whether RO clash_api grants should include selector-switch/connection-close.


**Tests needed:** A generator test asserting external_controller is 127.0.0.1 when WAN access is off, and that a secret is present whenever the bind address is non-loopback.


**Risk:** Changing the default bind could break existing YACD-over-LAN users; may need a migration note or an explicit opt-in flag.


**Verification:** confirmed → P2

**Verification evidence:**

Confirmed: on a default install, sing-box's Clash controller listens on the LAN IP port 9090 with no secret.

1. Bind address and secret (forkop/files/usr/lib/singbox/generator.uc:397-414)
   - `let controller = as_string(service_address || "");` The controller moves to 0.0.0.0 only when enable_yacd=1 and enable_yacd_wan_access=1. It falls back to 127.0.0.1 only when no service address is known.
   - `if (bool_option(settings, "enable_yacd", false)) { ... if (secret != "") result.secret = secret; }` A secret is only ever added when YACD is on.
   - The production caller is singbox/runtime.uc:863-873, which passes `service_listen_address_value(settings)`. That function (runtime.uc:572-594) returns the manual service_listen_address, else the ipv4 of network.interface.lan, else the br-lan address. In practice that is the LAN IP.
   - The shipped config has `option enable_yacd '0'` (etc/config/forkop:29) and no secret.

2. Nothing restricts access to port 9090
   - No Forkop nft input rule mentions 9090. Forkop creates only prerouting and output chains (nft/apply.uc:882, 885, 1628, 1671).
   - The OpenWrt lan zone accepts input by default.
   - The product relies on LAN reachability: fe-app-forkop/src/helpers/getClashApiUrl.ts:15-25 builds `ws://${hostname}:9090` and `http://${hostname}:9090`. The dashboard (initController.ts:642, 678), Monitoring (:1932) and getDashboardSections.ts:160 connect from the browser with `?token=` empty on a default install.

3. Backend sends no auth by default
   - `clash_auth_args` (diagnostics/runtime.uc:1582-1587) sends a Bearer header only when enable_yacd_wan_access is set.
   - `clash_api_url` (runtime.uc:1575-1580) targets the service listen address.
   - The mutating actions set_group_proxy, close_connection and close_all_connections (runtime.uc:1841-1873) use PUT/DELETE against that same unauthenticated controller.

4. Upstream guidance: sing-box's clash-api docs (fetched via context7) say to always set a secret when the API listens on 0.0.0.0. They also say `access_control_allow_origin` defaults to `*` when empty, and Forkop never sets it.

Corrections to the finding:
- **RO clash_api grants claim: refuted as stated.** The read ACL (luci-app-forkop.json:40-44) grants only get_proxies, get_connections, get_proxy_latency, get_proxy_latencies and get_group_latency. set_group_proxy and close_* need the write grant `/usr/bin/forkop` exec (json:95), and the frontend calls them only through rpcd. RO reading connections and proxies over rpcd is intended by STAGE6_UX_DESIGN.md:858, 867-868. An RO user can mutate only through the raw LAN socket, like any unauthenticated LAN host, so this is a network-exposure problem, not an ACL defect.
- **Progress-path write concern: already guarded.** The RO wildcard on get_proxy_latencies passes a user-chosen progress path (arg3) to service/ui.uc update_latency_progress_state (ui.uc:633-644). That function checks `latency_action_path_allowed` and requires an existing running latency state. No arbitrary write.


**Verification reproduction:**

Scratch script: scratch/audit-verify-clash\repro.sh, run in WSL with a private mktemp -d work dir.

The script runs the real `singbox/generator.uc generate-config-fixture` with service address 192.168.1.1 (the value runtime.uc passes in production) and one connection section. It prints `experimental.clash_api` for each settings combination. Observed output:

| Settings | Generated clash_api |
|---|---|
| default (enable_yacd absent) | `{ "external_controller": "192.168.1.1:9090" }` |
| enable_yacd=0 (shipped default) | `{ "external_controller": "192.168.1.1:9090" }` |
| enable_yacd=1, no secret | `{ "external_controller": "192.168.1.1:9090", "external_ui": "ui" }` |
| enable_yacd=1, secret, no WAN | `{ ..."192.168.1.1:9090", "external_ui": "ui", "secret": "s3cr" }` |
| enable_yacd=1, WAN, no secret | `{ "external_controller": "0.0.0.0:9090", "external_ui": "ui" }` |
| enable_yacd=0, WAN=1, secret | `{ "external_controller": "192.168.1.1:9090" }` |

This proves the default bind is the LAN IP with no secret.

Not run:
- LAN-host reachability was not tested against a router (no router contact allowed). It follows statically from the missing input filtering, the default lan zone accepting input, and the frontend's by-design direct ws/http access to host:9090.
- No existing test pins `clash_api.external_controller` or the secret. The only mention is a hand-written fixture in tests/autotune_apply.sh:209.


**Verification notes:**

**Severity: keep P2 and product_decision=true.**
- **What an unauthenticated LAN host can do:**
  - Read every client's connection metadata (`/connections`).
  - Switch selector and priority-group nodes (`PUT /proxies/<group>`). This can fight Forkop's priority-group controller. The choice is stored in cache.db, which lives in /tmp and does not survive a reboot.
  - Close connections.
  - Probably also flush the FakeIP cache and run DNS queries through sing-box. These come from sing-box's standard Clash endpoints and were not verified in this tree.
- **What it cannot do:** it gets no proxy credentials (`/proxies` exposes no server credentials) and cannot change the configuration.
- **Why not P1:** it is inherited upstream-podkop LAN design and the impact is bounded.
- **Amplifier (unverified against the shipped sing-box binary):**
  - The CORS default is `*` because access_control_allow_origin is unset.
  - In a browser that does not enforce Private Network Access, a public web page opened by any LAN user could read `http://<router>:9090/connections`.
  - This argues for fixing the default even though it is a product decision.

**Line-reference corrections:**
- runtime.uc range is 572-594, not 571-593.
- generator.uc range is 397-414.

**Related defects found while verifying (separate, P3):**
- **Generator and backend disagree on when the secret is used.**
  - The generator adds the secret whenever enable_yacd=1 (generator.uc:407-411).
  - The backend sends it only when enable_yacd_wan_access=1 (diagnostics/runtime.uc:1584).
  - Failure: with enable_yacd=1, WAN off and a secret set (reachable via uci CLI or import; LuCI removes the hidden option), every backend clash_api call gets 401. `clash-api-ready` then fails, so `forkop_running`/`forkop_stably_running` never become true (service/state.uc:928-949). Start is reported as failed.
- **WAN exposure without a secret is allowed.** enable_yacd=1 + WAN=1 + empty secret produces `0.0.0.0:9090` with no secret. The LuCI secret field (settings.js:484-494) has no non-empty validation. WAN exposure also requires the user to open the firewall manually, per the option's description.

**Better minimal fix (fail closed without breaking the UI):**
1. **generator.uc clash_api_config:** when enable_yacd=0, bind `127.0.0.1:9090`. When enable_yacd=1 without WAN, keep the LAN bind but require a secret. Whether to fail generation or auto-generate one is a product choice. When WAN=1, refuse to generate with an empty secret.
2. **diagnostics/runtime.uc clash_api_url/clash_auth_args:** stop deriving the address from service-listen-address. Either always use 127.0.0.1 (works for loopback and 0.0.0.0 binds) or read address and secret from the generated config, as autotune/apply.uc:300-307 `clash_controller()` already does. Send the secret whenever the generated config has one. Without this the readiness probe breaks after the bind change.
3. **Frontend:** no change needed. Direct ws/fetch to host:9090 already falls back to rpcd polling (dashboard initController.ts:661-674, getDashboardSections.ts:171-178, Monitoring), pinned by tests/luci_clash_transport_fallback.sh. The cost is more rpcd/curl polling load and no direct WebSocket on plain-http LuCI.
4. **Tests:** add a generator test (default gives loopback with no LAN bind; any non-loopback bind has a secret) and a runtime test that clash_api_url/auth follow the generated config.

**Risk:** existing users who reach YACD or the controller from LAN clients with enable_yacd=0 lose that access. Needs a release note; users with enable_yacd=1 keep LAN access, now with a secret.

**Minor, noted only:** the RO ACL allows latency tests (get_*_latency) although STAGE6_UX_DESIGN.md:868 lists "проверка задержки" as not available to RO. A group delay test can make a URLTest group re-pick its node. This is a runtime effect, not a config mutation; low impact.


---

<a id="uc-008"></a>

## UC-008 · P2 · S2 — Списки выбора, отфильтрованные по доступности, теряют сохранённое значение: сохранение правила меняет action на Connection, удаляет DPI-стратегию и перенаправляет ссылки на другие секции

**Severity:** P2<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** frontend/settings + rule editor<br>
**Sources:** frontend-arch#1, uci-rules#3, uci-global#4, uci-rules#4<br>
**Original title:** Availability-filtered select lists drop the configured value; the next Save silently rewrites rule action / DNS detour / download sections<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** section.js:3844-3861 populateActionOptionValues adds 'zapret'/'zapret2'/'byedpi' only `if (isZapretInstalledForUi())` etc.; the action ListValue (section.js:6866-6885) re-populates on load and returns cfgvalue 'zapret'. nfqws_opt `o.depends("action", "zapret")` has no retain (section.js ~6949-6955), and parseStrategyWithRemoteValidation removes it when inactive (`if (!this.retain) return Promise.resolve(this.remove(section_id))`). settings.js:25-57 refreshDownloadSectionChoices keeps only `sec.enabled !== "0" && isDownloadSectionAction(...)`, used for dns_detour_section (settings.js:309-315) and download_lists/components_via_proxy_section (620-649); same pattern at section.js:108-133/136 (rule dns detour) and 1733-1759 (subscription download target). LuCI ui.Select (ui.js) renders <option>s only for choice keys, so the browser selects the first option and getValue() returns it.


**Reproduction:** Set dns_detour_enabled=1 and dns_detour_section=X, disable rule X, Save & Apply, reload Settings, change any unrelated setting, then Save. uci show forkop.settings.dns_detour_section now names another rule. Or: remove Zapret in Components, open a zapret rule, edit its label, Save: action=connection and nfqws_opt is gone.


**Expected:** The configured value survives a round-trip unchanged, or Save is blocked with a clear message (fail closed).


**Actual:** The configured value is missing from the choices. The select shows the first choice, and LuCI parse writes it because cfgvalue != formvalue. Dependent DPI options are removed.


**Impact:** (a) A zapret/zapret2/byedpi rule whose provider is not installed (removed via Components, broken, or detection failed) is converted to 'connection' by any save of its edit modal, even one that only changes the label. Its DPI strategy (nfqws_opt/nfqws2_opt/byedpi options) is deleted. Reinstalling the provider does not bring the rule back. (b) If the section used for DNS detour or list/component downloads is later disabled, or its provider is missing, the next Save of Settings re-points the router's DNS or download path to whichever eligible rule comes first. This is a silent routing mutation the user never requested (invariant 16). If no rule is eligible, Save fails with a confusing 'must not be empty'. Borderline P1 (unsafe mutation), but it needs a precondition.


**Root cause:** Choices are built from current availability/enabled state without including the persisted value, combined with LuCI Select semantics (no option for unknown values).


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js`

**Proposed fix:** In populateActionOptionValues, refreshDownloadSectionChoices, refreshDnsDetourSectionOptionValues and subscriptionDownloadTargetChoices, always add the currently configured value as a choice. Label it e.g. '<label> (disabled)' or '<provider> (not installed)'. Give the option a validate() that rejects that choice with an explicit message, so Save fails closed until the user picks deliberately. Never let the browser fall back to the first option.


**Tests needed:** A node test with a LuCI form/ui stub: (1) rule with action=zapret while zapretInstalled=false -> the action choices contain 'zapret' and validate() rejects it; (2) dns_detour_section pointing to a disabled rule -> the choice is present and Save is rejected, never rewritten.


**Verification:** confirmed → P2

**Verification evidence:**

Rule action (part a), confirmed:
- section.js:3844-3861 `populateActionOptionValues` adds zapret, zapret2 and byedpi only under `if (isZapretInstalledForUi())` and the matching checks. section.js:6877-6885: `o.cfgvalue` still returns the raw configured action, and `o.load` repopulates the choices, then returns `this.cfgvalue(section_id)`.
- LuCI (feed checkout 128a7812) ui.js UISelect.render emits an <option> only for keys in `sort: this.keylist`, marked `'selected': (this.values.indexOf(keys[i]) > -1)`. `getValue()` returns `this.node.firstChild.value`, so the browser falls back to the first option, "connection".
- form.js:2137-2178 AbstractValue.parse writes when `!isEqual(cval, fval)`. When the option is inactive it does `else if (!this.retain) return ... this.remove(section_id)`.
- GridSection.parse (form.js:4115-4128) skips modalonly options on the main Map save, so this only happens on the modal Save. That modal Save is the normal edit path, and no override exists: configureSectionSection (section.js:7849-7866) only wraps handleRemove and load.
- nfqws_opt (section.js:6948-6954, `o.depends("action", "zapret")`, no retain) removes itself through parseStrategyWithRemoteValidation at section.js:6430-6431. nfqws2_opt (7001) and byedpi_cmd_opts (7044) have no retain either.
- Nothing upstream blocks the precondition. components/action.uc:1289-1308 `remove_optional_component` removes zapret, zapret2 or byedpi without checking the rules that use them. The backend treats a provider-missing DPI rule as valid and keeps it: config/validator.uc:1406-1410 `if (!context.zapret_installed) { validate_common_rule_references(...); return; }`. generator.uc:2314-2322 still emits its outbound. So the UI turns a valid, deliberately tolerated config into a different one.
- Detection failure makes it worse. When getUiCapabilities, getUiState and the per-provider RPCs all fail, shell.js:114-151/183 and section.js:3717-3722 set every provider to not installed with `loaded=true` for the rest of the page session.
- Aggravating effect, not in the original finding: the rewritten rule is a Connection rule with no sources. The validator accepts it, because it requires sources only for download targets (validator.uc:637). Then generator.uc:2281-2282 runs `runtime_generate_unsupported("connection section has no usable outbounds")`, which calls exit(2) (generator.uc:161-163; pinned by tests/sing_box_runtime.sh:133-137). If the rule is enabled, the whole Forkop reload fails at generation. If it is disabled, the change is completely silent.

Download / DNS-detour targets (part b), confirmed mechanically but lower impact:
- settings.js:43-59 keeps only `sec.enabled !== "0" && isDownloadSectionAction(...)`, and configureDownloadSectionOption (61-86) returns the raw cfgvalue.
- The same pattern appears at section.js:112-148 (rule DNS detour, load at 6940-6943) and section.js:1728-1766 (subscription download target, load at 2302-2306).
- The settings TypedSections are parsed on every Settings Save & Apply (page/settings.js:205-222), so the rewrite happens even when the user saves an unrelated rule.
- However, the backend already rejects the precondition state: validator.uc:982-987 (settings DNS detour to a missing or disabled rule, or a provider-missing action), 625-635 (download sections) and 1380-1385 (rule DNS detour). The UI does not break a valid config here. It silently repairs an invalid one by picking an arbitrary section, while displaying that pick as if it were the configured value.

Tests: nothing pins this behaviour. tests/ has no case covering populateActionOptionValues, refreshDownloadSectionChoices or isDnsDetourTargetSection filtering. The only reference, tests/helpers/config_contract_matrix.js:132, just enumerates the literal values.


**Verification reproduction:**

Scratch script (read-only against the tree): scratch/audit-verify-select-drop\repro.js, run with WSL node 18.

The script extracts and runs the real Forkop functions: populateActionOptionValues, getRuleConfiguredAction and parseStrategyWithRemoteValidation from section.js, and isDownloadSectionAction, refreshDownloadSectionChoices and configureDownloadSectionOption from settings.js. It runs them together with the real LuCI UISelect.render/getValue (ui.js) and AbstractValue.parse/isEqual (form.js) from ~/.cache/flint2-openwrt/openwrt/feeds/luci. A small DOM stub implements HTML single-select default selectedness (no option selected means the first option is selected).

Output:
A: configured action = zapret | choices = ["connection","bypass","block","dns"] | widget value = connection
A: uci ops = [["set","rule1","action","connection"],["unset","rule1","nfqws_opt"]]
A: rule after modal save = {".name":"rule1",".type":"section","action":"connection","label":"YouTube"}
B: configured dns_detour_section = vpn_x | choices = ["conn_y"] | widget value = conn_y
B: uci ops = [["set","settings","dns_detour_section","conn_y"]]
C: choices = [] | widget value = "" | save rejected: Option "dns_detour_section" contains an invalid input value. Select a section
ALL CASES REPRODUCED

Limits: this is not a real browser. Real modal cloning (cloneOptions) and checkDepends were checked statically against form.js:3765-3822 and 2087-2090. No router was used. The follow-on generator exit for an empty Connection rule is proven statically and pinned by an existing test; it was not re-run.


**Verification notes:**

Severity: stays P2, not P1. Part (a) silently corrupts persistent rule config in a normal workflow. A rule whose provider was removed through Forkop's own Components page loses its action and DPI strategy on any modal Save. If the rule is enabled, the next Save & Apply also makes the whole sing-box generation fail. I did not rate it P1 because Save & Apply first takes an automatic pre-apply snapshot (page/settings.js:95-117), so History & recovery can restore the lost strategy, and an enabled rule shows "reload not confirmed". Part (b) alone would be P3: the backend already rejects the precondition, so the UI only chooses a replacement the user never picked, which is misleading (invariants 15 and 18).

Corrections to the finding:
1. Line refs: rule DNS-detour filter is section.js:112-134, with refresh at 136-148 and load at 6940-6943. Subscription target is 1728-1766 plus use at 2301-2306. nfqws_opt is 6948-6954; byedpi_cmd_opts (7038-7074) uses default parse and is lost the same way.
2. Reproduction step (b) is wrong as written. Disabling X and then Save & Apply does not apply cleanly: the backend validator aborts with "DNS through a section references disabled rule" (validator.uc:984-985). The rewrite to the first eligible rule happens on the next Save & Apply, and it is triggered by any Settings save, not only DNS-tab edits.
3. Impact (a) is understated. The rewritten rule is an empty Connection rule, so generator.uc:2281-2282 exits 2 and the whole Forkop reload or next restart fails, not just that rule.
4. Impact (a) has an extra trigger: a transient RPC failure in capability detection marks every provider as not installed for the page session (shell.js:114-151, section.js:3717-3722).

Minimal fix, refined:
- Action (populateActionOptionValues(option, section_id)): always add the configured action when it is missing, labelled e.g. "Zapret (not installed)". Allow saving it unchanged, because the backend deliberately accepts provider-missing DPI rules (validator.uc:1406-1410). Do not reject it in validate(), or editing such a rule's label would be blocked. Test that nfqws_opt/nfqws2_opt/byedpi_cmd_opts stay unchanged, so their remote validator is not called while the provider is missing.
- Settings dns_detour_section and download_*_section, rule dns_detour_section, subscription download_via_proxy_section: add the configured value as a choice labelled "(disabled)" or "(unavailable)". Give it a validate() that rejects it with the backend's explicit message, which matches validator.uc (fail closed) and never falls back to the first option.
- Tests: a node test in the style of this repro covering (1) action=zapret with the provider missing: the choice is present, and a label-only save leaves action and nfqws_opt unchanged; (2) dns_detour_section pointing to a disabled rule: the choice is present, Save is rejected, and nothing is rewritten.


### Also reported as uci-rules#3 (P2): Editing a DPI rule while its provider is not detected converts it to Connection and deletes the strategy

**Evidence:** section.js:3844-3861 populateActionOptionValues adds zapret/zapret2/byedpi only `if (isZapretInstalledForUi())` etc. section.js:6866-6885 action ListValue cfgvalue returns the raw stored action. LuCI ui.Select (ui.js:832-839) marks no <option> selected when the value is not among the choices, so the browser submits the first option "connection". nfqws_opt/nfqws2_opt/byedpi_cmd_opts depend on their action with no retain (section.js:6954, 6998-7000, 7044). Detection failure sets all providers false (section.js:3716-3722). The backend explicitly tolerates DPI rules without the provider (validator.uc:1409-1428 `if (!context.zapret_installed) { validate_common_rule_references(...); return; }`). An empty connection is not caught by the validator but fails in the generator (generator.uc:2281-2282 `connection section has no usable outbounds`).


**Proposed fix:** In populateActionOptionValues always add the rule's currently configured action if missing (label it e.g. 'Zapret (not installed)'), or make the ListValue refuse to change a stored value that is not in the choices. Set retain=true on nfqws_opt/nfqws2_opt/byedpi_cmd_opts, or clear them only when the user actually changed the action.


**Verification:** confirmed → P2

**Verification notes:**

Line-reference corrections: nfqws2_opt depends at section.js:7001, not 6998-7000. The validator's provider-tolerant branch is validator.uc:1406-1428, not 1409. The catch branch is section.js:3717-3722. The strategy removal comes from the custom parseStrategyWithRemoteValidation at section.js:6430-6432 for nfqws and nfqws2, and from the default AbstractValue.parse for byedpi.

Triggers, from most to least likely:
- a documented flow: provider removed via Settings -> Components (action.uc:2609-2618), with rules left in place because the backend tolerates them;
- sysupgrade wiping /opt/zapret;
- all three capability RPC tiers failing transiently (shell.js:154-191), which makes providers false even when they are installed and active.

Impact adjustments:
- The change is not fully invisible. The Basic tab shows Action = Connection and the NFQWS field disappears. But the user cannot select Zapret at all, so a DPI rule whose provider is not detected cannot be edited at all without losing its action and strategy. Cancel is the only safe exit.
- After Save & Apply the reload fails at staged sing-box config generation (lifecycle.uc:1831-1835 `abort_reload(status, false)`). The running runtime is preserved, and page/settings.js shows the "Runtime reload has not been confirmed" warning.
- Because UCI is already committed, the next start or boot fails at the "sing-box-config" phase (lifecycle.uc:951-953) until the user fixes the rule.
- Recovery exists: handleSaveApply takes an automatic pre-apply snapshot (page/settings.js:95-117), and LKG still holds the pre-edit config. That keeps this at P2 rather than P1.
- Variant: if a converted rule still carried connection sources (e.g. created via CLI or import), the conversion would silently route DPI traffic through the proxy with a successful apply.
- The same root cause turns legacy actions proxy, vpn and outbound into connection (harness confirmed). That is low impact because connections.uc:298-306 normalizes them to connection anyway.

Better minimal fix:
- Pass the section's configured action into populateActionOptionValues from the action ListValue's o.load (section_id is available there). Append the configured action when it is missing, with a localized label such as _("Zapret (not installed)"); this needs .pot/ru.po entries. The declaration-time call stays provider-gated, so new rules still only offer installed providers.
- With the action preserved, nfqws_opt, nfqws2_opt and byedpi_cmd_opts stay active and untouched. Their parse only calls remote validation when the value changed, so retain=true is not needed. retain=true would also leave stale strategies behind when the user deliberately switches action, so skip it or treat it as a separate decision.

Test to add: a node round-trip in the style of tests/luci_hidden_rule_options.sh (section.js is hand-written). Load the rule modal with providers {zapretInstalled:false, zapret2Installed:false, byedpiInstalled:false}, save without edits, and assert that action and the strategy option are unchanged for zapret, zapret2 and byedpi. Include a control with the provider present.


### Also reported as uci-global#4 (P3): Settings 'through section' dropdowns silently rewrite a reference to the first eligible rule when the configured rule is disabled or ineligible

**Evidence:** settings.js:43-59 refreshDownloadSectionChoices builds keylist from enabled rules with an eligible action only (`sec.enabled !== "0" && isDownloadSectionAction(...)`), and cfgvalue returns the configured name (settings.js:64-70). LuCI ListValue.renderWidget passes sort=this.keylist and optional=false to ui.Select, which renders no <option> for a value outside keylist, so the browser selects the first option. CBIAbstractValue.parse then writes it because !isEqual(cval,fval) (LuCI form.js 24.10, lines 702-719). The snapshot diff masks dns_detour_section/download_*_section as '***' (snapshots.uc:206-213). The same pattern exists in section.js:6930-6945 (DNS-rule dns_detour_section).


**Proposed fix:** In the load/refresh functions, if the configured value is not in keylist, add it with a label such as '<name> (unavailable)' so the widget keeps it and validation fails visibly. Filter out Connection rules without sources, to match the validator.


### Also reported as uci-rules#4 (P3): Reference ListValues silently re-point to another rule when the stored target is not currently eligible

**Evidence:** section.js:6929-6946 DNS rule dns_detour_section ListValue, whose choices come from refreshDnsDetourSectionOptionValues. isDnsDetourTargetSection (section.js:111-131) excludes enabled=="0" and uninstalled DPI providers. section.js:2296-2320 subscription download_via_proxy_section uses subscriptionDownloadTargetChoices. settings.js:43-86 refreshDownloadSectionChoices/configureDownloadSectionOption, used for settings dns_detour_section (settings.js:307-315) and download_*_via_proxy_section (settings.js:621-662). The settings ones are parsed on every Settings Save & Apply. ui.Select picks the first option when the stored value is absent.


**Proposed fix:** When the stored value is not in the choices, add it as a choice marked '(unavailable)' so validation reports it, or make validate() reject it with a message, instead of letting the widget substitute the first choice.


---

<a id="uc-009"></a>

## UC-009 · P2 · S0 — Backend CI без uci CLI: 5 тестов autotune всегда падают без вывода и блокируют release

**Severity:** P2<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** CI / test environment<br>
**Sources:** tests#0<br>
**Original title:** Backend CI has no uci CLI: 5 autotune tests always fail (with no output), which blocks the release workflow<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-5

**Evidence:** .github/workflows/backend-ci.yml:47-51 builds only ucode ('-DUCI_SUPPORT=OFF') and never installs the OpenWrt uci CLI; lines 68-70 run every tests/*.sh ('for test_file in tests/*.sh; do ... bash "$test_file"'). forkop/files/usr/lib/autotune/manager.uc:43 'const UCI = getenv("FORKOP_AUTOTUNE_UCI") || "uci";' and :257-260 uci_apply() shells out to it. The tests call it with no prerequisite check: tests/autotune_groups.sh:125 'manager policy-set mode auto >"$WORK/mode.json"', autotune_recovery.sh:29, autotune_manual_apply.sh:54, helpers/autotune_scheduler/setup.sh. .github/workflows/build.yml:136-139 'release: needs: ... backend-checks'. Reproduced with the runner: without ~/.local/openwrt-uci/bin on PATH, autotune_groups, autotune_manual_apply, autotune_autoapply, autotune_scheduler and autotune_recovery FAIL in 0.2-0.6 s with EMPTY logs; with uci on PATH they PASS.


**Reproduction:** wsl: FORKOP_TEST_CACHE=~/.cache/x bash tests/runner/run.sh --lanes backend 'autotune_*'  (without ~/.local/openwrt-uci/bin on PATH) -> 5 FAIL with empty logs; add it to PATH -> PASS


**Expected:** CI provides every tool the suite needs, and a missing prerequisite produces an explicit failure message.


**Actual:** On ubuntu-24.04 without the uci CLI, the five tests exit 1 with no diagnostic, and Backend CI (and the release job) fail.


**Impact:** The Backend CI job cannot pass on GitHub runners since Stage 6.8.2 (commit 413e3914). A permanently red job hides real regressions in the other 150+ tests, and the tag-driven release job (needs backend-checks) cannot publish. When the tests fail, CI records 'Backend regression failed:' with an empty reason, because manager exits non-zero under set -e with output redirected to a file.


**Root cause:** Stage 6.8.x moved autotune policy/target writes to the real 'uci -c DIR -t SAVEDIR' CLI (private save directory semantics), but the CI environment was not updated and the tests have no prerequisite check.


**Affected files:** `.github/workflows/backend-ci.yml`, `tests/autotune_groups.sh`, `tests/autotune_manual_apply.sh`, `tests/autotune_autoapply.sh`, `tests/autotune_scheduler.sh`, `tests/autotune_recovery.sh`, `tests/helpers/autotune_scheduler/setup.sh`

**Proposed fix:** Add a CI step that builds libubox + uci from source (cmake, same pattern as the ucode step), or installs a pinned prebuilt, and puts the uci CLI on PATH. In the five tests, add an explicit prerequisite check at the top, e.g. 'command -v uci >/dev/null || fail "OpenWrt uci CLI required (tests need uci -c/-t semantics)"', so a missing tool fails loudly instead of silently.


**Tests needed:** A green Backend CI run on a PR, plus a check that removing uci from PATH makes the five tests fail with the explicit prerequisite message.


**Verification:** confirmed → P2

**Verification evidence:**

The failure is real. I read the code in worktree 07872084 and also reproduced it.

- .github/workflows/backend-ci.yml:47-53 clones and builds only ucode ('-DUCI_SUPPORT=OFF' at line 50). No step installs the OpenWrt uci CLI. Lines 67-85 run every tests/*.sh as 'if output="$(bash "$test_file" 2>&1)"'. On failure, the reason comes from 'tail -n 20' of that output.
- forkop/files/usr/lib/autotune/manager.uc:43 has 'const UCI = getenv("FORKOP_AUTOTUNE_UCI") || "uci";'. uci_apply() at :253-263 runs [UCI, "-c", dir, "-t", savedir, ...] through success() at :76. success() is 'system(command(args) + " >/dev/null 2>&1") == 0', so the shell's "uci: not found" message is discarded. The result is {status:"failed", reason:"uci_failed"}, and :869 then calls 'exit(output.status == "ok" ? 0 : 1)'.
- The five tests call manager policy-set with stdout sent to /dev/null or to a file in $WORK, and $WORK is deleted by the trap. They run under 'set -euo pipefail' and have no prerequisite check. Nothing is written to stderr, so the test output is empty.
- First failing line in each test, confirmed with bash -x:
  - autotune_groups.sh:125 'manager policy-set mode auto'
  - autotune_recovery.sh:29
  - autotune_manual_apply.sh:54
  - autotune_autoapply.sh:78
  - autotune_scheduler.sh:25
- The last four source tests/helpers/autotune_scheduler/setup.sh. It sets FORKOP_AUTOTUNE_UCI_SAVEDIR but not FORKOP_AUTOTUNE_UCI.
- The scope is exactly these five tests. Only autotune/manager.uc:43 and autotune/apply.uc:45 shell out to the uci CLI. autotune_apply.sh:20 points FORKOP_AUTOTUNE_UCI at a stub, and setup.sh replaces apply.uc with a stub. autotune_state.sh only calls the read commands 'status' and 'target'.
- .github/workflows/build.yml:130-140: the release job 'needs: preparation, build, backend-checks, frontend-checks', and backend-checks is 'uses: ./.github/workflows/backend-ci.yml'. A red backend CI therefore skips the GitHub release. The build job does not depend on it, so artifacts are still built.
- The regression dates from 413e3914 (6.8.2). 'git log -S"\"-t\", dir"' on manager.uc points there. The CI workflow was last changed in f8a72dcf, and the workflow files are identical to origin/main.
- There is no uci stub in the tests and no documentation of the prerequisite: rg over docs/ and tests/*.md finds nothing.


**Verification reproduction:**

I wrote a scratch script (scratch/audit-verify-ci-uci/repro.sh). It copies the worktree to a private mktemp directory, uses a private TMPDIR, and runs a replica of the CI loop from backend-ci.yml:67-85 under WSL. By default WSL has no uci ('command -v uci' finds nothing; node is at /usr/bin/node).

Without uci on PATH:

| Test | Exit code | Time | Output size | CI error text |
|---|---|---|---|---|
| autotune_groups | 1 | 111 ms | 0 bytes | empty |
| autotune_recovery | 1 | 100 ms | 0 bytes | empty |
| autotune_manual_apply | 1 | 108 ms | 0 bytes | empty |
| autotune_autoapply | 1 | 244 ms | 0 bytes | empty |
| autotune_scheduler | 1 | 292 ms | 0 bytes | empty |
| autotune_apply (control, uses the stub) | 0 | 93.7 s | – | – |

With ~/.local/openwrt-uci/bin on PATH, all five pass:
- groups: 'autotune groups checks passed', 0.3 s
- recovery: OK, 12.6 s
- manual_apply: OK, 17.9 s
- autoapply: OK, 5.5 s
- scheduler: OK, 14.3 s

Running 'manager.uc policy-set mode recommend' directly without uci prints '{ "status": "failed", "reason": "uci_failed" }' and exits 1. trace.sh (bash -x) shows that each test stops at its first 'manager policy-set' call.

I did not observe this on GitHub. 'gh api repos/Asofwar/forkop/actions/runs' reports total_count 0 (Actions is enabled, and the four workflows are active). The claim that the GitHub-hosted runner lacks uci rests on the workflow text: nothing installs it, and uci is not part of the ubuntu-24.04 image. The worktree was left unchanged; 'git status' shows only the pre-existing untracked tests/runner/.


**Verification notes:**

I keep P2 as a "broken major workflow", with some context. The breakage has not reached any shipped release yet. 413e3914 through 07872084 exist only on origin/feature/observability-safety-ux and origin/claude/project-thread-wcqm6t, not on origin/main or any tag, and the repo has no recorded Actions runs. It becomes a hard blocker as soon as a PR from this branch runs Backend CI, or the branch is merged and tagged. There is no runtime or router impact, because OpenWrt always ships uci. The empty CI error message on its own would be P3.

Line-reference corrections:
- The uci_apply body is manager.uc:253-263 (the finding said 257-260).
- The silent failure comes from success() at manager.uc:76, which sends both stdout and stderr of the uci call to /dev/null. The test redirections alone do not explain it. On top of that, the manager JSON is written into $WORK, which is deleted.
- build.yml: the 'needs' block is 136-140, and the release job starts at 130.

Minimal fix:
1. Add a step to backend-ci.yml after the ucode build. It should build libubox and uci from git.openwrt.org at pinned commits with '-DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF', install and run ldconfig, then check 'command -v uci'. libjson-c-dev and cmake are already installed.
2. Do not replace the real CLI with a stub in these five tests. They deliberately exercise the real '-c/-t' private save-directory semantics and the 'staged UCI changes block writes' guard (autotune_groups.sh:128-130).
3. Put the prerequisite check once in tests/helpers/autotune_scheduler/setup.sh, which covers four of the tests, and once at the top of tests/autotune_groups.sh. For example: 'command -v uci >/dev/null 2>&1 || { echo "FAIL: OpenWrt uci CLI (uci -c/-t) required" >&2; exit 1; }'.
4. Optionally, document the local prerequisite (the libubox+uci build in ~/.local/openwrt-uci) next to tests/runner, which is currently untracked.

No product decision is needed.


---

<a id="uc-010"></a>

## UC-010 · P2 · S3 — Отложенный start из init.d регистрирует PID завершающейся оболочки rc.common владельцем reload.lock — сериализация start/reload не работает

**Severity:** P2<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A7 locks / A6 start lifecycle<br>
**Sources:** process-locks#0<br>
**Original title:** Detached init.d start registers the exiting rc.common shell PID as reload.lock (and UI job) owner, so start/reload serialization is broken for every start<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/files/etc/init.d/forkop:38-41 `if [ -e "/proc/$$/fd/1000" ]; then initd_ucode start-service "$1" "$$" ... 1000>&- &` then `return 0`. OpenWrt package/system/procd/files/procd.sh:48-76,686 (checked in ~/.cache/flint2-openwrt, 2026-06): sourcing procd.sh runs `_procd_wrapper` -> `procd_lock` -> `exec 1000>/var/lock/procd_<svc>.lock`, so fd 1000 exists in EVERY init.d invocation and the detached branch is always taken. service/initd.uc:603-604 `let runtime_lock_owner = owner_pid || owner_pid_value(); acquire_runtime_dir_lock_wait(RELOAD_LOCK_DIR, runtime_lock_owner, ...)`; initd.uc:212 / state.uc:325 stale test `pid_alive(first_line_value(lock_dir + "/pid"))` (kill -0); initd.uc:611,616 `release_runtime_dir_lock(RELOAD_LOCK_DIR)` without any owner check (190-197). initd.uc:581/447 the same dead PID becomes the service-action job pid (`service-action-update-pid`). lifecycle.uc:1378-1381 relies on this: "initd serializes both with reload.lock". lifecycle.uc:1042,1051 start_impl itself spawns list-update-after-start and automatic-latency-test, and both wait on reload.lock (updates.uc:3944, diagnostics/runtime.uc:1924). Repro: scratch/audit-a6a7/repro_detached_start_lock.sh printed `owner DEAD while start is running`, `RACE: competitor acquired reload.lock while detached start holds it`, and `start's release removed the competitor's lock`.


**Reproduction:** wsl bash scratch/audit-a6a7/repro_detached_start_lock.sh (no router needed)


**Expected:** The detached start worker owns reload.lock with a live, verifiable identity until it finishes, and release never removes another owner's lock.


**Actual:** reload.lock/pid = PID of the rc.common shell, which exits within milliseconds. Any contender treats the lock as stale and takes it while `forkop start` runs. The start's release then removes the contender's lock.


**Impact:** The reload.lock excludes nothing during a start, and the start's final release deletes whoever stole the lock. At boot with a due list update, list-update-after-start steals reload.lock and starts downloads and nft snapshots while start is still verifying. Start then deletes that lock, so further reloads (config trigger, ruleset-cache, badwan) run concurrently with the list worker and with each other. The same holds for a second start (postinst, WAN retry, component restart), snapshot restore and autotune apply reloads, forced subscription updates and dns_failover_apply. Concurrent start_impl/reload/sing-box transitions end in refused or failed transitions, cleanup_failed_runtime (Forkop down plus 30 s retries) or an incoherent runtime. For non-UI starts, the UI job is marked 'Service action worker exited unexpectedly' after 15 s while the start is still running, then flips to success (invariant 15).


**Root cause:** The init script passes `$$` (the parent shell) as the owner of work it has just backgrounded. Lock ownership is a bare PID checked with kill -0, and release is unconditional.


**Affected files:** `forkop/files/etc/init.d/forkop`, `forkop/files/usr/lib/service/initd.uc`, `forkop/files/usr/lib/service/state.uc`, `tests/start_reload_serialization.sh`

**Dependencies:** Fix together with the reload/subscription lock-order inversion (P3 finding below). Related to the start/restart exit-status finding (same detached branch).


**Proposed fix:** Minimal change: in the detached branch pass no owner (`initd_ucode start-service "$1" "" ...`). initd.uc then uses its own live PID for the whole start; better, derive it from /proc/self and record pid+start ticks. Make release_runtime_dir_lock (initd.uc, state.uc) remove the lock only when its pid file still names the releasing owner. Treat an owner as stale only when pid+ticks no longer match (reuse core/process_identity.record/matches). Apply this together with the lock-order fix below, because it activates the reload/subscription inversion.


**Tests needed:** Extend start_reload_serialization.sh: run the real init.d start_service logic with fd 1000 open (bash wrapper, as in the repro), assert that a competing acquire-runtime-dir-lock fails while the stub `forkop start` is still running, and assert that the start's release leaves a lock owned by another PID intact. Add a UI-state test: a non-UI start job must not turn stale while start.in-progress is live.


**Risk:** Low. With the fix, a start waits for real reload holders (list/subscription updates) up to START_RUNTIME_LOCK_WAIT_SECONDS=30 and may be deferred more often; see the note in extra about deferral scheduling no retry.


**Verification:** confirmed → P2

**Verification evidence:**

1) The detached branch runs on every init.d invocation. rc.common (flint2 OpenWrt tree, package/base-files/files/etc/rc.common) sources procd.sh when USE_PROCD=1. At source time procd.sh:686 `_procd_wrapper` calls `procd_lock` (procd.sh:48-58). That function runs `flock -n 1000 &>/dev/null`, which fails because fd 1000 is not open, and then `exec 1000>"$IPKG_INSTROOT/var/lock/procd_${service_name}.lock"; flock 1000`. BUSYBOX_DEFAULT_ASH_BASH_COMPAT defaults to y, so `&>` parses as intended on the router. As a result `/proc/$$/fd/1000` always exists in start_service (forkop/files/etc/init.d/forkop:38), for boot, CLI, the UI worker (it closes 1000 but rc.common reopens it), package.uc postinst_restore (`INIT_PATH start`, package.uc:230), the WAN retry and the start-retry worker. The synchronous branch (lines 44-46) only ever runs in tests.
2) Line 39 `initd_ucode start-service "$1" "$$" ... 1000>&- &` passes the PID of the rc.common shell. That shell returns at line 41 and exits within about 0.1 s.
3) initd.uc:603-604 `let runtime_lock_owner = owner_pid || owner_pid_value(); acquire_runtime_dir_lock_wait(RELOAD_LOCK_DIR, runtime_lock_owner, ...)` stores that dead PID. Contenders treat the lock as stale through `pid_alive(first_line_value(lock_dir + "/pid"))` (kill -0) at initd.uc:212 and state.uc:325, then rm, rmdir and mkdir it.
4) initd.uc:616 `release_runtime_dir_lock(RELOAD_LOCK_DIR)` is unconditional (initd.uc:190-197 and state.uc:303-310 have no owner check), so it deletes whoever took the lock.
5) initd.uc:581 → 447 `service-action-update-pid job_id owner_pid` gives the non-UI start job the same dead PID. ui.uc:716-730 refresh_pid_job_state marks it stale after ACTION_STALE_GRACE_SECONDS (15), and finished_action_state_value (ui.uc:650) later overwrites it with success.
6) The design relies on this lock:
- lifecycle.uc:1378-1381 ("initd serializes both with reload.lock").
- updates.uc:3786 ("Startup owns the lifecycle lock").
- updates.uc:3944 (the list worker waits up to 300 s on reload.lock).
- diagnostics/runtime.uc:1924-1925 (the latency test waits on reload.lock).
- lifecycle.uc:1621 (dns_failover_apply).
- lifecycle.uc:983-992 refresh_rulesets_after_start → `init.d reload ruleset-cache`.
- autotune/apply.uc:246-248 service_action() uses `/proc/<reload.lock pid>` as its "no_service_action" precondition for apply (389), stale_reason (564) and rollback (769).
start_impl spawns list-update-after-start, refresh-rulesets-after-start and automatic-latency-test (lifecycle.uc:1038-1051) before start_inner's wait-forkop-stable-start. That is the verification window these workers now enter.
7) No test covers the detached branch. tests/start_reload_serialization.sh calls initd.uc directly with a live "$$". tests/service_start_trap.sh:106-109 only checks the init script text.


**Verification reproduction:**

I wrote scratch/audit-verify-detached-start-lock/repro.sh and ran it in WSL with a private mktemp TMPDIR. It uses the real OpenWrt rc.common, procd.sh, functions.sh and service.sh from ~/.cache/flint2-openwrt, with IPKG_INSTROOT pointing at a fake root, no-op jshn/ubus stubs and bash standing in for busybox ash. The Forkop init script is byte-identical except for its hard-coded FORKOP_LIB path (the diff is printed). The backend `forkop start` stub sleeps 6 s. The run was a non-UI start (FORKOP_UI_ACTION_TRACKED unset) with the stale grace set to 2 s. Observed output:
[1] "/etc/init.d/forkop start" returned rc=0 after 0.13s; procd_forkop.lock was created by procd_lock at source time. The detached branch was taken with no fd 1000 inherited.
[2] reload.lock/pid=24238; the owner was DEAD while the backend start was running (backend pid 24310).
[3] RACE: a list-update-style competitor calling `state.uc acquire-runtime-dir-lock-wait` acquired reload.lock while the start was running.
[4] With the start still running, the UI job became {running:false, success:false, message:"Service action worker exited unexpectedly", pid:"24238"}.
[5] The backend-end line logged reload.lock/pid=24403, the competitor. After initd's release the lock dir was gone while competitor 24403 was still alive.
[6] The UI job ended as {success:true, message:"Service start completed"}.
The original auditor's simplified repro, which used a bash `exec 1000>`, gave the same result. I also checked `sh -c 'echo $PPID'` through ucode popen under dash: it returned a transient shell PID, not the ucode PID (ppid.uc). This matters for the fix (see notes). Runtime effects past the lock itself (sing-box or nft interference during start verification) need a real router and are argued statically.


**Verification notes:**

The finding is correct in substance and P2 is right: every real start breaks start-vs-reload serialization, and the unconditional release destroys whoever took the lock. The impact needs these corrections:
(a) Reloads started through init.d do NOT run concurrently with each other. rc.common holds the procd flock, taken at source time, for the whole synchronous reload_service. The real concurrency is:
- the detached start worker, which closed fd 1000 and holds no flock, against init.d reloads;
- in-process reload.lock users (list/subscription update, latency test, dns_failover_apply, autotune apply/rollback preconditions) against the start;
- after start's release wipes their lock, those users against later init.d reloads;
- a second detached start against the first.
The most concrete boot scenarios:
- With list sources, list-update-after-start takes reload.lock during wait-forkop-stable-start.
- Without list sources, refresh_rulesets_after_start calls `init.d reload ruleset-cache`, which now runs during start verification. That can fail verification and trigger cleanup_failed_runtime, bringing Forkop down until the 30 s retry.
(b) Extra consumer the finding missed: autotune/apply.uc:246-248 service_action() reports no service action during a start. The Stage 5 apply, stale_reason and rollback preconditions therefore pass while a start is in progress, which weakens invariant 18.
(c) The UI/invariant-15 sub-impact is overstated. The frontend polls only its own job ids, and Overview still shows "starting" through start.in-progress, which has a live lifecycle PID. What is actually visible: after 15 s active_service_action becomes empty, so begin_service_action_if_idle accepts UI stop/reload during an ongoing non-UI start (start/restart stay blocked by start_worker_running), and config-change queueing loses its active-action signal (partly mitigated by mark_pending_reload_if_config_changed).
(d) The comment at init.d:33-37 ("rcS/procd keeps its service transaction on fd 1000") is inaccurate. fd 1000 is procd.sh's own lock, so the synchronous branch is dead code on OpenWrt.
Fix corrections:
- Passing "" makes initd.uc fall back to owner_pid_value() (`sh -c 'echo $PPID'`). That returns the ucode PID only when /bin/sh execs the last -c command. busybox ash does; dash, used on the test hosts, does not (confirmed). Take the PID from /proc/self/stat instead, as ui.uc current_pid() does, preferably recorded as PID plus start ticks through core/process_identity.
- Make at least initd.uc start_service's release owner-checked (compare the pid file with runtime_lock_owner before rm/rmdir). state.uc release-runtime-dir-lock callers pass no owner, so an owner-checked state.uc release needs call-site changes.
- Fix together with the reload→subscription vs subscription→reload lock-order inversion (lifecycle start_main:892 vs updates.uc:4335-4342). With a live owner, a forced subscription update and a start will wait on each other for up to 300 s.
- Add a test that runs the real init.d start_service with fd 1000 open, as the repro does.


---

<a id="uc-011"></a>

## UC-011 · P2 · S3 — Каталоговый lock без записанного pid считается устаревшим, release безусловный — два процесса одновременно держат reload.lock

**Severity:** P2<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A8 transaction markers/locks<br>
**Sources:** persistence#2, process-locks#6<br>
**Original title:** Runtime directory lock treats a lock whose owner has not yet written its pid as stale, so two processes hold the reload lock<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/state.uc:312-339 (duplicated in service/initd.uc:199-226): `if (command_success_from_args([ "mkdir", lock_dir ])) { if (lock_dir_write_owner(lock_dir, owner_pid)) return true; ...}` then, for a contender, `if (pid_alive(first_line_value(lock_dir + "/pid"))) return false; command_success_from_args([ "rm", "-f", lock_dir + "/pid" ]); ... rmdir ... mkdir ...`. pid_alive('') is false. Scratch repro_lock_steal.sh: with the lock dir created but no pid yet, a second acquirer prints 'GOT the lock'; the first owner then writes its pid, so both believe they own it. Users: RELOAD_LOCK_DIR (initd.uc:604,690,712; lifecycle.uc:1621; diagnostics/runtime.uc:1925,1994), SUBSCRIPTION_UPDATE_LOCK_DIR (lifecycle.uc:638; subscription/cache.uc:2515), list/component locks (components/updates.uc:1237-1244), latency locks (ui.uc:1436; runtime.uc:1906). snapshots.uc:93-116 and autotune/lock.uc already use the safe pending-dir + rename scheme.


**Reproduction:** wsl bash scratch/audit-atomicity/repro_lock_steal.sh


**Expected:** A lock being initialised is never considered stale.


**Actual:** A half-acquired lock (dir without pid) is broken and taken over.


**Impact:** Two lifecycle actions (e.g. a WAN-up reload and a list-content reload or UI stop) can run concurrently when they hit a free lock at the same moment. nft, dnsmasq and sing-box transitions interleave, and one owner's release removes the other's lock. This can leave an inconsistent dataplane or DNS pointed at a stopped sing-box. The window is small but real.


**Root cause:** Two-step acquisition (mkdir, then write pid) with a staleness test that accepts a missing owner record.


**Affected files:** `forkop/files/usr/lib/service/state.uc`, `forkop/files/usr/lib/service/initd.uc`, `forkop/files/usr/lib/components/action.uc`, `forkop/files/usr/lib/full-uninstall.sh`, `forkop/files/usr/lib/service/ui.uc`

**Proposed fix:** Publish the owner record before the lock becomes visible: mkdir `<lock>.new.<pid>`, write pid (+start ticks), then `fs.rename(pending, lock_dir)` (rename refuses a non-empty target), as snapshots.uc acquire() does. At minimum, treat a lock dir with a missing/empty pid whose ctime is younger than ~5 s as busy. release should unlink only its own record.


**Tests needed:** State test: a freshly created empty lock dir must not be acquirable, while an empty lock dir older than the grace period may be. Existing runtime_state_owner/latency_reload_serialization tests must still pass.


**Risk:** Medium: the change touches every serialized lifecycle path; keep the API unchanged.


**Verification:** confirmed → P2

**Verification evidence:**

Code (worktree 07872084):
- service/state.uc:318-323 `if (command_success_from_args([ "mkdir", lock_dir ])) { if (lock_dir_write_owner(lock_dir, owner_pid)) return true; ...}`. Acquisition takes two steps: mkdir runs through system() (state.uc:107-108), and only afterwards does fs.writefile write `<lock>/pid` (state.uc:299-301).
- state.uc:325-335 is the contender path: `if (pid_alive(first_line_value(lock_dir + "/pid"))) return false;` then `rm -f pid`, `rmdir`, `mkdir`, write own pid. first_line_value returns "" for a missing file (state.uc:285-292), and pid_alive("") is false because it requires /^[0-9]+$/ (state.uc:294-297). A lock dir whose owner has not written its pid yet is therefore broken as stale. If the owner has already written its pid after the contender's read, the contender's `rm -f` deletes that pid and the `rmdir` still succeeds.
- release_runtime_dir_lock does not check the owner: state.uc:303-310 does `rm -f pid; rmdir` for any caller. Once two processes hold the lock, the first release drops it for both.
- service/initd.uc:186-226 is a byte-for-byte duplicate, used in-process by init.d start (initd.uc:604), reload pending (690) and reload (712).
- Users of RELOAD_LOCK_DIR: initd.uc:604/690/712, lifecycle.uc:1621 (DNS failover apply), diagnostics/runtime.uc:1925/1994 (automatic latency worker), components/updates.uc:3944 (list update, waits) and 4342 (subscription update). SUBSCRIPTION_UPDATE_LOCK_DIR: lifecycle.uc:638, updates.uc:4335, subscription/cache.uc:2515.
- No guard elsewhere: the init.d shell takes no outer lock (etc/init.d/forkop has none; runtime_state_owner.sh:43-44 forbids one). No test pins "empty dir = stale". runtime_state_predicates.sh:263-282 covers only the live-pid refusal and the dead-pid (999999) takeover.
- Realistic coincident trigger: the list-update cron runs daily by default (`update_interval '1d'` in etc/config/forkop:32), which gives "0 0 * * *" (updates.uc:1320-1342, 1525). The subscription cron (updates.uc:1556) runs subscription_update_common(false) on every tick (updates.uc:4359-4361). When the schedules coincide, crond starts both at the same second, and both take RELOAD_LOCK_DIR soon after process start (updates.uc:3944 and 4335/4342). Two polling waiters can also collide when a long holder releases: initd.uc:236 polls every 1 s, state.uc:350 every 2 s.


**Verification reproduction:**

I ran the real CLI (`ucode -L <lib> service/state.uc acquire-runtime-dir-lock <dir> <live pid>`) in WSL with a private mktemp -d. Scripts are in scratch/audit-verify-lock-steal/.
1) stress_lock.sh: 6 contenders released by a busy-wait barrier onto a free lock. Nobody releases. Each passes the live parent shell pid, so a second winner can only come from the empty-pid "stale" path. Result: `SUMMARY: rounds=60 contenders=6 double_ownership_rounds=35 zero_winner_rounds=0`, for example `round 2: 2 contenders all got the lock`. A single invocation takes about 42 ms.
2) stress_lock2.sh MODE=jitter: 2 contenders, the second delayed by a random 0..JMS ms. JMS=10 gave 63/100 rounds with two owners. JMS=50 gave 18/100, so on WSL the effective vulnerable arrival window is about 9 ms. It is not the "tiny" window the finding describes.
3) stress_lock2.sh MODE=stale: the lock pre-exists with dead pid 999999 and 4 contenders break it at once. 0/60 rounds had two owners, so the fixed-name stale-break check-then-act gap is real in code but very narrow in practice.
The auditor's repro_lock_steal.sh only shows the logic (a hand-made empty dir gets taken over); the concurrent runs above show the actual race. I could not measure on the router how often production callers collide (read-only audit, no device access); the router window will differ from WSL but has the same order (fork/exec of sh plus mkdir).


**Verification notes:**

Line references in the finding are correct: state.uc:312-339 and initd.uc:199-226 (release at 303-310 and 190-197). The impact statement holds, and the window is wider than claimed: two acquirers that start within a few ms of each other double-acquire most of the time.

Additional points:
(a) Same root cause in autotune/apply.uc:246-250 service_action(): it reads RELOAD_LOCK/pid, so a half-initialised reload lock (dir present, no pid yet) reads as "no service action in progress". That is only a check without holding the lock, so it is secondary.
(b) Proposed fix: the pending-dir + rename scheme is correct only with a uniquely named owner record (owner.<pid>.<ticks>, as in config/snapshots.uc:86-118 and autotune/lock.uc:51-78). If the fixed name `pid` is kept, stale-breaking still has a check-then-act gap: two contenders both read a dead pid; the winner renames its fresh lock in; the loser then unlinks `lock/pid` (the winner's) and renames over the now-empty dir.
(c) A changed on-disk format needs compatibility handling. These readers/tests create or read `<lock>/pid`: autotune/apply.uc:247, tests/list_bootstrap.sh:54-56, list_update_final_reload.sh:95-96, start_reload_serialization.sh:32-33, runtime_state_predicates.sh:266,277-281. The lock lives in tmpfs, so no persistent migration is needed, but a legacy `pid` file with a live pid must still count as busy during an upgrade.
(d) Truly minimal fix with no format change: in the contender path, when `pid` is missing or empty and `fs.stat(lock_dir).mtime` is less than about 10 s old, return false (busy). This closes the demonstrated window. A crash between mkdir and write still recovers after the grace period, and waiters only lose one poll during the two-step release. Apply it once, and ideally make initd.uc reuse the state.uc implementation (removes a duplicate, CLEANUP).
(e) An owner-checked release (remove only when `pid` equals the caller's owner) needs an owner argument on the `release-runtime-dir-lock` CLI at all call sites. It prevents the cascade after a double acquisition but is optional.

Tests needed: a deterministic case (fresh empty lock dir is busy, empty dir older than the grace period is breakable) plus a concurrency case (N simultaneous acquirers yield exactly one winner, like stress_lock.sh). latency_reload_serialization.sh, start_reload_serialization.sh and runtime_state_predicates.sh must still pass.

Severity stays P2: a serious race that lets two lifecycle, list or subscription actions run concurrently (interleaved nft/sing-box/dnsmasq transitions, one release dropping the other's lock). A later reload normally reconciles, and it needs coincident arrival, so not P1. product_decision=false. Confidence: high.


### Also reported as process-locks#6 (P3): Directory-lock helpers have TOCTOU windows (mkdir->pid gap, concurrent dead-owner takeover), PID-only liveness and unconditional release

**Evidence:** service/state.uc:312-339 and initd.uc:199-226: `if (mkdir) { write pid }` else `if (pid_alive(first_line(pid))) return false; rm -f pid; rmdir; mkdir; write pid`. An existing directory with no pid yet (owner between mkdir and write) counts as stale, and two contenders that both saw a dead owner can both win (the second `rm -f pid` deletes the first owner's pid). components/action.uc:258-278 has the same pattern and no pid-write check. full-uninstall.sh:148-159,171-172 writes the pid after mkdir and hands off from `start`'s $$ to the worker's $$. release (state.uc:303-310, initd.uc:190-197, action.uc:280-286) never checks ownership. Only ui.uc:838-842 has the 5 s grace for an empty pid. Liveness is `kill -0` only, so a stale lock with a reused PID is 'busy' until that process exits. Repro: scratch/audit-a6a7/repro_lock_gap.sh printed `B acquired a lock whose directory A had just created` and `B also took over`.


**Proposed fix:** Replace the five ad-hoc helpers with one module using the snapshots.uc/autotune lock.uc scheme: an owner.<pid>.<ticks> record published by atomic rename, stale only when the pid+ticks identity is gone, and release only of one's own record.


---

<a id="uc-012"></a>

## UC-012 · P2 · S3 — stop не сериализован с держателями reload.lock: обновление подписки или DNS-failover поднимают sing-box после остановки

**Severity:** P2<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A6 stop lifecycle / A7<br>
**Sources:** process-locks#2<br>
**Original title:** Stop is not serialized with reload.lock holders: an in-flight subscription update or DNS-failover apply restarts sing-box after Forkop stop<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/initd.uc:656-668 stop_service runs `BIN_PATH stop` with no reload.lock and no start.in-progress check. It is serialized only with synchronous init.d reloads via procd's fd-1000 flock. lifecycle.uc:1072-1075 stop_main stops only the DNS-failover worker, Priority, the deferred subscription worker and the list update; it does not stop subscription update jobs or cron runs. components/updates.uc:4335-4352 a subscription update holds subscription-update.lock and reload.lock across downloads, then 4263-4305 `stop-managed-sing-box-runtime` (no-op when stopped) -> commit -> `start-managed-sing-box-runtime` -> `subscription_start_auxiliary_runtimes`; 4243 configure-service re-enables sing-box. singbox/dns_failover.uc:318-322 stop TERMs only the worker ucode; its synchronous child `forkop dns_failover_apply` (225-235) keeps running and holds reload.lock through a stop/patch/start of sing-box (lifecycle.uc:1621-1667). service/ui.uc:1384-1407 lets the UI issue 'stop' during a subscription job. autotune/apply.uc:243-247 assumes "A lifecycle action (reload/start/stop) holds the reload lock", which is false for stop. service/package.uc:79-95,224-228: postinst waits 15 s for any sing-box to exit, then gives up.


**Reproduction:** Code path analysis. Stub scenario: start a forced `forkop subscription_update`, run `/etc/init.d/forkop stop` during the download phase, and observe sing-box running afterwards.


**Expected:** After stop returns success, no Forkop-owned runtime is started by work that began before the stop.


**Actual:** Stop and subscription update or DNS-failover apply interleave, and sing-box plus auxiliary workers run again after a successful stop.


**Impact:** A user triggers 'Update subscription' and clicks Stop, or a scheduled update runs during a component action's 'Stopping Forkop before sing-box package change' or during prerm. Stop completes: nft table removed, dnsmasq restored, shutdown_correctly=1. The subscription worker then starts sing-box plus the DNS-failover and Priority workers. Forkop reports stopped while sing-box runs. The next start fails with 'unexpected sing-box exists before start' until cleanup plus retry; with the service disabled there is no retry. During a package upgrade, postinst times out and does not start Forkop. The package component change can run while sing-box is being restarted.


**Root cause:** Stop does not participate in the reload.lock protocol and does not terminate or await every runtime mutator; mutators do not re-validate the service state before re-starting sing-box.


**Affected files:** `forkop/files/usr/lib/service/initd.uc`, `forkop/files/usr/lib/service/lifecycle.uc`, `forkop/files/usr/lib/components/updates.uc`, `forkop/files/usr/lib/singbox/dns_failover.uc`, `forkop/files/usr/lib/autotune/apply.uc`

**Dependencies:** Interacts with the reload-on-stopped-runtime finding and with the start/reload serialization finding.


**Proposed fix:** Make stop_service take reload.lock with a bounded wait, using the fixed identity-aware helper. Alternatively, have stop_main first stop reload.lock holders by identity (subscription update worker, dns_failover_apply) and wait for them. Have subscription_update_common_locked and dns_failover_apply re-check that Forkop is still running before start-managed-sing-box-runtime (for example, abort when a new 'stopped' marker written by stop exists). Correct the apply.uc:243 comment.


**Tests needed:** Lifecycle test with stubs: hold reload.lock with a fake subscription worker, run stop, then let the worker continue. Assert that no start-managed-sing-box-runtime is issued, or that stop waits. Also cover a dns_failover_apply child surviving a TERM of its worker.


**Risk:** Stop may wait up to the lock timeout while a download finishes. Prefer terminating the subscription job by identity rather than waiting on network I/O.


**Verification:** confirmed → P2

**Verification evidence:**

Static proof (tree at 07872084), backed by a runtime reproduction:
- service/initd.uc:656-667 `stop_service` calls `clear_start_retry` and `begin_external_service_action`, then goes straight to `command_status_from_args([ BIN_PATH, "stop" ])`. It never touches RELOAD_LOCK_DIR. start_service does take the lock (initd.uc:604, `acquire_runtime_dir_lock_wait(RELOAD_LOCK_DIR, ...)`, wait 30 s), and so does reload (initd.uc:690/712). lifecycle start_main also takes subscription-update.lock (`acquire_start_subscription_update_lock`). Stop is the only lifecycle action that takes neither lock. The init.d wrapper (etc/init.d/forkop:64-66) adds nothing. The procd fd-1000 flock only serializes init.d invocations, and the subscription and DNS-failover workers are not init.d invocations.
- lifecycle.uc:1458-1490 stop_impl -> stop_main (1055-1111). stop_main stops the DNS-failover worker, Priority, the deferred bootstrap worker and list_update (1072-1075), removes cron, deletes the nft table, and runs `stop-managed-sing-box-runtime`. It does not stop an in-flight subscription update and does not wait for any holder of reload.lock.
- components/updates.uc:4330-4356 subscription_update_common takes subscription-update.lock (4335) and reload.lock (4342), then runs the locked body. That body (4224-4305) downloads first (`subscription_prepare_cache_request`, 4228). Then it runs `configure-service` (4243; this sets sing-box UCI main.enabled=1), `stop-managed-sing-box-runtime`, `commit-config-stage` and `start-managed-sing-box-runtime` (4281-4283), followed by `subscription_start_auxiliary_runtimes` (4295). Nothing checks whether Forkop is still running. state.uc:718-723 stop_managed returns true when nothing runs. state.uc:771-809 start_managed checks only that no sing-box exists, then starts it.
- service/ui.uc:1384-1405 service_action_async blocks only start/restart during a start worker and only other *service* actions (begin_service_action_if_idle, 1172-1197). A stop issued during a subscription job is accepted. components/action.uc:938-950 (component stop before a sing-box package change) and package.uc:183-192 (prerm stop) do not coordinate with subscription jobs either.
- singbox/dns_failover.uc:319-322 stop_runtime sends TERM to the single worker PID (process_identity.signal -> `kill -15 pid`, core/process_identity.uc:134-139). The worker runs `forkop dns_failover_apply` synchronously through system() (228). lifecycle.uc:1615-1667 dns_failover_apply holds reload.lock through stop -> patch -> start -> an 8 s verify-state. If the verify fails, the rollback at 1657-1662 starts sing-box again.
- autotune/apply.uc:243-245 says "A lifecycle action (reload/start/stop) holds the reload lock". This is false for stop.
- package.uc:79-95 waits UPGRADE_SING_BOX_WAIT_SECONDS (15) for sing-box to exit; on timeout, 224-228 warns and never starts Forkop.
- Next start after a leak: start_inner finds no conflict (the sole sing-box is owned) and "forkop-stably-running" is false (no nft table), so it calls start_main -> start_sing_box_and_wait -> start_managed. That call refuses with "unexpected sing-box exists before start". cleanup_failed_runtime then stops sing-box, and the retry runs only when the service is enabled (initd.uc:487-500).
- Tests: tests/subscription_update_reload.sh pins the stop-managed -> commit -> start-managed sequence without a running check. No test covers stop vs reload.lock (tests/initd_state.sh:237-239 only greps for 'stop-service').


**Verification reproduction:**

1) Scratch script scratch/audit-verify-stop-reloadlock/repro.sh, run in WSL with a private mktemp dir. It runs the REAL components/updates.uc `subscription-update` (the forced path used by `forkop subscription_update` and the UI job). Only the leaf modules are stubbed: state.uc models sing-box running/stopped and the mkdir lock, the update-request stub blocks in "download", and the validator, singbox/runtime, priority and dns_failover are stubs. While the update is blocked in download, the script runs the REAL service/initd.uc `stop-service` against the same FORKOP_RELOAD_LOCK_DIR, with FORKOP_BIN set to a fake `forkop` that models a successful stop. Output:
reload.lock held during download: yes
initd stop-service rc=0 elapsed_ms=18 sing-box after stop: stopped
subscription update rc=0
sing-box state at end: running
Call log order: update-request -> bin:stop (lock-dir-present=yes) -> FORKOP STOP COMPLETED -> validate-runtime -> configure-service -> prepare-config-stage -> dns_failover/priority stop-runtime -> stop-managed-sing-box-runtime -> commit-config-stage -> start-managed-sing-box-runtime -> SING-BOX STARTED -> priority:start-runtime -> dns_failover:start-runtime -> write-current-reload-state-clean.
So stop does not wait for reload.lock, and the update restarts sing-box and both auxiliary workers after stop returned success.
2) scratch/audit-verify-stop-reloadlock/child_survives.sh: a ucode worker running system("sleep 2; echo ... > file") gets kill -15. The worker exits with 143 and the child still completes ("child survived TERM of worker"). This confirms that a `forkop dns_failover_apply` child outlives dns_failover stop-runtime.
The package-upgrade and component-action consequences are shown statically. They need an opkg transaction on a real router.


**Verification notes:**

Verdict: confirmed. Severity stays P2. The race is real, the state it leaves is misleading, and it breaks the upgrade and component workflows. It is not P1: stop removes the nft table and restores dnsmasq, so the stray sing-box does not intercept traffic. The network does not break; Forkop just stays stopped or fails its next start.

Corrections and precision:
- Line refs are mostly accurate. The subscription lock acquisition is updates.uc:4335/4342 (function at 4330). The post-download start sequence is 4260-4305 (start-managed at 4281-4283, auxiliary start at 4295). dns_failover stop_runtime is dns_failover.uc:319-322 and the system() child is at 228. lifecycle dns_failover_apply is 1615-1667.
- The DNS-failover window is wider than the finding says. Besides stop landing between the child's stop and start of sing-box, a stop during the child's 8 s verify-state loop kills the verified sing-box. verify fails, and the rollback branch (lifecycle.uc:1657-1662) restarts sing-box after Forkop stop. This path fires only on an actual DNS switch, so it is less likely than the subscription case.
- "configure-service re-enables sing-box" means sing-box UCI main.enabled=1 (singbox/runtime.uc:462-503). That matters in the component-action case: action.uc:938-950 prepare_sing_box_service_disabled sets enabled=0, the in-flight subscription sets it back to 1 and starts sing-box in the middle of the package change.
- init.d restart and the component's restart_forkop_after_successful_change also fail. Stop does not lock. Start waits up to 30 s on reload.lock, then finds the stray sing-box and fails with "unexpected sing-box exists before start". Cleanup follows, and a retry is scheduled only if the service is enabled.
- Variant with no race: a forced `forkop subscription_update` (CLI or UI job) while Forkop is already stopped goes through the same unconditional stop-managed(no-op) -> start-managed path and starts sing-box plus the workers. The repro effectively shows this too. I did not check whether the UI hides the button while stopped.
- Related variants (same root cause and invariants 13/14; worth a separate check, not verified in depth here):
  - stop_list_update (updates.uc:4063-4070) sends a plain `kill pid` with no identity check, and the list update's children survive. The list update holds reload.lock (updates.uc:3944).
  - stop_deferred_subscription_bootstrap_retry_worker (subscription/cache.uc:2462-2469) sends a plain `kill`.
  - cancel_scheduled_start_retry (initd.uc:276-283) sends a plain `kill`.

Better minimal fix (no redesign):
(a) In initd.uc stop_service, take RELOAD_LOCK_DIR with acquire_runtime_dir_lock_wait (bounded, e.g. the same 30 s as START_RUNTIME_LOCK_WAIT_SECONDS) around `forkop stop`, and release it afterwards. On timeout, still stop (a stop must not fail because of a download) and log a warning. None of the callers hold reload.lock, so this cannot self-deadlock: action.uc:945/1712/1876/2077, package.uc:189, the lifecycle uninstall at 2124 and UI service actions. The internal failure-cleanup paths call stop_main directly, not stop_service.
(b) Close the timeout and already-stopped cases: in subscription_update_common_locked (before stop-managed/start-managed and before the auxiliary start) and in dns_failover_apply (before each start-managed, including the rollback start), re-check that Forkop is active. Start and reload hold reload.lock, so a missing production `inet forkop` table under that lock means Forkop is stopped; a stop-request marker written at the top of stop_main also works. If Forkop is stopped: commit or keep the validated config, do NOT start sing-box or the auxiliary workers, and return success-with-info.
(c) Fix the apply.uc:243 comment, or make it true through (a).

Tests: extend tests/subscription_update_reload.sh or add a lifecycle test based on the scratch repro. Block update-request, run initd.uc stop-service, and assert either that stop waits for the lock or that no start-managed-sing-box-runtime or auxiliary start happens after stop. Add a case where the dns_failover_apply child outlives its worker's TERM. Add a case where a forced subscription_update runs while Forkop is stopped and must not start sing-box.


---

<a id="uc-013"></a>

## UC-013 · P2 · S3 — /etc/init.d/forkop start|restart всегда возвращает 0 — откаты и fallback по коду возврата не срабатывают

**Severity:** P2<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A6 start lifecycle<br>
**Sources:** process-locks#3<br>
**Original title:** `/etc/init.d/forkop start|restart` always exits 0, so status-based rollbacks and fallbacks never run<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** etc/init.d/forkop:38-42 `FORKOP_LAST_START_STATUS=0; return 0` in the detached branch, which is always taken because procd.sh `_procd_wrapper` -> `procd_lock` opens fd 1000 for every init.d call. rc.common `restart(){ stop; start }` returns the start status. components/action.uc:2516-2524 Direct Proxy: `if (!command_success_from_args([ SERVICE_INIT, "restart" ])) { ...restore previous enabled/port...; action_fail(...) }` is dead code, and success is reported unconditionally (2527-2530). action.uc:312-313 `if (!start) restart` fallback never triggers. initd.uc:516-518 retry_start_on_wan_up logs '[info] Forkop recovered automatically after a failed start' whenever start returns 0. package.uc:230 postinst treats start as successful.


**Reproduction:** Code path analysis. procd.sh source confirmed in the local OpenWrt tree ~/.cache/flint2-openwrt/openwrt/package/system/procd/files/procd.sh.


**Expected:** Callers learn whether Forkop actually started and act on failure (roll back or report).


**Actual:** The init.d start/restart exit status is 0 regardless of the start outcome.


**Impact:** Enabling Direct Proxy with settings that make the start fail reports 'Direct Proxy has been enabled'. The async start fails, cleanup_failed_runtime stops Forkop, and the retry worker re-starts every 30 s with the same broken settings; the designed rollback to the previous settings never happens. The WAN-up retry writes a false 'recovered' log line. This violates invariant 5 (needs_attention masked as success).


**Root cause:** The deadlock-avoidance detach turned start into fire-and-forget, but existing callers kept exit-status semantics.


**Affected files:** `forkop/files/usr/lib/components/action.uc`, `forkop/files/usr/lib/service/initd.uc`, `forkop/files/etc/init.d/forkop`

**Dependencies:** Same root branch as the detached-start owner finding.


**Proposed fix:** Callers that need the outcome should not trust the init.d status. After start/restart, poll the runtime (as restore_forkop_opkg_service already does with forkop_status_running_with_timeout and a 45x4 s loop) and treat a timeout as failure. Apply this to set_direct_proxy (then roll back), restart_forkop_after_failed_sing_box_change and retry_start_on_wan_up (log only after verification). Alternatively, provide an initd.uc 'start-and-wait' entry that waits for the detached worker's result file.


**Tests needed:** A components test for set_direct_proxy with a restart stub that exits 0 while the runtime never becomes running; expect the rollback and action_fail. An initd test that retry_start_on_wan_up does not log 'recovered' before the runtime is verified.


**Risk:** Low; polling adds up to about 3 minutes to component actions on failure.


**Verification:** confirmed → P2

**Verification evidence:**

Root cause: the detach test at forkop/files/etc/init.d/forkop:38-41 (`if [ -e "/proc/$$/fd/1000" ]; then initd_ucode start-service ... 1000>&- &; FORKOP_LAST_START_STATUS=0; return 0`) is meant to spot an rcS/procd transaction. But OpenWrt's own procd.sh opens fd 1000 in every procd init script. I checked this in the local OpenWrt v25.12.5 tree (procd 2025-05-28):
- rc.common:127 sources procd.sh for any USE_PROCD script.
- procd.sh:686 calls `_procd_wrapper` when the file is sourced.
- `_procd_wrapper` (procd.sh:70) calls `procd_lock` first.
- procd_lock (procd.sh:48-58) runs `flock -n 1000 &> /dev/null`, which fails with EBADF when fd 1000 is not open, and then runs `exec 1000>"$IPKG_INSTROOT/var/lock/procd_${service_name}.lock"; flock 1000`.

So `/proc/$$/fd/1000` exists for every `/etc/init.d/forkop start|restart`. On a real router the synchronous branch (lines 44-46) never runs.

How the 0 reaches callers: rc.common:138-140 `start(){ rc_procd start_service "$@"; if type service_started; then service_started; fi }` returns service_started's status. Forkop's service_started (init.d:49-51) returns FORKOP_LAST_START_STATUS, which is 0. rc.common `restart(){ stop; start }` returns that same status.

Callers that depend on the status, checked in this tree:
- components/action.uc:2516-2524: the Direct Proxy rollback (`if (!command_success_from_args([ SERVICE_INIT, "restart" ])) { ...restore enabled/port...; action_fail(...) }`) is dead code. action_success "Direct Proxy has been enabled" (2526-2529) is always reached. The frontend then marks it enabled (fe-app-forkop/src/forkop/tabs/updates/initController.ts:413).
- action.uc:312-313: the `if (!start) restart` fallback is dead.
- service/initd.uc:516-518: `status == 0` always leads to logging "[info] Forkop recovered automatically after a failed start". The detached start-service (initd.uc:601-633) then fails, marks the retry, reschedules it every 30 s (START_RETRY_DELAY_SECONDS) and logs "[warn] Forkop start failed". Each retry therefore writes a false "recovered" line.
- service/package.uc:229-233 (the finding's "package.uc:230" is this file): postinst unlinks PACKAGE_UPGRADE_STATE and returns success before the start outcome is known.
- action.uc:2074-2089 restore_forkop_opkg_service is NOT affected, because it already polls forkop_status_running_with_timeout.

Mitigations that exist but do not refute the finding:
- The detached initd start records the job through finish_external_service_action. The service-status area can therefore show the failure (components actions are not FORKOP_UI_ACTION_TRACKED).
- cleanup_failed_runtime restores DNS fail-safe, so traffic falls back to direct.

What remains wrong: the action result reports success, the new settings are kept, the designed rollback to the previous working settings never runs, and the logs misreport recovery. This goes against invariant 5 (needs_attention masked as success).

Tests pin the wrong assumption:
- tests/service_start_trap.sh:106-109 requires `FORKOP_LAST_START_STATUS="$?"` ("must preserve backend start status for rc.common"). That is the synchronous branch, which is dead on a router.
- tests/idempotent_start.sh:181-191 stubs SERVICE_INIT start returning 19 and expects the "[error] ... recovery attempt failed" log. No test sources the real procd.sh, so the suite always takes the synchronous branch.
- No test covers the set_direct_proxy rollback.


**Verification reproduction:**

Script: scratch/audit-verify-initd-start-status\repro.sh, run in WSL with a private mktemp -d root and IPKG_INSTROOT.

Setup:
- Real rc.common, functions.sh, service.sh and procd.sh from ~/.cache/flint2-openwrt/openwrt (v25.12.5).
- Stubs for jshn.sh and ubus.
- The unmodified Forkop init script from the worktree, plus a copy with only FORKOP_LIB redirected to a stub initd.uc whose start-service sleeps 1 s and exits 1.
- bash as the shell. It matches OpenWrt busybox ash, which has BUSYBOX_DEFAULT_ASH_BASH_COMPAT=y (Config-defaults.in:3024) and so parses `&>` and `let`. procd.sh itself relies on both.

Results:
- A1/A2: unmodified init with the backend missing. start exit=0 (0.10 s), restart exit=0.
- B1/B2: stub backend fails. start exit=0 (0.09 s), restart exit=0. The backend log afterwards shows `start-service ... exit=1` twice.
- C: a ucode caller shaped like action.uc's `command_success_from_args([SERVICE_INIT,"restart"])` returns true, so the rollback is skipped. The backend fails afterwards.
- D: nested `start triggered` while the parent holds the procd lock on fd 1000 (the retry_start_on_wan_up path) exits 0; the backend fails.
- E (control): procd.sh with the procd_lock call removed from `_procd_wrapper`. start exit=1 after 1.08 s, so the synchronous branch runs and returns the failure. procd_lock is the only thing that decides the branch.
- F: INIT_TRACE shows `flock -n 1000` -> `flock 1000` -> `[ -e /proc/PID/fd/1000 ]` -> `FORKOP_LAST_START_STATUS=0; return 0`.
- Under dash (no `&>` support) procd_lock never runs exec and the synchronous branch is taken (exit=1). OpenWrt ash is not dash.

No router contact. The final behaviour on hardware is inferred from the matching OpenWrt source tree, not observed on the device.


**Verification notes:**

Corrections:
- The package.uc path is forkop/files/usr/lib/service/package.uc:229-233, not components/.
- The success report is at action.uc:2526-2529.
- The root cause is more exact than "procd_lock opens fd 1000 for every init.d call". procd.sh:686 calls `_procd_wrapper` when the file is sourced, and `_procd_wrapper` calls procd_lock. Together with rc.common:127 this means every USE_PROCD script invocation takes the per-service lock on fd 1000 before any action runs. The rcS-detection premise in the f97b5b28 comment is false, so the synchronous branch at init.d:44-46 and service_started's status only ever run in tests.
- It depends on busybox ash parsing `&>` (ASH_BASH_COMPAT, default y in OpenWrt).

Impact scope:
- Real and designed-for: Direct Proxy rollback (action.uc:2516-2524), the start-then-restart fallback (action.uc:312-313), and the false "recovered" syslog line on every 30 s retry (initd.uc:516-518).
- Minor: package.uc postinst drops PACKAGE_UPGRADE_STATE early. initd start_service still schedules its own retry, so that one is low impact.
- Partially mitigated: the initd start job's finish status and the "[warn] Forkop start failed" log still surface the failure in service status and logs. Network falls back to direct via cleanup_failed_runtime, so there is no router break. P2 stands: misleading action result plus a dead designed rollback, not P1.

Fix options:
1. Recommended: keep init.d async and have status-dependent callers wait for the real outcome. After start/restart, wait for the detached start job's result, or poll `forkop get_status` running with a bounded timeout, the same pattern as restore_forkop_opkg_service at action.uc:2074-2089. Apply this in set_direct_proxy (then roll back and action_fail), restart_forkop_after_failed_sing_box_change, and retry_start_on_wan_up (log "recovered" only after verification; otherwise log that the retry was only dispatched). A small initd.uc `start-result`/`wait-start` mode is cleaner and fails faster than a 3-minute poll.
2. Root-level: make the detach condition identify the real boot context, for example override boot() to set a flag. This needs hardware validation of the original rcS deadlock and is not a pure code decision.

Tests to update:
- Make service_start_trap.sh stop implying the sync status is what production sees.
- Add a regression test that sources the real procd.sh from a fixture, or at least asserts the fd-1000 predicate, plus a set_direct_proxy rollback test with an init stub that exits 0 while the runtime never reaches running.

Related, for the separate owner finding: in the detached branch, owner_pid=$$ is passed to start-service and used as the RELOAD_LOCK_DIR owner (initd.uc:602-603), but that shell exits immediately. This is the dependency the finding mentions; not re-verified here.


---

<a id="uc-014"></a>

## UC-014 · P2 · S3 — Воркеры останавливаются по голому PID: SIGTERM чужому процессу из устаревшего pidfile; переиспользованный PID блокирует обновления и повторы

**Severity:** P2<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A6 process identity<br>
**Sources:** process-locks#4, quality#5<br>
**Original title:** PID-only stoppers TERM foreign processes from stale pidfiles (list update worker, deferred subscription worker, start-retry worker); a reused PID also blocks list updates and retries<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** components/updates.uc:4063-4069 `let pid = ...readfile(LIST_UPDATE_PID_FILE); if (pid != "" && runtime_pid_running(pid)) command_success_from_args([ "kill", pid ])` (kill -0 check only, 1111); :3605-3616 list_update_pid_begin skips 'Another lists update is already running' for any live PID. subscription/cache.uc:2462-2468 `if (pid_running(pid)) command_success_from_args([ "kill", pid ])`; :2450-2455 start skips when the PID is alive. service/initd.uc:276-283 cancel_scheduled_start_retry `if (pid_alive(pid)) kill pid`; :291-293 schedule_start_retry `if (pid_alive(scheduled_pid)) return true`. Callers: lifecycle.uc:1074-1075 (every stop and cleanup_failed_runtime), init.d disable, stop, WAN-up handling. The stale pidfile remains when a worker is OOM-killed or SIGKILLed; the pidfile lives in /var/run until reboot. Repro: scratch/audit-a6a7/repro_foreign_pid_kill.sh printed `FOREIGN PID ... WAS KILLED` for all three.


**Reproduction:** wsl bash scratch/audit-a6a7/repro_foreign_pid_kill.sh


**Expected:** Only the recorded worker (pid+ticks+argv) is ever signalled; a stale record is removed.


**Actual:** A stale pidfile holding a live foreign PID leads to kill <pid>.


**Impact:** After a worker crash and PID reuse (pid_max 32768 wraps quickly on a busy router), the next stop, reload-restart or disable sends SIGTERM to an unrelated process (dnsmasq, netifd, uhttpd, rpcd, ...). With a long-lived reuser, list updates are skipped forever ('already running') and failed-start retries are never scheduled. This violates invariants 13 and 14 and is the same class as prior F-004, whose fix did not cover these three workers.


**Root cause:** The F-004 remediation migrated only dns_failover, priority, byedpi and zapret to process_identity; these worker pidfiles still store a bare PID.


**Affected files:** `forkop/files/usr/lib/components/updates.uc`, `forkop/files/usr/lib/subscription/cache.uc`, `forkop/files/usr/lib/service/initd.uc`, `tests/foreign_pid_stop.sh`, `forkop/files/usr/lib/service/ui.uc`, `forkop/files/usr/lib/service/lifecycle.uc`

**Dependencies:** None.


**Proposed fix:** Record these pidfiles with core/process_identity.record (pid+ticks). Stop with process_identity.signal using the exact argv prefix: [ucode,-L,LIB,components/updates.uc] for the list worker (mode list-update / list-update-after-start / prepare), [ucode,-L,LIB,subscription/cache.uc,deferred-bootstrap-worker] for the deferred worker, and [sh,-c,<script>] for the retry worker. Use process_identity.matches for the 'already running' checks.


**Tests needed:** Extend foreign_pid_stop.sh with stop-list-update, stop-deferred-bootstrap-worker and cancel-scheduled-start-retry against a live `sleep` PID (the repro script is a ready template). Add a list_update_pid_begin test where a reused PID must not block updates.


**Risk:** Low.


**Verification:** confirmed → P2

**Verification evidence:**

The code at 07872084 matches the finding. All three stoppers and all three "already running" checks look only at a bare PID, using `kill -0` and nothing else:
- updates.uc:1109-1112 `runtime_pid_running(pid)`: `match(pid,/^[0-9]+$/) && command_success_from_args(["kill","-0",pid])`.
- updates.uc:4063-4069 `stop_list_update`: `if (pid != "" && runtime_pid_running(pid)) command_success_from_args([ "kill", pid ])`.
- updates.uc:3605-3611 `list_update_pid_begin`: any live PID means "Another lists update is already running, skipping".
- subscription/cache.uc:2350-2353 `pid_running` (kill -0 only); :2450-2454 skips launch when the PID is alive; :2462-2468 `if (pid_running(pid)) command_success_from_args([ "kill", pid ])`.
- service/initd.uc:181-184 `pid_alive` (kill -0 only); :276-283 `cancel_scheduled_start_retry` kills that PID; :291-293 `if (pid_alive(scheduled_pid)) return true`.

Nothing in another layer blocks the scenario:
- lifecycle.uc:1073-1075 `stop_main` calls both worker stoppers unconditionally. `stop_main` runs from stop (1472), `restart_runtime_for_reload` (1502) and `cleanup_failed_runtime` (1116).
- `cancel_scheduled_start_retry` runs more often than the finding says. It runs on every successful start (initd.uc:617-619), on a blocking start failure (622-623), on monitored WAN-up with action reload or skip_running (553-554, 560-561), and on stop (657-658).
- Normal worker exits do remove their pidfiles: updates.uc:3789/3819/3946, cache.uc:2531, and the retry `sh` does `rm -f` after its sleep (initd.uc:299-301). A pidfile is therefore left behind only when a worker dies abnormally (SIGKILL, OOM kill, crash or an uncaught ucode exception). The list pidfile is /var/run/forkop_list_update.pid. It is outside /var/run/forkop, so even full-uninstall.sh:138-140 does not sweep it. Only stop or a reboot (tmpfs) clears it.

The project has already solved this problem elsewhere:
- install.sh:989-999 `installer_cancel_stale_start_retry` checks argv (`INSTALLER_FORKOP_INIT` + `retry_start_on_wan_up`) before killing the same start-retry pidfile. initd.uc has no such check.
- core/process_identity.uc provides record/matches/signal with pid+starttime+exe+argv. The F-004 fix (docs/audit/FIX_VALIDATION.md:67-83) moved only DNS failover, Priority, ByeDPI and NFQUEUE to it.
- tests/foreign_pid_stop.sh covers only those modules. No test pins the current behaviour of these three workers. subscription_cache_state.sh:213 and initd_state.sh:140-165 test only the normal path.


**Verification reproduction:**

I wrote scratch/audit-verify-foreign-pid/repro.sh and ran it in WSL with a private mktemp dir, a stubbed `logger`, and `sleep 300` processes standing in for foreign PIDs. The script calls the production entry points directly. Output:

A) `list-update` blocked on the reload lock was SIGKILLed. The pidfile stayed ("after SIGKILL: pidfile content=395"). A stale file really does persist after an abnormal death.

B) With a live foreign PID in list.pid, `list-update` exited 0. It logged "Another lists update is already running" once and left the pidfile unchanged, so the update was skipped.

C) stop-list-update, stop-deferred-bootstrap-worker and cancel-scheduled-start-retry each killed their foreign PID ("FOREIGN 430/431/432 KILLED").

D) `schedule-start-retry` with a live foreign PID in the pidfile returned 0 and scheduled nothing. The fake init script got no retry_start_on_wan_up call.

E) `start-deferred-bootstrap-worker` with a live foreign PID logged "already running with PID 456" and launched nothing.

I also ran scratch/audit-verify-foreign-pid/ppid_probe.sh. It shows that on dash `owner_pid()` returns the short-lived popen shell PID, not ucode (ucode self pid=477, owner_pid()=478). That is why part A shows pidfile 395 while the worker was 390.

The next point is a static inference, not a device test: on OpenWrt, BusyBox ash execs the last `-c` command without forking (evalstring with EV_EXIT). So in production the pidfile does hold the real ucode worker PID. BusyBox is not installed in WSL, so I could not confirm this locally.

PID wrap and reuse on the real router was also not reproduced, because that needs the device.


**Verification notes:**

Severity: keep P2. It directly breaks invariants 13 and 14, it is the same class the earlier audit rated Medium (F-004), and the fix is already a known pattern. How likely it is differs by worker:
- **List worker:** the most likely case. An OOM kill while processing big lists on a low-RAM router, or a ucode crash, leaves a stale file.
- **Deferred subscription worker:** long-lived, but small, so less likely to be killed.
- **Start-retry worker:** the least likely. The `sh` lives about 30 s and removes its own pidfile, so it goes stale only if it is SIGKILLed inside that window. But its canceller runs on every successful start and every monitored WAN-up.

After a stale file appears, reuse still needs a PID wrap. The chance that the stale PID is held by a live process when the next stop comes is roughly the number of live processes divided by 32768 (about 0.3%). The signal is TERM, not KILL.

Corrections to the finding:
1. "List updates skipped forever" is overstated. Updates stay blocked, with only an info-level log, until the reusing process exits, or the next stop / full-restart reload / failed-start cleanup, or a reboot. The stop that clears the block first TERMs the reusing process.
2. The finding lists too few start-retry cancel callers (see evidence). WAN-up events also call retry_start_on_wan_up directly, so a suppressed timed retry is partly covered.
3. The line references are accurate.

Refinements to the minimal fix:
- Record the list pidfile with process_identity.record, but take the worker's own PID from `/proc/self/stat` read inside ucode. Do not use `owner_pid()` (`sh -c 'echo $PPID'`): on dash, the test shell, it returns a dead short-lived PID. `record()` would then retry for about 5 s and fail, and list updates would abort in tests.
- For the start-retry worker, `process_identity` compares `basename(/proc/<pid>/exe)`. On OpenWrt that is `busybox`, not `sh`, so the caller must pass the resolved `/bin/sh` target. An alternative is to reuse the argv check that install.sh:989-999 already performs.
- Use `matches()` (a stale or mismatched record means "not running") in list_update_pid_begin, start_deferred_subscription_bootstrap_retry_worker and schedule_start_retry.
- Extend tests/foreign_pid_stop.sh with the three production entry points (repro.sh is a ready template).

Related: other `kill pid` sites (updates.uc:2119/2632, ui.uc:1271/1483) kill a child launched a moment earlier, not a PID read from a pidfile, so they are not variants of this bug. validator.uc:1899 kills by a `ps w` substring match, which is a separate pattern that I did not assess.


### Also reported as quality#5 (P3): UI action/start liveness uses `kill -0 <pid>` without start-time identity: a reused PID keeps a dead job 'running' forever and blocks UI service actions

**Evidence:** forkop/files/usr/lib/service/ui.uc:701-704 `return job_pid_valid(pid) && command_success_from_args([ "kill", "-0", pid ]);`. ui.uc:716-729 refresh_pid_job_state `if (job_pid_valid(pid) && pid_running(pid)) return;` has no age bound and no start ticks. Job records store only the pid (ui.uc:679-691). ui.uc:706-708 start_worker_running reads the bare pid written by lifecycle.uc:1452 `write_file(START_IN_PROGRESS_FILE, owner_pid() + "\n")`. Effects: ui.uc:1106-1113 forces status 'starting/reloading', and ui.uc:1183-1186 refuses new service actions while active_service_action_value() != ''. core/process_identity.uc already provides pid plus start-ticks records (used by autotune/lock.uc and snapshots.uc).


**Proposed fix:** Record start ticks with the pid when the job pid and START_IN_PROGRESS are written, and compare them (process_identity.record / matches_record). As a minimal alternative, mark running jobs older than SERVICE_ACTION_TIMEOUT_SECONDS + grace as stale regardless of kill -0.


---

<a id="uc-015"></a>

## UC-015 · P2 · S3 — Команда `forkop main` вызывает start_main() в обход защит start_inner и пересобирает рабочую таблицу nft

**Severity:** P2<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** lifecycle / CLI surface<br>
**Sources:** map#1<br>
**Original title:** Команда-сирота `forkop main` вызывает start_main() в обход всех защит start_inner и пересобирает рабочую таблицу nft<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/files/usr/bin/forkop:64 help `main                    Run main Forkop process`; :158 `main: [ "service/lifecycle.uc", "main", 0 ]`; service/lifecycle.uc:2166-2167 `if (mode == "main") status = start_main();`. Защиты есть только в start_inner (:1352-1398): wait-managed-upgrade-sing-box-exit, `sing-box-process-conflict` ("Refusing Forkop start: sing-box process ownership is ambiguous"), проверка forkop_transition_guard для повторного старта, cleanup_failed_runtime() при сбое, wait-forkop-stable-start. start_main (:870-990) выполняет nft_candidate_begin/nft_rebuild_runtime (nft/apply.uc:1766-1771 `if (nft_table_present(table) && !nft_delete_table(table))` → попадает в batch) и nft_candidate_finish(true) до start_sing_box_and_wait. rg по репозиторию: `main` не вызывают ни init.d, ни initd.uc, ни UI, ни install.sh, ни тесты. tests/runtime_ownership_gates.sh проверяет только stop_main/reload/restart.


**Reproduction:** Код: `forkop main` → lifecycle.uc:2166 → start_main() → nft_rebuild_runtime() без предварительного вызова sing-box-process-conflict.


**Expected:** Любая точка входа, которая перестраивает dataplane, проходит те же защиты, что и `forkop start`, либо отказывает (fail closed).


**Actual:** `forkop main` выполняет разрушительную пересборку dataplane без проверок владения, provenance, отката и стабильности.


**Impact:** Нарушаются инварианты 4 и 18 и контракт владения рантаймом. Если root или админ (ACL write разрешает `/usr/bin/forkop` с любыми аргументами) запустит `forkop main`, пока жив посторонний или дублирующий sing-box или пока активна отказоустойчивая защита неудачного перехода, то рабочая таблица nft будет удалена и пересоздана (сама защита тоже), а затем попытается стартовать sing-box. При сбое отката нет (частичный рантайм остаётся), а сериализации с reload.lock не было. Команда выглядит как штатная точка входа, ведь в help сказано «Run main Forkop process».


**Root cause:** Устаревшая команда эпохи procd `main` осталась в таблице диспетчера, а при рефакторинге все защиты переехали в start_inner()/start(), не затронув start_main().


**Affected files:** `forkop/files/usr/bin/forkop`, `forkop/files/usr/lib/service/lifecycle.uc`, `tests/runtime_ownership_gates.sh`

**Proposed fix:** Минимально: в lifecycle.uc режим "main" направить в защищённый start() (или вовсе убрать `main` из command_spec/help и оставить алиас на `start` ради совместимости). Дополнительно добавить в runtime_ownership_gates.sh проверку, что каждый режим CLI, доходящий до start_main, проходит через start_inner.


**Tests needed:** Статический тест порядка вызовов: lifecycle mode main никогда не вызывает start_main напрямую. Поведенческий тест с заглушкой state.uc, у которой sing-box-process-conflict возвращает успех → `forkop main` завершается с ненулевым кодом и не вызывает nft-rebuild-runtime-from-uci.


**Verification:** confirmed → P2

**Verification evidence:**

Всё проверено на дереве 07872084.

- Команда зарегистрирована и видна в справке. `forkop/files/usr/bin/forkop:64` содержит `main                    Run main Forkop process`, `:158` содержит `main: [ "service/lifecycle.uc", "main", 0 ]`. Кроме того, `:261` внёс `"main"` в список команд, которые блокирует `/tmp/forkop-full-uninstall.lock`: код считает её start-подобной, но из всех start-защит проверяет только эту блокировку.
- Диспетчер вызывает функцию напрямую: `service/lifecycle.uc:2166-2167` `if (mode == "main") status = start_main();`. Режим `start` (`:2168-2173`) идёт через `start()`, затем `start_inner()`, записывает `health record start` и `snapshots confirm-working`. Режим `main` ничего из этого не делает.
- Все защиты, которые должны идти до мутации, находятся только в `start_inner()` (`lifecycle.uc:1352-1398`):
  - wait-managed-upgrade-sing-box-exit;
  - `sing-box-process-conflict` («Refusing Forkop start: sing-box process ownership is ambiguous; preserving the existing runtime»);
  - отказ при живой цепочке `forkop_transition_guard`.
  После них идут `cleanup_failed_runtime()` при сбое (`:1403-1405`, `:1419-1422`) и маркер `START_IN_PROGRESS_FILE` в `start()` (`:1452`).
- `start_main()` (`lifecycle.uc:870-990`) меняет состояние до всякой проверки владения:
  1. `nft_candidate_begin()`, затем `nft_rebuild_runtime()`, затем `nft_candidate_finish(true)` (`:914-949`). Внутри `nft/apply.uc:1768` `if (nft_table_present(table) && !nft_delete_table(table))`: в режиме батча строка `delete table inet ForkopTable` пишется в кандидат и коммитится одной транзакцией.
  2. `singbox init-config` перезаписывает конфиг (`:951`), затем `refresh_cron` (`:955`) и `byedpi start-runtime` (`:959`).
  3. Только после этого `start_sing_box_and_wait()` (`:961`).
  При ошибке нет ни `cleanup_failed_runtime()`, ни отката nft.
- Защитная цепочка при пересборке не восстанавливается. `nft_create_full_runtime_from_uci` не содержит `forkop_transition_guard`: `NFT_TRANSITION_GUARD_CHAIN` используется только в `nft/apply.uc:1620-1650`. Значит, удаление таблицы снимает защитную цепочку, которую `abort_guarded_transition` (`lifecycle.uc:1344-1348`) намеренно оставляет («tearing down the table would create a direct leak window»). Это нарушение инвариантов 4 и 18.
- sing-box не убивается и не подменяется. `state.uc:780-783` `start_managed_sing_box_and_verify` отказывает: «unexpected sing-box exists before start». Так что вред ограничен nft, config.json, cron и byedpi, но все эти мутации уже зафиксированы.
- Автоматических вызовов нет: `rg` не находит `main` в init.d, initd.uc, package.uc, install.sh, build.sh, UI и тестах. Последний init.d с `/usr/bin/podkop main` относится к эпохе podkop (`3b2a7ba8`, 2025-03-05). `tests/runtime_ownership_gates.sh` проверяет только stop_main, reload и restart. Поведение `main` не закреплено ни одним тестом.
- Досягаемость. RO-роль не может вызвать `main`: в read ACL (`luci-app-forkop.json:5-48`) перечислены только конкретные подкоманды. Write ACL (`:96`) выдаёт `"/usr/bin/forkop": ["exec"]` на любые аргументы, то есть админ LuCI и root по SSH могут. Граница привилегий не пересекается: админ и так может выполнить stop или uninstall.


**Verification reproduction:**

Воспроизведено реальным кодом. Скрипт `scratch/audit-verify-main\repro.sh` запускался в WSL с приватными mktemp и TMPDIR.

Настоящие `/usr/bin/forkop` и `service/lifecycle.uc` из worktree (проверено через `cmp`) работают против копии lib, где все модули, которые lifecycle вызывает подпроцессами (state, nft, singbox, validator, updates и т. д.), заменены логирующими заглушками. `nft` и `logger` подменены через PATH. Моделируется неоднозначное владение: `sing-box-process-conflict`→0 (конфликт есть), `start-managed-sing-box-runtime`→1.

Результат:
- `forkop start`: exit 1. Вызовы: `state sing-box-process-conflict`, logger «Refusing Forkop start: sing-box process ownership is ambiguous; preserving the existing runtime», `health record start failure`. Ни одного вызова nft.
- `forkop main`: exit 1. Вызовы по порядку:
  1. validator
  2. `nft ensure-bridge-netfilter-disabled`
  3. `nft nft-rebuild-runtime-from-uci forkop ForkopTable ...`
  4. `singbox configure-service`
  5. `nft nft-populate-runtime-sets-from-uci`
  6. `nft nft-apply-candidate-batch <file>` (коммит)
  7. `singbox init-config`
  8. `updates refresh-cron-from-uci`
  9. `autotune cron-sync`
  10. `byedpi start-runtime`
  11. `state start-managed-sing-box-runtime 15`, отказ
  12. logger «sing-box did not reach a stable running state after start. Aborted.»
  `sing-box-process-conflict` не вызывается ни разу. Нет ни cleanup, ни отката nft, ни записи в health.

То, что пересборка удаляет таблицу вместе с `forkop_transition_guard`, доказано статически (`nft/apply.uc:1768` и отсутствие guard в create-пути). Проверить на живом nft без роутера нельзя.


**Verification notes:**

Поправки к находке:
1. «Без проверок стабильности» — неточно. `start_main` вызывает `start_sing_box_and_wait()` (`lifecycle.uc:847-862`), а тот делает `start-managed-sing-box-runtime` (проверка «единственный процесс, запущенный через procd» после старта) и `wait-forkop-stable-start`. Не хватает именно проверок до мутации, отката при сбое и второй проверки стабильности после DNS из `start_inner`.
2. «Сама защита тоже удаляется» — верно только для цепочки `forkop_transition_guard` внутри ForkopTable. DPI-защиты — это отдельные таблицы `ForkopTableDpiGuard` и `ForkopConfigRestoreDpiGuard` (`nft/apply.uc:1653-1680`, `health.uc:211-213`), пересборка их не трогает.
3. Довод про reload.lock к `main` не специфичен: прямой `forkop start` из CLI тоже работает без reload.lock. Блокировку берёт только `initd.uc:604` (`start_service`). Этот довод стоит убрать.
4. Посторонний sing-box не убивается и не подменяется (`state.uc:780-783`), поэтому инварианты 13 и 14 не нарушаются.
5. Дополнительные последствия, которых нет в находке:
   - `main` не пишет `health record` и `START_IN_PROGRESS_FILE`. Сбой не попадает в историю, UI не блокирует кнопку старта.
   - После снятия `forkop_transition_guard` `health.uc:211-213` перестаёт видеть защиту, и признак needs_attention может погаснуть (инвариант 5).
   - Самый частый реальный сценарий: Forkop работает штатно, в UCI есть ещё не применённые изменения, и кто-то запускает `forkop main`. Новая nft-политика и новый config.json фиксируются, а старый sing-box продолжает работать со старой конфигурацией. Получается ровно та рассинхронизация таблицы и конфига, от которой защищает reload.
6. Номера строк в находке верны: 64, 158, 2166-2167, 870-990, 1352-1398, `nft/apply.uc:1766-1771` (условие на 1768).

Оценка серьёзности: P2 оставляю. Мутация небезопасна (снятие отказоустойчивой защиты, nft направляется на неизвестный процесс, отката нет), но запустить её может только root или админ вручную, командой, которую не вызывает ни одна автоматика. Если команда решит не учитывать ручные вызовы CLI, можно понизить до P3. Граница привилегий не нарушается: RO до `main` не дотянется.

Минимальное исправление, product_decision=false: оставить `main` как алиас защищённого старта ради совместимости (инвариант 17) и убрать из справки.
- В `forkop/files/usr/bin/forkop:158` заменить на `main: [ "service/lifecycle.uc", "start", 0 ]`.
- Либо в `lifecycle.uc:2166` направить `mode == "main"` в ту же ветку, что `start` (`start()` плюс запись в health).
- Удалить `main` из `show_help` и из Usage в `lifecycle.uc:2207`.
- Мёртвый прямой вызов `start_main()` с верхнего уровня убрать, чтобы `start_main` вызывался только из `start_impl`.

Тест:
- В `tests/runtime_ownership_gates.sh` добавить awk-проверку, что `start_main()` вызывается ровно один раз, из `start_impl`.
- Добавить поведенческий кейс по образцу моего `repro.sh`: `forkop main` при `sing-box-process-conflict`=true даёт exit≠0 и не вызывает `nft-rebuild-runtime-from-uci` и `nft-apply-candidate-batch`.


---

<a id="uc-016"></a>

## UC-016 · P2 · S3 — curl к Clash API без таймаутов: зависший контроллер блокирует опрос UI и проверку reload/start

**Severity:** P2<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A25 ucode quality / A23<br>
**Sources:** quality#1<br>
**Original title:** Clash API curl calls have no connect/max timeout: a hung controller blocks get_ui_state polls and reload/start verification with no time limit<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/files/usr/lib/diagnostics/runtime.uc:1600-1607 `let args = [ "curl", "-s" ]; ... value = json(command_output(command_from_args(args)));` (clash_proxy_type_map, used by clash_api_ready 1622-1624, mode 2269-2270). Also unbounded: runtime.uc:1753, 1760, 1772, 1811, 1832, 1845, 1858, 1867. Callers: state.uc:931-937 sing_box_clash_api_ready, reached from forkop_stably_running (946-950) and forkop_running (941-944). That covers every get_ui_state poll (ui.uc:870-878), health.uc:207, and reload/start verification `wait-forkop-stable-start` (lifecycle.uc:1924-1934), which runs while the transition guard is installed. Every other curl in the code base is bounded (autotune/probe.uc:139-143, diagnostics/connectivity.uc:58-61, singbox/ruleset_cache.uc:390, components/updates.uc:2935). rpcd kills only its direct child on exec timeout: file.c rpc_file_exec_timeout_cb `kill(c->process.pid, SIGKILL)` after RPC_EXEC_DEFAULT_TIMEOUT (120*1000).


**Reproduction:** wsl bash scratch/audit-perf-shell-ucode/curl_hang.sh (listener that accepts and never answers; SB_CLASH_API_CONTROLLER_PORT pointed at it).


**Expected:** The readiness probe fails within a few seconds, so get_ui_state reports not-running and reload verification times out and rolls back.


**Actual:** `ucode runtime.uc clash-api-ready` against a listener that accepts but never replies was still blocked after 12 s (timeout rc=124). curl was invoked as `curl -s <addr>:9090/proxies`.


**Impact:**

If sing-box's Clash API accepts TCP but stops answering (stopped, deadlocked or thrashing sing-box):
(a) every get_ui_state poll leaves a stuck chain (ucode ui.uc -> ucode state.uc -> ucode runtime.uc -> curl). The browser times out after 3 s and polls again 1 s later, so each open tab adds a new stuck chain about every 4 s. rpcd SIGKILLs only /usr/bin/forkop after 120 s; the nested processes are orphaned and never reaped, so memory runs out over minutes.
(b) reload/start verification blocks indefinitely under the transition guard and reload lock instead of timing out into abort_guarded_transition, so the fail-closed recovery (rollback) never runs.
(c) Priority worker probes block, so no failover happens.


**Root cause:** The Clash API helpers build curl argument lists without --connect-timeout/--max-time, and no outer timeout exists (BusyBox has no `timeout`; the frontend timeout does not stop backend processes).


**Affected files:** `forkop/files/usr/lib/diagnostics/runtime.uc`, `forkop/files/usr/lib/service/state.uc`

**Dependencies:** None


**Proposed fix:** Add `--connect-timeout 2 --max-time 5` to clash_proxy_type_map and to the get_proxies, get_connections, set_group_proxy and close_* curls. For the delay endpoints use `--max-time` = requested timeout in ms /1000 + 2.


**Tests needed:** Backend test with a local listener that never responds (python3 or a ucode socket fixture), or a curl stub recording its arguments. Assert that --max-time is passed for every clash_api action and that clash-api-ready returns non-zero within the bound.


**Risk:** Low. The delay endpoints need max-time larger than sing-box's own delay timeout to avoid false failures.


**Verification:** confirmed → P2

**Verification evidence:**

Code, checked against the worktree at 07872084:
- diagnostics/runtime.uc:1600-1607 builds `let args = [ "curl", "-s" ]; ... value = json(command_output(command_from_args(args)));`. It has no --connect-timeout and no -m/--max-time.
- The other Clash API curls are unbounded too: runtime.uc:1753, 1760, 1772, 1811, 1832, 1845, 1858, 1867.
- The runner adds no bound of its own. command_capture (runtime.uc:107-115) does `fs.popen(command, "r")` and then `pipe.read("all")`. ucode's system() also gets no timeout argument anywhere in this chain.
- Call chains:
  - Readiness probe: state.uc:928-934 `sing_box_clash_api_ready` runs `ucode ... runtime.uc clash-api-ready`. forkop_running (941-944) and forkop_stably_running (946-950) use it, and so does wait_forkop_stable_start (952-963). That loop counts iterations; it does not check elapsed time.
  - get_ui_state poll: dispatcher `get_ui_state: [ "service/ui.uc", "get-ui-state", 0 ]` (bin/forkop:190) -> ui.uc:1095 forkop_running() -> ui.uc:870-878 `forkop-stably-running`. health.uc:208 (not 207) calls get-ui-state as well.
  - Reload under the transition guard: lifecycle.uc:1908 installs the guard, and 1924-1934 runs `wait-forkop-stable-start`. abort_guarded_transition is reached only if that call returns.
  - Other unbounded callers the finding does not list: lifecycle.uc:793-799 and 855-861 (verification inside the restore/rollback paths themselves), 1383 and 1414 (start, run while initd.uc:604 holds reload.lock), 1513, 1708, 2086; runtime.uc:1943/1976 (automatic latency test); lifecycle.uc:457-484 (selector restore).
- Every other curl is bounded: autotune/apply.uc:310 `--max-time 3`, connectivity.uc:58, country.uc:195 `-m 10`, ruleset_cache.uc:390, updates.uc:2935, action.uc:577, runtime.uc:1416 `-m 3`, and subscription/cache.uc:1543 (`--connect-timeout 15 --speed-time 15`).
- rpcd (openwrt/rpcd file.c, fetched upstream) has `rpc_file_exec_timeout_cb`, which does `kill(c->process.pid, SIGKILL)` on the direct child only. It uses no setsid, setpgid or killpg.
- The frontend timeout does not stop the backend. withTimeout(fs.exec(...), 3000) (helpers/executeShellCommand.ts, methods/shell/index.ts:20) only rejects in the browser. runtimeUiState.service.ts then schedules the next poll 1 s later.
- A held reload.lock is never reclaimed while its owner PID is alive (initd.uc:212). So a hung reload blocks later starts (initd.uc:604, which then defers) and queues later reloads as pending.


**Verification reproduction:**

Script: scratch/audit-verify-clash-curl-timeout/repro.sh (+ clash_server.py), run in WSL with a private mktemp dir and a random port.
- Fixture: taken from tests/runtime_state_predicates.sh.
  - The sing-box stub is a copy of sleep, reported by a stub ubus. netstat and nft are stubs.
  - Only `tproxy-route-rule-present` is stubbed. clash-api-ready runs the real runtime.uc against a Python HTTP server that answers GET /proxies.
- Control (server responsive):
  - clash-api-ready rc=0 in 0.08 s.
  - `state.uc wait-forkop-stable-start forkop ForkopTable 0x00100000 2 2` rc=0 in 0.2 s.
- After `kill -STOP` of the server (models a frozen sing-box; the kernel still accepts TCP):
  - wait-forkop-stable-start with a verify timeout of 2: rc=124, still blocked when the outer `timeout 25` killed it after 25.0 s.
  - forkop-stably-running: rc=124 at 10 s.
  - `clash-api get_proxies`: rc=124 at 10 s.
- rpcd-style kill: I started forkop-stably-running, then sent SIGKILL to the top ucode PID only.
  - The chain survived, reparented, and was still blocked: `/bin/sh -c 'ucode' ... clash-api-ready` -> `ucode ... runtime.uc clash-api-ready` -> `sh -c -- 'curl' '-s' '127.0.0.1:45961/proxies'` -> `curl -s 127.0.0.1:45961/proxies`.
  - The curl command line shows no timeout flags.
- Cleanup was checked: no leftover processes.
- Reload/rollback under a real transition guard, and memory growth through rpcd/uhttpd, were not reproduced; that needs a router. The reload claim rests on the static call chain plus the reproduced unbounded wait-forkop-stable-start.


**Verification notes:**

Verdict: confirmed. Severity stays P2. The failure is real, but the trigger is narrow:
- The trigger needs sing-box to be alive, own its ports and pass the pid/age checks, while its controller socket accepts connections and never answers. Examples: SIGSTOP/cgroup freezer, severe memory or zram thrash, a Go-side deadlock, or a new config that wedges the API.
- A crashed or exited sing-box gives ECONNREFUSED, or the runtime checks that come before the probe (state.uc:947-948) short-circuit, so the ordinary crash case fails fast.
- On the reload path the impact borders on P1: a fail-closed rollback that never runs, with the drop guard left installed and reload.lock held. Low likelihood keeps it at P2.

Corrections to the finding:
1. The health.uc call is at line 208, not 207.
2. The finding misses the callers where the fix matters most (full list in evidence): the rollback/restore verification in lifecycle.uc:793-799 and 855-861, which can hang the same way, and start verification at 1383/1414 under reload.lock.
3. Impact (a):
   - Orphan survival is confirmed. The orphans are live blocked processes reparented to init, not "unreaped" zombies. They unwind as soon as sing-box answers or its socket closes.
   - "Memory runs out over minutes" is not verified. The accumulation rate depends on uhttpd max_requests and script_timeout, the LuCI rpc timeout and the number of open tabs. Each stuck chain is about 8 processes.
4. Impact (b) is worse than stated. The hung owner keeps reload.lock (initd.uc:212 never reclaims a live PID), so a UI Restart/Start defers (initd.uc:604-606) and reloads queue as pending. Meanwhile the transition guard keeps dropping protected traffic. Recovery then needs SSH or a reboot.
5. Impact (c) is weak. If the API is hung, set_group_proxy failover could not work anyway. The effect is only a stalled Priority worker that resumes when the API answers again.

Better minimal fix:
- In one helper (e.g. `clash_curl_base(max_time)`), add `--connect-timeout 2 --max-time N` to every Clash API curl in runtime.uc:
  - readiness, get_proxies, get_connections, PUT and DELETE: about 3-5 s;
  - delay endpoints: ceil(timeout_ms/1000) + 2 (the group delay uses a 10000 ms timeout, so 12 s).
- Optionally, make wait_forkop_stable_start (state.uc:952-963) deadline-based on clock() rather than iteration-based. One iteration can then still take a few seconds, but the total verify time stays bounded near SING_BOX_START_VERIFY_TIMEOUT.
- This touches no safety invariant. A probe timeout reports not-ready, which is the fail-closed direction (invariant 18).

Test:
- Use a PATH curl stub in tests/runtime_state_predicates.sh or diagnostics tests that records argv and asserts `--max-time` for every clash-api action.
- Optionally add a hanging-stub variant (the stub sleeps unless --max-time is present) and assert that wait-forkop-stable-start returns non-zero within its bound.
- Do not rely on python3 in the test environment.

Side observation, not a new finding: with enable_yacd_wan_access, the bearer secret is on the curl command line (runtime.uc:1586), so a hung curl keeps it visible in `ps w` for as long as it hangs. autotune/apply.uc:311-313 already passes it through a private header file. The support report that includes `ps w` is explicitly labelled confidential, so this does not violate invariant 2.


---

<a id="uc-017"></a>

## UC-017 · P2 · S4 — Автоматический откат autotune после неудачной проверки перезаписывает изменения конфигурации, сделанные во время проверки

**Severity:** P2<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** autotune/apply.uc ↔ snapshot restore interplay<br>
**Sources:** snapshots#1<br>
**Original title:** Autotune automatic rollback after failed verification overwrites configuration changes made during verification<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** autotune/apply.uc:738 `if (!v.ok) return rollback_to(audit, p, "verification_failed");` with no check that CONFIG is still the candidate. rollback_to:601 `snapshots([ "restore", audit.pre_snapshot ])` is unconditional. Contrast the success path at 741 (`fingerprint(...) != candidate.fingerprint` -> needs_attention) and operator rollback at 768 (`if (d.diagnosis != "candidate_active") return ... rollback_needs_candidate_config`). verify_production fails when a concurrent action runs (387-390: no_guard, no_snapshot_operation, no_service_action), so a concurrent user action both triggers and is undone by the rollback.


**Reproduction:** scratch/audit-a10\at_harness.sh (lines 1-242 of tests/autotune_apply.sh with ROOT fixed, plus scenario_rollback_overwrite.sh)


**Expected:** The automatic rollback only reverts the candidate it wrote. If the file is no longer the candidate, the apply ends needs_attention and leaves the operator's configuration in place.


**Actual:** Reproduced (tests/autotune_apply.sh harness plus scenario): PROD_PLAN=reset, and the user sets dns_rewrite_ttl 31 during verification. Result: status rolled_back, config == pre-apply hash, the user edit exists only in snapshot reason 'pre-restore'.


**Impact:** A LuCI Save & Apply, autotune policy change or snapshot restore made while a manual (6.9.1) or scheduled (6.8.5) apply is verifying is silently reverted, including options unrelated to nfqws_opt. This goes against invariant 8: autotune should change only its DPI rule. The result is reported as a clean 'rolled_back' and history 'recovered'. The edit survives only as a 'pre-restore' snapshot.


**Root cause:** The automatic rollback path skips the 'config is still the candidate' precondition that the operator rollback and LKG-confirm paths enforce.


**Affected files:** `forkop/files/usr/lib/autotune/apply.uc`

**Proposed fix:** In apply() before the automatic rollback_to: `let d = diagnose(audit); if (d.config_is != "candidate")` -> needs_attention with reason 'config_changed_during_verification' and no restore, mirroring the success path and operator rollback(). Optionally also skip the rollback while service_action() != null and report needs_attention.


**Tests needed:** autotune_apply.sh: verification fails together with a concurrent config edit -> needs_attention, config keeps the edit, no restore call, LKG unchanged. Same with a concurrent snapshots.uc restore finishing before the verdict.


**Risk:** More needs_attention outcomes when users edit during verification; this is the intended fail-closed behaviour.


**Verification:** confirmed → P2

**Verification evidence:**

Code at 07872084 (forkop/files/usr/lib/autotune/apply.uc):
- :738 `if (!v.ok) return rollback_to(audit, p, "verification_failed");` There is no diagnose() or fingerprint check before this line. The success path right after it has one at :741: `if (fingerprint(fs.readfile(CONFIG_FILE)) != candidate.fingerprint)` leads to needs_attention "config_changed_during_verification".
- :597-633 rollback_to(): :601 `snapshots([ "restore", audit.pre_snapshot ])` is unconditional. The follow-up proof at :620-626 compares the restored file with p.config_hash, so it cannot detect that a foreign edit was destroyed. It reports "rolled_back".
- The operator rollback() at :768 does enforce the precondition: `if (d.diagnosis != "candidate_active") return { ... "rollback_needs_candidate_config" }`. tests/autotune_apply.sh:690-701 pins the intended design: "config changed outside the apply -> record superseded ..., no automatic rollback".
- config/snapshots.uc do_restore :351-363 has no expected-hash precondition. Only the pre-apply path passes apply_mode=true (:387). So the restore overwrites whatever the file holds. The overwritten content is kept only as an automatic "pre-restore" snapshot (:356), which retention trims (:166-178).
- Nothing blocks a concurrent edit while apply.uc holds only the autotune lock:
  - The snapshot lock is held only inside the snapshots.uc calls, not during verification.
  - manager.uc policy_set/uci_apply (:253-283) commits /etc/config/forkop with no lock against apply.
  - LuCI Save & Apply commits via rpcd, and init.d service_triggers (:103-129) adds config reload triggers.
  - The settings/section views do not look at autotune state.
- verify_production :387-390 (no_guard, no_snapshot_operation, no_service_action) runs before the ~10-20 s traffic phase (:398-428). A concurrent LuCI apply therefore both makes verification fail (service action, or nfqws restart disturbing the probes) and gets overwritten.
- Both the manual 6.9.1 path and the scheduled 6.8.5 path go through the same apply(). The manager records rolled_back as "recovered" (tests/autotune_manual_apply.sh:210).


**Verification reproduction:**

Reproduced in WSL on the audit tree with my own scratch harness. run.sh builds a private TMPDIR, copies lines 1-242 of tests/autotune_apply.sh with ROOT fixed, and appends scenario.sh. Both files are in scratch/audit-verify-rollback-overwrite\. Results:
- S1: PROD_PLAN=reset (the candidate fails in production). While the 'curl production' probes run, the user sets dns_rewrite_ttl 60->31.
  - Result: status rolled_back, reason verification_failed, rollback {status: success, config_exact: true, config_hash_restored: true, lkg_is_pre_snapshot: true, runtime_ok: true}.
  - The config holds the user edit 0 times, config == pre-apply: yes, persisted phase rolled_back.
  - Health log: "autotune_apply success", "restore success".
  - The user edit survives only in snapshot 1790606740_738825707 (automatic, pre-restore).
- S2: the same, but the user edits the nfqws_opt of a different DPI rule (Game: repeats=6 -> 9). That edit is silently reverted too, with status rolled_back and config == pre-apply. So autotune's rollback changes a rule it never mutated (invariant 8).
- S3 (control): verification succeeds with the same edit. Result: needs_attention / config_changed_during_verification, and the config keeps the edit. The existing guard works only on the success path.
- S4 (control): no concurrent edit, verification fails. Result: a normal rolled_back.
- A LuCI apply with a real procd-triggered reload needs a router. Statically, that path fails verification even more reliably (no_service_action, or an nfqws restart during the probes) and then goes through the same rollback_to.


**Verification notes:**

Assessment:
- Line references are all accurate: 738, 601, 741, 768, 387-390.
- P2 is the right severity, not P1:
  - The edit can be recovered from the pre-restore snapshot, but only until retention removes that snapshot.
  - The router ends up on a verified pre-apply configuration.
  - The window is limited to the verification phase, roughly 10-30 s. The scheduled autoapply runs at most once a day, but in the background, and nothing warns a user who is editing at the same time.
  - It is still an unsafe mutation of unrelated configuration (invariant 8) reported as a clean success (invariant 5). The only record is a generic "restore success" history entry.

Better minimal fix (the proposed one is directionally right but incomplete):
1. In apply(), before the automatic rollback at :738, call `let d = diagnose(audit)`. If `d.config_is != "candidate"`, do not call rollback_to. End with needs_attention, reason "config_changed_during_verification", keep rollback null, and leave LKG untouched. This mirrors :741 and :768.
   - A config_is of "pre_apply" (the user restored it themselves) could be treated as no-restore plus proof of the old runtime instead of needs_attention. That part is optional.
2. The check in step 1 still leaves a TOCTOU window between diagnose() and do_restore's read_config(). do_restore has no precondition. To close it, give `snapshots.uc restore` an optional expected-hash argument (the candidate hash). do_restore checks it under the snapshot lock and re-checks it after the guard is installed, the same way do_apply/guarded_replace's apply_mode concurrent_change check does (:326-329). apply.uc's rollback_to passes audit.candidate_hash.
3. Product decision: under step 1, a failed candidate strategy stays live on the Dpi rule. The user's edit was made on top of the candidate file, and the operator rollback refuses because the diagnosis is not candidate_active. A stronger alternative preserves the edit and still honours invariant 8: when the foreign edit did not touch <section>.nfqws_opt, run a targeted revert of only that option on top of the current file, through the same guarded transaction with an expected hash. Use needs_attention only when the user also changed that option.

Tests to add to tests/autotune_apply.sh:
- PROD_PLAN=reset plus an edit during verification. Expect needs_attention (or a targeted revert), the edit kept, no restore call in health.log, and LKG == PRE_LKG.
- A variant where a snapshots.uc restore finishes during verification.

Related, not part of this finding: the same TOCTOU exists in the operator rollback() between :764 diagnose and :601. The expected-hash restore argument from step 2 fixes both.


---

<a id="uc-018"></a>

## UC-018 · P2 · S4 — Diff снимков теряет или приписывает не той секции изменения в анонимных секциях UCI — предпросмотр пишет «Нет сохранённых изменений»

**Severity:** P2<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** config/snapshots.uc diff / History restore preview<br>
**Sources:** snapshots#2, uci-global#3, uci-rules#9<br>
**Original title:** Snapshot diff loses or misattributes changes in anonymous UCI sections, so the restore preview can say 'No saved changes'<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** snapshots.uc:240 `let start = match(line, /^[ \t]*config[ \t]+[A-Za-z0-9_-]+[ \t]+['"]?([A-Za-z0-9_-]+)['"]?/);` requires a section name, so a line `config section_interface` does not reset `section`. Its options are keyed `<previous named section>.<option>` (251), and each anonymous section overwrites (258) or appends to (255) the same key. Anonymous sections are real: section.js:4066 `uci.add(UCI_PACKAGE, options.typeName)` for subscription_url/section_interface/urltest/priority_level items (3310-3378), and migration.uc:1559 `cursor.add(CONFIG_NAME, op.type)`. Hardware evidence: the stage-6 history probe diff lists 'Alloha · section' and 'Alloha · name', which are child-item owner/name options attributed to the named section 'Alloha'.


**Reproduction:** scratch/audit-a10\anon_diff.sh


**Expected:** One row: section '@section_interface[0]', option 'enabled', before '1', after '0'.


**Actual:** Repro with libuci-written files (two anonymous section_interface items, only the first disabled): fixture-diff returns [].


**Impact:** The 'Changes' modal and the restore confirmation (initController.ts:243-261) under-report or mislabel changes. Example: disabling one of two interface items yields an empty diff, so the preview says 'No saved changes since this snapshot' while the restore re-enables that interface. List options of several anonymous items are concatenated, and reorderings show phantom rows. Read-only users see the same wrong data.


**Root cause:** The regex assumes every UCI section is named. libuci writes anonymous sections as `config <type>` with no name.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `tests/config_snapshots.sh`

**Proposed fix:** In options(), start a new section on every `config <type>` line with the name optional. Key anonymous sections as `@<type>[<n>]` (per-type index in file order, libuci's own addressing) so they never merge into the previous named section. The UI renders the key as is.


**Tests needed:** config_snapshots.sh fixture-diff cases: anonymous sections after a named one; a change in the first of two anonymous sections; list options in two anonymous sections; a named section followed by an anonymous one with the same option name.


**Risk:** Index-based keys make diffs noisier when an anonymous item is inserted or deleted in the middle; that is still better than silent loss.


**Verification:** confirmed → P2

**Verification evidence:**

forkop/files/usr/lib/config/snapshots.uc:240 `let start = match(line, /^[ \t]*config[ \t]+[A-Za-z0-9_-]+[ \t]+['"]?([A-Za-z0-9_-]+)['"]?/);` matches only a header that has a name. libuci writes anonymous sections as a bare `config section_interface`, so `section` is not reset. The options of that section are keyed `<previous named section>.<option>` (line 251). A later anonymous section of any type overwrites the same scalar key (line 258) or appends to the same list (line 255). diff() at lines 267-295 then compares only the last value per key.

No other layer corrects this. The `config_snapshot_diff` CLI (usr/bin/forkop:196) runs `snapshots.uc diff`. History's loadDiff/restoreSnapshot (fe-app-forkop/src/forkop/tabs/history/initController.ts:197-261) and diffRows (model.ts:218-223) show the rows unchanged. When the array is empty, the restore confirmation says 'No saved changes since this snapshot' (initController.ts:260).

Anonymous sections exist in real configs:
- section.js:4066 calls `uci.add(UCI_PACKAGE, options.typeName)` with no createId for subscription_url, section_interface, urltest and priority_level (3310-3378).
- migration.uc:1559 calls `cursor.add(CONFIG_NAME, op.type)`.
- urltest_override.uc:63 calls `uci_core.add(CONFIG_NAME, "urltest_override")`.
- The router's own baseline (hardware-validation-stage6-07872084/backup/forkop.config.baseline) has anonymous `config section_interface` blocks after 'Czech' (two in a row, lines 180 and 187), 'WardogswebAPIviaMain', 'Windows' and 'Alloha'.
- Interface membership is stored only in these child sections. The named section 'main' has no interface list.
- The hardware history probe (10-history/history-probe.txt:3) shows the rows 'Alloha · section' and 'Alloha · name'. These are options of the anonymous section_interface that follows 'Alloha'.

No test pins or covers this. tests/config_snapshots.sh fixture-diff cases (lines 139-204) use only the named 'settings' section.


**Verification reproduction:**

I wrote and ran an independent script: scratch/audit-verify-anon-diff\repro.sh, run via wsl.exe with a private mktemp -d. The config is written by the real libuci CLI: `config section 'Czech'` plus two anonymous section_interface children (awg0 and awg1, same resolver settings, owner option section='Czech'). Then `ucode snapshots.uc fixture-diff before after`. Observed:

- A: delete the FIRST interface item (awg0 leaves routing section Czech). diff: `[ ]`. The file really lost the awg0 block.
- B: set domain_resolver_dns_type udp->doh on the FIRST item only. diff: `[ ]`.
- C: rename the FIRST item's interface awg0->awg5. diff: `[ ]`.
- D: the same change on the SECOND item. diff shows `{section:"Czech", option:"domain_resolver_dns_type", "***"->"***"}`, attributed to the named section.
- F: two anonymous urltest items after 'main' with `list include_countries` DE and NL, values swapped. This shows as one merged `main · include_countries` list row.
- G: named 'main' has `option name 'Main'` and is followed by an anonymous child with `option name 'awg0'`. Renaming main to 'Renamed' gives diff `[ ]`: the child hides the parent's own option.
- E: an accidental misplacement (reorder index counts all sections) put a child right after 'settings'. Its options then showed up as 'settings · section', 'settings · name', and so on, which is another case of misattribution.

Cases A/B/C are exactly the situation where History > Restore says 'No saved changes since this snapshot'. The restore itself replaces the whole file and would re-add or change a routing interface.

This did not need a router: the parser is pure text processing, and the file format came from libuci itself.


**Verification notes:**

Corrections to the finding:
1. The example scenario is wrong. 'Disabling one of two interface items' is not possible: section_interface has no `enabled` option. Its only options are section, name and domain_resolver_enabled/dns_type/dns_server (section.js:2074-2088). The original anon_diff.sh set `enabled` by hand. The real, stronger scenario: removing the first of two interfaces from a routing section, or replacing or retuning it, gives an empty diff. The preview then says 'No saved changes since this snapshot' while the restore adds an interface back to routing.
2. Additional impact the finding missed: an anonymous child also hides the named parent's own option of the same name (case G). Anonymous sections that come before any named section are dropped entirely by `if (section == "" ...)` at line 243. That second case is unlikely, because 'settings' is always first.
3. The 'reordering shows phantom rows' claim is weak. Index-based keys from the proposed fix would also report a reorder, and order can matter for interface numbering. Drop that part of the impact claim.
4. Values are mostly masked. safe_value (206-212) turns most child options into ***, so even correctly keyed rows show '*** -> ***'. The main harm is missing rows and wrong section labels, not wrong values.
5. The restore/apply result field `changes` (lines 361 and 387) uses the same diff(). autotune/apply.uc keeps its own `changes`, so autotune is not affected.

Severity: stays P2 ('misleading important state'). This is the only preview before a routing-affecting restore, it happens on the real router's config layout, and read-only users see it too. There is no data loss: the restore still writes the full snapshot under the guard. Anyone who treats the dialog as purely informational would call it P3.

Minimal fix (confirmed as sound): in options(), match `^[ \t]*config[ \t]+([A-Za-z0-9_-]+)(?:[ \t]+['"]?([A-Za-z0-9_-]+)['"]?)?[ \t]*$`. Keep a per-type counter; a section without a name gets the key `@<type>[<n>]`, which is libuci's own addressing. Reset `section` on every config line. The key has no '.', so diff()'s `index(key, ".")` split stays correct.

Optional UI nicety, not required: label anonymous rows with the owner option (section/group), for example 'Czech › interface #1'.

Tests: add fixture-diff cases to tests/config_snapshots.sh, using libuci-format input (bare `config section_interface`):
- removing or changing the first of two anonymous items;
- a change in the second item keyed to @type[1], not to the named parent;
- list options in two anonymous items kept separate;
- a named-section option with the same name as a following child's option.


### Also reported as uci-global#3 (P3): Snapshot diff merges options of anonymous UCI sections into the preceding named section; changes are hidden or misattributed

**Evidence:** snapshots.uc:240 `match(line, /^[ \t]*config[ \t]+[A-Za-z0-9_-]+[ \t]+['"]?([A-Za-z0-9_-]+)['"]?/)` requires a section name. libuci exports anonymous sections as `config urltest` (no name), and Forkop creates urltest/subscription_url/section_interface children anonymously (section.js:4064-4066; migration.uc:287-299). The keys become '<previous named section>.<option>', and later sections overwrite earlier ones (snapshots.uc:249-257).


**Proposed fix:** In options(), accept a nameless `config <type>` line and key anonymous sections as '@<type>[<ordinal>]' (or '<type>@<owner section option>#n'), so they are never merged into the previous named section.


### Also reported as uci-rules#9 (P3): Snapshot diff ignores changes inside anonymous child sections (subscription_url, urltest, section_interface)

**Evidence:** config/snapshots.uc options(): `let start = match(line, /^[ \t]*config[ \t]+[A-Za-z0-9_-]+[ \t]+['"]?([A-Za-z0-9_-]+)['"]?/)` requires a section name. Unnamed `config urltest` lines keep the previous section name, so child options overwrite each other under '<rule>.<option>'. UI children are created anonymous (section.js createChildItem `uci.add(UCI_PACKAGE, options.typeName)` except priority groups).


**Proposed fix:** Key anonymous sections by type plus ordinal (e.g. '@urltest[1]') or by their owner and value (section+url/name). Accept the 'config <type>' line without a name as a new section.


---

<a id="uc-019"></a>

## UC-019 · P2 · S4 — Оставленный lifecycle DPI guard делает восстановление ненадёжным: DPI-восстановление всегда падает, остальные сообщают успех при активном guard

**Severity:** P2<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** restore ↔ lifecycle DPI transition guard<br>
**Sources:** snapshots#3, nft#4<br>
**Original title:** A kept lifecycle DPI guard (ForkopTableDpiGuard) makes restore unreliable: DPI-changing restores always fail, others report success while the guard is still active<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** lifecycle.uc:1291-1294 keeps the guards when DPI rollback fails ('preserving the fail-closed guards'). lifecycle.uc:1225 `install-dpi-transition-guard` is create-only: nft/apply.uc:1663-1666 `if ((!remove && present) ...) return remove && !present;` returns false when the table exists. The failure aborts the reload (lifecycle.uc:1880-1884, 1946-1948). Only stop removes it (lifecycle.uc:1086). snapshots.uc guarded_replace (336-338) takes reload exit 0 as proof of coherence and never checks ForkopTableDpiGuard / forkop_transition_guard, although health.uc:211-213 treats them as 'guard active'.


**Expected:** Restore reports success only when no Forkop fail-closed guard remains. The recovery path for a kept lifecycle guard is explicit.


**Actual:** Static trace: no test covers a reload or restore after a kept ForkopTableDpiGuard (dpi_reload_faults.sh and dpi_transition_guard.sh stop at the rollback failure).


**Impact:** After a lifecycle DPI rollback failure, History/Overview send the user to restore. A restore whose plan restarts DPI always fails (recovered or needs_attention, with the restore guard now also active). A restore of the old config (plan: no DPI restart, 'Reload skipped') reports 'Configuration restored and reloaded', moves LKG and releases the restore guard while ForkopTableDpiGuard still drops DPI traffic. Only a service restart or reboot recovers, and nothing tells the user. This is the same class of defect that commit 0fa3d250 fixed for the restore guard (invariant 6).


**Root cause:** The restore transaction's notion of 'coherent runtime' is 'reload exit 0'. The lifecycle's own kept guard is invisible to it, and the lifecycle install is create-only.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `forkop/files/usr/lib/service/lifecycle.uc`, `fe-app-forkop/src/forkop/tabs/dashboard/overview.ts`, `tests/dpi_reload_faults.sh`

**Dependencies:** Shared with the lifecycle/DPI-transition audit area.


**Proposed fix:** (a) In guarded_replace, count a reload as coherent only if ForkopTableDpiGuard and ForkopTable/forkop_transition_guard are absent afterwards; otherwise return needs_attention with reason 'runtime_guard_active' and keep the restore guard and LKG. (b) In lifecycle reload, detect a kept ForkopTableDpiGuard up front and fail with an explicit 'restart required' log/result (or re-snapshot and use ensure semantics). (c) The UI names 'restart the service' as the recovery for this state.


**Tests needed:** Lifecycle test: DPI rollback failure keeps the guard, then a reload needing a DPI restart. snapshots test: a guard stub reporting ForkopTableDpiGuard present after reload -> restore must not be success.


**Verification:** confirmed → P2

**Verification evidence:**

The chain holds against the code at 07872084:
1. The guard is kept. lifecycle.uc:1290-1294 (`if (!dpi_restored) { log_message("DPI reload rollback failed; preserving the fail-closed guards ...") ... return status; }`) returns without removing ForkopTableDpiGuard. RELOAD_STATE_FILE is not rewritten, so it still holds the state of the last successful reload (the old config).
2. Install is create-only. apply.uc:1663-1666 (`if ((!remove && present) || ...) return remove && !present;`). tests/dpi_transition_guard.sh:37-38 deliberately pins this ("exit 3" if a second install succeeds).
3. The reload plan looks only at config. reload.uc:56-154 compares config signatures only (zapret_queue/zapret_runtime/zapret2_*/byedpi_runtime), and state.uc:1820-1823 builds them from UCI. Nothing in reload() looks at a kept guard: forkop_running (state.uc:941-944) checks sing-box and network only.
   - If the restored config's DPI signatures differ from the committed state, the plan restarts DPI and switch_dpi_runtime fails at lifecycle.uc:1225-1227. The abort goes through abort_reload(status,false) at :1883, or abort_guarded_transition at :1948. dpi_switch_started is false and restore_dnsmasq_reload_config returns true when there is no backup (:607-608), so the reload returns 1 and the guard is untouched. guarded_replace then writes `before` back and reloads again. That reload fails the same way if `before` also changes DPI, giving needs_attention/runtime_rollback_failed with ForkopConfigRestoreDpiGuard now also active.
   - If the restored config's DPI signatures equal the committed state (e.g. restoring the LKG), the plan has no DPI restart. snapshot_dpi_runtime leaves dpi_snapshot_dir empty, switch_dpi_runtime returns 0 at :1223-1224, and dpi_guard_active is false in this process, so :1891/:1955 never remove the guard. Reload exits 0.
4. The restore trusts exit 0. snapshots.uc:336-338 (`if (valid && reload_ran(detect_queued)) { if (!restore_guard(true)) ... else result = on_success(); }`) then releases the restore guard, writes LKG (:360) and returns success. The frontend (initController.ts:271-272) shows 'Configuration restored and reloaded'.
5. The contrast: the project's own autotune path treats the lifecycle guard as blocking. autotune/apply.uc:63 (`GUARD_TABLES = [ "ForkopConfigRestoreDpiGuard", PROD_TABLE + "DpiGuard" ]`) with :562/:703/:721. health.uc:211-213 does the same. snapshots.uc and lifecycle finish_reload_status (lifecycle.uc:402-404, which checks only ForkopConfigRestoreDpiGuard) do not.
No test covers a reload or restore after a kept ForkopTableDpiGuard. dpi_reload_faults.sh stops at abort_reload, and config_snapshots.sh / config_restore_guard.sh stub the reload.


**Verification reproduction:**

Scratch script: scratch/audit-verify-restore-dpiguard\repro.sh. It ran in WSL with a private mktemp dir, a stateful stub nft (tables stored as files) and the real ucode modules from the worktree. Output:
A) Real nft/apply.uc: `install-dpi-transition-guard ForkopTable` exits 1 when ForkopTableDpiGuard is present, 0 when it is absent, and 1 on a second install. Create-only confirmed.
B) Real service/reload.uc plan-state-files with force=1 (reason '' as `/etc/init.d/forkop reload` passes):
- committed old state vs the restored old config: needs_sing_box_reload=1, needs_zapret/zapret2/byedpi_restart=0, has_work=1. No DPI restart.
- committed state vs a config with a changed zapret runtime: needs_zapret_restart=1. This path hits the create-only install and fails.
C) Real config/snapshots.uc restore. ForkopTableDpiGuard is present; the reload stub exits 0, as statically proven for the no-DPI-restart plan. Result: exit 0, {"status":"success",...}, LKG = the restored snapshot id, restore guard released, "tables left: ForkopTableDpiGuard".
The lifecycle segment (reload() returning 0 or 1 with the guard kept) is static proof from lifecycle.uc:1222-1229, 1251-1316 and 1879-1964. A full lifecycle reload needs the router, so it was not run.


**Verification notes:**

Corrections to the finding:
- "plan: no DPI restart, 'Reload skipped'" is inaccurate. snapshots.uc calls `/etc/init.d/forkop reload`, and rc.common passes an empty reason, so force_runtime_reload=1 (lifecycle.uc:1684). The plan then does a sing-box reload (reload.uc:135-143) instead of "Reload skipped". The outcome is the same: exit 0, the lifecycle guard is untouched, the restore reports success.
- "nothing tells the user" is overstated. health.uc:211 still reports guard.active, so Overview shows 'DPI protection is holding traffic' (overview.ts:93-100, recovery card 'Protection is active'). History shows 'DPI guard: Active' and 'Last recovery: In progress' (history/model.ts:59-72). The real UX defect: that "In progress" never ends, nothing says a restart is required, and it contradicts the restore toast/event 'success'.
- "Only stop removes it" is too narrow. stop_main (lifecycle.uc:1086) runs on stop, restart, cleanup_failed_runtime and restart_runtime_for_reload, so a service restart recovers.
- LKG only really moves when the restored snapshot is not already the LKG. Restoring the LKG, the most natural choice, keeps the same id. The restore guard is still released without a coherent runtime (invariant 4), and the result masks a still-blocked DPI path as success (invariant 5).

Severity: P2 is right. The precondition is a double fault (new DPI start fails and the old DPI restore also fails). The state stays fail-closed (drops, no leak) and a restart recovers. But the recovery workflow reports success on an incoherent runtime.

Same-root-cause variants that the fix should cover:
- lifecycle.uc:400-404 finish_reload_status. A plain successful reload (no DPI restart) calls confirm-working while ForkopTableDpiGuard or the forkop_transition_guard chain is kept. snapshots.uc:439-444 confirm-working does no guard check.
- lifecycle.uc:1389-1397 start_inner duplicate-start check. It checks only the forkop_transition_guard chain, not ForkopTableDpiGuard. A `start` on a running runtime returns 0, and lifecycle.uc:2171-2172 then calls confirm-working.
- DPI-changing restore where `before` has the committed DPI signatures. The rollback reload succeeds and returns 'recovered' with the lifecycle guard still active.
- The forkop_transition_guard install is also create-only (apply.uc:1642-1643). A kept chain has the same interaction when the plan needs a sing-box transition.

Better minimal fix:
(1) One shared predicate "lifecycle guard kept": `nft list table inet ForkopTableDpiGuard` or `nft list chain inet ForkopTable forkop_transition_guard`.
(2) In snapshots.uc guarded_replace, after reload_ran(), when the predicate is true return needs_attention with reason 'runtime_guard_active', guard 'active'. Keep the restore guard and do not touch LKG. This mirrors autotune/apply.uc guards_present().
(3) Use the same predicate in finish_reload_status and in the start_inner duplicate-start branch to skip confirm-working. Optionally, reload() fails early with an explicit 'restart required' log when the guard is present at entry; the reload lock is held there, so it is a kept guard, not an in-flight one.
(4) The UI maps guard.active plus no transition to 'restart the service' rather than 'In progress'.
Auto-routing reload to restart_runtime_for_reload when the guard is kept would also work. That tears down the fail-closed runtime on a failed start, so it would be a product decision. The fixes above are not.

Tests to add: in config_snapshots.sh, a reload stub that leaves ForkopTableDpiGuard present means restore is not success. A lifecycle harness case: kept guard plus a plan without DPI restart means no confirm-working.


### Also reported as nft#4 (P3): Duplicate start returns success while a retained DPI guard (ForkopTableDpiGuard / ForkopConfigRestoreDpiGuard) still drops zapret traffic

**Evidence:** lifecycle.uc:1383-1400: when `forkop-stably-running` is true, only `nft list chain inet ForkopTable forkop_transition_guard` is checked before logging 'Forkop is already stably running; treating duplicate start as successful' and returning 0. state.uc:946-950 forkop_stably_running checks sing-box, ports, clash and table+route only. lifecycle.uc:1290-1294 abort_reload retains the DPI guard on rollback failure ('preserving the fail-closed guards'). snapshots.uc keeps the restore guard on needs_attention.


**Proposed fix:** In start_inner, also refuse when `nft list table inet ForkopTableDpiGuard` or `ForkopConfigRestoreDpiGuard` succeeds. Reuse the existing refusal message.


---

<a id="uc-020"></a>

## UC-020 · P2 · S4 — Сбой между reload и проверкой autotune оставляет непроверенного кандидата; следующий start/reload делает его LKG, отката нет

**Severity:** P2<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** A11 apply / crash recovery (6.8.6)<br>
**Sources:** autotune#2<br>
**Original title:** Crash or interrupt between reload and verification leaves an unverified candidate live; the next start/reload confirms it as LKG; no automatic or UI rollback exists (design H.7/H.8)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** config/snapshots.uc:336-339 `if (valid && reload_ran(detect_queued)) { if (!restore_guard(true)) ... else result = on_success();` (guard released before autotune verification); apply.uc:727-737 phase 'verifying' / `reason = "interrupted_after_apply"; audit.rollback_available = true`; service/lifecycle.uc:2169-2172 `status = start(); ... if (status == 0) module_success(... snapshots.uc, [ "confirm-working" ])` and lifecycle.uc:401-404 (reload confirms when no guard); manager.uc:477-487 crash only pushes an 'unknown' record and cooldown and does not set group.last_apply; manager.uc:341-349 blocker -> 'apply_unresolved' blocks all runs; forkop/files/usr/bin/forkop:224-235 has no autotune_rollback command; docs/design/STAGE6_UX_DESIGN.md:845 'Crash recovery: при старте worker и при boot ... candidate_active без записи — штатный rollback' and :826/:843 (autotune_rollback write API)


**Expected:** The crash is detected and the pre-apply snapshot restored via apply.uc rollback (or at least LKG is not moved and a rollback action is offered)


**Actual:** After a crash in phase 'verifying': config = unverified candidate, LKG = candidate after the next start, autotune blocked with no rollback path in the UI or CLI


**Impact:** Take a power loss, OOM kill or SIGTERM during the ~20-40 s verification window. The candidate strategy, never verified in production, stays in /etc/config/forkop. The boot 'forkop start', or any later reload such as WAN-up, then promotes it to last-known-working. Autotune shows only 'Last check postponed: a previous apply is not resolved', and scheduling stops indefinitely. The group card still shows the previous apply. The only way out is to find the 'Before autotune' snapshot in History and restore it by hand. Invariant 3 is weakened (an unverified config becomes LKG) and design H.7/H.8 recovery is missing.


**Root cause:** The snapshot transaction releases the guard at reload success. The lifecycle confirms LKG on any guard-free successful start/reload. The 6.8.6 recovery only records and blocks, and never invokes apply.uc rollback.


**Affected files:** `forkop/files/usr/lib/service/lifecycle.uc`, `forkop/files/usr/lib/autotune/manager.uc`, `forkop/files/usr/lib/autotune/apply.uc`, `forkop/files/usr/bin/forkop`, `fe-app-forkop/src/forkop/tabs/autotune/initController.ts`, `luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json`

**Dependencies:** None


**Proposed fix:** (a) Fail closed on LKG: lifecycle start and finish_reload_status skip confirm-working while autotune-apply.json has a non-terminal phase, or failed/interrupted_after_apply, whose candidate_fingerprint equals the current config. (b) Crash recovery through the Stage 5 engine: when begin_run or blocker sees apply status unresolved with diagnosis candidate_active, no guard/snapshot/service action, and no autotune lock held, run `apply.uc rollback`. Record history, set group.last_apply to the crash record, and cool the candidate down. (c) Expose autotune_rollback (CLI + admin ACL + group menu) as design H.7 specifies.


**Tests needed:** A recovery test that kills apply.uc in phase verifying, then runs lifecycle start (stubbed) and asserts LKG is unchanged; a manager test that the next run triggers apply.uc rollback and history; an ACL/CLI test for autotune_rollback


**Risk:** Medium. It touches the lifecycle's LKG confirmation; the guard must be narrowly scoped to a matching candidate fingerprint.


**Verification:** confirmed → P2

**Verification evidence:**

The finding holds at commit 07872084. In one sub-case the outcome is worse than the finding says.

1. The guard is released before verification starts.
   - config/snapshots.uc:336-339 runs `if (valid && reload_ran(detect_queued)) { if (!restore_guard(true)) ... else result = on_success();`.
   - For do_apply (snapshots.uc:389), on_success only returns `{status:"success"}`.
   - apply.uc:727-728 then writes `audit.phase = "verifying"; state_write(audit);` to /etc/forkop/autotune-apply.json (on flash) before verify_production runs.

2. The lifecycle confirms LKG without checking verification.
   - lifecycle.uc:2168-2173: `status = start(); ... if (status == 0) module_success(... snapshots.uc, [ "confirm-working" ])`. There is no guard check here.
   - lifecycle.uc:400-404 (finish_reload_status) confirms whenever the ForkopConfigRestoreDpiGuard table is absent. This includes the no-op "Reload skipped: runtime-relevant configuration is unchanged" path at lifecycle.uc:1782-1791.
   - The boot path is initd.uc:615 `[BIN_PATH, "start"]` into lifecycle start.
   - Stage 5 treats this as a hazard itself: apply.uc:264-265 says "a queued reload after the guard is gone would confirm LKG unverified", and apply.uc:733 says "LKG still points at the pre-apply state".

3. There is no rollback path in the product.
   - forkop/files/usr/bin/forkop:224-235 has no autotune_rollback entry, and the ACL has no such entry either.
   - The UI only shows blockerText 'apply_unresolved' → "a previous apply is not resolved" (model.ts:548).
   - manager status does not expose the apply diagnosis.
   - tests/acl_boundary.sh:35 already lists `/usr/bin/forkop autotune_rollback` as a write command. The command was planned (design H.7/H.8, STAGE6_UX_DESIGN.md:826-845) but never built.

4. Autotune stays blocked.
   - manager.uc:348: `if (type(s.state) == "object" && s.resolved === false) return "apply_unresolved";`. This is checked in run_locked (511), apply_group (418) and manual_apply_locked (673).
   - apply.uc:804: `result.resolved = index(TERMINAL_PHASES, s.phase) >= 0 && !unresolved(s, d);`. A dead record left in the non-terminal phase 'verifying' (SIGKILL, power loss, OOM) is therefore never resolved, whatever the diagnosis.
   - apply() gates only on unresolved() (apply.uc:651), so it would accept a new apply. The two gates disagree, and the manager never reaches apply().

5. manager.uc:477-487 begin_run pushes an 'unknown' record and starts a cooldown. It does not touch group.last_apply or the apply state.


**Verification reproduction:**

I ran a scratch reproduction in WSL against the real apply.uc and snapshots.uc from the audit tree. It used a private mktemp dir, env-redirected paths, and an nft stub that lists no tables.
Script: scratch/audit-verify-crash-lkg\repro.sh (helpers mksnap.uc and mkstate.uc are in the same dir).
State at the start: config = candidate, LKG = 100_1 (pre-apply content), before-autotune snapshot = 200_1, and an apply state exactly as apply.uc writes it at phase 'verifying'.

Observed:
- **A (SIGKILL or power loss).**
  - `apply.uc status` → resolved:false, diagnosis:candidate_active, phase:verifying.
  - `snapshots.uc confirm-working` (the call lifecycle start/reload makes) → {"status":"confirmed"}. The new LKG content is the candidate (true).
- **A1. The operator restores the before-autotune snapshot** (end state: config = pre, LKG = 200_1).
  - status → resolved:false, diagnosis:not_applied.
  - `apply.uc rollback` → {"status":"failed","reason":"rollback_needs_candidate_config"}.
- **A2. The config is edited instead** → resolved:false, diagnosis:superseded. Autotune stays blocked.
- **B (SIGTERM, recorded as failed/interrupted_after_apply).**
  - status → resolved:false while the candidate is active.
  - After the restore → resolved:true. Only this case is unblocked by a manual restore.
- **C. LKG has moved and the before-autotune snapshot has been trimmed by retention.**
  - `apply.uc rollback` → {"status":"failed","reason":"pre_apply_snapshot_missing"}. The LKG fallback at apply.uc:771-778 no longer matches plan_config_fingerprint.

Not run: the full lifecycle start itself (it needs the router runtime) and the manager blocker end to end. Both are simple, unconditional code paths and are shown statically above. Existing test 20 (tests/autotune_apply.sh) only checks LKG right after the interruption. Test 19 pins resolved=false for a dead non-terminal record with diagnosis not_applied. tests/autotune_recovery.sh uses a stub apply.uc, so the real unresolved blocking is never tested together with the manager.


**Verification notes:**

Corrections to the finding:

1. **Impact is worse in the SIGKILL/power-loss case and milder in the SIGTERM case.**
   - The finding says the only way out is to restore 'Before autotune' from History. That is true only for SIGTERM, where apply.uc records failed/interrupted_after_apply: a restore, or any config edit, clears the block there.
   - With SIGKILL, power loss or OOM, the phase stays 'verifying'. status().resolved (apply.uc:804) then stays false forever, and every scheduled and manual autotune run is refused with apply_unresolved.
   - After a History restore, even `apply.uc rollback` refuses (rollback_needs_candidate_config).
   - The only exits are over SSH: run apply.uc rollback while the config is still the candidate, or delete /etc/forkop/autotune-apply.json.

2. **Framing of invariant 3.**
   - The candidate is not a "failed" config: the validator and the reload succeeded, and it is a supported TCP/443 catalog profile.
   - What is broken is the Stage 5 contract "only a verified apply moves LKG" (apply.uc:264-265, apply.uc:733, and the test assertion "an unverified edit was confirmed").
   - Concrete effects:
     - History marks the unverified candidate as last-known-working.
     - The old LKG snapshot loses retention protection.
     - The rollback fallback breaks (case C, pre_apply_snapshot_missing).
   - The network does not break, so this stays P2, not P1.

3. **manager.uc:477-487 applies only if the manager worker itself died** (worker.state = running). If only apply.uc was killed, apply_group records apply_output_invalid instead.

4. **Better minimal fix.**
   - (a) Put the LKG skip in lifecycle, at both call sites: start (lifecycle.uc:2168-2173) and finish_reload_status (400-407).
     - Do not put it in snapshots.uc confirm-working. apply.uc's own confirm (apply.uc:746) runs while its persisted phase is still 'verifying', so a check there would block the legitimate confirmation.
     - Read the JSON state directly; do not spawn apply.uc status in the start path. Compare candidate_fingerprint with external_config_fingerprint(). Skip when the phase is non-terminal, or failed with rollback_available, or needs_attention.
   - (b') Smallest unblock: in apply.uc status(), judge a dead non-terminal record by unresolved() alone:
     `resolved = (index(TERMINAL_PHASES, s.phase) >= 0 || !autotune_lock.held()) && !unresolved(s, d)`
     The manager already checks autotune_lock_held before resolved. Update test 19's `resolved == false` assertion to match. Alternatively, finalize dead records to failed/interrupted_after_apply with rollback_available under the autotune lock.
   - (b) Run automatic rollback through `apply.uc rollback`, as design H.8 describes. Prefer worker start over boot: rollback_to re-verifies production (verify_production), which may fail before WAN is up and end in needs_attention.
   - (c) Add autotune_rollback to the CLI, the admin ACL and the group menu, as design H.7 specifies.

5. **product_decision stays false.** Design H.7/H.8 is accepted. Only the timing of automatic rollback (boot vs worker start) is an implementation choice.

6. **Tests to add:**
   - Real apply.uc killed with -9 in 'verifying', then confirm-working, then assert LKG is unchanged once fix (a) is in.
   - Manager against the real apply.uc status after a dead 'verifying' record plus a restore: autotune must no longer be blocked.
   - CLI/ACL coverage for autotune_rollback.


---

<a id="uc-021"></a>

## UC-021 · P2 · S4 — Карточка «Восстановление» в Обзоре пишет «Не требуется» при незавершённом восстановлении, а при недоступном health — «исправно»

**Severity:** P2<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** frontend/overview<br>
**Sources:** frontend-arch#2<br>
**Original title:** Overview Recovery card says 'No recovery needed' while the backend reports pending recovery; the state card says 'healthy' when health is unavailable<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/tabs/dashboard/overview.ts:236-267 overviewRecovery: `status: guard ? 'needs_attention' : 'healthy', title: guard ? _('Protection is active') : _('No recovery needed')`, which ignores health.recovery.pending and health.package_recovery.pending (diagnostics/health.uc:165-181 sets `recovery: { pending: guard || failed }` and package_recovery.pending). overview.ts:145-152: when health is null or overall is 'unknown', the else branch sets `status = ... 'healthy'`, title 'Forkop X is running'. tests/overview.test.ts has no pending-recovery case for the card.


**Reproduction:** scratch/audit-frontend\build\fe-app-forkop\src\forkop\tabs\dashboard\tests\audit_repro.test.ts (vitest run in the scratch copy)


**Expected:** Pending recovery is never shown as healthy, and unknown health is never shown as healthy.


**Actual:** Scratch vitest: package_recovery.pending=true gives recovery {status:'healthy', title:'No recovery needed'} while state={status:'error'}. recovery.pending=true after a failed reload gives 'No recovery needed'. health=null gives state {status:'healthy', title:'Forkop X is running'}.


**Impact:** After an interrupted package upgrade (package_recovery.pending) or a failed last change (recovery.pending), the Recovery card shows a green 'No recovery needed'. That masks needs_attention as success (invariant 5). The warning banner and state card show an error, so the page contradicts itself. When get_health_status fails (health=null), the state card claims 'healthy'.


**Root cause:** The view model derives recovery only from guard.active and treats missing health as healthy.


**Affected files:** `fe-app-forkop/src/forkop/tabs/dashboard/overview.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/tests/overview.test.ts`

**Proposed fix:** overviewRecovery: return needs_attention with 'Recovery has not finished' when health.package_recovery.pending, and a warning or needs_attention when health.recovery.pending. overviewState: when availability is running but health is null or overall is 'unknown', use status 'unknown' (neutral) instead of 'healthy'.


**Tests needed:** overview.test.ts cases: package_recovery.pending, recovery.pending with a failed last event, and health=null. Assert the status is not 'healthy'.


**Verification:** confirmed → P2

**Verification evidence:**

1) fe-app-forkop/src/forkop/tabs/dashboard/overview.ts:242,263-266 builds the Recovery card only from the guard: `const guard = Boolean(health.guard?.active)` ... `status: guard ? 'needs_attention' : 'healthy', title: guard ? _('Protection is active') : _('No recovery needed')`. It never reads `health.recovery.pending` or `health.package_recovery.pending`. The backend sets both in forkop/files/usr/lib/diagnostics/health.uc:164-181 (`failed = last != null && last.status == "failure"`, `overall = guard || package_pending || failed ? "error"`, `recovery: { pending: guard || failed }`, `package_recovery: { pending: package_pending }`). tests/health_status.sh:50,61 pins that backend contract.
2) The Overview disagrees with the page it links to. The Recovery card's "Recovery details" button opens History, and history/model.ts:68-78 shows `Last recovery = In progress` when recovery.pending is set and `Package recovery = Waiting to finish` when package_recovery.pending is set. On the same data the Overview says "No recovery needed" in green.
3) Design docs/design/STAGE6_UX_DESIGN.md:891 (J.1) maps "guard active + recovery pending, package_pending" to `needs_attention`, so a green card breaks both the design and invariant 5 at card level.
4) overview.ts:146-148: when availability is 'running' and health is null or overall is 'unknown', the else branch gives `status = ... 'healthy'`. initController.ts:82 sets `overviewHealth = response.success && response.data ? response.data : null` on every 10 s poll (line 1949). callBaseMethod.ts:15-49 turns timeouts, exceptions and non-zero exits into `success:false`. One failed poll replaces known health with null. overviewWarning(null) then returns null (overview.ts:87), so the red "DPI protection is holding traffic" banner disappears and the State card turns green. The same happens on first render when a cached runtime snapshot exists and health has not loaded yet (initController.ts:1947-1951).
5) No test pins the wrong behaviour. overview.test.ts:225-240 covers only the default all-false health and guard=true.


**Verification reproduction:**

Runtime reproduction with no router needed, using real backend output.
(a) Scratch script gen.sh, run in WSL with a private mktemp TMPDIR and the FORKOP_RUNTIME_STATE_DIR, FORKOP_HISTORY_FILE and FORKOP_OPKG_RECOVERY_DIR overrides. It calls `ucode -L <wt>/forkop/files/usr/lib health.uc fixture <json>` for 4 inputs and writes the health JSON the backend really produces:
- pkg: package_pending=true. Output: overall=error, recovery.pending=false, package_recovery.pending=true.
- fail: last reload failed. Output: overall=error, recovery.pending=true.
- startfail: last start failed. Output: recovery.pending=true.
- unknown: empty ui. Output: overall=unknown.
(b) Scratch copy of fe-app-forkop/src with a vitest file (verify_repro.test.ts) that loads those JSONs and runs overviewWarning, overviewState, overviewRecovery and history recoveryRows. Results:
- pkg: warning 'Package recovery has not finished', state error 'Forkop X needs attention', recovery {status:'healthy', title:'No recovery needed'}. History on the same data shows 'Package recovery=Waiting to finish/warning'.
- fail: warning 'The last configuration change failed', state error, recovery healthy 'No recovery needed' with line 'Last reload: Failed · 1 min ago' in error tone. History shows 'Last recovery=In progress/loading'.
- startfail: recovery healthy.
- unknown: state {healthy, 'Forkop X is running'}.
- null: state {healthy, 'Forkop X is running'}, warning null, recovery {unknown, 'State unavailable'}.
The existing overview.test.ts (14 tests) also passed in the same run. Scratch files are in scratch/audit-verify-overview-recovery\ (gen.sh, out/*.health.json, fe/src/forkop/tabs/dashboard/tests/verify_repro.test.ts).
Side effect: the scratch copy used a junction to the worktree's gitignored fe-app-forkop/node_modules. Vitest rewrote its cache file node_modules/.vite/vitest/<hash>/results.json and touched node_modules/.vite-temp there. No tracked files changed (git status shows only `!! fe-app-forkop/node_modules/`). The junction was removed afterwards with `rmdir`, and its target was left intact.


**Verification notes:**

The finding is confirmed, and one part is worse than it was reported.

1. The health=null case is the strongest part of this finding, not a side note. On a transient get_health_status failure (15 s timeout, rpcd error, non-zero exit), initController.ts:82 overwrites the last known health with null. This clears the warning banner, turns the State card green and changes the Recovery card to 'State unavailable'. An active DPI guard, where traffic is being held, is then hidden until the next successful poll. That is a fail-open display and conflicts with invariants 5 and 18. The page is also briefly green on first render before health loads.

2. For the pending-recovery case, the page is partly mitigated: the role=alert banner and the State card do show the error. The defect is that the Recovery card, and the History page it links to, contradict each other. P2 still fits as "misleading important state", counting item 1. If only the pending-card mismatch is considered, P3 would be defensible.

3. Package recovery pending is a real and persistent state. components/action.uc:2092-2130 leaves /etc/forkop/opkg-package-set-recovery/pending in place on 'manual recovery required' and 'rollback failed' paths. In those cases the card says 'No recovery needed' while manual action is needed.

4. Correction to the proposed fix. Do not show recovery.pending as busy or 'has not finished' when only the last event failed. health.uc:164,180 sets `recovery.pending = guard || failed`, and 'failed' only means the last recorded event had status failure: the previous config was kept or restored, and nothing is running. Minimal fix for overviewRecovery:
- guard: needs_attention, 'Protection is active' (unchanged).
- else if package_recovery.pending: needs_attention, 'Package recovery has not finished'.
- else if recovery.pending (last event failed): 'error' or 'warning', 'The last change failed; previous configuration kept'.
- otherwise: healthy, 'No recovery needed'.

Minimal fix for overviewState: when availability is 'running' and (!health || health.overall === 'unknown' || typeof health !== 'object'), use status 'unknown'. The title can stay 'Forkop X is running' (availability is observed), plus a line 'Health state unavailable'.

For refreshHealth, the fail-closed option is to keep the last successful health on a failed poll and add a 'stale' marker, rather than dropping to null. This keeps a guard warning visible.

Tests to add in overview.test.ts: package_recovery.pending, recovery.pending with a failed last event, health=null and overall='unknown'. Each should assert that the status is not 'healthy'.

5. Related issue outside this finding: history/model.ts:68-69 shows 'Last recovery: In progress' with a loading tone whenever recovery.pending is set. After a failed reload or start it stays 'In progress' until the next successful event, even though nothing is in progress. The root cause is that health.uc conflates 'last event failed' with 'recovery pending'. Changing the backend field is pinned by tests/health_status.sh:61, so the frontend should interpret it instead. This is P3, and if another auditor has not already reported it, record it as a separate finding.

6. The cited line ranges are correct (overview.ts:236-267 and 145-152, health.uc:165-181). product_decision=false stands, with one caveat: whether a failed last change is shown as 'error' or 'warning' on the card is a wording choice.


---

<a id="uc-022"></a>

## UC-022 · P2 · S4 — Десять ручных снимков блокируют restore, снимки pre-restore/LKG и autotune; отказ показывается как общая ошибка и записывается как 'restore failure'

**Severity:** P2 (изменено при ревью плана; по аудиту и проверке — P3)<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** snapshot retention / history events / UI<br>
**Sources:** snapshots#5<br>
**Original title:** Ten manual snapshots block restore, pre-restore/LKG snapshots and autotune; refusal is shown as a generic failure and recorded as 'restore failure'<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-14

**Evidence:** snapshots.uc:169-173 trim_retention returns false when every snapshot is manual or LKG. create() -> 'retention_full' (196). do_restore -> 'pre_restore_snapshot_failed' (357). confirm-working fails (440-443), so LKG stops advancing, and autotune refuses 'config_not_last_known_good' (apply.uc:575). snapshots.uc:427-431 records a restore event for every outcome, including refusals before any mutation, while apply records only `if (answer.started)` (435). health.uc:164-165 then sets overall 'error' and recovery.pending. initController.ts:279-284 ignores result.reason ('Restore failed; check the recovery state before retrying').


**Reproduction:** scratch/audit-a10\retention_manual.sh


**Expected:** The user is told why a restore or snapshot is refused. A refusal without mutation is not recorded as a recovery failure. LKG can always advance.


**Actual:** Repro: after 10 manual creates -> create automatic {failed, retention_full}; confirm-working {failed}; restore {failed, pre_restore_snapshot_failed}.


**Impact:** A user with 10 manual snapshots cannot restore (the recovery tool), gets no hint to delete manual snapshots, and sees health 'error' plus 'Last recovery: In progress' although nothing changed. After further configuration changes LKG silently stays on an old snapshot, and autotune refuses with an obscure reason. The stage-6 router already holds 10 snapshots.


**Root cause:** Manual snapshots count against a single shared cap and are never pruned. The failure reasons are not surfaced, and restore events are recorded without the started check.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `fe-app-forkop/src/forkop/tabs/history/initController.ts`

**Proposed fix:** (1) Record the restore event only when a transaction started (answer.started), as for apply. (2) Map reasons in the UI: retention_full/pre_restore_snapshot_failed -> 'Snapshot storage is full - delete a manual snapshot'. (3) Policy: reserve slots for automatic snapshots, for example refuse manual create when manual count >= RETENTION-2 with an explicit reason.


**Tests needed:** config_snapshots.sh: a refused restore records no event (health stub). History model test: retention_full message. Policy test if a manual cap is introduced.


---

<a id="uc-023"></a>

## UC-023 · P2 · S4 — Откат restore перезаписывает правки конфигурации, закоммиченные во время (долгого) reload цели и не попавшие ни в один снимок

**Severity:** P2 (изменено при ревью плана; по аудиту и проверке — P3)<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** config/snapshots.uc guarded_replace rollback<br>
**Sources:** snapshots#11<br>
**Original title:** Restore rollback overwrites configuration edits committed during the (long) target reload, which are kept in no snapshot<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** snapshots.uc:340 `else if (!atomic(CONFIG, before))` writes back the pre-restore content without checking that CONFIG still equals the target it wrote (the apply-mode concurrent check at 326 covers only the window before the write). During the reload the lifecycle's own 'create automatic' snapshot is refused by the held snapshot lock, so an edit committed in that window exists nowhere else.


**Expected:** A concurrent edit is never discarded without a copy.


**Actual:** A concurrent edit is overwritten by `before` on rollback.


**Impact:** A Save & Apply, autotune policy_set (manager.uc uci_apply commit) or urltest override saved from another tab while a restore reload runs, followed by a failed target reload, loses that edit silently.


**Root cause:** The rollback assumes exclusive ownership of /etc/config/forkop for the whole transaction, but UCI commits do not take the snapshot lock.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`

**Proposed fix:** Before the rollback write, if sha(read_config()) != sha(content), first save the foreign file as an automatic snapshot (the lock is already held; call create() with keep=[pre id]) or return needs_attention without overwriting.


**Tests needed:** config_restore_guard.sh: the reload stub edits the config and then fails -> the edit is preserved in a snapshot or the result is needs_attention.


---

<a id="uc-024"></a>

## UC-024 · P2 · S5 — Ошибки set/commit UCI считаются успехом (core/uci.uc сравнивает с false, dns/apply.uc игнорирует результат)

**Severity:** P2<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A8 persistence error handling<br>
**Sources:** persistence#0, packaging#2, uci-global#6<br>
**Original title:** UCI commit failures are reported as success (core/uci.uc compares with false; dns/apply.uc discards the result)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/files/usr/lib/core/uci.uc:545 `return c.commit(package_name) != false;`. Upstream ucode lib/uci.c: commit() -> uc_uci_pkg_command -> `err_return(res)` returns NULL; jsdoc: 'Returns `null` on error, e.g. ... when a file system error occurred'. Local ucode check: `null != false` evaluates to true (scratch nullcmp.uc). Scratch repro_uci_commit.sh: with a cursor whose commit() returns null, `core.uci.commit()` returns true. forkop/files/usr/lib/dns/apply.uc:50-52 `function uci_commit(package_name) { uci.commit(package_name); }`; :244-246 and :265-267 `uci_commit("dhcp"); return restart_dnsmasq();`. Checks made dead by this: service/lifecycle.uc:530-534 config_commit (start :1016-1020, stop :1476-1481); components/action.uc:2477, 2513, 2551 ('Failed to save ... settings'); config/urltest_override.uc:46,67,71; config/migration.uc:1600,1623-1627 (postinst migrate); singbox/runtime.uc:382. Same pattern: core/uci.uc:462,488,528 return true even when `c.set(...)` returns null.


**Reproduction:** wsl bash scratch/audit-atomicity/repro_uci_commit.sh -> 'core.uci.commit() with binding returning null => true'


**Expected:** A failed commit returns false and the operation reports failure (fail closed).


**Actual:** core.uci.commit() returns true when the binding reports failure (null); dns/apply.uc never looks at the commit result.


**Impact:** Failed writes of /etc/config/{forkop,dhcp,network,sing-box} are treated as saved. On stop/disable/uninstall with a failing or read-only overlay, the dhcp restore commit fails silently: dnsmasq is restarted, the stop reports success, and the persistent dhcp config still forwards to 127.0.0.42 (noresolv=1) while sing-box is stopped, so LAN DNS breaks (after reboot at the latest). The postinst 'migrate' reports success without writing the migrated config (invariant 17). UI toggles report success while nothing was persisted. Violates invariants 5 and 18.


**Root cause:** The ucode uci binding signals errors with null, not false, and ucode `null != false` is true. The dns/apply wrapper drops the return value.


**Affected files:** `forkop/files/usr/lib/core/uci.uc`, `forkop/files/usr/lib/dns/apply.uc`, `forkop/files/usr/lib/service/lifecycle.uc`, `forkop/files/usr/lib/components/action.uc`, `forkop/files/usr/lib/config/urltest_override.uc`, `forkop/files/usr/lib/config/migration.uc`, `forkop/files/usr/lib/singbox/runtime.uc`, `tests/core_uci_runtime.sh`

**Proposed fix:** core/uci.uc: `return c.commit(package_name) === true;`; in set/set_section/delete/add_list/del_list, check the binding result (`let r = c.set(...); return r === true;`). dns/apply.uc: `function uci_commit(p) { return uci.commit(p); }`; in dnsmasq_configure/dnsmasq_restore, `if (!uci_commit("dhcp")) { log("Failed to save dnsmasq settings", "error"); return false; }` before restart_dnsmasq, so lifecycle stop/start return non-zero and the existing failsafe paths run.


**Tests needed:** tests/core_uci_runtime.sh: stub cursor commit()/set() returning null must make uci.commit()/uci.set() return false. dns/apply restore with a failing commit must exit 1. lifecycle stop must return non-zero and run the failsafe. migration.uc migrate must exit 1 when the commit fails.


**Risk:** Low; turns silent failures into reported failures. Callers that ignore the result keep today's behaviour.


**Verification:** confirmed → P2

**Verification evidence:**

Primary source, upstream ucode lib/uci.c (fetched from jow-/ucode master): `#define err_return(err) do { uc_vm_registry_set(vm, "uci.error", ...); return NULL; } while(0)`. uc_uci_pkg_command (commit/save/revert), uc_uci_set and uc_uci_delete all return NULL through err_return on failure and `ucv_boolean_new(true)` on success. They never throw. The commit() jsdoc says it returns `null` on error, for example when a file system error occurred. In libuci, uci_file_commit throws UCI_ERR_IO when opening the config for write, mkstemp, flock or rename fails, so a read-only overlay, or a full ubifs/jffs2 overlay that fails mkstemp, gives null.

Forkop, tree 07872084:
- core/uci.uc:545 `return c.commit(package_name) != false;`. `null != false` is true in ucode, so a failed commit is reported as success. The try/catch never fires because the binding does not throw.
- core/uci.uc:461-462 (set), 487-488 (add_list), 523-528 (del_list), 419-420 (set_section): each calls `c.set(...)` and then `return true;` with the binding result ignored.
- dns/apply.uc:50-52 `function uci_commit(package_name) { uci.commit(package_name); }`, called at :244 (configure) and :265 (restore), each followed by `return restart_dnsmasq();`.
- dns/apply.uc:283-284 failsafe_restore: `dnsmasq_restore("force", true); return true;`. This is a second masking layer: the failsafe exits 0 even when the restore or the dnsmasq restart fails. lifecycle.uc:1120, 1487 and 2203 consume its status, and full-uninstall.sh:83 reaches it through `forkop dnsmasq_restore` (lifecycle.uc:2203).

The following result checks never see a binding failure:
- lifecycle.uc:530-534 config_commit, used at 542, 1019 and 1479.
- components/action.uc:885, 2477 (network, packet steering), 2513 (Direct Proxy), 2551 (TorrServer Direct).
- config/urltest_override.uc:46, 67, 71.
- config/migration.uc:1600 through commit_cursor at 1629-1633 (postinst `migrate`, install.sh `migrate-podkop`).
- singbox/runtime.uc:382 and 497.

No existing test pins success on failure. tests/core_uci_runtime.sh uses a stub whose commit and set always return true, and tests/dns_apply.sh uses the UCI_STATE fixture path (state_commit), so neither covers binding failure.

Not affected: the autotune Stage 5 engine (autotune/apply.uc:192, manager.uc:260) commits through the uci CLI and checks the exit code, which is correct.


**Verification reproduction:**

Scratch run in WSL with the local ucode, a private mktemp TMPDIR, and stubbed logger and dnsmasq init. Files are in scratch/audit-verify-uci-commit/: run.sh, check_core.uc, and stub/uci.uc, a stub uci module that mimics lib/uci.c by returning null from commit() and set() on failure. Output:
- `null != false => true`
- With commit() and set() returning null: `set(forkop.settings.shutdown_correctly,1) => true`, `set(forkop.missing_section.x,1) => true`, `commit(dhcp) => true`, `commit(forkop) => true`.
- `dns/apply.uc restore force`: the binding log shows `commit dhcp -> null`, then the dnsmasq init is called with `restart`, then `exit=0`.
- `dns/apply.uc configure force`: `commit dhcp -> null`, restart, `exit=0`.
- `dns/apply.uc failsafe-restore`: `commit dhcp -> null`, restart, `exit=0`.

No router was needed. The local ucode has no uci.so, so the binding semantics come from the upstream C source and jsdoc rather than a real libuci run. The lifecycle, components and migration effects are proven statically: each of those callers depends only on the core.uci return value shown above.


**Verification notes:**

Corrections and refinements:
1. Line refs. migration.uc commit_cursor is at 1629-1633, not 1623-1627. set_section (core/uci.uc:419-420) has the same pattern and belongs in the list.
2. Impact timing. The ucode cursor keeps set/delete changes in memory; nothing is saved to /tmp/.uci. When the dhcp commit fails, `dnsmasq restart` re-reads the unchanged /etc/config/dhcp (server=127.0.0.42, noresolv=1). LAN DNS therefore breaks as soon as stop_main stops sing-box, not only after a reboot.
3. Severity stays P2. The trigger needs a filesystem failure, such as a read-only overlay or an overlay filled by a package install or lists. The DNS break itself comes from that failure. Forkop's defect is reporting success for it (invariants 5 and 18): stop, uninstall's dnsmasq_restore, component toggles, urltest override save and postinst migrate all report success. For full uninstall, fixing this makes the `set -eu` worker abort in the stop phase with an error instead of removing packages and claiming success.
4. Additional masking layer the fix must include: dns/apply.uc:283-284 failsafe_restore ignores dnsmasq_restore()'s result (`dnsmasq_restore("force", true); return true;`). Without changing it to `return dnsmasq_restore("force", true);`, the failed-start cleanup (lifecycle.uc:1120), the stop failsafe and full uninstall still exit 0.
5. The proposed fix needs one adjustment for delete. The binding returns null (UCI_ERR_NOTFOUND) when deleting an absent option, so a strict `=== true` in delete_path would turn idempotent deletes into failures, for example the migration or urltest_override paths. Treat a non-true result as success only when the target is now absent, or leave delete_path unchanged. For commit, set, set_section, add_list and del_list, `=== true` is correct: the binding returns boolean true on success.
6. Same root cause, not in the finding: core/uci.uc load() (around lines 292-294) calls `c.load(package_name)` without checking for null. It marks the package as loaded and returns true even when /etc/config/<pkg> is missing or unparsable. Minimal fix: `if (c.load(package_name) !== true) return false;`.
7. Minimal fix set:
   - core/uci.uc: `return c.commit(package_name) === true;`, plus `=== true` checks on set, set_section, add_list and del_list, and the load check above.
   - dns/apply.uc: uci_commit returns the result. In dnsmasq_configure and dnsmasq_restore, log and `return false` when the commit fails. In failsafe_restore, propagate the result.
   - Tests: a stub returning null in core_uci_runtime.sh, plus a dns_apply restore/failsafe case that must exit 1.

   Whether stop should keep sing-box running when the DNS restore cannot be persisted, so that LAN DNS keeps working, is a separate product decision and not needed for this fix.


### Also reported as packaging#2 (P2): core/uci.uc treats libuci failures as success (ucode uci returns null, code checks != false / no check), so a failed migration commit on upgrade passes

**Evidence:** core/uci.uc:545 `return c.commit(package_name) != false;`, :461-463 `c.set(...); return true;`, :292-296 `c.load(package_name); loaded_packages[package_name] = true; return true;`. Upstream ucode lib/uci.c: `#define err_return(err) do { uc_vm_registry_set(vm, "uci.error", ...); return NULL; } while(0)`, so commit/set/load/delete return null and never throw. ucode `null != false` evaluates true (checked with the WSL ucode). config/migration.uc:1599-1631 `commit: function(p){ return uci_core.commit(p); }` / `if (!cursor.commit(CONFIG_NAME)) return false;`. tests/core_uci_runtime.sh:100-102 stub `commit: function(_package_name) { return true; }` never exercises a failure.


**Proposed fix:** In core/uci.uc treat a null return as failure: `let r = c.commit(p); return r === true;`; for set/set_section/delete/add_list use `return c.set(...) != null;` (and likewise), keeping the try/catch. In load(), mark loaded_packages only when `c.load(p) === true`. Grep callers that rely on the old always-true behaviour.


**Verification:** confirmed → P3

**Verification notes:**

Verdict: confirmed. The adapter turns every libuci write or commit error into success. This makes every fail-closed `if (!uci_core.commit(...))` check in the ucode code dead in production.

Why severity goes down from P2 to P3:
1. The trigger needs a real libuci error: EROFS or ENOSPC on mkstemp or on the open for write, a flock, rename or realpath failure, or an unloaded package. These are rare.
2. The finding's own repro, "fill the overlay then upgrade", is unreliable:
   - With a full overlay the package install usually fails before postinst runs.
   - If mkstemp still succeeds, libuci ignores the fflush/fsync errors (file.c:808-809) and renames a truncated file, returning success. That is an upstream libuci problem the wrapper fix cannot catch.
   - A better repro is a read-only bind mount over /etc/config.
3. There is no corruption from Forkop's side. The commit is atomic by rename, so a failed commit leaves the old file. applied_migrations is not persisted, so the next upgrade retries the migration.
4. The parse-broken or missing config case is already caught later: service/package.uc:216 `!uci_core.load(...) || !uci_core.exists(CONFIG_NAME + ".settings")`, because exists() goes through c.get_all, which returns null.

The result is a real but rare error-handling gap. It is still worth fixing because it silently disables a whole class of guards (invariant 18). If the product considers starting new code on an unmigrated config a routing risk, raise it to P2.

Corrections and refinements:
- The line references are correct: set is 461-463, load is 293-296, the migration commit adapter is 1599-1601 and commit_cursor is 1629-1634.
- The load() part of the finding has almost no impact. Reads auto-load via the cursor, and exists() catches missing packages. Caching only successful loads is fine. Be aware that c.load() unloads and then reloads the package: never call it again after pending in-memory writes.
- migration.uc:1653-1654 removes the runtime caches (remove_cache_path) before the commit. A failed commit still drops the caches. Minor; order the removal after a successful commit.
- dns/apply.uc:50-52 `uci_commit` discards the result entirely. Same variant, CLEANUP/P3.

Minimal fix for core/uci.uc:
- commit: `return c.commit(package_name) === true;`
- set, set_section, add_list, del_list: `return c.set(...) === true;` / `c.delete(...) === true` inside the existing try. Callers were checked. urltest_override sets only on sections that exist or were just added. components/action.uc sets forkop.settings.*, and postinst ensures that section exists. singbox/runtime.uc checks exists() first. dns/apply.uc and migration ignore the result. So nothing depends on set returning true for a missing section.
- delete: do not use a naive `=== true`. Real c.delete returns null (UCI_ERR_NOTFOUND) for an option or section that is already absent, and the current wrapper treats that as idempotent success. Pre-check existence (`c.get`/`c.get_all` == null → return true), then require `=== true`.

Tests to add:
- tests/core_uci_runtime.sh: stubs that return null for commit, set and delete must make the wrappers return false.
- A runtime-mode test showing that `migration.uc migrate` exits 1 when the commit returns null. The scratch stub above can be reused.

Coordination (a product-level choice): once this is fixed, a failed migration commit exits 1 and the postinst `&&` chain stops. The prerm has already stopped the service, so Forkop stays down after the upgrade. That is the same symptom as the known hardware P2 (the postinst chain leaves Forkop stopped when the mirror is unreachable). Keeping the service stopped on a genuine migration failure is the fail-closed choice. It should be surfaced as needs_attention or a postinst error, rather than decided implicitly. Fix this together with the known postinst P2 so the two changes do not conflict.

Verified OK:
- autotune/apply.uc and autotune/manager.uc do not use core.uci. They call the `uci` CLI (the UCI constant at :45 and :43), so the Stage 5 DPI mutation path is unaffected.
- core/constants.uc:19 only reads.
- `!null` is true, so callers using `if (!x)` would be correct once the wrapper stops converting null to true.


### Also reported as uci-global#6 (P3): core/uci.uc reports failed set/delete/commit as success (ucode uci returns null, not an exception), so migration and lifecycle write failures are not surfaced

**Evidence:** core/uci.uc:461-466 `try { c.set(...); return true; } catch (e) { return false; }` and core/uci.uc:544-545 `return c.commit(package_name) != false;`. ucode lib/uci.c err_return sets uci.error and returns NULL, and its commit is documented 'Returns null on error' (scratch audit-a3/ucode_uci.c:60-63). `null != false` evaluates to true (scratch audit-a3/null_ne_false.uc). Callers that rely on the result include migration.uc:1629-1633 commit_cursor -> migrate_runtime -> postinst `|| exit`, lifecycle.uc:498-500 config_set / config_commit, and components/action.uc:2509-2512 and 2553 direct proxy / torrserver toggles. migration.uc:1549-1574 apply_operations ignores results entirely.


**Proposed fix:** In core/uci.uc, treat a null return as failure: `return c.set(...) != null;`, `return c.delete(...) != null;`, `return c.commit(pkg) === true;`. In migration.uc apply_operations, stop and return false on the first failed operation so migrate_runtime fails.


---

<a id="uc-025"></a>

## UC-025 · P2 · S5 — Критичные файлы на flash заменяются rename без sync: на UBIFS сбой питания оставляет config, снимки и запись apply нулевой длины

**Severity:** P2<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A8 crash safety<br>
**Sources:** persistence#1<br>
**Original title:** Critical flash files are renamed into place without fsync; on UBIFS a power cut can leave /etc/config/forkop, snapshots and the apply record zero-length<br>
**Confidence:** medium<br>
**Hardware required:** yes<br>
**Product decision:** no

**Evidence:** config/snapshots.uc:50-57 `if (fs.writefile(tmp, data) == null || !fs.chmod(tmp, 0600) || !fs.rename(tmp, path))`, with no sync. It is used for /etc/config/forkop (:330 `atomic(CONFIG, content)`, :340), snapshots (:202) and LKG (:344,:360,:442). Same for autotune/apply.uc:211-216 state_write, autotune/state.uc:68-75 write_atomic and diagnostics/health.uc:104-108. The only sync in the backend is components/action.uc:2181. ucode fs file handles have no fsync (local check: fsync=null; only flush/fileno/truncate/lock). UBIFS has no ext4-style replace-by-rename flush: rename is synchronous and data write-back is not, so power cuts produce zero-length files (linux-mtd discussion 'Synchronization in UBIFS (zero length files)'; ubifs FAQ). libuci's own commit does fsync before rename.


**Expected:** After a crash, each critical file is either its complete old version or its complete new version.


**Actual:** Temp file + rename without any data flush for the config, snapshots, LKG and apply state.


**Impact:** On a NAND/UBIFS router in autotune mode auto, an autonomous apply at night rewrites /etc/config/forkop, the before-autotune snapshot and autotune-apply.json. A power cut in the next ~5-30 s leaves them 0 bytes. After boot the user configuration is empty, so Forkop cannot run its rules, and the apply record reads as 'no recorded apply' (rollback() -> no_recorded_apply). The user must find and restore the LKG snapshot by hand. The same applies to manual restore and rollback. Corrupt persistent state and config loss, recoverable only manually.


**Root cause:** ucode fs lacks fsync, and the code relies on rename alone; that is safe on ext4 (auto_da_alloc) but not on UBIFS.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `forkop/files/usr/lib/autotune/apply.uc`, `forkop/files/usr/lib/autotune/state.uc`, `forkop/files/usr/lib/diagnostics/health.uc`

**Dependencies:** The UBIFS behaviour comes from upstream MTD documentation/discussion, not from a local reproduction.


**Proposed fix:** Add a small helper (e.g. in core/helpers.uc) `durable_replace(tmp, path)` that runs `sync` after writefile and before rename, plus one more `sync` after the rename. Use it only for the low-frequency critical writers: snapshots.uc atomic(), apply.uc state_write, autotune/state.uc write (already only-if-changed), and the health.uc history rotation. Keep RAM writers unchanged.


**Tests needed:** Unit: put a stub `sync` on PATH and assert it runs between writefile and rename for these writers. Router: power-cut test on a UBIFS device (optional).


**Risk:** sync flushes the whole page cache; it adds latency to rare transactions only.


**Verification:** confirmed → P2

**Verification evidence:**

Code (worktree 07872084):
- config/snapshots.uc:50-57 `atomic()`: `if (fs.writefile(tmp, data) == null || !fs.chmod(tmp, 0600) || !fs.rename(tmp, path))`. Nothing flushes data before or after the rename. All the cited callers are correct: create() :202 (snapshot files), guarded_replace() :330 `atomic(CONFIG, content)`, :340 `atomic(CONFIG, before)`, :344 and :360 LKG pointer, confirm-working :442. ROOT is /etc/forkop/config-snapshots and CONFIG is /etc/config/forkop, so both are on the flash overlay. HASH_DIR is /var/run and is not affected.
- autotune/apply.uc:211-217 state_write() writes the temp file and renames it to STATE_FILE=/etc/forkop/autotune-apply.json (:44), with no flush. It runs at every phase transition (:600, :608, :614, :631, :664-666, :687, :712, :724, :728, :736, :744, :752, :755).
- autotune/state.uc:68-75 write_atomic() writes /etc/forkop/autotune/state.json (:24). diagnostics/health.uc:104-108 rotates /etc/forkop/history.jsonl.
- grep over forkop/files for sync: the only real flush is components/action.uc:2181 `command_success_from_args([ "sync" ])` for the opkg recovery marker. init.d/forkop:78 `sync)` is only a case label. The project already relies on `sync` for durability in that one place.
- ucode (WSL) check: a fs file handle has `fsync: null, fdatasync: null`, `fs.sync: null`, and only `flush` (stdio flush), so the current code has no per-file durability primitive.
- libuci does flush: `nm -D libuci.so` shows imports `fsync`, `fflush`, `mkstemp`, `rename`. LuCI/uci commits of /etc/config/forkop are durable. Only the Forkop ucode writers are not.
- Upstream UBIFS docs (linux-mtd faq/ubifs.html and doc/ubifs.html, fetched into scratch). The "How do I change a file atomically?" FAQ entry says to synchronize the copy before rename(). The "Why is my file empty after an unclean reboot?" entry says file creation is synchronous and data writing is not. It adds "UBIFS does not provide a similar hack" to ext4's rename flush. The write-buffer is synced every 3-5 s, while data waits for dirty_expire_centisecs (30 s by default).
- Nothing on the boot path restores the config automatically. The next autotune apply() treats a missing or unparsable record as "no previous apply": at :648-653 the `type(previous) == "object"` check fails. rollback() at :762-763 returns `no_recorded_apply`.


**Verification reproduction:**

Static proof plus upstream documentation. Proving the power-cut outcome needs a NAND/UBIFS device and a real power cut: WSL has no UBIFS or nandsim, and contacting the router is forbidden. What I checked locally:
1. `rg` over forkop/files: no `sync`/fsync on any of the listed paths (output above).
2. `ucode -e` in WSL: file handle methods fsync/fdatasync are null, fs.sync is null, and flush exists.
3. `nm -D ~/.local/openwrt-uci/lib/libuci.so`: libuci imports fsync, so uci commit is durable and Forkop's ucode writers are the only exception.
4. I downloaded the UBIFS FAQ and doc into scratch/audit-verify-fsync and extracted the "change a file atomically", "empty file after unclean reboot" and "Synchronization exceptions for buggy applications" sections. They confirm that UBIFS makes creation and rename durable within about 3-5 s, while buffered data can stay unwritten for about 30 s, and that UBIFS has no ext4 auto_da_alloc-style rename flush.
Failure sequence on UBIFS: do_apply() writes the before-autotune snapshot (:202), then atomic(CONFIG) (:330), and the rename commits through the write-buffer within about 5 s. If power is lost before writeback (about 30-35 s), the old inode is already unlinked by the rename and the new inode has no data nodes. After boot, /etc/config/forkop is 0 bytes (or its data reads as zeros). I did not reproduce this on hardware.


**Verification notes:**

Refutation attempts that failed:
(a) No other layer flushes these writes. LuCI/rpcd saves go through libuci, which fsyncs, but autotune apply, snapshot restore, rollback and confirm-working write the files directly with ucode. start_impl/stop call config_commit() (libuci), which would incidentally re-write the config durably, but only on a full start or stop. A reload that does not restart the runtime does not commit.
(b) ucode has no fsync.
(c) OpenWrt mounts the UBIFS overlay without -o sync.
The finding stands.

Corrections and refinements:
1. The line refs are accurate; apply.uc state_write spans 211-217.
2. Scope depends on the filesystem. The bug appears on UBIFS (NAND devices such as GL-MT3000). f2fs is possibly affected (no rename hack; unverified). JFFS2 on NOR is nearly synchronous, and ext4 with auto_da_alloc lowers the risk. The validation router GL-MT6000 is eMMC-based, so a power-cut test there would not exercise UBIFS. Use a NAND device.
3. Impact is slightly narrower than stated. The previous LKG snapshot and the `last-known-working` pointer were written long before the transaction, are already on flash, and survive. At most the latest change is lost. Manual restore still works on an empty config: read_config() returns "" rather than null, so do_restore() proceeds.
4. Escalation check (static only; I did not run it because WSL has no ucode uci module): an empty config should not become LKG. Boot start_impl (lifecycle.uc:1016) fails at `config_set(forkop.settings.shutdown_correctly)` because the section is missing, so confirm-working (lifecycle.uc:2172) is not reached.
5. Extra consequence: a zero-length autotune-apply.json written right after a needs_attention record erases it. The next apply is then not blocked by `previous_apply_unresolved`, and the status shows nothing. This is next to invariant 5.
6. The four targets have different priority. autotune/state.uc is already resilient: a corrupt file is moved to .corrupt and state resets. health history is non-critical, and its append path is non-atomic anyway. The minimal must-fix set is snapshots.uc atomic() and apply.uc state_write.
7. Fix caveats:
   - A global `sync` flushes all mounted filesystems. On routers with USB storage holding a lot of dirty data (the package ships TorrServer), it can stall for a long time.
   - Inside guarded_replace, that stall would happen while the DPI transition guard is installed.
   - Minimal fix: make the command overridable (e.g. FORKOP_SYNC_COMMAND, default `sync`) so tests can stub it. Run it between writefile/chmod and rename, and optionally once more after the rename. If `sync` fails, treat it as a write failure (fail closed).
   - For CONFIG, consider writing and syncing the temp file before restore_guard(false) and doing only the rename under the guard.
   - A targeted per-file flush (BusyBox `sync -d FILE` or `dd conv=fsync`) depends on BusyBox build options. I did not verify it for OpenWrt defaults.
8. Severity stays P2. The outcome matches the P1 wording "corrupt persistent state", but it needs a UBIFS device and a power cut within about 35 s of a low-frequency write, and it is recoverable from the surviving LKG snapshot without a security or routing-safety breach. hardware_required=true and product_decision=false remain correct.


---

<a id="uc-026"></a>

## UC-026 · P2 · S6 — Обновление пакета оставляет Forkop остановленным, если mirror-migration.sh упал (зеркало недоступно или платформы нет в индексе)

**Severity:** P2<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** package lifecycle / upgrade<br>
**Sources:** packaging#0, map#0, cli-contract#11, persistence#3, quality#6, process-locks#5, uci-global#1<br>
**Original title:** Known P2 confirmed: package postinst/post-upgrade chain skips package_postinst when mirror-migration.sh fails, leaving Forkop stopped<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** build.sh:300-302 IPK postinst `...migration.uc migrate || exit $?` / `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || exit $?` / `/usr/bin/forkop package_postinst`; build.sh:438 and :461 APK post-install/post-upgrade `exit(system("... migrate && ... mirror-migration.sh && /usr/bin/forkop package_postinst"))`; forkop/Makefile:55-57 same. mirror-migration.sh:168 always calls check_platform_index -> :137-143 `if ! curl ... forkop-platforms.tsv ...; then ... if [ "$MIRROR_BASE_URL" = "https://mirror.infotechtg.ru" ]; then ... return 1`; APK branch :185-190 always downloads `$MIRROR_BASE_URL/forkop/forkop-apk.pem` under `set -eu` (fatal for any mirror); MIGRATION_ID (:4) is recorded (:217-220) but never used to skip. package.uc:221-233 is the only consumer of /tmp/forkop-package-was-running (`if (!path_exists(PACKAGE_UPGRADE_STATE)) return true; ... INIT_PATH start`). action.uc:2401-2407 in-app APK: `if (!run_logged(... pkg_install_files_command(files))) action_fail(...)` without restarting (action_fail :322-328 only restarts after a sing-box change).


**Reproduction:** Router running Forkop; make the mirror unreachable (or curl fail for forkop-apk.pem on APK); `apk add forkop_<new>.apk` or `opkg install forkop_<new>.ipk` -> script error, `/etc/init.d/forkop status` = stopped, /tmp/forkop-package-was-running still present.


**Expected:** A mirror-feed maintenance failure must not stop routing: package_postinst should restore the pre-upgrade service state and the mirror problem should be reported as a warning.


**Actual:** If mirror-migration.sh exits non-zero (index or key unreachable), package_postinst never runs, the prerm restart hand-off is never consumed, and Forkop stays stopped. apk/opkg report a script error.


**Impact:** Any Forkop upgrade while the mirror is unreachable, or on APK while the key URL is unreachable, leaves Forkop stopped until someone starts it or the router reboots. On APK even an already-migrated router needs the mirror on every upgrade. Affects manual apk/opkg upgrade, `apk add` from the forkop feed, and the in-app APK upgrade. The in-app opkg path recovers the service via finish_forkop_opkg_recovery, and install.sh restores the service state itself.


**Root cause:** The feed-migration step is chained with && / `|| exit` ahead of the service-restore step, and it depends on the network on every run instead of only the first migration.


**Affected files:** `build.sh`, `forkop/Makefile`, `forkop/files/usr/share/forkop/mirror-migration.sh`, `forkop/files/usr/lib/service/package.uc`, `forkop/files/usr/lib/components/action.uc`

**Dependencies:** Same change covers the in-app APK path only partly; see the in-app action_fail finding.


**Proposed fix:** In all three script variants (build.sh IPK postinst, APK post-install/post-upgrade, Makefile postinst), keep `migrate || exit` (fail closed on config migration). Make the mirror step non-fatal in package context, e.g. `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || { mirror_rc=$?; logger -t forkop "mirror migration failed ($mirror_rc); feeds unchanged"; }`, then always run `/usr/bin/forkop package_postinst` and return its status (optionally mirror_rc afterwards). Optionally (product decision) skip network steps in postinst when applied_migrations already contains mirror_infotechtg_ru_v1 and the key file exists.


**Tests needed:** Extend package_lifecycle.sh/package_contract.sh with a fake mirror-migration.sh that exits 1 and a was-running marker; assert package_postinst still runs, init start is invoked and the script exit status is reported. Keep the package_contract.sh count check for `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh` (currently -eq 3) consistent with the new form. Add an in-app APK case: apk add fails, previously running Forkop is restarted.


**Risk:** Low: only changes ordering and exit semantics of the maintainer scripts; config migration stays fail-closed.


**Verification:** confirmed → P2

**Verification evidence:**

All cited lines check out at 07872084.
- build.sh:300-302, the IPK postinst: `...migration.uc migrate || exit $?` / `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || exit $?` / `/usr/bin/forkop package_postinst`.
- build.sh:438 (APK post-install) and build.sh:461 (APK post-upgrade) chain the same three steps with `migrate && ... mirror-migration.sh && /usr/bin/forkop package_postinst`. forkop/Makefile:55-57 matches the IPK form.
- mirror-migration.sh:2 sets `set -eu`, and line 168 runs `check_platform_index` unconditionally. On the default mirror, lines 137-143 turn a curl failure into `return 1`, which ends the script. Line 157 also returns 1 when the platform is missing from the index.
- The APK branch (lines 185-186) fetches `$MIRROR_BASE_URL/forkop/forkop-apk.pem` with no guard, so a failed download under `set -e` is fatal for any mirror, custom or default.
- MIGRATION_ID (line 4) is read only at lines 217-219, to avoid a duplicate add_list. It never skips the network steps. The shipped default config already contains `list applied_migrations 'mirror_infotechtg_ru_v1'` (pinned by package_contract.sh:144), yet every postinst still needs the network.
- package.uc:221-233 is the only consumer of /tmp/forkop-package-was-running (`if (!path_exists(PACKAGE_UPGRADE_STATE)) return true; ... [ INIT_PATH, "start" ]`). prerm (package.uc:177-189) writes that marker and then runs `INIT_PATH stop`. Nothing else in forkop/files reads the marker, and no watchdog or cron restarts the service.
- In-app APK: action.uc:2286 (`upgrade_bounded_stop(SERVICE_INIT)`) stops Forkop before apk runs. If `apk add` fails, action.uc:2406-2407 calls action_fail. action_fail (322-328) calls restart_forkop_after_failed_sing_box_change (308-314), which returns early unless `forkop_stopped_for_sing_box_change` is set. That flag is false on this path, so Forkop stays stopped.
- Tests: tests/mirror_migration.sh:369-380 pins the intended exit-1 when the readiness index is unavailable. No test covers the postinst chain with a failing mirror. package_contract.sh:150-153 only counts the literal `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh` (the count must stay -eq 3).
- History: the same fatal chain has shipped in every release tag since 1.0.0 (a1ba4756; the FORKOP_PACKAGE_POSTINST form since b8056bbe/1.0.12). 1.0.26 carries it unchanged.


**Verification reproduction:**

Runtime reproduction in WSL with a private mktemp root. Script: scratch/audit-verify-postinst-mirror\repro.sh.

How it works:
- It extracts the IPK postinst and the APK post-upgrade script verbatim from the worktree's build.sh (with awk) and redirects only the absolute paths.
- It runs them against the real mirror-migration.sh and the real service/package.uc prerm/postinst.
- Test doubles: curl (fails with "Could not resolve host", or succeeds), apk/opkg, uci, the init script, and a migration.uc stub that exits 0.
- Each case first runs the real `package.uc prerm upgrade` while the stub init reports running, so the was-running marker exists.

Results:
- A. IPK, default mirror, unreachable: rc=1; marker present before and after; package_postinst calls=0; init start=0. stderr: "The mirror platform index is unavailable; package feeds were not changed".
- B. IPK, default mirror, reachable (control): rc=0; marker consumed; package_postinst=1; init start=1.
- C. IPK, custom mirror, unreachable: rc=0; init start=1. Not affected.
- D. APK post-upgrade, default mirror, unreachable: rc=1; marker kept; package_postinst=0; start=0.
- E. APK, custom mirror, unreachable: rc=6 (the key download fails after the index check is tolerated); package_postinst=0; start=0.
- F. APK, reachable (control): rc=0; start=1.
- G. APK on an already-migrated root (key and feeds already in place from F), mirror unreachable: rc=1; start=0.

Not reproduced here (needs a router): how apk/opkg treat a non-zero maintainer script. Known behaviour: opkg prints "Collected errors", exits non-zero and leaves the package "unpacked"; apk reports a script error and exits non-zero. The separate hardware validation of this commit observed the end state.


**Verification notes:**

The finding holds, and P2 is right. Forkop is left stopped and inactive until someone starts it or the router reboots. prerm has already restored dnsmasq, so the router's basic network keeps working. Nothing is lost, and mirror-migration.sh rolls back its own feed and key changes. That makes it a broken major workflow, not a router break (P1).

Corrections and additions:
1. Scope needs one refinement. For IPK/opkg, only the default mirror (mirror.infotechtg.ru) triggers it. With a custom mirror, a missing index is tolerated (lines 140-144) and there is no key download on opkg (case C passes). For APK, any mirror triggers it, because of the key fetch at lines 185-186. On the default mirror, even an already-migrated router needs the mirror index on every upgrade (case G), not just APK routers.
2. There is a deterministic trigger besides network loss. If the mirror index is reachable but lacks the router's target/arch/release/format, line 157 returns 1 and every package upgrade leaves Forkop stopped. install.sh:1880-1909 checks this only at install time. It can still happen after an OpenWrt minor-release change, or with packages installed without install.sh. Likelihood is lower.
3. The finding says the in-app opkg path recovers the service via finish_forkop_opkg_recovery. That is wrong when the mirror is unreachable. I checked this statically.
   - install_forkop_opkg_set (action.uc:2186-2208) installs the backend first. Its postinst fails, so opkg exits non-zero, the loop breaks and the app stays old. The version sets then mismatch, so recover_forkop_opkg_set runs.
   - Recovery reinstalls the previous release's backend with --force-reinstall/--force-downgrade (action.uc:2121-2128). Every tag since 1.0.0 has the same fatal chain, so that postinst fails again. The result is `restored=false` and "Forkop package-set rollback failed; recovery archives retained".
   - This returns before finish_forkop_opkg_recovery, so no service restore happens. Forkop was already stopped by action.uc:2286.
   - The pending marker makes the next attempt go through component_action:2588-2592 → recover_forkop_opkg_set, which fails the same way while the mirror is down.
   - So all four paths are affected: manual opkg, manual apk, in-app APK and in-app opkg. Only install.sh restores the service itself (install.sh:80-85, 2155-2160).
4. Better minimal fix. Keep `migrate || exit $?` (config migration stays fail-closed). Make the mirror step a logged warning. Always run package_postinst and return its status. Do NOT propagate the mirror return code afterwards (drop the finding's "optionally mirror_rc" idea). Any non-zero postinst leaves opkg's package "unpacked", so the next `opkg install` of any package re-runs it. It also makes the in-app opkg path treat the upgrade as failed and roll back. IPK and Makefile form:
   `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || logger -t forkop "mirror migration failed (rc $?); package feeds unchanged"`
   followed by `/usr/bin/forkop package_postinst`.
   For the APK ucode scripts, use a sequential shell string, e.g. `system("... migrate || exit $?; FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || logger -t forkop ...; exec /usr/bin/forkop package_postinst")`.
   Keeping the literal `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh` text keeps the package_contract.sh -eq 3 count valid. With the fix, `apk add` succeeds, so the in-app APK path restarts through action.uc:2426-2429. The remaining in-app gap (other apk failures after the pre-install stop at action.uc:2286 → action_fail with no restart) is the separate action_fail finding.
5. The optional product decision (skip network steps when mirror_infotechtg_ru_v1 is applied and the key or feed already matches) is reasonable but not required for this fix. Note that the default config pre-marks it for fresh installs.
6. Test gap is confirmed. The contract tests only grep the script text; nothing runs the generated maintainer scripts with a failing mirror. My scratch harness (extract the heredocs from build.sh, redirect paths, fake curl) is a workable template for a tests/package_lifecycle.sh case that asserts the init start happens and the marker is consumed when mirror-migration exits 1.


### Also reported as map#0 (P2): При недоступном зеркале обновление пакета оставляет Forkop остановленным: цепочка postinst продублирована 4 раза и прерывается на mirror-migration

**Evidence:** build.sh:300-302 (ipk postinst) `ucode ... migration.uc migrate || exit $?` / `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || exit $?` / `/usr/bin/forkop package_postinst`; build.sh:438 и :461 (apk post-install/post-upgrade) `exit(system("... migration.uc migrate && FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh && /usr/bin/forkop package_postinst"))`; forkop/Makefile postinst: та же цепочка. mirror-migration.sh:2 `set -eu`; check_platform_index (около :136-150): `if ! "$CURL_BIN" ... forkop-platforms.tsv ...; then ... if [ "$MIRROR_BASE_URL" = "https://mirror.infotechtg.ru" ]; then echo "The mirror platform index is unavailable..."; return 1`, вызывается безусловно на :163; для apk ключ скачивается через curl на :185 (`exit 1` при ошибке). Проверки applied_migrations перед сетевыми запросами нет. service/package.uc:178-189 prerm_cleanup останавливает службу и записывает /tmp/forkop-package-was-running; только postinst_restore (:192-230) перезапускает её.


**Proposed fix:** Сделать mirror migration несмертельной для перезапуска службы. Во всех 4 местах: migrate || exit; mirror-migration.sh || logger/warn (migration остаётся в статусе pending и повторяется позже); затем всегда `/usr/bin/forkop package_postinst`, его код возврата пробрасывать. По возможности генерировать тела хуков из одной функции build.sh (и Makefile), чтобы 4 копии больше не расходились.


**Verification:** confirmed → P2

**Verification notes:**

Уточнения к находке:

1. Номера строк: вызов check_platform_index на mirror-migration.sh:168 (не :163). В package.uc prerm_cleanup находится на :183-194 (не 178-189), remember_upgrade_state на :164-181, postinst_restore на :196-235 (не 192-230).

2. Условия срабатывания шире, чем «зеркало недоступно»:
   - (a) стандартное зеркало недоступно напрямую. Важно: на этапе postinst Forkop уже остановлен, поэтому curl идёт мимо прокси;
   - (b) платформы нет в forkop-platforms.tsv, даже если зеркало доступно. Например, после минорного обновления OpenWrt, пока зеркало не синхронизировано. Тогда отказ повторяется при КАЖДОМ обновлении;
   - (c) apk с недоступным пользовательским зеркалом: ключ скачивается curl на :185 без обработки ошибки.

3. Вероятное (не воспроизведено) усиление через обновление из UI, components/action.uc install_forkop. Релизы качаются с https://fold8.ru/forkop (core/constants.uc:41), причём, возможно, через прокси sing-box. Значит, ситуация «релиз скачался, а mirror.infotechtg.ru недоступен» реальна. Перед установкой stop_old_sing_box_before_forkop_upgrade (:2284) останавливает Forkop.
   - opkg: если opkg возвращает ненулевой код при сбое postinst, срабатывает recover_forkop_opkg_set. Он переустанавливает старый backend; новый prerm при этом видит остановленную службу и удаляет маркер. Postinst старой версии с той же цепочкой снова падает, результат — "rollback failed; recovery archives retained" и action_fail. restart_forkop_after_failed_sing_box_change (:308) закрыт условием forkop_stopped_for_sing_box_change, поэтому Forkop остаётся остановленным, а pending-маркер блокирует следующие автоматические обновления.
   - apk: action_fail "Failed to install Forkop release packages", перезапуска тоже нет.
   Код возврата opkg/apk при сбое postinst локально не проверен: исходников opkg/apk нет.

4. Копия в Makefile на практике замаскирована default_postinst (см. evidence). Сборки через buildroot стартуют службу без учёта was-running и без ожидания выхода sing-box — это отдельная тема, не эта находка.

Минимальное исправление:
- В трёх хуках build.sh (и в Makefile для единообразия) сделать mirror migration несмертельной. Код возврата config migrate оставить фатальным: это корректный fail-closed.
- ipk:
  `...migration.uc migrate || exit $?`
  `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || logger -t forkop "[warn] Mirror migration deferred; package feeds unchanged" || true`
  `/usr/bin/forkop package_postinst`
- apk (ucode):
  `system("... migrate && { FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || logger -t forkop '[warn] ...' || true; } && /usr/bin/forkop package_postinst")`
- Это безопасно. Транзакция mirror-migration.sh при ошибке уже откатывает фиды и ключ (cleanup/rollback_transaction, стр. 48-70), а маркер applied_migrations не пишется. Поэтому миграция просто повторится при следующем обновлении. Отдельного механизма «повторить позже» нет, и нужен ли он — вопрос вне этой находки.
- Необязательное улучшение: пропускать сетевой гейт, если `mirror_infotechtg_ru_v1` уже есть в applied_migrations, а фиды уже указывают на зеркало.
- Строка `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh` должна остаться ровно в 3 местах build.sh: этого требует tests/package_contract.sh:152.

Нужные тесты:
- Извлечь тела хуков из build.sh и forkop/Makefile (как в repro.sh). Подставить mirror-migration, завершающуюся с rc=1, и существующий маркер was-running. Проверить, что package_postinst вызван, выполнен `init start` и маркер удалён.
- Статический тест: во всех трёх телах хуков из build.sh одинаковая структура, устойчивая к сбою mirror migration.

product_decision: false. Решение о том, что сбой зеркала не должен блокировать восстановление службы, не требует продуктового выбора.


### Also reported as cli-contract#11 (P2): KNOWN (hardware P2): package upgrade leaves Forkop stopped when mirror migration fails

**Evidence:** service/package.uc:189 prerm `command_success_from_args([ INIT_PATH, "stop" ])`. build.sh:438 and :461 `exit(system("... migration.uc migrate && FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh && /usr/bin/forkop package_postinst"))`. build.sh:300-302 and forkop/Makefile:55-57 use `... || exit $?` before `/usr/bin/forkop package_postinst`. mirror-migration.sh:160-190 does network checks (check_platform_index, curl of the key) and exits 1 on failure (cleanup trap :62-69).


**Proposed fix:** Run `forkop package_postinst` unconditionally (after migrate, which must stay fatal) and treat a mirror-migration failure as a warning with its rollback, e.g. `mirror-migration.sh || logger ...; /usr/bin/forkop package_postinst`. Propagate the migration status after the restart.


**Verification:** confirmed → P2

**Verification notes:**

Verdict: confirmed. P2 is correct, not P1: per the STOP report, router connectivity and DNS keep working, LKG and config are intact, and a manual `/etc/init.d/forkop start` or reboot recovers. It is still a broken major workflow, since any upgrade during a mirror outage leaves policy routing silently off.

Line-reference corrections:
- The failure is mirror-migration.sh:137-142, reached from the call at :168, plus the APK key fetch at :185-190. It is not the :160-190 range as a whole; :160-166 is update_package_index, which is skipped when FORKOP_PACKAGE_POSTINST=1.
- The prerm code is service/package.uc:183-194. The handoff write is at :177-178 and the restart consumer at :221-233.
- The IPK postinst lines are build.sh:297-303.

Correction to the proposed fix: do NOT "propagate the migration status after the restart". A non-zero package-script exit breaks the in-UI updater even after package_postinst has run:
- APK: apk returns 1 (hardware apk_rc=1), and action.uc:2406-2407 calls action_fail without restarting. The updater stopped Forkop itself (action.uc:2395 → 2286), so prerm wrote no handoff file and package_postinst will not start it either. Forkop stays down.
- OPKG (static reading, not run): the backend is left unconfigured. install_forkop_opkg_set (:2187-2208) goes to recover_forkop_opkg_set, which reinstalls the previous release. That release's postinst has the same chain, according to the STOP report "Origin" note, so it fails again with "rollback failed; recovery archives retained" and a pending marker is left behind.

Minimal fix:
- In build.sh:300-302 / :438 / :461 and forkop/Makefile:55-57, keep migrate fatal.
- Make the mirror step non-fatal to the script's exit status, e.g. `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || logger -t forkop "[warn] mirror migration failed; feeds unchanged, will retry on next upgrade"`, then `/usr/bin/forkop package_postinst`, with the script's status coming from migrate/package_postinst only.
- For the APK ucode wrappers, split into two system() calls: `if (system(migrate) != 0) exit(1); system(mirror || logger ...); exit(system(package_postinst));`.
- This is safe because the script rolls back feeds and keys on failure, never records applied_migrations on failure, and retries on the next upgrade.
- Keep the literal `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh`. tests/package_contract.sh:150-153 greps it in the Makefile and requires exactly 3 occurrences in build.sh.
- Leave tests/mirror_migration.sh:368-380 (non-zero script exit) unchanged.

Contributing factor, record only: mirror-migration.sh makes network calls on every upgrade, even when mirror_infotechtg_ru_v1 is already in applied_migrations. The default config marks it applied (package_contract.sh:144), and the router baseline had it too. So the dependence on mirror availability is permanent, not limited to the first migration. The re-run appears intentional for key rotation (tests/mirror_migration.sh key-rotation block), so skipping it when already applied would be a product decision and is not part of the minimal fix.

Tests to add:
- tests/package_lifecycle.sh: run the generated postinst / post-upgrade with a mirror stub exiting 1. Assert that package_postinst is invoked, the script exits 0, and a pre-existing handoff file leads to an init start.
- A negative case: a migrate failure still exits non-zero and skips package_postinst.

product_decision=false. hardware_required=false.


### Also reported as persistence#3 (P2): [Known HW item, root cause confirmed] Package upgrade leaves Forkop stopped when migration or mirror-migration fails

**Evidence:** build.sh:300-302, :438 and :461, and forkop/Makefile:55-57: `migration.uc migrate || exit $?` / `mirror-migration.sh || exit $?` / `forkop package_postinst` (apk: `... migrate && mirror-migration.sh && forkop package_postinst`). prerm has already stopped the service and written /tmp/forkop-package-was-running (service/package.uc:178,187-189). mirror-migration.sh:131-145 check_platform_index returns 1 when the default mirror index is unreachable ('package feeds were not changed'); with `set -eu` the top-level call at :168 exits 1, so package_postinst (the only consumer of the marker, package.uc:224-229) never runs.


**Proposed fix:** Always run `forkop package_postinst` and propagate the first failure, e.g. `migrate; m=$?; FORKOP_PACKAGE_POSTINST=1 mirror-migration.sh; mm=$?; /usr/bin/forkop package_postinst; p=$?; [ $m -ne 0 ] && exit $m; [ $mm -ne 0 ] && exit $mm; exit $p`. Apply the same in the apk ucode wrappers.


**Verification:** confirmed → P2

**Verification notes:**

Line reference corrections:
- The module lives at forkop/files/usr/lib/service/package.uc and is installed as /usr/lib/forkop/service/package.uc.
- The marker is written at :177-178 and the service stopped at :188-189. The marker is consumed at :221-233; the finding cited :224-229.

The trigger is wider than "mirror unreachable". Because mirror-migration.sh re-runs its readiness gate on every upgrade, even after the migration was applied, Forkop is also left stopped when:
- the mirror is reachable but does not list the platform (:156-157) — this happens on every upgrade until the mirror syncs;
- the apk key fetch fails (:185-190);
- a custom mirror URL is invalid (:35);
- a feed URL cannot be rewritten (:103-105);
- a uci commit fails.

Impact per path:
- Direct `opkg install/upgrade` or `apk add/upgrade` (incl. ops/mirror/router-bootstrap.sh) hits the prerm-marker path shown in the repro.
- The LuCI updater on apk is also affected, but through a different mechanism: the UI stops Forkop itself before apk, so no marker is written, and action_fail never restarts.
- install.sh is mitigated by its pre-check and restore_current_forkop_on_failure.

Severity stays P2. It breaks the upgrade workflow and leaves routing direct and Forkop down until reboot or a manual start, but prerm tears down cleanly (dnsmasq restored), so the router is not broken.

Disagreement with the proposed fix: do NOT restart after a failed `migration.uc migrate`. migrate_runtime (config/migration.uc:1642-1657) commits nothing on failure, so the new backend would run on an unmigrated config. Keeping `migrate || exit $?` is the fail-closed behaviour (invariants 17/18). Only the network-dependent mirror step should be decoupled.

Also, "run package_postinst but still exit with the mirror status" is incomplete:
- The LuCI apk updater would still see apk fail, call action_fail, and not restart; there is no marker in that path.
- The LuCI opkg updater would still roll back to the previous release because of a mirror hiccup.

Better minimal fix (ipk/Makefile; the same logic goes in both apk ucode wrappers as separate system() calls):
`migrate || exit $?; ms=0; FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || ms=$?; /usr/bin/forkop package_postinst || exit $?; [ $ms -eq 0 ] || logger -t forkop "[warn] package mirror migration deferred (status $ms); package feeds unchanged"; exit 0`
The mirror script is transactional and restores the feeds on failure, so a warning-only result is safe. Returning non-zero instead is a product decision, and it needs matching action.uc handling: in action_fail, restart when forkop_was_running and the Forkop install path stopped it.
- Keep exactly 3 occurrences of the `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh` string in build.sh (package_contract.sh:152).
- Add a lifecycle test that runs the extracted postinst with a failing curl stub and asserts that init start runs and the marker is consumed.
- Optional hardening: skip the readiness gate when mirror_infotechtg_ru_v1 is already applied and the feeds already point at the mirror.


### Also reported as quality#6 (P2): [Known hardware P2 - root cause confirmed] Package upgrade leaves Forkop stopped when the mirror is unreachable

**Evidence:** build.sh:438 and :461 (apk post-install/post-upgrade): `exit(system("... migration.uc migrate && FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh && /usr/bin/forkop package_postinst"))`. build.sh:301-302 and forkop/Makefile:56-57 (ipk): `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || exit $?` placed before `/usr/bin/forkop package_postinst`. mirror-migration.sh:2 `set -eu`. check_platform_index (137-145) returns 1 for the default mirror when the index download fails, and is called unguarded at :170. In the apk branch the key download at :185-190 is also fatal. The service was already stopped by prerm (build.sh:454 `package_prerm upgrade`, Makefile:46).


**Proposed fix:** Run package_postinst regardless of the mirror-migration result and log a warning instead. For example: `FORKOP_PACKAGE_POSTINST=1 mirror-migration.sh || logger -t forkop "[warn] mirror migration failed; package feeds unchanged"; /usr/bin/forkop package_postinst` in all four scripts (build.sh ipk/apk, Makefile). mirror-migration already rolls back feeds on failure. Whether a failing migration.uc should also stop the start is a separate product decision.


**Verification:** confirmed → P2

**Verification notes:**

Line corrections:
- check_platform_index is called at mirror-migration.sh:168, not :170. Line 169 is `TRANSACTION_ACTIVE=1`.
- The failing returns are at :140-142 (index unavailable, default mirror only) and :156-157 (platform row missing, any mirror).

The trigger is wider than "mirror unreachable":
- If the mirror is reachable but its forkop-platforms.tsv has no row for this router's exact target/arch/release/format, every upgrade leaves Forkop stopped. Example: the router is on an OpenWrt point release the mirror has not synced yet.
- apk with an unreachable custom mirror fails at the key fetch (:185-186).
- opkg with a custom mirror is not affected, because a missing index returns 0 for non-default mirrors (:144).

Affected entry points:
1. Plain `opkg upgrade` / `apk upgrade`, CLI or LuCI Software page: confirmed by the reproduction.
2. In-app update, Settings -> Components -> Forkop. It downloads from GitHub, not the mirror, so the mirror can be down while the download works.
   - apk: `apk add` returns an error from the failed post-upgrade script. action.uc:2402-2403 then calls action_fail "Failed to install Forkop release packages" before the restart fallback at :2419-2429. The new files are installed, the service is stopped, and the UI reports a failed install. That is a misleading outcome on top of the outage.
   - opkg: install_forkop_opkg_set (action.uc:2186-2208) sees the backend install fail and calls recover_forkop_opkg_set. That reinstalls the previous release, whose postinst has had the same chain since 1.0.0 (commit a1ba4756), so the rollback probably fails the same way and returns "rollback failed; recovery archives retained" without a restart. This opkg path is static reasoning only, medium confidence.
3. install.sh is mostly protected. check_mirror_platform_support (install.sh:1880-1908) fails early for the default mirror before anything is installed. Only a narrow window remains where the mirror goes down between that check and postinst.

Severity stays P2, not P1. prerm stops the service cleanly: init stop removes the rules and restore_dnsmasq restores DNS. The router keeps plain connectivity, but Forkop routing/DPI stays off until a manual start or a reboot, and the upgrade workflow is broken. No persistent state is corrupted: mirror-migration rolls back feeds and keys, and applied_migrations is written only on success.

The proposed fix is correct and minimal. It keeps the exact string `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh` three times in build.sh, as tests/package_contract.sh:152 requires. The exit status of package_postinst should still decide the postinst exit status.
- ipk (build.sh:301, Makefile:56): `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || logger -t forkop "[warn] Mirror migration failed; package feeds unchanged"`, followed by the existing `/usr/bin/forkop package_postinst` line.
- apk ucode (build.sh:438, :461): `... migration.uc migrate && { FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || logger -t forkop '...'; } && /usr/bin/forkop package_postinst`
- Do not propagate the mirror failure as a non-zero postinst exit. Otherwise the apk in-app updater still reports failure (action.uc:2402).

Swallowing the mirror failure weakens no invariant. Feed migration is not a runtime-safety gate, it rolls back on its own, and it simply retries on the next upgrade because nothing marks it as done.

Should a failing migration.uc also skip the start? That stays a separate product decision, and invariant 18 argues for keeping it fatal.

Suggested regression test: reuse repro.sh. Extract the three build.sh chains and the Makefile chain, stub mirror-migration to exit 1, and assert the package_postinst stub is still called. Also cover the platform-missing case.


### Also reported as process-locks#5 (P2): KNOWN (hardware report P2): package upgrade leaves Forkop stopped when the mirror migration fails

**Evidence:** forkop/Makefile:55-57 and build.sh:300-302 (and the apk scripts at 438, 461): `ucode ... migration.uc migrate || exit $$?` / `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || exit $$?` / `/usr/bin/forkop package_postinst`. mirror-migration.sh:185-190 exits 1 when the mirror key cannot be fetched. The prerm path (Makefile:45-49 -> service/package.uc:183-194) has already run `INIT_PATH stop` and recorded /tmp/forkop-package-was-running, which only postinst_restore (221-234) consumes.


**Proposed fix:** Always run `forkop package_postinst` (the service restore) after prerm stopped the service, even if mirror migration fails. Record the migration failure (status/log) and propagate a non-zero exit only after the service is restored. Keep migrate failure fatal only when the config is unusable.


**Verification:** confirmed → P2

**Verification notes:**

Corrections to the finding:
1. Wrong failure point. With the default mirror (mirror.infotechtg.ru), the script fails at check_platform_index (mirror-migration.sh:137-143, called at :168) for both apk and opkg, not at the key fetch. The key fetch (185-186) fails only for apk with a custom mirror, and it exits with curl's code via `set -e` (line 2). Lines 187-190 fire only when the downloaded key body is invalid. opkg with an unreachable custom mirror succeeds.
2. Wider trigger. A reachable mirror that does not list the router's target/arch/release (156-157) also aborts postinst on every upgrade.
3. The migration is not gated on applied_migrations (217-220 only de-duplicate), so every upgrade depends on the network, even on routers that are already migrated.
4. Correct references: build.sh:297-303 (ipk postinst), 435-440 and 458-463 (apk scripts), forkop/Makefile:51-58.

Related variant, static evidence only (not reproduced; confirming it needs apk exit-code semantics on a real device). The in-UI self-update in components/action.uc does not rely on prerm/postinst to restart Forkop:
- install_forkop calls stop_old_sing_box_before_forkop_upgrade (:2395), which stops Forkop unconditionally (:2285-2286). Prerm therefore records "not running" and package_postinst never starts it.
- The restart happens only on the success path (:2426-2429).
- On any failure, action_fail runs restart_forkop_after_failed_sing_box_change (:308-314). That is a no-op here, because forkop_stopped_for_sing_box_change is set only in stop_forkop_before_sing_box_change (:939-951), which install_forkop never calls.
- Consequences:
  - (a) If a fixed postinst restores the service but still exits non-zero, the UI apk path still leaves Forkop stopped: apk fails, action_fail runs, and nothing restarts.
  - (b) Adjacent defect for a separate finding: opkg pre-mutation refusals in install_forkop_opkg_set (:2135-2182, e.g. "Previous Forkop release packages are unavailable") and the refusal at :2395-2396 also leave a previously running Forkop stopped even though nothing was changed.

Better minimal fix, in all four chains:
- Keep `migration.uc migrate` fatal. Its failure may leave the config unusable, and failing closed is correct.
- Treat mirror-migration.sh as non-fatal: `ms=0; FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || ms=$?`.
- Always run `/usr/bin/forkop package_postinst || exit $?`.
- If ms != 0, log a warning (`logger -t forkop`) and exit 0.

Exiting 0 avoids apk/opkg marking the package's scripts as broken or half-configured, and it lets the UI success path restart Forkop. mirror-migration already rolls back feeds and keys on failure, so starting Forkop afterwards is safe. It is optionally better to run package_postinst before the mirror step: downtime is then not extended by curl timeouts (15s connect / 60s max per fetch), and the restored runtime is available to the migration.

Separately, have install_forkop remember that it stopped Forkop so that action_fail restarts it when forkop_was_running.

Test: extend package_lifecycle.sh along the lines of repro.sh. Extract the chains from build.sh and the Makefile, use a failing curl stub and an existing PACKAGE_UPGRADE_STATE, and assert init start and consumption of the state file.

Severity stays P2: a major workflow is broken and the service is not restored, but there is no data or secret loss. product_decision=false for restoring the service. Whether a mirror failure should still surface as a package error is a minor product choice.


### Also reported as uci-global#1 (P2): KNOWN HW P2 (root cause + wider trigger): postinst chain stops before package_postinst when mirror-migration.sh fails, including when the mirror is reachable but the platform is unlisted

**Evidence:** build.sh:300-301 (ipk postinst) `migration.uc migrate || exit $?` / `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || exit $?` before `/usr/bin/forkop package_postinst`. build.sh:438 and 461 (apk post-install/post-upgrade) chain `... migrate && ... mirror-migration.sh && /usr/bin/forkop package_postinst`. forkop/Makefile:55-56 same. mirror-migration.sh runs under `set -eu`, and check_platform_index returns 1 both for an unreachable default mirror ('The mirror platform index is unavailable') and for a reachable index without the router's target/arch/release/format row ('The Forkop mirror does not yet contain ...'). The prerm (build.sh backend-pre-upgrade `forkop package_prerm upgrade`) has already stopped the service.


**Proposed fix:** Decouple feed rewriting from service recovery. In postinst, run migration.uc migrate (keep failing on error only if the config is unusable), run mirror-migration.sh as best-effort (`|| logger -t forkop 'mirror migration skipped: ...'`), and always run /usr/bin/forkop package_postinst (it validates the config and fails closed on its own). Optionally make check_platform_index non-fatal when FORKOP_PACKAGE_POSTINST=1: it already rolls back, so exit 0 with a warning.


**Verification:** confirmed → P2

**Verification notes:**

Verdict: confirmed. Severity stays P2 and is not P1: config, LKG and snapshots are unchanged, feeds are rolled back, dnsmasq is restored so the router keeps connectivity, and the service stays enabled so it comes back after a reboot. But proxy/DPI routing is silently down until someone starts it manually. The mirror-down trigger is the known hardware item.

Line-ref corrections:
- The ipk postinst is build.sh:297-303.
- The apk scripts are build.sh:435-440 (post-install) and 458-463 (post-upgrade).
- forkop/Makefile:51-58.

Wider triggers the finding missed:
1. APK with a custom mirror_base_url that is unreachable: mirror-migration.sh:185-186 key download under set -e exits 28.
2. Release lag: check_platform_index matches the exact DISTRIB_RELEASE, so the first upgrade after the router moves to an OpenWrt point release the index does not list yet stops the chain.
3. The check runs on every upgrade even after mirror_infotechtg_ru_v1 is applied.

Correction on the unlisted-platform trigger: install.sh:1909 refuses unlisted platforms at first install, so this applies to platforms that later leave the index (or have not yet been added for the new release), not to arbitrary unlisted routers installed via install.sh.

Wider impact paths:
- UI self-update on APK: action.uc stops Forkop before `apk add`, so prerm writes no marker. apk then returns 1 and action_fail does not restart (restart only when forkop_stopped_for_sing_box_change). Forkop stays stopped and the UI reports "Failed to install" although the new packages are installed.
- UI self-update on OPKG (static, lower confidence): the backend postinst failure triggers recover_forkop_opkg_set. The previous release's postinst has the same chain (1.0.26-5 per the hardware report), so the rollback likely fails too. The recovery marker is retained, and later installs retry the same failing recovery.

Better minimal fix, same direction as the finding but precise:
- ipk postinst and Makefile: keep `migrate || exit $?` (fail closed on config migration). Replace the mirror line with `FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh || logger -s -t forkop "Package mirror migration skipped (status $?); package feeds were left unchanged"`, then `/usr/bin/forkop package_postinst` as the script's final status.
- apk ucode scripts: `let rc = system("...migrate"); if (rc != 0) exit(rc); if (system("FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh") != 0) system("logger -s -t forkop '...skipped...'"); exit(system("/usr/bin/forkop package_postinst"));`.
- The mirror failure must NOT propagate into the script's exit status. If the chain runs package_postinst but still returns the mirror's non-zero status, apk still returns 1 and the UI APK path (marker absent, no restart in action_fail) keeps Forkop stopped.
- Keep the literal string 'FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh' (package_contract.sh:150-153 counts it, expecting exactly 3 in build.sh).
- Prefer the chain-level fix over making check_platform_index non-fatal under FORKOP_PACKAGE_POSTINST=1: it also covers the key-download and uci-commit failure modes and keeps the standalone contract pinned by tests/mirror_migration.sh.
- Optional defence in depth: in action.uc install_forkop, restart Forkop in the failure path when forkop_was_running and packages are at the new version.

Tests to add:
- A behavioural test that extracts the generated postinst/post-upgrade from build.sh (as in repro.sh) and asserts that package_postinst runs and exit=0 when mirror-migration exits 1 (unlisted, down, APK key fetch failure).
- A test that a migrate failure still exits non-zero.

A migrate failure still leaves the service stopped silently. That is fail-closed per invariant 18, but surfacing it (needs_attention) is a separate decision. Invariants are not weakened: mirror-migration already rolls back feeds and keys on failure, and package_postinst validates the config before any start.


---

<a id="uc-027"></a>

## UC-027 · P2 · S6 — Установка/обновление Forkop из интерфейса останавливает службу до проверок и оставляет её остановленной при отказе или ошибке

**Severity:** P2<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** components/action.uc self-update<br>
**Sources:** packaging#1<br>
**Original title:** In-app Forkop install/upgrade stops Forkop first and leaves it stopped when the action later fails or is refused (even with no package change)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** action.uc:2395-2396 `if (!stop_old_sing_box_before_forkop_upgrade()) action_fail(...)`; that function first calls `upgrade_bounded_stop(SERVICE_INIT)` (:2285-2286). The opkg branch then calls install_forkop_opkg_set (:2410-2412), whose pre-mutation refusals return before any opkg install: :2138 "Installed Forkop package versions are inconsistent", :2140-2142 `previous_forkop_release(FORKOP_VERSION)` (GitHub API only, :2036-2045, now fetched directly because the service proxy is gone, :561-568) -> "Previous Forkop release packages are unavailable; automatic upgrade refused", :2157-2161 previous-package download failure, :2170-2173 --noaction preflight failure. The APK branch :2406-2407 fails on any `apk add` error. action_fail (:322-328) only calls restart_forkop_after_failed_sing_box_change(), which returns unless forkop_stopped_for_sing_box_change (:309). Scratch repro (scratch/audit-a26/refused_upgrade.sh, which extracts the production functions) prints `{"success":false,"message":"Previous Forkop release packages are unavailable; automatic upgrade refused","service_running":false}`.


**Reproduction:** OpenWrt 24.10 with Forkop running and api.github.com unreachable directly (or an installed version without a GitHub release): LuCI -> Updates -> Install Forkop -> job fails with 'automatic upgrade refused'; `forkop get_status` shows running:0.


**Expected:** A refused or failed upgrade leaves the service in its pre-action state (running if it was running), matching install.sh's restore_current_forkop_on_failure and the opkg recovery path.


**Actual:** Forkop is stopped before the preconditions are checked; a refusal or package-manager error ends the job without restarting it.


**Impact:** Clicking Update/Install on a running router can end with "refused"/"failed" and Forkop silently stopped (proxy routing and DPI off) although nothing was installed. Likely triggers on OpenWrt 24.10: GitHub API or release-asset download unreachable once the proxy is stopped, API rate limit, a mixed package set, --noaction failure (space/deps), any x.y.z-N or dev build (previous_forkop_release rejects the version). On APK: any apk add failure, including the known mirror post-upgrade failure.


**Root cause:** The service is stopped too early in install_forkop, and the shared action_fail cleanup only knows how to recover from sing-box component changes.


**Affected files:** `forkop/files/usr/lib/components/action.uc`

**Dependencies:** Complements the known P2 fix for the APK path.


**Proposed fix:** Minimal: add `let forkop_stopped_for_upgrade = false;`, set it right before stop_old_sing_box_before_forkop_upgrade(). In action_fail, when forkop_stopped_for_upgrade && forkop_was_running && !forkop_status_running_with_timeout(), run `SERVICE_INIT start` with the same fallback as restart_forkop_after_failed_sing_box_change. Better for opkg: move the version-consistency check, previous_forkop_release, previous-package download and both --noaction preflights before the stop (they need no stopped service), so refusals happen while Forkop still runs and the proxy is still available for GitHub.


**Tests needed:** Extend tests/forkop_opkg_set.sh or a new probe that runs install_forkop with stubs: previous_forkop_release -> null, inconsistent versions, --noaction failure, apk add failure; assert the service ends running when forkop_was_running and stays stopped when it was not; assert no double start on the opkg recovery path.


**Risk:** Low; restarting is already the documented behaviour of the success path (:2426-2429). Avoid starting when the opkg recovery already restored the service (check status first).


**Verification:** confirmed → P2

**Verification evidence:**

Cited code checked in the audit tree (07872084), forkop/files/usr/lib/components/action.uc. All line references are accurate.
- The order is: component_action:2597 calls capture_forkop_running_state(), then install_forkop:2395 `if (!stop_old_sing_box_before_forkop_upgrade())`. That function runs `upgrade_bounded_stop(SERVICE_INIT)` unconditionally at :2285-2286 and returns true only once no sing-box process is left (:2291, :2312).
- The refusals that come before any mutation all run after that stop, inside install_forkop_opkg_set:
  - :2136 pending recovery
  - :2138 "Installed Forkop package versions are inconsistent"
  - :2140-2142 `previous_forkop_release(FORKOP_VERSION)`, then "Previous Forkop release packages are unavailable; automatic upgrade refused"
  - :2145-2153 staging directory errors
  - :2157-2161 "Failed to stage previous Forkop release packages"
  - :2170-2173 "Forkop package-set preflight failed"
  - :2175-2182 marker write
- The APK branch fails at :2406-2407. The stop function's own refusal at :2396 ("Old sing-box processes have ambiguous ownership or did not stop") also comes after the Forkop stop at :2286.
- action_fail (:322-328) only calls restart_forkop_after_failed_sing_box_change. That returns at :309 `if (!forkop_stopped_for_sing_box_change || ...) return;`. This flag is set only by stop_forkop_before_sing_box_change (:942), which the forkop install path never calls.
- Nothing above action.uc restarts the service. The worker (updates.uc:2575-2590, finish_component_job :2527-2548) only records the JSON. The UI updates flow has no automatic start.
- No test pins the current behaviour:
  - tests/forkop_opkg_set.sh calls install_forkop_opkg_set on its own, starting with service_running=true, so it never sees the earlier stop.
  - tests/forkop_recovery_boundary.sh replaces install_forkop with a stub.
- The proxy really is gone at :2140. service_proxy_address (:561-568) returns "" unless the sing-box service is running, and stop_old_sing_box_before_forkop_upgrade only succeeds with zero sing-box processes left. So previous_forkop_release has to reach GitHub directly.
- previous_forkop_release (:2043) always uses api.github.com. Its absolute github.com browser_download_url values pass through forkop_release_url (:679) unchanged. The forward packages, by contrast, come from the mirror FORKOP_RELEASE_BASE_URL=https://fold8.ru/forkop (:14, :661-669), and they are downloaded before the stop. A router that reaches the mirror but not GitHub directly therefore has every opkg in-app upgrade refused, and Forkop is left stopped each time.
- Expected behaviour exists in install.sh: restore_current_forkop_on_failure at install.sh:2151-2161 restores the previous service state after a failure.


**Verification reproduction:**

I ran the real production entry point `ucode -L <lib> components/action.uc component-action forkop install` end to end, not an extraction.
- Isolation: a private user and mount namespace (`unshare -r -m`) with a tmpfs on /tmp, so action.uc's fixed /tmp paths never touch the shared WSL /tmp. No network is used.
- Stubs: curl serves a local "mirror.test" and fails for GitHub unless GITHUB_OK is set. opkg and apk stubs keep installed versions in a file. /etc/init.d/forkop is a stub that records calls and flips the running state. The forkop get_status stub reads that state. ubus and logger are stubbed.
- Environment overrides: FORKOP_SERVICE_INIT, FORKOP_BIN, FORKOP_VERSION=1.0.0, FORKOP_RELEASE_BASE_URL, FORKOP_OPKG_RECOVERY_DIR, FORKOP_RUNTIME_STATE_DIR.
- Scripts: scratch/audit-verify-upgrade-stop/{run.sh, scenario.sh, stub_*.sh}.

Results:
- **A.** opkg, Forkop running, GitHub unreachable. Response `"success": false, "message": "Previous Forkop release packages are unavailable; automatic upgrade refused"`. Service running after the job: 0. Init calls: only `stop`. No package-manager mutations; versions unchanged at 1.0.0-r1. The api.github.com request was made with no proxy (`proxy=`).
- **B.** opkg, running, GitHub OK, `opkg --noaction` fails. "Forkop package-set preflight failed; automatic upgrade refused". Running: 0. Init calls: `stop`. No mutation.
- **C.** Control, full success. "Forkop has been installed". Running: 1. Init calls: `stop start`. So the success path does restore the service.
- **D.** Control, not running before. Refused; stays 0, which is correct.
- **E.** APK, running, `apk add` fails. "Failed to install Forkop release packages". Running: 0. Init calls: `stop`.

A and B show the claimed failure: nothing was installed, yet Forkop ends stopped, and the message does not mention the stop. The packaging auditor's extraction repro (audit-a26/refused_upgrade.sh) replaced the stop function with a stub; my run exercises the real one.


**Verification notes:**

Corrections and precision:
1. **Trigger list.**
   - The "x.y.z-N or dev build" trigger is mostly unrealistic. forkop/Makefile:11 refuses any FORKOP_VERSION that is not x.y.z, so a built package always passes the regex at :2037.
   - One trigger is missing: the refusal at :2396 itself. A sing-box not owned by procd, such as one the user runs, or a procd sing-box that takes more than about 17s to exit, causes a refusal after Forkop is already stopped at :2286.
   - The most practical trigger is not rate limiting but an asymmetry. Forward packages come from the mirror, but rollback metadata and assets come only from GitHub, and that fetch happens after the proxy is torn down.
2. **Impact wording.** "Silently" is slightly strong: the Overview shows the service as stopped. But the job's failure message never says Forkop was stopped, and nothing restarts it until a reboot or a manual Start. The router network stays up (traffic goes direct), so this is P2, not P1.
3. **Refinement to the minimal fix.**
   - Add a module flag, e.g. `forkop_stopped_for_upgrade`, set just before stop_old_sing_box_before_forkop_upgrade(). action_fail should start the service only when all of these hold:
     - the flag is set
     - forkop_was_running
     - `!file_exists(FORKOP_OPKG_RECOVERY_DIR + "/pending")`
     - `!forkop_status_running_with_timeout()`
   - The pending check matters. After a failed opkg rollback ("rollback failed; recovery archives retained", :2127-2128) the package set may be mixed. That design deliberately requires a fresh component action, which then restores the service through restore_forkop_opkg_service. After a successful rollback, finish_forkop_opkg_recovery has already restored the service, and the status check prevents a double start.
   - Use `SERVICE_INIT start`, falling back to `restart`, the same way restart_forkop_after_failed_sing_box_change does.
4. **The "better" reorder alone is not enough.** Moving the opkg preconditions (version consistency, previous_forkop_release, staging download, both --noaction preflights) before the stop is worthwhile. Refusals then happen while the proxy still works, and they need no stopped service. The staging directory without a marker is already treated as pre-mutation (:2144-2146). But the reorder does not cover :2396 or the APK branch, so the flag-based restore is needed either way.
5. **Tests to add.** A probe around install_forkop, or the real entry point as in my scenario.sh, with these cases:
   - previous release null → running restored
   - --noaction failure → restored
   - :2396 refusal → restored
   - apk add failure → restored
   - was-stopped → stays stopped
   - pending-marker rollback failure → not started
   - successful rollback → exactly one start

Separate defect found while reproducing (not part of this finding; please file on its own; P2, confirmed):
- **Where:** resolve_forkop_release_json, action.uc:2009-2012: `let plan = trim(helper_output_input(...)); let fields = split(plan, "\t"); if (length(fields) < 7 ...) return null;`.
- **Cause:** when luci-i18n-forkop-ru is not installed, i18n_required is "0". The helper forkop-release-plan (updater.uc:237-262) then prints the line with two empty trailing fields ("...\t\t\n"). ucode trim() strips the trailing tabs, leaving 5 fields, so the function returns null. I checked this with `ucode -e`: trim of such a string splits into 5.
- **Effect:** every in-app Forkop update on a router without the Russian language pack fails with "Failed to resolve Forkop release packages" (:2373). Scenario F reproduces this with the real code. The failure happens before the stop, so the service keeps running.
- **Coverage:** tests/components_updater_job.sh:333 tests only the helper output, not this parsing.
- **Minimal fix:** strip only the trailing newline, e.g. `replace(plan, /\n+$/, "")`, instead of trim().


---

<a id="uc-028"></a>

## UC-028 · P2 · S6 — Удаление пакета и полное удаление игнорируют отказ остановки и оставляют ForkopTable, ip rule 105 и cron

**Severity:** P2<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** remove / full uninstall<br>
**Sources:** packaging#3, nft#5<br>
**Original title:** Package removal and Full uninstall ignore a refused Forkop stop and remove the packages anyway, leaving the nft/ip policy and cron behind<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** lifecycle.uc:1066-1069 `if (module_success(STATE_UC, [ "sing-box-process-conflict" ])) { log_message("Refusing Forkop stop: ...preserving the existing runtime", "fatal"); return 1; }` returns before remove_cron_jobs (:1076), `nft delete table inet ForkopTable` and ip rule/route cleanup. package.uc:189 `command_success_from_args([ INIT_PATH, "stop" ]);` result ignored; build.sh:305-312/442-449 prerm/pre-deinstall always `exit(0)`. OpenWrt 24.10 rc.common procd `stop(){ procd_lock; stop_service; procd_kill ...; if eval "type service_stopped" ...; then service_stopped; fi }` returns 0 because Forkop defines no service_stopped, so full-uninstall.sh:79-81 (`"$ROOT/etc/init.d/forkop" stop` under set -eu) cannot see the refusal and continues to apk del/opkg remove and PHASE=complete.


**Reproduction:** Start an extra `sing-box run` process outside procd, then run Full uninstall from LuCI: the job completes; `nft list table inet ForkopTable` still succeeds and `ip rule` still shows the fwmark rule for table 105.


**Expected:** The destructive uninstall fails closed (nothing removed, state 'failed' with a reason) when Forkop's runtime could not be torn down.


**Actual:** Removal proceeds and reports success after a refused stop.


**Impact:** If sing-box ownership is ambiguous at removal time (a foreign sing-box process, or procd briefly reporting an old PID, which lifecycle.uc:1060-1065 explicitly expects), the uninstall reports "complete". ForkopTable TPROXY/mark rules and the table-105 ip rules stay active with no Forkop binary left to remove them. Traffic for routed destinations is diverted to a sing-box port that the removed or foreign sing-box may not serve until reboot. Cron lines calling the missing /usr/bin/forkop also remain.


**Root cause:** The stop result is not observable through rc.common and is never re-verified before the destructive phases.


**Affected files:** `forkop/files/usr/lib/full-uninstall.sh`, `forkop/files/usr/lib/service/package.uc`, `forkop/Makefile`, `build.sh`

**Dependencies:** None


**Proposed fix:** In full-uninstall.sh stop phase, after `/etc/init.d/forkop stop`, verify teardown and fail closed before the repositories/packages phases, e.g. `if nft list table inet ForkopTable >/dev/null 2>&1; then echo 'Forkop runtime is still active (sing-box ownership ambiguous); stop it and retry' >&2; return 1; fi` (plus the ip rule check). In package.uc prerm_cleanup for action "remove", log loudly when the table is still present; optionally still remove the Forkop cron lines, which is harmless.


**Tests needed:** tests/full_uninstall_cleanup.sh: fake init stop that leaves a marker for an existing ForkopTable (fake nft returning 0 for `list table inet ForkopTable`); assert state failed at phase stop, packages not removed, feeds untouched.


**Risk:** Low: adds a precondition check; the user can retry after resolving the conflict or rebooting.


**Verification:** confirmed → P2

**Verification evidence:**

Checked every link in the chain against tree 07872084:
- lifecycle.uc:1066-1069: stop_main() returns 1 on `module_success(STATE_UC, [ "sing-box-process-conflict" ])` before remove_cron_jobs() (:1076), ZAPRET/ZAPRET2/BYEDPI stop-runtime (:1083-1085), remove-dpi-transition-guard (:1086), `nft delete table inet ForkopTable` (:1088-1089), and the ip rule del / route flush for table 105 (:1091-1099). stop_impl() (:1459-1488) passes the 1 back up. initd.uc stop_service (:656-668) returns it through stop_finish, and `exit(stop_service(ARGV[1]))` (:847-848) makes it the exit status of `initd_ucode stop-service`.
- init.d/forkop defines stop_service() and service_started(), but not service_stopped(). OpenWrt 24.10 procd-mode rc.common (fetched from openwrt-24.10 package/base-files/files/etc/rc.common) has `stop() { procd_lock; stop_service "$@"; procd_kill ...; if eval "type service_stopped" ...; then service_stopped; fi }` and ends with `$action "$@"`. Because the `if` is false it returns 0, so `/etc/init.d/forkop stop` exits 0 even when stop_service returned 1. The project already works around the same rc.common behaviour for start: tests/service_start_trap.sh:106-109 pins `FORKOP_LAST_START_STATUS` plus the `service_started()` hook. No equivalent exists for stop.
- full-uninstall.sh:79-81 runs `"$ROOT/etc/init.d/forkop" stop` under `set -eu`. It then runs disable, `$BIN dnsmasq_restore` and the sing-box init stop/disable, restores the feeds (:89-96), removes the packages (:98-110), deletes /usr/lib/forkop and /usr/bin/forkop (:112-140) and writes state complete (:141-142). Nothing re-checks the nft or ip rule state.
- package.uc:183-193 prerm_cleanup: `command_success_from_args([ INIT_PATH, "stop" ]);` ignores the result, then runs restore_dnsmasq_if_needed, remove_managed_sing_box and remove_rt_tables_entry. build.sh prerm (~:303-310) and backend-pre-deinstall (~:442-448), and forkop/Makefile:42-49, all use system(... >/dev/null 2>&1) and then exit(0).
- No gate elsewhere: the dispatcher's full-uninstall lock gate (bin/forkop:258-265) does not block `stop`, and components/uninstall.uc:5 starts full-uninstall.sh without any precheck.
- The gate fires for real, persistent conditions. state.uc:636-638 reports a conflict when any process's /proc/PID/exe basename is `sing-box` and the procd-owned PID is not the single sing-box (state.uc:463-481, 586-617). A foreign or orphaned sing-box outside procd therefore makes both stops refuse: the full-uninstall stop and the second stop in package prerm.
- Not pinned by tests: tests/full_uninstall_cleanup.sh never creates $ROOT/etc/init.d/forkop, so the stop phase is not exercised. Its stub reads FAIL_STOP but no case sets it. tests/runtime_ownership_gates.sh only pins the gate in stop_main; it says nothing about uninstall.


**Verification reproduction:**

I wrote a scratch script, scratch/audit-verify-uninstall-stop/repro.sh, and ran it in WSL with a private mktemp dir. It runs the real forkop/files/usr/lib/full-uninstall.sh from the audit tree with FORKOP_UNINSTALL_ROOT and an opkg fixture copied from tests/full_uninstall_cleanup.sh. The fake /etc/init.d/forkop has a stop_service that returns 1, as initd.uc does when stop_main refuses. Its stop() is copied verbatim from the procd stop() in openwrt-24.10 rc.common, and the dispatch is `$action "$@"`. Marker files stand in for ForkopTable, the fwmark/table-105 ip rule and the Forkop crontab line.
Case "rc.common (real OpenWrt stop semantics)": final status {"state":"complete","phase":"complete"}. Calls, in order: stop_service refused (exit 1), procd_kill, forkop disable, forkop dnsmasq_restore, sing-box init stop, sing-box init disable, `opkg remove luci-app-forkop forkop sing-box`. No packages remain, /usr/lib/forkop is gone and distfeeds is restored, but the ForkopTable and table-105 ip rule markers and the `/usr/bin/forkop list_update_if_due` crontab line are left behind.
Control case, the same fixture with a stop() that propagates the status: {"state":"failed","phase":"stop"}. Packages, /usr/lib/forkop and the mirror feeds stay untouched. So full-uninstall.sh is written to fail closed on a failed stop, and only rc.common's discarded status defeats it.
I proved the lifecycle layer (stop_main refusing on a sing-box conflict) statically. Reproducing it at runtime needs a real /proc with two sing-box processes and procd/ubus, which means a router, and this audit forbids touching one.


**Verification notes:**

Corrections:
1. The transient trigger ("procd briefly reporting an old PID") mostly heals itself in the full-uninstall path. full-uninstall.sh stops /etc/init.d/sing-box in phase stop. The forkop package prerm then calls init.d stop a second time, now with sing_box_process_count()==0, so stop_main completes teardown. The trigger that actually matters is a persistent foreign or orphaned sing-box (exe basename `sing-box`, outside procd). With the transient trigger the defect remains real only for plain package removal (`apk del forkop` / `opkg remove forkop`), where prerm makes its single stop call and then removes the managed sing-box.
2. Line refs are right. More precisely, the ignored call is package.uc:189 inside prerm_cleanup (:183-193). The build.sh heredocs sit at about :303-310 (prerm) and :442-448 (pre-deinstall); forkop/Makefile:42-49 has the same pattern.
3. Understated leftovers: zapret, zapret2 and byedpi runtimes, the DPI transition guard table, and the DNS-failover and priority runtimes are also never stopped, because they come after the refusal at :1066. DNS itself is safe: stop_impl restores dnsmasq before stop_main, initd stop_finish runs a failsafe restore, and full-uninstall runs `$BIN dnsmasq_restore`.
4. Impact depends on the other process. An orphaned old Forkop sing-box keeps TPROXYing with its in-memory config. An unrelated sing-box usually leaves the TPROXY port unserved, so IP-list and FakeIP-marked flows go to a port nothing listens on. Everything clears on reboot, because nft and ip rules are not persistent and Forkop is gone. It stays P2 rather than P1 for three reasons: the precondition is rare, the state is not persistent, and there is no data loss. It is still a case of invariant 18 (fail closed) not being honoured, and of invariant 5 in spirit, since uninstall reports "complete" while an active policy has no owner.
5. Root cause and variants: rc.common drops stop_service's status because init.d/forkop has no service_stopped hook (compare the existing service_started pattern). The same blind spot affects other callers of `SERVICE_INIT stop`. For example, components/action.uc:945 (the "Stopping Forkop before sing-box package change" run_logged step) goes on to change the sing-box package after a refused stop. action.uc:2077 is mitigated by its own forkop_status_running_with_timeout() re-check.
6. Best minimal fix for this finding is the targeted post-stop verification the finding proposes, with one adjustment. In full-uninstall.sh, right after `/etc/init.d/forkop stop` and before disable, fail if `nft list table inet ForkopTable` succeeds or `ip -4/-6 rule list` still shows the `fwmark ... lookup forkop|105` rule. rt_tables still names it `forkop` at that point. Print a clear message, and finish() will record failed/stop. Do not propagate the full stop status into full-uninstall (for example through a service_stopped hook alone): stop_impl also returns non-zero for dnsmasq-restore or config_commit failures, which would block the user's recovery path for unrelated reasons. A service_stopped hook mirroring FORKOP_LAST_START_STATUS is a worthwhile separate change for the other callers, but it touches every consumer of init.d stop.
7. In package.uc prerm_cleanup for remove, log to syslog (logger -t forkop) when ForkopTable survives the stop. The prerm redirects its own output to /dev/null, so anything not sent to syslog is lost. Cron cleanup there is harmless and can run unconditionally.
8. Test: in tests/full_uninstall_cleanup.sh, add a case with a fake init.d/forkop whose stop leaves an nft stub answering `list table inet ForkopTable` with 0. Assert failed/stop, packages and feeds untouched, and no service-calls after stop. The fixture's unused FAIL_STOP can be removed or wired in.
9. Whether plain package removal should abort or force teardown on a refused stop is a product decision. The full-uninstall fail-closed fix is not.


### Also reported as nft#5 (P3): Package removal and full uninstall ignore a refused stop and leave ForkopTable TPROXY, the DPI guard and ip rule/table 105 behind

**Evidence:** service/package.uc:183-193 prerm_cleanup: `command_success_from_args([ INIT_PATH, "stop" ])` result ignored, then remove_rt_tables_entry(). forkop/Makefile prerm always exit(0). lifecycle.uc:1066-1069 stop_main returns 1 without touching nft when `sing-box-process-conflict`. full-uninstall.sh:80 `"$ROOT/etc/init.d/forkop" stop`: rc.common stop returns procd_kill's status, so the refusal is not seen under set -e. lifecycle.uc:1091-1099 later detection of ip rules and routes relies on the name `lookup forkop`, which prerm has just removed from rt_tables (package.uc:108-124).


**Proposed fix:** Product decision. Option A: on `remove`, if stop failed, delete ForkopTable, ForkopTableDpiGuard and ip rules/routes by table id 105 (not by name) after the sing-box init stop. Option B: make prerm exit non-zero so opkg/apk abort the removal, and have full-uninstall.sh check `forkop` stop status via `/usr/bin/forkop stop` instead of rc.common.


---

<a id="uc-029"></a>

## UC-029 · P2 · S8 — Приоритетное bypass-правило только по портам пропускает FakeIP-адреса без tproxy-метки — трафик теряется

**Severity:** P2<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** routing<br>
**Sources:** routing#0<br>
**Original title:** nft port-only bypass priority rule accepts IPv4 FakeIP destinations without the tproxy mark, so the traffic is black-holed and never reaches sing-box<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:**

nft/apply.uc:646-648 `return section_rule_ports_csv(section) != "" && !section_has_destination_matchers(section);`
nft/apply.uc:668-671: a bypass section with only port matchers gets priority sets.
nft/apply.uc:720-730 builds `ip daddr != @localv4` + match + verdict, with no FakeIP exclusion.
nft/apply.uc:695-699: the bypass verdict is `[ "counter", "accept" ]` (no mark).
nft/apply.uc:833-838 adds the rule to priority_rules and priority_output_rules.
nft/apply.uc:895 `jump priority_rules` runs before the FakeIP mark rules at 908-909.
LOCALV4_RANGES (nft/apply.uc:498-512) does not contain 198.18.0.0/15, while LOCALV6_RANGES contains fc00::/7, so only IPv6 FakeIP is protected, and only by accident.
For comparison, the fully-routed bypass rule already excludes FakeIP: nft/apply.uc:762-763 `append_array(args, [ ip_key, "daddr", "!=", fakeip_range ])`.
tests/nft_apply.sh:348 pins the port-only bypass rule without the exclusion.


**Reproduction:** Code path read end to end. The emitted rule is shown verbatim in tests/nft_apply.sh:348: `priority_rules iifname @forkop_interfaces ip daddr != @localv4 tcp dport @forkop_rule_port_bypass_ports counter accept`.


**Expected:** A FakeIP destination is always delivered to sing-box. The bypass port rule is then applied by sing-box's own rule (bypass-out to the real address) in UCI order, as the generator already emits it (generator.uc:3059-3064).


**Actual:** Config: section 'yt' (zapret, domain_suffix youtube.com) and section 'tv' (bypass, source_ip_cidr 192.168.1.50/32, ports 443). The TV is not in the source-aware DNS set because 'tv' has no domain matchers, so youtube.com resolves to 198.18.x.x. The TV connects to 198.18.x.x:443. mangle jumps to priority_rules, the 'tv' rule `ip saddr @..._sources ip daddr != @localv4 tcp dport @..._ports counter accept` accepts the packet without the mark, the proxy chain does not tproxy it, and the packet is routed to the WAN toward a FakeIP address, so the connection fails. The same happens for a plain port-only bypass rule (for example ports 8443) for all devices.


**Impact:** Every FakeIP-resolved domain (any domain matched by another rule) becomes unreachable on the bypassed ports for the affected devices, or for all devices when the rule has no device filter. This covers LAN clients and router-originated traffic (priority_output_rules). It also silently overrides sing-box first-match order: route_trace and the resolver report the sing-box owner (for example 'Zapret yt') for connections that nft never delivers to sing-box.


**Root cause:** When priority bypass fast-paths were added, the FakeIP exclusion was implemented only for fully_routed_ips bypass rules. The ip/port priority rules rely on `ip daddr != @localv4`, and that set deliberately does not include the IPv4 FakeIP range.


**Affected files:** `forkop/files/usr/lib/nft/apply.uc`, `tests/nft_apply.sh`

**Dependencies:** None


**Proposed fix:** In nft_priority_rule_args (or nft_add_section_priority_rules), when section_priority_action(section) == "bypass", append `ip daddr != <fakeip_range>` for IPv4 and `ip6 daddr != <fakeip6_range>` for IPv6. This mirrors nft_fully_routed_priority_args and applies to both chains. FakeIP traffic then always reaches sing-box, where the section's port-only route rule (bypass-out) is applied in UCI order. Update the nft_apply.sh:348-351 expectations.


**Tests needed:** nft_apply.sh: port-only and ip bypass priority rules contain `ip daddr != 198.18.0.0/15` and `ip6 daddr != fc00::/18`, for both prerouting and output. A hardware check that a FakeIP domain on a bypassed port still opens from a device covered by the bypass rule.


**Risk:** Low. It only narrows what the bypass fast path accepts, and FakeIP destinations are handled in sing-box.


**Verification:** confirmed → P2

**Verification evidence:**

Every cited line in the worktree at 07872084 is accurate.
- nft/apply.uc:646-648: `section_has_nft_port_only_matchers` is `ports != "" && !section_has_destination_matchers`. Lines 668-671 then give such a section priority sets.
- nft/apply.uc:720-730: `nft_priority_rule_args` emits `[ip saddr @sources] ip daddr != @localv4 <match> <verdict>`. Line 697 makes the bypass verdict `[ "counter", "accept" ]`, with no mark.
- nft/apply.uc:833-838: the port-only match lists go into both priority_rules and priority_output_rules.
- nft/apply.uc:895: `jump priority_rules` comes before the FakeIP mark rules at 908-909. The output path is the same: 919 `jump priority_output_rules` comes before 969-970.
- nft/apply.uc:498-512: LOCALV4_RANGES has no 198.18.0.0/15. LOCALV6_RANGES (514-523) has fc00::/7, so IPv6 FakeIP (fc00::/18) is already excluded. Only IPv4 is exposed.
- nft/apply.uc:762-763: only `nft_fully_routed_priority_args` adds `ip daddr != fakeip_range` for bypass (added in commit 81dbe7d3, "Optimize forced bypass routing"). The older port-only path was never updated.

No other layer prevents the failure:
- The TV does not get real-address DNS. `source_aware_dns_sources` (generator.uc:2743-2770) and nft `source_aware_dns_values` (apply.uc:1854-1871) add source IPs only for sections with DNS matchers, or for fully_routed_ips of bypass/dns sections. A port-only rule has neither, so dnsmasq -> sing-box returns FakeIP for any domain captured by another rule (`section_dns_server`, generator.uc:2533-2538).
- Nothing in the backend or UI rejects a port-only rule. The generator supports it explicitly (generator.uc:3059-3064).
- tests/nft_apply.sh:348 pins the rule without the exclusion.


**Verification reproduction:**

Runtime reproduction, local only, in a private `unshare -rn` user+network namespace. No external network was involved. Scripts are in scratch/audit-verify-fakeip-bypass\.

1. gen.sh runs Forkop's own nft/apply.uc with a logging nft stub. It uses the nft-create-runtime-base, nft-add-section-priority-rules-fixture and nft-create-runtime-output-rules modes, with the production default names and marks (ForkopTable, fakeip mark 0x04000000, tproxy :1602). The config has three sections:
   - yt: zapret, domain_suffix youtube.com
   - tv: bypass, source_ip_cidr 172.31.99.50/32, ports 443
   - port_bypass: bypass, ports 8443

   The emitted rules match the finding exactly, for example `priority_rules iifname @forkop_interfaces ip saddr @forkop_rule_tv_sources ip daddr != @localv4 tcp dport @forkop_rule_tv_ports counter accept`, plus the same rule in priority_output_rules.

2. netns2.sh replays those exact commands with the real nft binary. It then adds a transparent listener on :1602 (standing in for sing-box), the production fwmark policy route (table 105, local 0/0 dev lo), a nested netns as the LAN client on v1 (router side v0 is in forkop_interfaces), and a dummy wan interface holding the default route. Results:
   - .60 (no bypass) -> 198.18.0.5:443: CONNECTED, and the listener accepted it.
   - .50 (tv bypass) -> 198.18.0.5:443: FAILED, timed out.
   - .60 -> 198.18.0.5:8443 (port-only bypass): FAILED, timed out.
   - Counters: the tv and port_bypass priority rules had 2 packets each. The diag chain showed `fakeip_NOT_marked` = 4. The postrouting counter showed `oifname wan ip daddr 198.18.0.0/15` = 4, so the SYNs were forwarded to the WAN unmarked and never tproxied.

3. The first run (netns.sh, same netns, router-originated sockets) shows the same behaviour for priority_output_rules. The tv and port_bypass output rules counted 1 packet each and accepted them unmarked, and the connections failed. The non-bypassed control was marked and reached the listener.

4. Fix validation: patchlog.py inserts `ip daddr != 198.18.0.0/15` and `ip6 daddr != fc00::/18` after the @localv4/@localv6 check in the bypass priority rules. The replay then showed all three connections CONNECTED to the tproxy listener, and the bypass priority counters stayed at 0 for FakeIP.


**Verification notes:**

Line refs are all correct. Corrections and refinements:

1. Real exposure is IPv4 only. IPv6 FakeIP is already excluded because LOCALV6_RANGES contains fc00::/7. An explicit ip6 exclusion is harmless and makes the protection intentional rather than accidental.

2. Practical trigger:
   - A port-only bypass rule (with or without source_ip_cidr), combined with a FakeIP destination produced by another capture rule, on a bypassed port.
   - ip_cidr, ip_port or Discord UDP bypass priority rules are affected only if their subnet set covers 198.18.0.0/15, for example ip_cidr 0.0.0.0/0 used as a "bypass everything for this device" rule. Applying the exclusion to every bypass priority rule is still the right scope.

3. Better minimal fix: `fakeip_range` and `fakeip6_range` are already local in `nft_add_section_priority_rules` (apply.uc:789-790). When `section_priority_action(section) == "bypass"`, prefix every match4 list (match_ip4, match_ip_port4_*, match_udp_ip_port4, match_port4_*) with `[ "ip", "daddr", "!=", fakeip_range ]` and every match6 list with `[ "ip6", "daddr", "!=", fakeip6_range ]`. This covers both priority_rules and priority_output_rules without adding parameters to nft_add_priority_rule_pair / nft_priority_rule_args. The rule shape was validated in the netns replay. Capture rules must stay unchanged.

4. Tests: the grep -F substrings at tests/nft_apply.sh:346 and 348, and assert_line_before at 349-352, will change and must be updated. Add assertions that the port-only and ip bypass rules contain the FakeIP exclusion in both chains, and that capture rules do not.

5. Resolver claim is secondary:
   - routing/resolve.uc models only sing-box route rules. It reports 'yt' if yt comes before tv in UCI order, or bypass if tv comes first; in both cases nft actually black-holes the flow.
   - The result is labelled provenance "simulated", so this is a consequence of the nft bug, not a separate invariant-15 violation. It disappears with the fix.

6. Severity stays P2. The config combination is fairly narrow, but the outcome is silent, total loss of connectivity for those flows, including router-originated traffic. It also contradicts the rule's meaning ("bypass" should mean direct, not dead). There is no data loss or security boundary impact, so it is not P1. It is not a product decision.

7. Does not touch any safety invariant: autotune and the DPI engine are not involved.


---

<a id="uc-030"></a>

## UC-030 · P2 · S8 — ByeDPI-правило с IP, подсетями или портами зацикливает собственные соединения ciadpi через TPROXY обратно в sing-box

**Severity:** P2<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** nft/apply.uc priority_output_rules + providers/byedpi<br>
**Sources:** nft#0<br>
**Original title:** ByeDPI rule with IP, subnet-list or port matchers loops: ciadpi's own upstream connections are re-captured and TPROXYed back into sing-box<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-8

**Evidence:** nft/apply.uc:577-580 `action_captures_traffic` includes `action == "byedpi"`, so byedpi sections get priority sets. nft/apply.uc:673-677 `priority_output_rules` starts with `meta mark != 0 return` (only marked sockets are exempt). nft/apply.uc:816-818 and 833-837 add IP and port-only rules to priority_output_rules (`ip daddr @forkop_rule_X_subnets meta mark set 0x04000000 counter accept`). nft/apply.uc:918-919 `mangle_output ... jump priority_output_rules`. nft/apply.uc:912-915 the proxy chain TPROXYs any packet with the fakeip mark, including router traffic re-routed via table 105 onto lo. providers/byedpi/runtime.uc:256-262 starts ciadpi with no mark, uid or cgroup (`ciadpi --ip 127.0.0.1 --port N ...`). singbox/generator.uc:2336-2346 adds a socks outbound; add_combined_route_for_section (2981+) adds ip_cidr/port route rules on the tproxy inbound. singbox/route.uc:67-90 adds a real-IP `resolve` rule only for domain matchers. Scratch scripts byedpi_loop.sh and byedpi_ports.sh render `priority_output_rules ip daddr != @localv4 tcp dport @forkop_rule_b_ports meta mark set 0x04000000 counter accept` and the same for `forkop_rule_d_subnets` (community discord).


**Reproduction:** Static: scratch/audit-a5/byedpi_ports.sh and byedpi_loop.sh render the output-capture rules for byedpi sections. Runtime (isolated router only): add a rule with action=byedpi and ports=443, then curl https://example.com from a LAN client. Watch `ss -tn | grep -c 127.0.0.1:1080` and the ciadpi log grow without bound.


**Expected:** Traffic produced by the local DPI helper leaves the router directly, like sing-box traffic (mark 0x08000000) and TorrServer Direct (cgroup mark), and is never re-captured by Forkop.


**Actual:** ciadpi's upstream connection to a destination matched by the byedpi rule has mark 0. It is marked 0x04000000 in priority_output_rules, re-routed via ip rule 105 to local table 105 over lo, TPROXYed to sing-box :1602, and routed by the same rule back to the ByeDPI socks outbound. ciadpi then connects again, and the cycle repeats until ciadpi (ulimit 4096) or sing-box runs out of file descriptors.


**Impact:** Every client connection matched by a ByeDPI rule with ip_cidr, subnet community lists (discord, telegram, meta, twitter, cloudflare, ...), remote subnet lists or port-only matchers fails and triggers a connection storm. CPU load rises and file descriptors exhaust in ciadpi and sing-box, which can degrade all proxied traffic. With a port-only ByeDPI rule (for example all TCP/443), every HTTPS connection from the LAN and the router itself loops, which is a router-wide break. Domain-only ByeDPI rules are unaffected: they get no priority sets, and sing-box resolves the real IP.


**Root cause:** Router-originated capture (priority_output_rules) exempts only non-zero marks. ByeDPI is the only provider whose upstream sockets are created by a separate process that cannot set a mark (zapret uses sing-box routing_mark 0x0100000N; proxy and vpn use 0x08000000).


**Affected files:** `forkop/files/usr/lib/nft/apply.uc`, `forkop/files/usr/lib/providers/byedpi/runtime.uc`, `tests/nft_apply.sh`

**Proposed fix:** Minimal fix: do not emit priority_output_rules for sections whose action is byedpi. Router-local traffic to those destinations then goes direct, and ciadpi traffic can no longer match its own rule. More complete fix: exempt ciadpi sockets before `jump priority_output_rules`. Options are a dedicated cgroup with a cgroup-confined `meta mark set 0x08000000` at -151 (as for TorrServer, which contract.uc already accepts) or a dedicated uid with `meta skuid X return`. Separately, sets of other capture rules could still send ciadpi traffic into those rules.


**Tests needed:** nft_apply.sh fixture: a byedpi section with ip_cidr, discord and ports-only matchers must not produce priority_output_rules, or the ciadpi exemption must precede the jump. Router test: a byedpi port-only rule, one client connection, and a bounded number of ciadpi and sing-box sockets.


**Risk:** Low for the minimal fix: router-originated traffic to byedpi destinations loses DPI bypass and goes direct.


**Verification:** confirmed → P2

**Verification evidence:**

I checked every cited line in tree 07872084, and each one is accurate.
- nft/apply.uc:577-580: `action_captures_traffic` includes `action == "byedpi"`. From there, section_priority_action returns "capture" and section_needs_priority_sets (668-670) returns true for any byedpi section with ip_cidr, a subnet community list (twitter, meta, telegram, cloudflare, hetzner, ovh, digitalocean, cloudfront, discord, roblox; config/rule.uc:288-299), remote_subnet_lists, rule_sets_with_subnets, domain_ip_lists, or a port-only matcher (634-647).
- apply.uc:672-676: priority_output_rules starts with `meta mark != 0 return`. This is the only exemption inside that chain.
- apply.uc:815-818 (plain IP), 820-825 (IP+port), 827-830 (discord UDP) and 832-837 (port-only) add the same rules to priority_output_rules, with no source restriction unless the rule has source_ip matchers.
- apply.uc:915-919: mangle_output returns only for localv4/localv6 destinations and for the exact `meta mark 0x08000000`, then `jump priority_output_rules`. The proxy chain at 911-914 TPROXYs any packet carrying the fakeip mark to :1602.
- ensure_tproxy_route_rule at 1384-1433 installs `fwmark 0x04000000/0x04000000 table 105` plus `local 0.0.0.0/0 dev lo table 105`.
- providers/byedpi/runtime.uc:256-262 starts `ciadpi --ip 127.0.0.1 --port N <strategy>` with no uid, cgroup or mark. The strategy validator (providers/byedpi/validator.uc) exposes no mark option, and ciadpi has none.
- singbox/generator.uc:2336-2346: the byedpi outbound is `socks` to 127.0.0.1:1080+i. singbox/route.uc:39 sets `default_mark` to OUTBOUND_MARK, so sing-box's own sockets are exempt, but ciadpi's upstream sockets are not.
- generator.uc:3044-3063: the route rule is bound to `inbound: [tproxy-in, tproxy6-in]` with ip_cidr or port matchers. It is not scoped by source, so a connection re-captured from the router matches the same rule again.
- singbox/route.uc:67-90: the byedpi `resolve` rule is only emitted when domain or rule-set matchers exist. For IP-only and port-only rules the generator warns "Resolve real IP is enabled ... but no domain or rule-set matchers found".
- Other layers: none of them blocks this. The LuCI editor (section.js:16-26 ROUTING_ACTIONS, and ip_cidr/ports/community_lists depend on them at 155-170 and 7621-7629) and config/validator.uc:1422-1428 accept ip_cidr, community lists and ports for action=byedpi. No test pins or covers byedpi output capture: tests/nft_apply.sh has no byedpi fixture, and tests/provider_rules.sh only counts indexes.


**Verification reproduction:**

I reproduced this at runtime at the kernel level, in a private unprivileged network namespace. There was no router contact and nothing was written to the worktree. The scripts are in scratch/audit-verify-byedpi-loop/ (run.sh, render.sh, inner.sh, tproxy_listener.py, client.py, singbox_route.sh, dump.uc).

1. render.sh uses the production apply.uc in FORKOP_NFT_BATCH_FILE mode (nft-create-runtime-base, nft-add-section-priority-rules-fixture, nft-create-runtime-output-rules, nft-populate-runtime-sets-fixture) to render the runtime for two sections: `tg` {action=byedpi, ip_cidr 149.154.160.0/20} and `p` {action=byedpi, ports 8443}. The rendered batch contains `priority_output_rules ip daddr != @localv4 ip daddr @forkop_rule_tg_subnets meta mark set 0x04000000 counter accept` and `... tcp dport @forkop_rule_p_ports meta mark set 0x04000000 counter accept`.
2. Inside `unshare -rn` I applied the batch with `nft -f`, added the same table-105 policy routing as ensure_tproxy_route_rule, and added a dummy WAN with a default route. A python IP_TRANSPARENT listener on :1602 stands in for sing-box tproxy-in. A python client stands in for ciadpi's upstream socket, which has mark 0. Results:
   - Case A, 149.154.167.50:443 with mark 0: CONNECTED. Listener log: `CAPTURED peer=10.9.0.1:35876 orig_dst=149.154.167.50:443`.
   - Case B, 93.184.216.34:8443 with mark 0: CONNECTED. Listener log: `CAPTURED ... orig_dst=93.184.216.34:8443`.
   - Controls, all TimeoutError and not captured: an unmatched port 9999 with mark 0, the same IP with sing-box mark 0x08000000, and the same port with zapret mark 0x01000001.
   - Counters: `forkop_rule_tg_subnets ... counter packets 4` and `forkop_rule_p_ports ... counter packets 4`.
   A first attempt with 203.0.113.9 was not captured only because 203.0.113.0/24 is in LOCALV4_RANGES; that is expected.
3. singbox_route.sh runs generator.uc generate-config-fixture on the same sections. The route rules include `{"action":"route","inbound":["tproxy-in","tproxy6-in"],"outbound":"tg-out","ip_cidr":["149.154.160.0/20"]}` and `{... "outbound":"p-out","port":[8443]}`. tg-out and p-out are `socks` 127.0.0.1:1080 and :1081. No earlier rule exempts router-sourced connections; final is direct-out.
Together these prove the full cycle: LAN connection -> sing-box -> socks -> ciadpi -> mark-0 upstream -> priority_output_rules -> table 105/lo -> TPROXY :1602 -> the same route rule -> the same socks outbound -> ciadpi, and so on.
Not reproduced (needs sing-box, ciadpi and a router): the actual file-descriptor and connection storm. That part is a static inference, but the loop has no terminating condition, because sing-box only does loopback detection for its own direct outbound, not for socks or TPROXY.


**Verification notes:**

Verdict: confirmed. The finding's line references are accurate; minor offsets only: nft_create_priority_chains is at 672-676, the port-only block is at 832-837, and mangle_output is at 915-919.

Severity: I keep P2. ByeDPI with any IP, subnet-list or port matcher is fully non-functional: every matched connection loops until ciadpi (ulimit 4096) runs out of file descriptors. That is a broken major workflow, reachable through the normal UI. The port-only variant (for example byedpi on TCP 443) breaks all LAN HTTPS and is arguably P1 ("router/network break"). A second-order effect needs hardware to confirm: each client connection can create about 2000 looped connections and roughly 4000 conntrack entries, which linger for the 120s TIME_WAIT timeout, so conntrack pressure could degrade unrelated traffic. The damage is reversible by removing the rule; it does not persist.

Narrowing:
- Rules with source_ip matchers are not affected, because the output rules also require `ip saddr @sources` and ciadpi's source is the router address.
- Discord only adds UDP ip-port rules for its shared Cloudflare ranges. The plain discord subnets still get output rules.

Wider than the finding says:
1. Cross-rule loop (static reasoning only). A domain-only byedpi rule is safe only in isolation. ciadpi's upstream to the resolved real IP can still be captured by another section's priority_output_rules, for example a port-only or subnet VPN/proxy rule. sing-box then sniffs the SNI, and if the byedpi domain rule comes earlier in route order, the connection goes back to byedpi and loops.
2. Fakeip variant (low confidence). A port-only or IP-only byedpi rule has no resolve rule. If sing-box hands ciadpi an FQDN restored from a fakeip, and the router's resolver returns a fakeip, the generic `mangle_output ip daddr 198.18.0.0/15 ... mark set` rule (apply.uc:969-972) re-captures it even without priority_output_rules.

Fix:
- The proposed minimal fix (skip priority_output_rules for action=byedpi) removes the self-loop the finding describes. It does not remove variants 1 and 2.
- Better minimal fix, still no product decision: exempt ciadpi's own sockets in mangle_output before `jump priority_output_rules` and before the generic output rules. The most practical way is a dedicated uid or gid for ciadpi (the supervisor already builds the command line, and ciadpi's desync options need no capabilities), plus `meta skuid <uid> counter return`. Alternatively, reuse the TorrServer `socket cgroupv2` pattern in torrserver/direct.uc.
- Both fixes keep invariant 11: the autotune guard is `meta mark != 0 return`, and probes carry marks.

Tests needed:
- tests/nft_apply.sh: a fixture with a byedpi section using ip_cidr, a subnet community (telegram) and ports-only. It should assert that the ciadpi exemption precedes `jump priority_output_rules`, or that no byedpi output rules are emitted.
- The netns harness above can serve as a template for a future integration check.


---

<a id="uc-031"></a>

## UC-031 · P2 · S9 — Политика по умолчанию (probes=5) превышает бюджет портов изоляции — каждый запуск autotune отказывает too_many_probes

**Severity:** P2<br>
**Stage:** S9 (Autotune)<br>
**Area:** A11 scheduler / isolation<br>
**Sources:** autotune#0<br>
**Original title:** Default policy (probes=5) makes every real tune refuse with too_many_probes: autotune never produces a recommendation<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-4

**Evidence:** forkop/files/usr/lib/autotune/policy.uc:27-28 `max_applies_per_day: 1, cooldown: "24h", probes: 5`; policy.uc:35 `probes: [ 3, 7 ]`; isolation.uc:76 `const MAX_TUNE_PROBES_TOTAL = 32;`; isolation.uc:883 `if (length(supported) * probes > MAX_TUNE_PROBES_TOTAL) { ... reason = "too_many_probes"`; manager.uc:367 `run_tool("isolation", [ "tune", t.host, as_string(probes), dns_resolver ])` (no candidate list, so the full catalog); catalog.uc:18-46 has 8 TCP entries (direct + 7 DPI); the router's catalog validate output (hardware-validation-autotune/stage5-readonly/s5-hw-ro.out:16) shows all 8 TCP entries 'supported'; tests/autotune_select.sh:195 pins `tune 5 192.0.2.53` -> too_many_probes, while tests/autotune_scheduler.sh:57 asserts the manager passes `tune www.youtube.com 5 ...` to a stand-in; fe-app-forkop/src/forkop/tabs/autotune/initController.ts:429 `numberInput('probes', policy.probes, 3, 7)`


**Reproduction:** scratch/audit-autotune/repro_probes.sh (wsl): tune probes=5/6/7 -> 'refused too_many_probes'


**Expected:** The default policy and every value the UI accepts produce a measurement


**Actual:** Scheduled or manual tune with the default policy -> isolation tune returns {status: refused, reason: too_many_probes} for every target (reproduced in WSL: probes 5/6/7 -> refused too_many_probes; probes 3/4 pass the check)


**Impact:** With default settings, and with probes 5..7, which the UI offers, every scheduled or manual run marks every target refused/too_many_probes. Groups stay 'No data' ('The check gave no usable result'), and the job toast still says 'Check completed'. The feature is effectively dead until a user happens to lower probes to 3 or 4, and nothing hints at that.


**Root cause:** The policy probe range (3..7, default 5) was defined independently of isolation's 32-source-port budget. The catalog grew to 8 TCP candidates, and the manager tests use a stand-in isolation.uc, so the combination was never exercised.


**Affected files:** `forkop/files/usr/lib/autotune/policy.uc`, `forkop/files/usr/lib/autotune/isolation.uc`, `fe-app-forkop/src/forkop/tabs/autotune/initController.ts`, `fe-app-forkop/src/forkop/tabs/autotune/model.ts`, `tests/autotune_scheduler.sh`, `tests/autotune_state.sh`

**Dependencies:** None


**Proposed fix:** Make the policy bound consistent with the port budget. Set LIMITS.probes = [3, 4] and default probes = 4 (floor(32 / 8 supported TCP candidates)), with max 4 in the UI numberInput. Alternatively, have isolation clamp per-candidate probes to floor(MAX_TUNE_PROBES_TOTAL / length(supported)) and report the effective count. Also map 'too_many_probes' to an explanatory UI text in targetReasonText.


**Tests needed:** A manager-level test that runs the real isolation.uc tune arity/limit checks with the default policy (or asserts policy.LIMITS.probes[1] * supported TCP candidates <= MAX_TUNE_PROBES_TOTAL); a UI model test for the probes max


**Risk:** Low. It only narrows the accepted range; existing configs with probes 5-7 fall back to the default via policy.read errors, or they need a migration note.


**Verification:** confirmed → P2

**Verification evidence:**

Confirmed. I followed the default production path from start to finish and nothing on it lowers the probe count or narrows the candidate list:
- policy.uc:26-28 sets DEFAULTS `probes: 5` and LIMITS `probes: [ 3, 7 ]` (policy.uc:35). The default UCI file forkop/files/etc/config/forkop has no autotune section, so every fresh install uses 5. policy.check accepts 3..7.
- manager.uc:526 calls `tune_target(t, policy.probes, dns_resolver.ip)`. manager.uc:366-367 then runs `run_tool("isolation", [ "tune", t.host, as_string(probes), dns_resolver ])`. No candidate list is passed, so isolation.uc:1168 gets ARGV[4] = null, and tune_candidates (isolation.uc:845-861) uses the whole catalog.
- catalog.uc:18-46 has 9 entries. 8 of them are TCP (direct plus 7 DPI). udp_fake is excluded with `quic_probe_unavailable`.
- isolation.uc:56-58 limits the source ports to 61000-61031. isolation.uc:76 sets `MAX_TUNE_PROBES_TOTAL = 32`. isolation.uc:883 refuses with `too_many_probes` when `length(supported) * probes > MAX_TUNE_PROBES_TOTAL`. The default gives 8*5 = 40 > 32, so the tune is refused before preflight. With 7 supported candidates it is still 35 > 32.
- The router's catalog output (hardware-validation-autotune/stage5-readonly/s5-hw-ro.out, `== catalog`) lists all 8 TCP entries as `supported`, so real hardware hits the same limit.
- The earlier hardware tune runs (hardware-validation-autotune/forkop-autotune-hw3/run.json) only used a hand-picked subset `[direct, multisplit, fake, fakedsplit]` with 3 probes. The Stage 6 hardware report says autotune had "no data (no targets)". The default combination was never run on a device.
- What happens after the refusal: state.uc:96-113 stores status refused / reason too_many_probes. groups.uc:59-62 turns the group into `inconclusive` with reason `too_many_probes`. manager.uc run_locked still reports `result: "completed"`, because `reason == null` when no blocker fired. model.ts:89-131 targetReasonText has no case for too_many_probes, so the UI falls to the default text "The check gave no usable result.".
- initController.ts:429 `numberInput('probes', policy.probes, 3, 7)` offers 5..7, and every one of those fails the same way.
- Why the tests miss it: the scheduler tests use a stand-in isolation (tests/helpers/autotune_scheduler/isolation.uc, 751 B, no probe checks). tests/autotune_scheduler.sh:57 asserts `^tune www.youtube.com 5 192.0.2.53$`, meaning the manager sends 5 probes and no list. tests/autotune_select.sh:195 asserts that the real isolation refuses exactly that call: `tune 5 192.0.2.53` gives `too_many_probes`. Each half is tested separately; the two tests together describe the failure.
- Safety: this fails closed. Nothing is mutated and no safety invariant is violated. The feature just does nothing. Severity stays P2 (broken major workflow), not P1.


**Verification reproduction:**

1) I wrote my own scratch script, scratch/audit-verify-probes/repro.sh, and ran it in WSL with a private mktemp TMPDIR and FORKOP_AUTOTUNE_STATE_DIR, using a permissive nfqws stub. It runs the real forkop/files/usr/lib/autotune/isolation.uc exactly the way manager.uc:367 calls it: `tune example.com <probes> 192.0.2.53`, with no candidate list. Output:
   - policy.read([]) gives probes=5, and policy.check accepts 3..7.
   - probes=3 gives `refused stale_probe_state`. probes=4 gives the same. Both passed the budget check at line 883 and were only stopped later in preflight, because the environment has no nft stubs.
   - probes=5, 6 and 7 each give `refused too_many_probes`. excluded is only `udp_fake:quic_probe_unavailable`, so all 8 TCP candidates were supported.
   - With one candidate rejected by nfqws (7 supported TCP): probes=5 still gives `refused too_many_probes`.
2) I ran the existing tests through the isolated runner (FORKOP_TEST_CACHE=$HOME/.cache/forkop-tests-verify-probes). autotune_select passed; it pins `tune 5` + full catalog giving too_many_probes. autotune_scheduler passed; it pins the manager passing `tune <host> 5 <resolver>` with no list. Together they reproduce the failure. I did not run a manager-level test with the real isolation, because apply.uc status and nft need router stubs. For that link in the chain, static proof plus these two pinned tests is enough.


**Verification notes:**

The line references are accurate. The only extra reference: the manager call site is manager.uc:526 (tune_target at 366-367). Root cause is as the auditor stated. The 32-probe budget is a hard limit: each probe needs its own source port in 61000-61031 (isolation.uc:56-58), and a used port stays in TIME_WAIT for 60 s. So MAX_TUNE_PROBES_TOTAL cannot just be raised on its own.

Correction to the proposed fix: switching to probes=4 is not a neutral change. select.uc:21 has STABLE_RATIO = 0.8 ("3/3, 4/5, 5/6, 6/7"). With 4 probes, 3/4 = 0.75 no longer counts as stable, so a candidate is stable only at 4/4. One transient failure then makes it non-stable, and we would get more inconclusive runs than today's intended 5-probe policy (which tolerates 4/5). Also, existing UCI configs with probes 5-7 would then fail policy.check. They fall back to the default (policy.uc:97) and show a policy error. Choosing this option is a product/tuning decision (product_decision=true).

Two alternative minimal fixes:
(a) Widen the probe source-port range to 61000-61063 (64 ports ≥ 8 × 7 = 56). The policy contract (3..7, default 5) and the UI stay unchanged. It is still above OpenWrt's ephemeral maximum of 60999, and isolation.uc:372-374 already refuses if the range overlaps. It requires updating PORT_LAST, the contract.uc:406/553 default sport_range, and the tests that pin 61031 (tests/autotune_contract.sh, tests/autotune_isolation.sh).
(b) Keep the port range, and have the manager clamp probes to floor(32 / supported TCP candidates), or pass a bounded candidate list. The effective count must be reported in the result so the UI does not show a configured value as observed (invariant 15).

With either option:
- Add a test that fails if policy.LIMITS.probes[1] × the number of TCP catalog entries is greater than the port budget, or that runs the real isolation tune up to the budget check with the default policy.
- Map too_many_probes (and invalid_probe_count) in targetReasonText.
- Consider not reporting a run as plain "completed" when every measured target was refused by input validation.


---

<a id="uc-032"></a>

## UC-032 · P2 · S9 — Рекомендацию для правила со стратегией не «один профиль TCP/443» применить нельзя, но UI показывает «подтверждена» и «Применить»

**Severity:** P2<br>
**Stage:** S9 (Autotune)<br>
**Area:** A11 groups / autoapply / manual apply / UI<br>
**Sources:** autotune#1<br>
**Original title:** Recommendations for rules with a non-TCP/443-only strategy (incl. the rule editor's default) can never be applied, yet the UI shows 'confirmed' plus Apply and auto mode retries silently<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-7

**Evidence:** luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js:6960-6970 loads/writes ZAPRET_DEFAULT_NFQWS_OPT (TCP80 + TCP443 + UDP443 profiles) for every zapret rule; core/dpi_strategy.uc:37-42 -> strategy 'default', custom=false; groups.uc:93-95 `if (candidate == as_string(current)) ... no_change` otherwise `status = "recommendation"`; apply.uc:490-491 `default_strategy_not_tcp443_scoped` / `if (!tcp443_profile(current)) ... "strategy_not_tcp443_scoped"`; manager.uc:430 `record.reason = "plan_" + as_string(plan.status) + ":" + ...` (status not_applied, no outcome -> no reset, no cooldown); manager.uc:549 `group.decision = { reason: decision.reason ...}` = null; model.ts:373-382 applyCandidate ignores applicability; model.ts:402 `apply && apply.status !== 'not_applied'` hides the record; model.ts:706-710 refusalText default 'The strategy was not applied.'


**Expected:** A group whose strategy autotune cannot change is shown as not applicable, with the reason and a way to make it applicable. No Apply button, no retries.


**Actual:** group.ready=true, badge 'Recommendation confirmed', Apply offered. The apply is refused with plan_not_applicable:strategy_not_tcp443_scoped, and the UI gives no reason. Auto mode re-attempts every scheduled run.


**Impact:** For the most common setup (a zapret rule created in the UI), autotune measures, confirms and shows 'Recommendation confirmed'. In recommend mode it shows an Apply button that always ends with a bare 'The strategy was not applied.' In auto mode it re-plans on every scheduled run of that group forever, with no explanation (decision reason null, not_applied record hidden). This is misleading important state, and the core workflow is broken for default rules.


**Root cause:** The applicability rule (single TCP/443 profile) lives only in apply.uc plan. groups.aggregate, hysteresis, autoapply.decide and the UI treat every zapret rule as changeable.


**Affected files:** `forkop/files/usr/lib/autotune/manager.uc`, `forkop/files/usr/lib/autotune/groups.uc`, `forkop/files/usr/lib/autotune/apply.uc`, `fe-app-forkop/src/forkop/tabs/autotune/model.ts`

**Dependencies:** Independent of the probes fix, but both are needed for autotune to work on default installs


**Proposed fix:** Minimal (no product change): classify applicability before hysteresis and apply. In compute_groups, mark a group whose rule strategy is not tcp443_profile() (reuse apply.uc's helper, moved to a shared module) as result status 'not_applicable' with the reason. That means no readiness, no Apply button, and a UI text like 'Autotune can change only a rule whose strategy is a single TCP/443 profile; choose a catalog strategy for the rule to enable it'. Also map plan_not_applicable:* reasons in refusalText and decisionText. Product option (FUTURE): let Stage 5 replace only the TCP/443 profile inside a multi-profile strategy.


**Tests needed:** A groups/manager test with a rule on ZAPRET_DEFAULT_NFQWS_OPT -> result not_applicable, no ready, no apply attempt; a UI model test that applyCandidate is null and the text is explained


**Risk:** Low for the minimal fix. The product choice is whether to extend Stage 5 to multi-profile strategies.


**Verification:** confirmed → P2

**Verification evidence:**

The applicability rule exists only inside Stage 5. Every layer before it treats a rule on the default strategy as changeable.

1. Default strategy is multi-profile. core/constants.uc:138 defines ZAPRET_DEFAULT_NFQWS_OPT as "--filter-tcp=80 ... --new --filter-tcp=443 ... --new --filter-udp=443 ...". The rule editor stores exactly this for every zapret rule (section.js:6959-6986: `if (!value || value === ZAPRET_LEGACY_DEFAULT_NFQWS_OPT) return ZAPRET_DEFAULT_NFQWS_OPT;` on load, and the same substitution on write). migration.uc:662-666 also rewrites the legacy default into it.

2. Identity is "default", not custom. dpi_strategy.uc:36-42 returns strategy="default" (custom=false) for an empty option, for the default and for the legacy default. routing/resolve.uc:337-339 puts this into r.dpi, and manager.uc:159-160 copies it into g.current and g.custom.

3. It is treated as a normal recommendation.
   - groups.uc:93-95: `if (candidate == as_string(current)) ... no_change` and otherwise `result.status = "recommendation"`.
   - hysteresis confirms it.
   - autoapply.uc:43 rejects only `ctx.custom === true`.
   - manager.uc:643 (manual_fresh) rejects only `now_g.custom === true`.

4. Stage 5 refuses it every time.
   - apply.uc:161-172: tcp443_profile() returns false when the strategy contains "--new" or any "--filter-udp".
   - apply.uc:490 gives `default_strategy_not_tcp443_scoped` and apply.uc:491 gives `strategy_not_tcp443_scoped`.
   - manager.uc:430 records this as `record.reason = "plan_" + plan.status + ":" + plan.reason` with status "not_applied". There is no outcome, so there is no cooldown and no reset, and ready stays true.
   - manager.uc:549: `group.decision = { reason: decision.reason }` stays null because decide() returned apply:true.

5. The UI does not explain it.
   - model.ts:373-382: applyCandidate checks only mode, status, ready, custom and cooldown.
   - model.ts:402: `apply.status !== 'not_applied'` hides the record.
   - decisionText(null) returns '' (model.ts:212-213).
   - refusalText default (model.ts:708-710) returns the bare "The strategy was not applied." because STALE_REASONS and the blocker regex do not match "plan_not_applicable:...".

6. The rule cannot be made applicable from the UI. Any hand-typed single TCP/443 strategy that is not a verbatim catalog template gets custom=true, which is refused as custom_strategy_kept. The catalog template texts are not exposed anywhere in the UI, and the rule editor has no catalog preset.

Tests: tests/autotune_apply.sh:407-411 and :729-730 pin the Stage 5 refusal, which is correct and must stay. tests/autotune_autoapply.sh:133-151 pins that not_applicable plans are not counted and not cooled down; that is correct for transient reasons. No test covers the upstream path for a default-strategy group. The scheduler fixture (tests/helpers/autotune_scheduler/setup.sh:57-64) only uses single-profile strategies, and the frontend model.test.ts has no plan_not_applicable case.


**Verification reproduction:**

I reproduced this end-to-end in WSL without touching the audit tree. Scratch files are in scratch/audit-verify-tcp443\ (repro.sh, apply_wrapper.uc, ui.cjs, model.cjs).

Setup of repro.sh:
- It sources tests/helpers/autotune_scheduler/setup.sh with a private TMPDIR, so it uses the real manager, groups, hysteresis and autoapply, and stubbed probes.
- It links a wrapper as $WORK/lib/autotune/apply.uc. The wrapper sends "plan" to the REAL autotune/apply.uc plan, which is read-only, and sends status and apply to the test stub.
- It adds a stub nfqws for the catalog dry-run and puts the uci CLI on PATH.
- It rewrites the youtube rule as (a) a catalog multisplit strategy (control), (b) the exact ZAPRET_DEFAULT_NFQWS_OPT, and (c) no nfqws_opt.

Results:
- **Control (catalog):** the real plan is ready and the stub apply returns applied (plans=1, applies=1). This shows the harness and the real plan work.
- **default strategy, mode auto:**
  - `manager groups` gives current="default", custom=false. Two manual runs give ready=true.
  - Scheduled run 1 and run 2 both give applied={status:"not_applied", reason:"plan_not_applicable:strategy_not_tcp443_scoped", counted:false}.
  - State after both runs: ready=true, decision=null, cooldowns={}. Counts: plans=2, applies=0.
- **default strategy, mode recommend:** `manager apply youtube` twice gives {status:"refused", result:"refused", reason:"plan_not_applicable:strategy_not_tcp443_scoped"} both times, with ready still true.
- **Empty nfqws_opt:** the same results with reason plan_not_applicable:default_strategy_not_tcp443_scoped.

UI check: I bundled fe-app-forkop/src/forkop/tabs/autotune/model.ts with esbuild into the scratch dir and fed it the observed state (ui.cjs):
- auto: badge "Recommendation confirmed" (warning), explanation only "Does not work without bypass; a stable strategy was found.", lastApply null.
- recommend: the same badge, and applyCandidate="fake", so the "Apply fake" button is shown.
- applyResultView of the refused job: {tone:"warning", text:"The strategy was not applied."}.

No router was contacted; none is needed.


**Verification notes:**

The finding is correct as stated, and the line references are accurate.

Clarifications:
1. **Impact is wider than "the most common setup".** Given dpi_strategy.uc and custom_strategy_kept, autotune can only ever change a rule whose nfqws_opt is already, verbatim, a TCP catalog template. Every other rule is either "default" (always refused by Stage 5) or "custom" (refused by policy). No UI path creates a catalog-template rule. So the Stage 6.8.5 and 6.9.1 apply workflows are effectively unusable on installs whose rules were made in the UI.
2. **Safety is intact.** This is fail-closed: there is no mutation, and Stage 5 remains the only engine and the final authority (invariants 10 and 18 hold). The harm is misleading state (a confirmed recommendation plus an Apply button that can never succeed) and a dead workflow. P2 is correct, not P1.
3. **Cost of the retries.** "Retries forever" costs one read-only plan per scheduled run of that group. The probe measurements would run anyway. Each attempt also adds a not_applied record to state.applies, which is capped at 20 (state.uc:27,85). At the default 6h interval this is harmless. At a 1h interval with several such groups it could in theory evict a counted record less than 24h old and weaken the daily budget. This is low probability, and it is a general property of that cap rather than of this bug.
4. **Better minimal fix: follow the existing `custom` flag path** instead of adding a new aggregate status, which would also touch hysteresis reset events, the UI badge mapping and contract tests.
   - Move tcp443_profile() into a pure shared module (e.g. autotune/catalog.uc or core/dpi_strategy.uc), treating empty as not applicable, and have apply.uc import it. Stage 5 keeps its own check as the authority.
   - In compute_groups, set `g.applicable` / `g.not_applicable_reason` from the section's raw nfqws_opt. The raw text never leaves the backend.
   - Pass it to autoapply.decide as reason "strategy_not_tcp443_scoped", checked like custom_strategy_kept, so there is no plan call and decision.reason is set.
   - In manual_recommendation/manual_fresh, refuse it before any plan.
   - Expose the boolean and the reason in the autotune_groups and status JSON.
   - In model.ts: require it for applyCandidate, add decisionText/refusalText entries, and add a generic `plan_not_applicable:*` fallback in refusalText.
   - Keep hysteresis as it is; the measurements stay informative.
5. **product_decision=true is correct.** The text "choose a catalog strategy for the rule" is not actionable today, because catalog templates are not exposed in the UI and switching to one drops the rule's TCP/80 and UDP/443 handling. Making autotune useful needs a product choice: (a) extend Stage 5 to replace only the TCP/443 sub-profile of a multi-profile strategy (FUTURE, needs new verification), or (b) add catalog presets to the rule editor. The minimal fix only makes the current limit honest.
6. **Tests to add:**
   - A scheduler-harness case with the real plan on ZAPRET_DEFAULT_NFQWS_OPT and on an empty strategy: no plan call, decision reason set, no Apply offered.
   - A manual_apply refusal case.
   - model.test.ts cases for applyCandidate=null and the explanation text.
   - Keep tests/autotune_apply.sh:407-411 and :729-730 and tests/autotune_autoapply.sh:133-151 unchanged.


---

<a id="uc-033"></a>

## UC-033 · P2 · S10 — Асинхронный тест задержки одного прокси передаёт путь файла задачи как URL теста и сообщает успех

**Severity:** P2<br>
**Stage:** S10 (Контракты CLI/API и семантика ошибок)<br>
**Area:** latency_test_async -> clash_api get_proxy_latency arg contract<br>
**Sources:** cli-contract#1<br>
**Original title:** Async single-proxy latency test sends the job state path as the latency test URL<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/ui.uc:1442-1443 `let method = latency_clash_method(latency_type).method; let status = command_status(command_from_args([ BIN_PATH, "clash_api", method, tag, timeout, path ]) ...` (path is always the 4th clash_api arg). diagnostics/runtime.uc:1766-1777 get_proxy_latency: `let url = as_string(arg3 || ""); if (url == "") url = test_url; ... push(args, "url=" + url);` (arg3 means URL). ui.uc:1424-1431 maps latency_type 'proxy' to get_proxy_latency. FE uses 'proxy' for every non-tag-select section: fe-app-forkop/src/forkop/tabs/dashboard/initController.ts:1881-1886 `handleTestLatency('proxy', section.sectionName, ..., section.latencyTestTimeout)`. runtime.uc:1570-1573 clash_json_output always `return 0`, and latency_worker (ui.uc:1445-1448) marks the job successful.


**Reproduction:** Scratch script ...scratch/audit-cli-rpc/latency_proxy_url.sh (wsl bash).


**Expected:** The URL should be settings.latency_test_url (as the synchronous Diagnostics path uses, runSectionsCheck.ts:89-92), and the job should fail when sing-box reports an error.


**Actual:** Reproduced with a fake curl and the real /usr/bin/forkop → runtime.uc chain. The curl call was `-G -s 127.0.0.1:9090/proxies/proxy-out/delay --data-urlencode url=/tmp/.../ui/latency-actions/1790605789-414549924.json --data-urlencode timeout=5000`. With an error body returned, the job state is {"success":true,...,"message":"Latency test completed","exit_code":0}.


**Impact:** The dashboard 'test latency' action for single-outbound sections never measures anything useful. sing-box receives url=/var/run/forkop/ui-state/latency-actions/<id>.json (no host), so the delay test errors. The job still ends with success:true, 'Latency test completed', so the UI shows no error while the latency stays empty or stale. This is misleading state in a user-facing workflow.


**Root cause:** The latency worker appends the progress path for every method. The progress path only makes sense for get_proxy_latencies; for get_proxy_latency the 3rd positional arg is the test URL.


**Affected files:** `forkop/files/usr/lib/service/ui.uc`, `forkop/files/usr/lib/diagnostics/runtime.uc`

**Proposed fix:** Build the clash_api args per method in latency_worker: proxy → [tag, timeout] (the default latency_test_url is then used), group → [tag, timeout], proxy_list → [tags_json, timeout, path]. Also make get_proxy_latency/get_group_latency return non-zero when the sing-box body has no 'delay' (error 'message'), so the job reflects failure.


**Tests needed:** tests/ui_runtime_job.sh: run latency-worker for type proxy/group/proxy_list with a FORKOP_BIN stub that records argv, and assert that proxy/group get no path argument. tests/diagnostics_status.sh: get_proxy_latency with an error body ({"message":...}) exits non-zero.


**Risk:** Low. The change only affects arg forwarding and the rc of latency ops. Callers already check data.message (runSectionsCheck.ts:94,112).


**Verification:** confirmed → P2

**Verification evidence:**

The chain holds at every step in the audit tree (07872084):
- service/ui.uc:1442-1443, latency_worker: `command_from_args([ BIN_PATH, "clash_api", method, tag, timeout, path ])`. The job state path is appended for every latency_type.
- usr/bin/forkop:176, `clash_api: [ "diagnostics/runtime.uc", "clash-api", 4 ]`, forwards 4 positional args. runtime.uc:2267-2268 then calls `clash_api(ARGV[1], ARGV[2], ARGV[3], ARGV[4])`, so arg3 is the path.
- runtime.uc:1766-1775, get_proxy_latency: `let url = as_string(arg3 || ""); if (url == "") url = test_url; ... push(args, "url=" + url);`. The job path becomes the delay-test URL. get_group_latency (1829-1838) ignores arg3, so the group type is not affected. get_proxy_latencies (1796) is the only method where arg3 is meant as a progress path.
- ui.uc:1424-1431 maps any type other than group or proxy_list to get_proxy_latency.
- FE: renderSections.ts:358-359 calls `onTestLatency(section.outbounds[0].code)` for non-tag-select sections. initController.ts:1881-1886 turns that into `handleTestLatency('proxy', ...)`. getDashboardSections.ts:1476-1518 shows that 'vpn' (interface) and 'outbound' (JSON outbound) sections are exactly the withTagSelect:false sections that have an outbound.
- runtime.uc:1570-1573, clash_json_output: `print(...); return 0;`. It always returns 0, so latency_worker (ui.uc:1445-1446) writes "Latency test completed" with success:true.
- Upstream sing-box (experimental/clashapi/proxies.go getProxyDelay, common/urltest/urltest.go urlTest, fetched with gh): the url query is used as-is unless it starts with "http://". For "/var/run/..." url.Parse gives an empty hostname and port, so the dial or HEAD request fails. On error the handler calls `server.urlTestHistory.DeleteURLTestHistory(realTag)` and answers HTTP 503 with a JSON `{"message":"An error occurred in the delay test"}`. curl -s exits 0 on that answer.
- FE after success: completeLatencyTestJob (initController.ts:532-551) only refetches the sections. latency comes from `history?.[0]?.delay || 0` (getDashboardSections.ts:1487,1513), which renders with the `--empty` class. No error toast is shown.
- Regression origin: d61acd1d ("Add latency test progress feedback") added the 4th `path` arg for all methods. Later, 2546dfb6 ("Add Priority failover groups") made arg3 of get_proxy_latency a URL for priority.uc:226 (`[ "get_proxy_latency", tag_name, timeout, group.health_url ]`), and the two collided.
- No test pins the buggy argv. diagnostics_status.sh:146 only covers the 3-arg direct call. ui_runtime_job.sh:247-250 only starts proxy_list with FORKOP_BIN=/bin/true.


**Verification reproduction:**

Script: scratch/audit-verify-latency-url\repro.sh, run in WSL with a private mktemp dir.

Setup:
- The real ui.uc latency-worker runs, with FORKOP_BIN set to a wrapper around the real usr/bin/forkop dispatcher, then into runtime.uc.
- A fake curl in PATH logs its argv and returns a sing-box-style body.
- A UCI state file sets latency_test_url=https://latency.example/generate_204.

Observed:
- type=proxy, tag main-interface-1-out, timeout 10000:
  - curl argv: `-G -s 127.0.0.1:9090/proxies/main-interface-1-out/delay --data-urlencode url=/tmp/tmp.S2WyEw5H9b/ui-state/latency-actions/job-proxy.json --data-urlencode timeout=10000`
  - With body `{"message":"An error occurred in the delay test"}`, the final state is `{"success":true,...,"message":"Latency test completed","exit_code":0}`.
- type=group: curl uses `url=https://latency.example/generate_204`, so the URL is correct. With the error body, the result is still success:true.
- type=proxy_list: the URL is correct. With a valid JSON error body the state is progress failed:0 and success:true. Only a non-JSON body gives failed:2 and success:false.
- The direct 3-arg CLI `forkop clash_api get_proxy_latency proxy-out 5000` (the synchronous Diagnostics path and the automatic path) uses the configured URL, prints the error JSON, and exits with rc=0.

The sing-box side (the failed test, the 503 JSON body, and the deleted URL-test history) is proven statically from upstream source, not on a router.


**Verification notes:**

Line refs are accurate. Corrections and additions:

1. Real impact is slightly worse than described. On error, sing-box deletes the outbound's URL-test history (DeleteURLTestHistory). A "latency test" click on a vpn/interface or JSON-outbound dashboard section therefore:
   - always fails,
   - wipes the previously measured latency, so a working tunnel shows an empty latency cell,
   - and still reports "completed" with no toast.
   The automatic latency test (runtime.uc:1976, 3-arg call with "") later restores a correct value. Routing and traffic are not affected, so P2 stays (broken user-facing workflow plus misleading state), not P1.

2. Root cause: the argument contract for arg3 was overloaded. d61acd1d added the progress-path 4th argument for every method. 2546dfb6 then reused arg3 of get_proxy_latency as a health URL for priority.uc:226.

3. Minimal fix for the main bug, in ui.uc latency_worker only:
   `let args = [ BIN_PATH, "clash_api", method, tag, timeout ]; if (as_string(latency_type) == "proxy_list") push(args, path);`
   Do not change get_proxy_latency's URL arg, because priority.uc needs it.

4. The success-masking part of the proposed fix is broader than the finding says:
   - It also affects group, and proxy_list. In runtime.uc:1817 per-item failure is only counted when stdin-json fails, i.e. on a non-JSON body. sing-box returns valid JSON `{"message":...}` with curl exit 0, so failed stays 0.
   - Better fix: have one helper that requires a numeric `delay` (proxy/proxy_list) or a non-error object (group). Use it in clash_json_output for the latency actions and in the get_proxy_latencies per-item check.
   - Changing the rc to non-zero is compatible with current callers: FE callBaseMethod.ts:23-30 already turns a non-zero rc into success:false; runSectionsCheck treats that as an error; priority.uc:227 treats rc!=0 as not alive. The only behaviour change is that the automatic latency job (runtime.uc:1976) starts reporting failures. Alternatively, keep the CLI rc unchanged and have latency_worker capture and check the output instead.

5. Tests to add:
   - ui_runtime_job.sh: latency-worker with a FORKOP_BIN stub that records argv for proxy, group and proxy_list; assert the path is only passed for proxy_list.
   - diagnostics_status.sh: a JSON `{"message":...}` body gives a failure for get_proxy_latency, get_group_latency and get_proxy_latencies.

product_decision=false. No hardware needed for the fix; the router-side effect is inferred from sing-box source.


---

<a id="uc-034"></a>

## UC-034 · P3 · S1 — RO ACL выдаёт неиспользуемые и относительно мощные команды (check_proxy, тройка latency-команд clash_api и др.)

**Severity:** P3<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** rpcd read ACL least privilege<br>
**Sources:** cli-contract#8, ui-cleanup-deadcode#1, security#6<br>
**Original title:** RO ACL grants unused and relatively powerful commands (check_proxy, clash_api latency trio, others)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** luci-app-forkop.json:29 `"/usr/bin/forkop check_proxy"`, :42 `clash_api get_proxy_latency *`, :43 `get_proxy_latencies *`, :44 `get_group_latency *`, plus :12 get_ui_capabilities, :26 get_outbound_metadata *, :34 check_sing_box_logs. No RO UI path calls them: runSectionsCheck.ts:42-54 returns 'unsupported' in RO before any latency call, and grep finds no FE caller for check_proxy, get_outbound_metadata, get_ui_capabilities or check_sing_box_logs. check_proxy runs `sing-box -c <config> check` and up to 5× `sing-box tools fetch -c <copy>` (runtime.uc:646, :673); support_report deliberately avoids this because it risks the OOM killer on 256 MiB routers (runtime.uc:2207-2210). get_proxy_latency's 3rd arg is an arbitrary test URL (runtime.uc:1769-1775). get_proxy_latencies' 3rd arg is a progress path that is only prefix/suffix checked (ui.uc:623-631, '..' not rejected).


**Expected:** The RO grants cover only what the RO UI renders.


**Actual:** The RO role can exec these commands with arbitrary trailing args.


**Impact:** An authenticated read-only user can make the router run full sing-box instances next to the live one (memory pressure or OOM on small routers). They can also make it issue GET requests with arbitrary path and query to any host (including LAN services) through any outbound, trigger URLTest re-evaluation on groups, and rewrite progress counters of the admin's running latency job. None of this is needed by the RO UI.


**Root cause:** The ACL was carried over from the pre-RO design; grants were not pruned when RO pages stopped using them.


**Affected files:** `luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json`, `fe-app-forkop/src/forkop/services/readonlyCommandGuard.ts`, `tests/acl_boundary.sh`, `fe-app-forkop/src/forkop/methods/shell/index.ts`

**Proposed fix:** Remove the unused RO grants (check_proxy, check_nft, check_sing_box_logs, get_outbound_metadata, get_ui_capabilities, the clash_api latency trio) from the ACL and from READONLY_EXEC_PATTERNS together; acl_boundary.sh enforces the mirror. If RO latency is wanted later, pin get_proxy_latency to exactly two args in the pattern.


**Tests needed:** acl_boundary.sh: assert that these commands are not allowed for read; the readonlyCommandGuard mirror test.


**Risk:** External tools relying on RO access to these commands would lose it (no in-tree caller).


### Also reported as ui-cleanup-deadcode#1 (P3): Read-only ACL (and its frontend mirror) still grants CLI commands no page issues; check_nft returns the unmasked nft table to RO

**Evidence:** luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json read.file: "/usr/bin/forkop check_nft", "check_proxy", "show_sing_box_version", "get_outbound_metadata *", "check_sing_box_logs"; mirrored in fe-app-forkop/src/forkop/services/readonlyCommandGuard.ts:28-36. No caller: rg "'check_nft'|'check_proxy'|show_sing_box_version" fe-app-forkop/src luci-app-forkop/htdocs (excluding main.js/tests) -> only readonlyCommandGuard.ts and comments in types.ts:328-339; ForkopShellMethods.getOutboundMetadata (methods/shell/index.ts:245) and checkSingBoxLogs (:346) have zero callers (rg 'getOutboundMetadata|checkSingBoxLogs' -> definitions only; getDashboardSections.ts:1376 is an unrelated local function). diagnostics/runtime.uc:751-752 check_nft: "nolog(\"Sets configuration:\"); print(command_output_from_args([ \"nft\", \"list\", \"table\", \"inet\", NFT_TABLE_NAME ]))" (full rules/sets incl. source_ip_cidr/fully_routed_ips matches, nft/apply.uc:615,630), while the RO global check masks 'list ip_cidr', 'list source_ip_cidr', 'list fully_routed_ips' (maskDiagnostics.ts:54-62). check_proxy (runtime.uc:640-697) creates a temp dir and runs 'sing-box tools fetch ifconfig.me' from an RO session. The page-used check_nft_rules (runtime.uc:1414) returns only counters.


**Proposed fix:** Remove check_nft, check_proxy, show_sing_box_version, get_outbound_metadata *, check_sing_box_logs from acl.d read.file and from READONLY_EXEC_PATTERNS (tests/luci_readonly_command_guard.sh keeps both in sync); keep them available to admin via the write grant. Also drop the dead wrappers getOutboundMetadata/checkSingBoxLogs.


### Also reported as security#6 (CLEANUP): Read-only ACL grants several commands the UI never uses (attack surface, incl. check_proxy OOM/network and ubus service list)

**Evidence:** The read role is granted `/usr/bin/forkop check_proxy` (:29), `check_nft` (:30), `show_sing_box_version` (:28), `autotune_target *` (:17) and ubus `service` list (:88-89), but grep of fe-app-forkop/src + hand-written LuCI views (excluding main.js) shows no caller for check_proxy, check_nft, show_sing_box_version or autotune_target; only autotune_target_set/remove exist in the UI. check_proxy spins up a real sing-box `tools fetch` (diagnostics/runtime.uc:672-697) - network egress and memory cost - reachable by any RO user; check_nft runs `nft list table/ruleset`.


**Proposed fix:** Remove check_proxy, check_nft, show_sing_box_version and autotune_target from the read group (and from READONLY_EXEC_PATTERNS + acl_boundary.sh) unless a planned UI use exists; keep the parity test green.


---

<a id="uc-035"></a>

## UC-035 · P3 · S1 — Предикат авторизации Clash API расходится: генератор ставит secret при enable_yacd, backend шлёт Authorization только при WAN-доступе; выключение WAN-доступа стирает секрет, который продолжает действовать в LAN

**Severity:** P3<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** security<br>
**Sources:** security#4, uci-global#14<br>
**Original title:** Backend and generator disagree on when the Clash secret is required; frontend/monitoring masker and browser console leak the token<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** generator.uc:407-411 adds the Clash `secret` whenever enable_yacd is on (regardless of WAN access), but backend clash_api sends Authorization only when enable_yacd_wan_access is on (diagnostics/runtime.uc:1584); so with enable_yacd on + wan_access off the controller has a secret the backend never sends. Frontend dashboard/monitoring append the secret as a query token on the websocket URL: `${getClashWsUrl()}/connections?token=${clashApiSecret}` (tabs/monitoring/initController.ts:1932, dashboard/initController.ts:642,678) - a secret in a URL. safeText() (monitoring initController.ts:985-991) masks `token=...` but its earlier userinfo rule rewrites `foo@` first so `?token=SECRET` is only caught by the second rule (that one works), yet it masks the token NAME position: verified `?token=SECRET&a=1` -> `?SECRET=***` i.e. it drops the key and keeps... (rechecked: it replaces token=VALUE, but the userinfo pass mangles order) - net effect is inconsistent masking of Clash tokens shown in the connection path cell.


**Reproduction:** Static reading of the four files; token-in-console confirmed by socket.service.ts:72 logging url.


**Expected:** One consistent condition for requiring/sending the secret, and the secret never written to console or any URL that gets logged.


**Actual:** The secret-required condition differs between config generation (enable_yacd) and backend auth (enable_yacd_wan_access), and the Clash secret is placed in ws URLs that are logged to the browser console.


**Impact:** Minor: secret ends up in browser console/devtools history and query strings (violates the 'no secrets in URLs' privacy rule in spirit). The auth-condition mismatch is a latent correctness bug, not a leak by itself.


**Root cause:** Two independent checks (enable_yacd vs enable_yacd_wan_access) and URL-based token auth for the Clash websocket with verbose URL logging.


**Affected files:** `forkop/files/usr/lib/singbox/generator.uc`, `forkop/files/usr/lib/diagnostics/runtime.uc`, `fe-app-forkop/src/forkop/services/socket.service.ts`, `fe-app-forkop/src/forkop/tabs/monitoring/initController.ts`, `luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`

**Dependencies:** None.


**Proposed fix:** Use enable_yacd_wan_access (or a single derived predicate) consistently in both generator and backend. In socket.service, log the origin only (strip query) instead of the full URL; if the Clash controller supports header auth for websockets, avoid the ?token= form.


**Tests needed:** Assert generator/backend use the same enable_* predicate; a frontend test that socket logging does not include the token.


**Risk:** Low.


### Also reported as uci-global#14 (FUTURE): Clash API is reachable on the LAN IP without any secret by default, and turning off WAN access erases the secret although it is still applied on the LAN

**Evidence:** generator.uc:398-413: with enable_yacd=0 the controller is `<service_address>:9090` and no secret is set. With enable_yacd=1 the secret is applied on LAN as well. settings.js:492 `o.depends("enable_yacd_wan_access", "1")` makes LuCI remove yacd_secret_key when WAN access is unchecked (CBIAbstractValue.parse removes inactive options). The UI description says the secret is for WAN access only. The browser dashboard connects to ws://<router>:9090 directly (getClashApiUrl.ts:15-18).


**Proposed fix:** Product decision. Options: always generate a random controller secret stored outside the RO view and served only to admin sessions (the RO dashboard already falls back to RPC polling); and/or keep yacd_secret_key independent of the WAN toggle (retain=true or no depends).


---

<a id="uc-036"></a>

## UC-036 · P3 · S1 — Секрет Clash API выводится в консоль браузера; логгер хранит неограниченный буфер в памяти

**Severity:** P3<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** frontend/logging<br>
**Sources:** frontend-arch#8, uci-global#8<br>
**Original title:** Clash API secret is written to the browser console; the logger keeps an unbounded in-memory buffer<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** socket URLs carry the secret: dashboard/initController.ts:642,678 and monitoring/initController.ts:1932 `/connections?token=${clashApiSecret}`. socket.service.ts:72 `logger.info('[SOCKET]', 'Connected to', url)`, :90 `Disconnected: ${url}`, :95 `Socket error for ${url}`. logger.service.ts:6,16 `private logs: string[] = []; … this.logs.push(message)` has no cap, and getLogs()/download() have no callers. helpers/withTimeout.ts:21 logs every RPC ('[SHELL] … took N ms'), and the runtime poll alone makes about 1-2 RPCs/s.


**Expected:** No secret in any log; bounded memory.


**Actual:** '[INFO] [SOCKET] Connected to ws://<host>:9090/traffic?token=<secret>' is printed on every connect, and logs accumulate forever.


**Impact:** The yacd/Clash secret appears in the admin's devtools console, where it ends up in screenshots and bug-report pastes (invariant 2: secrets never in logs). A long-open Overview or Monitoring tab grows JS heap by an estimated 10-50 MB/day from unread log strings, plus constant console spam.


**Root cause:** The secret travels in the WS URL, and generic logging prints the full URL; the buffer is a leftover debugging feature.


**Affected files:** `fe-app-forkop/src/forkop/services/socket.service.ts`, `fe-app-forkop/src/forkop/services/logger.service.ts`, `fe-app-forkop/src/helpers/withTimeout.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`, `fe-app-forkop/src/forkop/tabs/monitoring/initController.ts`

**Proposed fix:** Log socket URLs without the query string (url.split('?')[0]). Cap the logger buffer to a ring of about 500 lines or drop it, since nothing reads it. Demote the per-RPC timing log to debug and do not buffer it.


**Tests needed:** socket.service test asserting that logged strings never contain 'token='; logger test asserting the buffer is capped.


### Also reported as uci-global#8 (P3): YACD/Clash secret is put unencoded into WebSocket URLs, and the tokenized URL is logged to the console

**Evidence:** dashboard/initController.ts:642 `${getClashWsUrl()}/traffic?token=${clashApiSecret}` and :678 (connections). monitoring/initController.ts:1932. socket.service.ts:58 `failed to construct WebSocket for ${url}`, :72 'Connected to', url and :90 `Disconnected: ${url}` send the secret to console via logger.service.ts. settings.js:484-494 puts no character restriction on yacd_secret_key.


**Proposed fix:** Use encodeURIComponent(clashApiSecret) when building the URLs. Log the URL with the token redacted (strip the query string before logging).


---

<a id="uc-037"></a>

## UC-037 · P3 · S1 — Сгенерированный конфиг sing-box записывается с правами чтения для всех (секреты в /etc/sing-box/config.json и /tmp)

**Severity:** P3<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** security<br>
**Sources:** security#5<br>
**Original title:** Generated sing-box config written world-readable (secrets in /etc/sing-box/config.json and /tmp)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** generate_config writes via write_json_file = common.write_json_file -> fs.writefile with no chmod (core/common.uc:60-62, generator.uc:3264, atomic_write_json_file:77-90 also no chmod); the staged config move (singbox/runtime.uc:925 `mv -f temp_config stage_path`) and save_config_file (:687 `mv -f temp_file config_path`) do not chmod either. Only the sing-box init script install (:431) and ruleset cache (:434) chmod. The section cache (share links, uuids) is written 0600 by subscription/cache.uc, but the main /etc/sing-box/config.json (full outbound secrets) relies on the process umask. Default OpenWrt umask is 022, so config.json is likely 0644 (world-readable).


**Reproduction:** Static; run-time mode not confirmed (no router).


**Expected:** config.json and its /tmp staging copy are chmod 0600 (root-only), consistent with how snapshots and the subscription cache are protected.


**Actual:** The primary generated sing-box config, which contains all outbound credentials, is created with default permissions (world-readable under umask 022) rather than 0600.


**Impact:** Local secret disclosure to non-root users on the router. Medium confidence because it depends on the process umask at runtime, which was not verified on the device.


**Root cause:** write_json_file / atomic_write_json_file / the mv-based save path never chmod the destination, unlike the snapshot and cache writers.


**Affected files:** `forkop/files/usr/lib/singbox/generator.uc`, `forkop/files/usr/lib/singbox/runtime.uc`, `forkop/files/usr/lib/core/common.uc`

**Dependencies:** Confirm the init script does not rely on a group-readable config.


**Proposed fix:** chmod 0600 the config after writing in save_config_file/discard staging and in atomic_write_json_file for the sing-box config path (or set umask 077 in the init script before generation, matching full-uninstall.sh which already does `umask 077`).


**Tests needed:** A test asserting the generated config file mode is 0600 after generate/save.


**Risk:** Low; sing-box runs as root so 0600 is fine.


---

<a id="uc-038"></a>

## UC-038 · P3 · S1 — Валидатор допускает доступ к Clash API из WAN с пустым секретом (UI это запрещает, бэкенд — нет)

**Severity:** P3<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** uci-global<br>
**Sources:** uci-global#13<br>
**Original title:** Validator allows Clash API WAN access with an empty secret (UI prevents it, backend does not)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** generator.uc:398-413 binds external_controller to 0.0.0.0:9090 when enable_yacd && enable_yacd_wan_access, and adds 'secret' only if non-empty. validator.uc validate_runtime_config (1640-1673) has no YACD checks. settings.js:484-494 relies on LuCI rmempty=false to block the empty secret in the form only.


**Reproduction:** `uci set forkop.settings.enable_yacd=1; uci set forkop.settings.enable_yacd_wan_access=1; uci delete forkop.settings.yacd_secret_key; uci commit; forkop reload` gives external_controller 0.0.0.0:9090 with no secret.


**Expected:** Rejected with a clear message.


**Actual:** Accepted.


**Impact:** A config produced by CLI, a snapshot restore or a hand edit with WAN access on and no secret starts sing-box with an unauthenticated Clash API on all interfaces (remote selector switching, connection listing and closing). Invariant 18 (fail closed) is not enforced in the backend.


**Root cause:** The security constraint is only enforced in the UI.


**Affected files:** `forkop/files/usr/lib/config/validator.uc`

**Proposed fix:** In validator.uc, fail validation when enable_yacd=1 && enable_yacd_wan_access=1 && trim(yacd_secret_key)==''.


**Tests needed:** validate-runtime-fixture case with WAN access and no secret must fail.


**Risk:** Very low.


---

<a id="uc-039"></a>

## UC-039 · P3 · S1 — ИЗВЕСТНО (HW-проверка, P3): Overview в режиме только чтения показывает теги outbound, так как get_readonly_config_sections отбрасывает имена дочерних элементов

**Severity:** P3<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** get_readonly_config_sections RO contract<br>
**Sources:** cli-contract#5, ui-css-a11y-i18n#8<br>
**Original title:** KNOWN (hardware P3): read-only Overview shows outbound tags because get_readonly_config_sections drops child item names<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** diagnostics/runtime.uc:814-815 `let safe_keys = [ "action", "enabled", "interface", "interfaces", "label", "section", "sort_by_latency", "urltest_enabled", "urltests", "priority_groups" ];` has no `name`/`display_name`. The FE hydrates interface names from the child `section_interface.name` (fe-app-forkop/src/forkop/methods/custom/getDashboardSections.ts:272-276 `next.interfaces = interfaceItems.map((item) => item.name || '')`), and the backend stores the interface there (config/connections.uc:321 `child_values(section, "section_interface", "name", "")`). urltest display names come from the same place (getDashboardSections.ts:283 `display_name: item.name || item.display_name`).


**Expected:** Interface and group display names are visible to RO; they are not secrets.


**Actual:** RO child items carry only .name/.type/section.


**Impact:** The RO Overview/dashboard shows 'main-interface-1-out' where the admin sees 'awg1'; URLTest and priority group names degrade to ids as well. This is the hardware-report item.


**Root cause:** The allowlist was designed for top-level rules and missed child item display fields.


**Affected files:** `forkop/files/usr/lib/diagnostics/runtime.uc`

**Proposed fix:** Allow `name` (and `display_name`) only for the .type values section_interface, urltest, priority_group and priority_level in get_readonly_config_sections. Never allow them globally (subscription_url/server children must stay minimal).


**Tests needed:** A test for the get_readonly_config_sections fixture: section_interface.name present, subscription_url.url absent.


**Risk:** Low. Interface/group names are not credentials.


### Also reported as ui-css-a11y-i18n#8 (P3): Read-only Overview shows raw outbound tags because the read-only config allowlist drops the child 'name' option (known HW item)

**Evidence:** forkop/files/usr/lib/diagnostics/runtime.uc:814-815 safe_keys = [ "action", "enabled", "interface", "interfaces", "label", "section", "sort_by_latency", "urltest_enabled", "urltests", "priority_groups" ] ('name' missing). The interface name lives in the section_interface child option 'name' (config/connections.uc:321 child_values(section, "section_interface", "name", "")). The read-only role has no uci read (acl.d: only luci-app-forkop-admin has read.uci ['forkop']), so methods/custom/getConfigSections.ts:6-11 falls back to getReadonlyConfigSections. getDashboardSections.ts:272-276 then builds 'next.interfaces = interfaceItems.map((item) => item.name || \'\').filter(Boolean)', which is empty, and urltest display names (:284 item.name) are lost too


**Proposed fix:** In get_readonly_config_sections, copy 'name' (and 'display_name') only for the child types section_interface, urltest, priority_group and priority_level. These are interface names and user labels, not secrets. Keep excluding links, URLs and credentials


---

<a id="uc-040"></a>

## UC-040 · P3 · S2 — Временный сбой бэкенд-валидатора кэшируется на время жизни страницы как невалидная стратегия и блокирует сохранение

**Severity:** P3<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** frontend/rule editor error handling<br>
**Sources:** frontend-arch#3<br>
**Original title:** A transient backend-validator failure is cached for the page lifetime as an invalid strategy and blocks Save<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** section.js:5098-5110 buildNfqwsRemoteValidationFallback returns `{ valid: false, message: _("Backend validation failed: %s")... }`; :5150-5156 `.catch((error) => cacheNfqwsRemoteValidation(normalized, buildNfqwsRemoteValidationFallback(error)))`; :5124-5126 every later call returns the cached entry; the same pattern is used for nfqws2 (~5578) and byedpi (~5990). analyzeNfqwsStrategy (5482-5505) and parseStrategyWithRemoteValidation reject Save when valid !== true.


**Expected:** A transient failure is retried; only real parser verdicts are cached.


**Actual:** The transport error is stored as {valid:false} under the normalized strategy and reused until reload.


**Impact:** One rpcd timeout or 'Access denied' while the user types a valid strategy marks it invalid until the page reloads. Save is refused with 'Backend validation failed: …' shown as an input error, and retrying cannot help because the result is cached. A backend failure is presented as invalid input.


**Root cause:** The catch branch feeds the failure into the same cache as successful verdicts.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`

**Proposed fix:** Cache only structured verdicts parsed from backend stdout. On transport failure (fs.exec rejects or unparsable output), do not cache. Mark the field 'Backend validation unavailable, retry' (warning), keep Save blocked (fail closed), and re-run the RPC on the next validation or Save.


**Tests needed:** A node test stubbing fs.exec to reject once and then resolve {valid:true}: the second validation must call the backend again and accept.


---

<a id="uc-041"></a>

## UC-041 · P3 · S2 — Скрытые опции каскада сохраняются, но их нельзя очистить из LuCI, поэтому ошибки валидации невозможно исправить

**Severity:** P3<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#5<br>
**Original title:** Hidden cascade options are retained but cannot be cleared from LuCI, so validation failures cannot be fixed<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-22

**Evidence:** section.js:7316-7366: outbound_detour_enabled/outbound_detour_section depend on action "__internal_hidden__" with retain=true (hidden since c784c8ca 2026-08-25). validator.uc:524-560 fails with 'Outbound cascade is supported only for Connection rules...', '...references disabled rule...' and '...references missing rule... disable cascade connection'. handleRemove (section.js:7852-7859) does not clear references to a deleted rule.


**Reproduction:** CLI: set forkop.a.outbound_detour_enabled=1, outbound_detour_section=b. In LuCI disable rule b and Save & Apply: the apply fails with the cascade message, and no UI control removes it.


**Expected:** Every validation error about a rule option can be resolved from the rule editor.


**Actual:** An unchanged or changed modal save keeps outbound_detour_enabled=1 (retain). Changing the action to bypass leaves it set, and validate_outbound_detours_rows aborts the apply.


**Impact:** Users with a cascade configured before 1.x hid it (or via CLI) get a failed apply after disabling or deleting the transit rule, or after changing the source rule's action away from Connection. The error tells them to 'disable cascade connection', a control that no longer exists in the UI. Only the CLI can fix it.


**Root cause:** The feature was hidden from the UI while its backend validation constraints stayed. The retain fix preserves values that the user can no longer see or clear.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `forkop/files/usr/lib/config/validator.uc`

**Proposed fix:** Product choice: either re-expose Cascade in the Advanced step, or clear outbound_detour_* when the action leaves Connection and when the target rule is deleted. The validator message should then match the available UI.


**Tests needed:** Validator + UI round trip: cascade source rule whose target is deleted, or whose action changes, can be fixed via the UI.


**Risk:** Low.


---

<a id="uc-042"></a>

## UC-042 · P3 · S2 — Устаревшие списковые опции remote_domain_lists/remote_subnet_lists/local_* не видны в LuCI; валидатор и генератор трактуют их по-разному

**Severity:** P3<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#6<br>
**Original title:** Legacy list options remote_domain_lists/remote_subnet_lists/local_* are invisible in LuCI; validator and generator disagree on them<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-6

**Evidence:** The backend consumes remote lists: generator.uc:2842-2848, 3016-3031 add_remote_list_rulesets; nft/apply.uc:636; components/updates.uc:3482-3576; migration.uc:1386 rewrites their mirror host. section.js never declares them, and the conditions summary (section.js:3802-3824) does not count them. validator.uc:1343-1351 dns_action_has_domain_matchers ignores remote_domain_lists. generator.uc:3103-3112 unsupported_matcher_key fails generation for local_domain_lists/local_subnet_lists/subnet/subnet_text, and the validator does not check these. tests/config_contract_matrix.sh:94 expects local_domain_lists/remote_* to be 'supported or migrated'.


**Reproduction:** Fixture rule {action:dns, dns_server:1.1.1.1, remote_domain_lists:[url]} gives a validation failure. Fixture rule with local_domain_lists passes the validator, then generation fails with 'section has unsupported matcher'.


**Expected:** Every option the backend honours is visible in the UI, and the validator and generator agree.


**Actual:** gen_check.sh dns_remote_only: validator FAIL 'DNS rule must contain at least one domain condition'. Harness: the editor shows no conditions for remote-list rules.


**Impact:** Migrated podkop users have rules whose conditions the UI shows as '—'. A DNS rule that uses only remote_domain_lists is rejected by the validator even though the generator supports it. A rule with local_domain_lists makes generation fail and cannot be fixed from the UI. These options also contribute to the source_ip_cidr loss (P1 finding).


**Root cause:** The podkop-era options were kept for runtime compatibility without a migration or a UI representation.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `forkop/files/usr/lib/config/validator.uc`, `forkop/files/usr/lib/config/migration.uc`, `forkop/files/usr/lib/singbox/generator.uc`

**Proposed fix:** Product choice: migrate remote_* into domain_ip_lists/rule_set equivalents (and local_* into supported references, or disable the rule with a history entry), or show them read-only in the editor with a remove button. At minimum count remote_domain_lists in dns_action_has_domain_matchers, and make the validator reject local_* with a clear message.


**Tests needed:** Validator fixture for a DNS rule with only remote_domain_lists. Validator fixture with local_domain_lists producing a validation error, not a generator failure.


**Risk:** Migration changes persistent format and needs an adapter/test.


---

<a id="uc-043"></a>

## UC-043 · P3 · S2 — Устаревшие условия text-mode / *_text и устаревший `list interfaces`: UI показывает или сохраняет не те значения, которые использует бэкенд

**Severity:** P3<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#8<br>
**Original title:** Legacy text-mode / *_text conditions and legacy `list interfaces`: UI shows or keeps different values than the backend uses<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-6

**Evidence:** Backend: routing/rule_conditions.uc:21-39 uses *_text when `<key>_text_mode`/`conditions_text_mode` is set, otherwise the list; generator.uc:2906-2911 and nft rule_ports_csv_value merge `ports` + `ports_text`. UI: addDynamicConditionField/addLocalDeviceSubnetDynamicField load the list when non-empty and ignore _text/_text_mode (section.js:6472-6486, 6510-6524); on write they unset `_text` and `_text_mode`. addTextConditionField load prefers ip_cidr over ip_cidr_text (section.js:6560-6573). SettingsDynamicList.remove for childType unsets this.option (section.js:1430-1439), which for InterfaceSettingsDynamicList is the legacy `interfaces` list that connections.interfaces still reads (connections.uc:318-330).


**Reproduction:** Fixture rule with ports:[443], ports_text:'80'. Edit ports in the UI: port 80 matching disappears.


**Expected:** The UI displays and preserves the effective values.


**Actual:** Harness: ip_text_mode_edited gives ip_cidr list+edit, with ip_cidr_text '8.8.8.8' (the effective value) removed. ports_text_edited removes ports_text '80' (effective, merged). legacy_interfaces_list: `interfaces: ["awg0"] -> undefined` on an unchanged save.


**Impact:** Legacy configs (CLI or old podkop-style) show values in the editor that are not the effective ones. After any edit, the previously effective text values are dropped. A connection that relied on a legacy `list interfaces` (no section_interface children) loses its interface on any modal save.


**Root cause:** The UI and backend legacy readers use different precedence rules. Podkop migration converts only domain/ip_cidr text forms, and forkop-native configs are never migrated.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `forkop/files/usr/lib/config/migration.uc`

**Proposed fix:** Make the UI loaders follow the backend precedence (text_mode, then _text, then list; merge ports and ports_text), or migrate these legacy forms once into the current representation. In the interfaces widget remove() do not unset a legacy list the widget never loaded, or migrate it into children.


**Tests needed:** Round-trip cases for _text_mode, ports_text and legacy interfaces.


**Risk:** Legacy-only population. Low.


---

<a id="uc-044"></a>

## UC-044 · P3 · S2 — Тег URLTest outbound включает зависящий от позиции анонимный UCI id групп URLTest, созданных из UI

**Severity:** P3<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#10<br>
**Original title:** URLTest outbound tag embeds the position-dependent anonymous UCI id of UI-created URLTest groups<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** generator.uc:1306-1311 `outbound_tag(section_name + "-urltest-" + urltest_id)` with urltest_id = child .name (connections.uc:340-350). UI URLTest children have no createId, unlike priority_group randomPriorityGroupId (section.js:2243-2255, 7248). libuci anonymous names are cfg<index><typehash>. scratch anon_id2.sh: cfg022898 becomes cfg032898 after inserting one section before it; value edits did not change it.


**Reproduction:** Create a URLTest in rule B, select it in the dashboard selector, delete a rule above B, apply: the selection resets.


**Expected:** Stable tags for user-created groups.


**Actual:** The tag changes whenever the file position of the anonymous section changes.


**Impact:** Deleting or reordering an earlier section changes every later URLTest tag. sing-box cache_file (generator.uc:499-503) then no longer finds the stored selector choice, and dashboard/monitoring continuity keyed by tag resets. The user's chosen group or server silently reverts to the default.


**Root cause:** The anonymous section id is used as a persistent identifier.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `forkop/files/usr/lib/config/migration.uc`

**Proposed fix:** Create named URLTest children (like priority groups, e.g. `ut_<random>`), and optionally migrate existing anonymous ones to stable names.


**Tests needed:** Generator tag stability test across section insertion/deletion.


**Risk:** Renaming existing groups changes tags once; do it in a migration.


---

<a id="uc-045"></a>

## UC-045 · P3 · S2 — Вложенные модальные окна элементов сразу пишут в UCI; закрытие модального окна правила их не откатывает

**Severity:** P3<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#11<br>
**Original title:** Nested item modals write UCI immediately; dismissing the rule modal does not revert them<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** showChildItemSettingsModal for existing children calls `applyChildItemSettings(value, diff)` directly (section.js:3262-3272). showRuleSetSettingsModal writes rule_set/rule_set_with_subnets directly (section.js:3638-3644). The LuCI modal map shares parent.data, and GridSection.handleModalCancel only removes an added section (form.js:4030-4041).


**Reproduction:** Open a rule, open a subscription source's settings, change the interval, Save the item modal, Dismiss the rule modal: the change is listed in unsaved changes.


**Expected:** Dismiss discards everything done in the rule modal.


**Actual:** Direct uci.set during a nested modal save.


**Impact:** 'Dismiss' leaves staged changes that are applied on the next Save & Apply without the user having confirmed them. Combined with the rule-set bug, the Built-in #2 deletion persists even after Dismiss.


**Root cause:** Direct UCI writes bypass the modal's parse/cancel lifecycle.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`

**Proposed fix:** Stage nested edits in the option's pendingChildSettings and apply them in the parent option's write(), or snapshot and revert on cancel.


**Tests needed:** Harness: nested edit followed by cancel leaves UCI unchanged.


**Risk:** Low.


---

<a id="uc-046"></a>

## UC-046 · P3 · S2 — Виджет 'Built-in rule sets #2' показывается для DNS-правил, но его выбор молча отбрасывается

**Severity:** P3<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#12<br>
**Original title:** Built-in rule sets #2 widget is shown for DNS rules but its selection is silently discarded<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** secondaryRulesetOption has no depends (section.js:7650-7673). dnsRuleSetOption.remove → writeDnsRulesetReferences(section_id, []) → `uci.unset(UCI_PACKAGE, section_id, "rule_set_with_subnets")` (section.js:6792-6796, 7727-7729). validator.uc:1364-1365 rejects rule_set_with_subnets on DNS rules with a message about 'Include IP addresses and subnets'.


**Reproduction:** DNS rule, pick Valve in Built-in rule sets #2, Save, reopen: it is empty.


**Expected:** The widget is hidden or disabled for DNS rules.


**Actual:** Harness dns_secondary_selected: override secondary_rule_sets=['valve'] leaves rule_set_with_subnets unset after save.


**Impact:** The UI accepts a selection that is thrown away on save without notice.


**Root cause:** The widget has no action dependency.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`

**Proposed fix:** Add dependsOnRoutingAction(secondaryRulesetOption), so it is hidden for dns (with retain so the shared storage is not erased).


**Tests needed:** dns_action_ui.sh assertion.


**Risk:** Low.


---

<a id="uc-047"></a>

## UC-047 · P3 · S4a — Обнаружение поставленного в очередь reload в режиме apply autotune не срабатывает: маркер pending имеет разрешение в одну секунду

**Severity:** P3<br>
**Stage:** S4a (Аварийный этап: fail-closed restore при reload в очереди (P1))<br>
**Area:** config/snapshots.uc apply mode (Stage 5)<br>
**Sources:** snapshots#4<br>
**Original title:** Queued-reload detection in autotune apply mode fails because the pending marker has one-second resolution<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** snapshots.uc:310-313 `pending_stamp()` = `mtime:size:content`. The marker writers use second resolution: initd.uc:249 and state.uc:252 `"reason=" + reason + "\nupdated_at=" + current_epoch()`. A second queued reload within the same second rewrites an identical marker, so reload_ran(true) returns true. tests/autotune_apply.sh:140 hides this: its stub writes `reload_busy $(date +%s%N)` (nanoseconds).


**Reproduction:** scratch/audit-a10\apply_queued.sh


**Expected:** A second queued reload is detected: needs_attention with the guard kept, as tests/autotune_apply.sh:652-655 asserts.


**Actual:** Reproduced 5/5 with the real initd.uc queueing: snapshots.uc apply -> {status:'recovered', reason:'target_reload_failed', guard:'inactive'} with 0 runtime reloads.


**Impact:** Candidate reload queued, then rollback reload queued in the same second: guarded_replace returns 'recovered', releases the restore guard and sets LKG to the before-autotune snapshot, though no reload ran and one is still queued. apply.uc then records phase 'failed' (reload_failed_recovered) instead of needs_attention. The final state usually converges (the pending reload applies the pre-apply config), but the 'q q -> needs_attention with the guard kept' guarantee from the test does not hold in production.


**Root cause:** The detection relies on the marker changing, but the marker content and mtime only change once per second.


**Affected files:** `forkop/files/usr/lib/service/initd.uc`, `forkop/files/usr/lib/service/state.uc`, `forkop/files/usr/lib/config/snapshots.uc`, `tests/autotune_apply.sh`

**Proposed fix:** Add a unique nonce to the pending marker (for example pid plus clock()[1]) in initd.uc and state.uc mark_pending_reload, or compare inode+nonce. Make the test stub write the production format.


**Tests needed:** Change the autotune_apply.sh reload stub to the production marker format and keep the 'q q' assertion. Add a unit test that two mark_pending_reload calls produce different stamps.


---

<a id="uc-048"></a>

## UC-048 · P3 · S0 — Фильтры путей backend CI пропускают изменения в luci-app-forkop/** и fe-app-forkop/**, хотя 31 backend-тест (включая границу RO ACL) читает эти файлы

**Severity:** P3<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** CI triggers<br>
**Sources:** tests#1<br>
**Original title:** Backend CI path filters skip changes to luci-app-forkop/** and fe-app-forkop/**, although 31 backend tests (including the ACL read-only boundary) read those files<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-5

**Evidence:** .github/workflows/backend-ci.yml:7-18 and :20-31 'paths:' list forkop/files/**, forkop/Makefile, build.sh, install.sh, ops/hosting/**, ops/mirror/**, tests/**, and nothing from luci-app-forkop/ or fe-app-forkop/. frontend-ci.yml triggers only on 'fe-app-forkop/**' and runs vitest only. 'grep -l luci-app-forkop tests/*.sh' gives 31 tests, among them acl_boundary.sh (rpcd ACL: read role must not exec mutating commands), luci_readonly_view.sh, luci_readonly_command_guard.sh, luci_localization.sh and package_contract.sh.


**Expected:** Every file a backend test asserts on triggers that test in PR CI.


**Actual:** Changes to the LuCI views, ACL or translations trigger no backend test.


**Impact:** Suppose a PR edits only luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json and grants the read role a mutating exec pattern. No workflow runs acl_boundary.sh, and push-to-main is filtered the same way, so the invariant-1 regression is caught only when a release tag is built.


**Root cause:** The path filters were written when backend tests only covered forkop/files. Later tests started asserting on LuCI views and the ACL, but the filters were never updated.


**Affected files:** `.github/workflows/backend-ci.yml`

**Proposed fix:** Add 'luci-app-forkop/**' and 'fe-app-forkop/src/**' (or at least the ACL, menu, po and view paths) to both the pull_request and push path lists of backend-ci.yml.


**Tests needed:** A dry-run PR touching only the ACL JSON must start Backend CI.


---

<a id="uc-049"></a>

## UC-049 · P3 · S0 — list_cache.sh зависит от хоста: TMP_SING_BOX_FOLDER не изолирован, а кейс '/tmp capacity' предполагает, что на ФС хоста свободно меньше ~931 GiB

**Severity:** P3<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** test portability<br>
**Sources:** tests#2<br>
**Original title:** list_cache.sh depends on the host: TMP_SING_BOX_FOLDER is not isolated and the '/tmp capacity' case assumes the host filesystem has less than ~931 GiB free<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-9

**Evidence:** tests/list_cache.sh:229-238: quota_cmd sets TMP_RULESET_FOLDER etc. but never TMP_SING_BOX_FOLDER. forkop/files/usr/lib/core/constants.uc:49 defaults it to "/tmp/sing-box". components/updates.uc:933-940: runtime_list_generation_has_capacity() does 'ensure_dir(TMP_SING_BOX_FOLDER)' (mkdir -p) and 'df -Pk TMP_SING_BOX_FOLDER'. tests/list_cache.sh:280: 'if FORKOP_LIST_DOWNLOAD_MIN_FREE_BYTES=999999999999 quota_cmd commit-runtime-list-generation; then fail'. WSL 'df -Pk /tmp' reports 993325472 KB available (about 1.017e12 bytes), which is more than the reserve, so the commit succeeds and the test fails.


**Expected:** The test is hermetic: capacity is simulated and all paths live under WORK_DIR.


**Actual:** The capacity check runs against the host /tmp/sing-box; the rejection case passes or fails depending on host disk size.


**Impact:** False failure on any host whose /tmp filesystem has more than ~931 GiB free (WSL ext4 vhdx, large dev disks). The test also creates /tmp/sing-box on the host and measures the host /tmp instead of its private WORK_DIR, so it passes only under the runner's tmpfs /tmp or on CI's small disk.


**Root cause:** The test assumed 999,999,999,999 bytes could never be free, and relied on the production default path /tmp/sing-box.


**Affected files:** `tests/list_cache.sh`

**Proposed fix:** Two parts: (1) set TMP_SING_BOX_FOLDER="$WORK_DIR/tmp-sing-box" in quota_cmd; (2) keep the foreign uncommitted fix (a 'df' stub reporting 4096 KB available, plus a 2^62 reserve for the real-df case). The module needs no change.


**Tests needed:** Run list_cache.sh with --no-isolate on WSL (big /tmp) and inside the runner; both must pass, and /tmp/sing-box must not be created.


---

<a id="uc-050"></a>

## UC-050 · P3 · S0 — config_contract_matrix требует историю git и может делать fetch из origin, записывая тег в репозиторий разработчика

**Severity:** P3<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** test portability / side effects<br>
**Sources:** tests#3<br>
**Original title:** config_contract_matrix needs git history and may fetch from origin, writing a tag into the developer's repository<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** tests/config_contract_matrix.sh:23-38 ensure_stable_ref(): 'git -C "$ROOT_DIR" rev-parse --verify "$STABLE_REF^{commit}"' then 'git -C "$ROOT_DIR" fetch --force --depth=1 origin "refs/tags/$STABLE_REF:refs/tags/$STABLE_REF"'; :52 'git -C "$ROOT_DIR" archive "$STABLE_REF" | tar -x'. In the runner (network namespace, worktree .git pointing to a Windows path) it fails with 'stable baseline is unavailable: tag 0.7.19.9 or commit 68d516e8...'.


**Expected:** A hermetic contract test with no git or network access.


**Actual:** Result depends on local git objects and network, with a side effect on refs/tags.


**Impact:** The test fails in git worktrees read from WSL, in tarball checkouts and offline. When online it contacts the network and silently creates a tag in the shared repository, a state-changing git operation on a workstation where several agents work in parallel.


**Root cause:** The stable baseline is taken from git history at run time instead of from a committed fixture.


**Affected files:** `tests/config_contract_matrix.sh`, `tests/helpers/config_contract_matrix.js`

**Proposed fix:** Vendor the few stable-release files the matrix reads (config template and legacy view/option inventory of 0.7.19.9) under tests/fixtures/stable-0.7.19.9, and use them when FORKOP_STABLE_REPO is not given. Remove the 'git fetch' fallback, or make it opt-in (FORKOP_TEST_ALLOW_FETCH=1).


**Tests needed:** Run the test from a plain file copy (no .git) in the network-isolated runner; it must pass.


---

<a id="uc-051"></a>

## UC-051 · P3 · S0 — Гонки fork/exec и фиксированных sleep в тестах (чужой незакоммиченный diff исправляет 7 файлов, остальные остаются)

**Severity:** P3<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** flaky tests<br>
**Sources:** tests#4<br>
**Original title:** Fork/exec and fixed-sleep races in tests (the foreign uncommitted diff fixes 7 files; others remain)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-9

**Evidence:** The foreign diff (git -C forkop diff -- tests/) replaces 'sleep 1; [ -s child.pid ]' with polling until /proc/<pid>/cmdline shows the exec'd command (process_identity.sh, dpi_runtime_snapshot.sh:33). It also replaces 1-second polling loops and fixed sleeps with 0.1 s polling (components_updater_job.sh:399-407, initd_state.sh:149-152, full_uninstall_cleanup.sh:47-51, ui_runtime_job.sh:288 'sleep 2'). Remaining in committed tests: autotune_scheduler.sh:128-130 'flock "$FORKOP_AUTOTUNE_STATE_DIR/worker.lock" sleep 3 & ... sleep 0.3; if manager run all ...; then fail "a second worker must be refused"'; dpi_runtime_snapshot.sh:233-236 (start supervisor 'new', record, 'sleep 1', then restore); dpi_runtime_snapshot.sh:63.


**Expected:** Tests synchronise on state (lock held, cmdline exec'd, file present) with a bounded timeout.


**Actual:** Results depend on scheduler timing (a 0.3 s or 1 s fixed wait).


**Impact:** Under load (parallel runner, slow CI), flock may not hold the lock within 0.3 s, so the 'refused' assertion fails, or a PID is recorded while it still shows the parent's cmdline, so the identity check rejects it. The result is intermittent false failures that erode trust in the suite. The fork/exec window also means that in production, a stop right after a spawn sees a non-matching cmdline and (correctly, per invariant 13) refuses to signal.


**Root cause:** Fixed sleeps assume a background process reaches a state within a fixed time; for bash '&' jobs, $! is known before exec.


**Affected files:** `tests/autotune_scheduler.sh`, `tests/dpi_runtime_snapshot.sh`, `tests/process_identity.sh`, `tests/components_updater_job.sh`, `tests/initd_state.sh`, `tests/full_uninstall_cleanup.sh`, `tests/ui_runtime_job.sh`

**Proposed fix:** Wait for the observable condition instead of sleeping: 'until ! flock -n "$lock" true; do sleep 0.05; done' before the refusal check; reuse the diff's wait_cmdline helper (move it into a shared tests/helpers/wait.sh) for every '&' + record site. Commit the foreign diff after review.


**Tests needed:** tests/runner/run.sh --repeat 20 autotune_scheduler dpi_runtime_snapshot process_identity under load (-j 64) must be stable.


---

<a id="uc-052"></a>

## UC-052 · P3 · S0 — Реальный nft доступен, но не используется: все заглушки nft принимают любой синтаксис, а nft_apply.sh тестирует только режим argv, хотя production всегда применяет batch-файл

**Severity:** P3<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** stub divergence / A28<br>
**Sources:** tests#6, nft#13<br>
**Original title:** Real nft is available but unused: every nft stub accepts any syntax, and nft_apply.sh only tests argv mode while production always applies a batch file<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** tests/nft_apply.sh:72-95, nft_atomic_apply.sh:12-19 and helpers/autotune_stubs.sh:72-119 accept any 'nft -f' input (only exit codes are simulated). nft_apply.sh never sets FORKOP_NFT_BATCH_FILE, while service/lifecycle.uc:307 always does ('FORKOP_NFT_BATCH_FILE: nft_candidate_batch_file'); in that mode nft/apply.uc:110-121 run_args() joins argv with spaces into a batch line. WSL has nftables 1.0.9, and 'unshare -rn nft -c -f' works without privileges: the 137-line production batch and the pinned probe/release batches pass both check and real apply (scratch/audit-tests/nft_batch_real_check.sh, probe_batch_check.sh).


**Expected:** Generated nft text is checked by the real parser wherever that costs nothing.


**Actual:** nft syntax and semantics are validated only by string matching against stubs.


**Impact:** A grammar error in a newly generated rule path (not pinned verbatim by an expect_line/assert_contains) would pass every test and surface only on the router as nft_setup_failed or a failed reload. The argv-to-batch-line conversion path used in production is not exercised by the large nft_apply.sh suite.


**Root cause:** Stubs were designed for hosts without nft privileges; unprivileged netns validation was not considered.


**Affected files:** `tests/nft_apply.sh`, `tests/nft_atomic_apply.sh`, `tests/autotune_isolation.sh`, `tests/runner/run.sh`, `tests/nft_real.sh`

**Proposed fix:** Add an optional lane or test (skipped with an explicit 'SKIP: nft/unshare unavailable' message only when the tools are missing) that runs the nft_apply.sh fixtures with FORKOP_NFT_BATCH_FILE set and validates the batch with 'unshare -rn nft -c -f'. Also apply it for real in the throwaway netns, then run the switch/release/guard batches against it. In CI, use 'sudo unshare -n' if unprivileged user namespaces are restricted.


**Tests needed:** nft_batch_real_check-style test covering the runtime base, output/provider/priority rules, set chunks, the DPI transition guard, the autotune probe/switch/release batches, and the '-j list' parsers fed real nft JSON (dpi_guard_rule_mark, probe_counters).


### Also reported as nft#13 (CLEANUP): No test exercises generated nft batches against real nft; stubs only log argv

**Evidence:** tests/nft_atomic_apply.sh:12-20 stub `nft` prints $* and exits 0. The runner (tests/runner/README.md) already gives each test a private user+net namespace, and WSL has nft 1.0.9. The scratch scripts real_nft.sh, real_probe.sh and guard_json.sh ran the rendered candidate, the rollback round trip, the probe batch with atomic replace, the bypass contract and the DPI guard verifier against real nft under `unshare -rn`. This surfaced the nft-version-dependent guard JSON finding.


**Proposed fix:** Add tests/nft_real.sh based on the scratch scripts (candidate -c/-f, rollback round trip, guard ensure/state, probe batch plus contract evaluate), skipped when `nft` or unshare is unavailable.


---

<a id="uc-053"></a>

## UC-053 · P3 · S3 — Очистка осиротевших процессов изоляции может отправить SIGTERM/SIGKILL чужому nfqws с совпадающей сигнатурой до отказа по queue_in_use

**Severity:** P3<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A11 isolation (invariant 13)<br>
**Sources:** autotune#9<br>
**Original title:** Isolation orphan cleanup can SIGTERM/SIGKILL a foreign nfqws that matches the signature, before the queue_in_use refusal<br>
**Confidence:** low<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** isolation.uc:445-459 orphans() selects any process whose exe == NFQWS, argv[1] = --qnum in 4600..4607, prefix [NFQWS, --qnum=N, --dpi-desync-fwmark=DESYNC_MARK]; isolation.uc:678-683 stop_identified(orphan, prefix, false) sends TERM then KILL; isolation.uc:791 preflight runs teardown(read_active()) before queue_check (isolation.uc:802)


**Expected:** Foreign processes are never signalled; the run refuses


**Actual:** A signature match is killed as an orphan


**Impact:** A process that is not ours, e.g. an admin's manual `/opt/zapret/nfq/nfqws --qnum=4600 --dpi-desync-fwmark=0x40000000 ...`, is killed by the next autotune run or cleanup instead of making the run refuse with queue_in_use. Low likelihood, but it violates invariant 13.


**Root cause:** Orphan identification by prefix signature only


**Affected files:** `forkop/files/usr/lib/autotune/isolation.uc`

**Dependencies:** None


**Proposed fix:** Treat as ours only processes recorded in active.json or the pidfiles, or unrecorded ones whose full argv exactly equals nfqws_argv(catalog opt, null, queue) for some catalog candidate. For any other signature match, refuse the run (queue_in_use) rather than signal it.


**Tests needed:** autotune_isolation.sh: a foreign stub nfqws on queue 4600 with extra args not from the catalog -> the run refuses and the process survives


**Risk:** Low


---

<a id="uc-054"></a>

## UC-054 · P3 · S3 — Инверсия порядка блокировок: start берёт reload.lock, затем subscription-update.lock, обновление подписки — в обратном порядке (латентно, пока есть баг detached-start)

**Severity:** P3<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A7 locks<br>
**Sources:** process-locks#7<br>
**Original title:** Lock-order inversion: start takes reload.lock then subscription-update.lock, subscription update takes them in the opposite order (latent while the detached-start bug exists)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/initd.uc:604 start acquires RELOAD_LOCK_DIR (wait 30 s), then `forkop start` -> lifecycle.uc:892 acquire_start_subscription_update_lock (637-645, wait 300 s). components/updates.uc:4335 subscription update acquires SUBSCRIPTION_UPDATE_LOCK_DIR, then :4342 RELOAD_LOCK_DIR (wait 300 s when force=true, as in the UI 'update now' and async job).


**Reproduction:** Code reading; the timeouts bound the stall.


**Expected:** A single acyclic lock order.


**Actual:** Two lock orders exist between reload.lock and subscription-update.lock.


**Impact:** Once the start holds reload.lock with a live owner, a forced subscription update started just before the start leaves both processes waiting on each other for up to 300 s. The subscription update then fails (marking a pending 'reload_busy'), and the start is delayed by about 5 minutes. Today the detached-start bug hides this by letting the subscription update steal reload.lock instead.


**Root cause:** Each module picked its own acquisition order; no documented global order.


**Affected files:** `forkop/files/usr/lib/components/updates.uc`, `forkop/files/usr/lib/service/lifecycle.uc`

**Dependencies:** Must land with the detached-start owner fix.


**Proposed fix:** Use one global order, reload.lock before subscription-update.lock: in subscription_update_common acquire reload.lock first, or make start's subscription-lock acquisition try-once and fail fast with deferral.


**Tests needed:** A test that runs a forced subscription update holding the subscription lock while a start holds reload.lock, and asserts no multi-minute wait (after the detached-start fix).


**Risk:** Low.


---

<a id="uc-055"></a>

## UC-055 · P3 · S3 — flock воркера autotune наследуют все потомки, включая перезапущенные reload при apply супервизоры zapret; после падения менеджера autotune занят, а мёртвый запуск числится активным

**Severity:** P3<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A7 locks / autotune<br>
**Sources:** process-locks#8<br>
**Original title:** Autotune worker flock is inherited by every descendant, including production zapret supervisors restarted by an apply's reload; after a manager crash autotune stays busy and the dead run shows as running<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** autotune/manager.uc:218-223 `let handle = fs.open(path, "a"); handle.lock(wait ? "x" : "xn")` (no close-on-exec); 588-592 and 719-723 hold it across run_locked/manual_apply_locked, which spawn isolation.uc and apply.uc (443). apply.uc -> snapshots.uc apply -> `/etc/init.d/forkop reload` -> lifecycle switch_dpi_runtime (lifecycle.uc:1236-1247) -> nfqueue start_rule `sh -c "ucode ... supervisor ... 1000>&- & echo $!"` (nfqueue/runtime.uc:441-451): only fd 1000 is closed. manager.uc:88-96 worker_view infers a crash from a free flock. Repro of the mechanism: scratch/audit-a6a7/flock_inherit.sh and flock_inherit2.sh printed `holder died without unlock, descendant alive: held`, while the normal path with an explicit unlock is released.


**Reproduction:** wsl bash scratch/audit-a6a7/flock_inherit2.sh (mechanism only).


**Expected:** Lock lifetime is bound to the manager run only.


**Actual:** Production daemons inherit and keep the autotune worker flock when the manager dies abnormally.


**Impact:** If the manager (cron if-due or async job) is SIGKILLed or OOM-killed during an apply after the reload restarted zapret, the long-lived supervisors and nfqws keep worker.lock. Every autotune run, apply and job then returns busy 'autotune_worker_running', and the status keeps showing the dead run as running (crash recovery in begin_run never runs) until zapret is restarted or the router reboots. This presents a stale state as observed (invariant 15).


**Root cause:** flock on an inheritable file descriptor held across process spawns.


**Affected files:** `forkop/files/usr/lib/autotune/manager.uc`

**Dependencies:** None.


**Proposed fix:** Open the worker and state lock files close-on-exec (if ucode fs.open supports an 'e' mode flag) or close the handle's fd in children. Simplest: switch the worker lock to the owner-record directory scheme with pid+ticks identity, as autotune/lock.uc already does.


**Tests needed:** A manager test: hold the worker lock, spawn a long-lived `sh -c 'sleep ... &'`, kill the manager with SIGKILL, and assert that the next run is not busy and status reports the run as crashed.


**Risk:** Low.


---

<a id="uc-056"></a>

## UC-056 · P3 · S3 — Reload остановленного runtime молча запускает Forkop, а stop оставляет триггеры reload (воркеры ruleset-refresh, reload.pending), поэтому остановка пользователем не сохраняется

**Severity:** P3<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A6 stop/reload lifecycle<br>
**Sources:** process-locks#9<br>
**Original title:** Reload of a stopped runtime silently starts Forkop, and stop leaves reload triggers behind (ruleset-refresh workers, reload.pending), so a user stop does not stick<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-15

**Evidence:** lifecycle.uc:1708-1711 `if (!forkop-running) { log 'Runtime state is incomplete; restarting Forkop runtime'; return restart_runtime_for_reload() }` (1496-1529 = stop_main + start_impl). initd.uc:700-719 ignores a reload of a stopped service only for reason on_config_change; ruleset-cache, pending, subscription_deferred_recovery and restore ("") proceed. Untracked background workers that later call reload: lifecycle.uc:984-998 refresh_rulesets_after_start (sync `SERVICE_INIT reload ruleset-cache`), 1045, 2024-2031; singbox/ruleset_cache.uc:687-697; none is stopped by stop_main (1055-1109). stop does not clear reload.pending (lifecycle.uc:537-549, state.uc:389-394), and later workers run `run-pending-reload-if-requested` (updates.uc:4353, 3829; diagnostics/runtime.uc:1982).


**Reproduction:** Code path analysis.


**Expected:** An explicit stop remains in effect until an explicit start.


**Actual:** Any non-config-change reload after a stop restarts Forkop.


**Impact:** The user stops Forkop from the UI while the post-start rule-set refresh is downloading, or while a pending reload marker exists. When the download finishes, `/etc/init.d/forkop reload ruleset-cache` runs, and the full runtime (nft, sing-box, dnsmasq) is started again without the user's consent; the service may even be disabled. A snapshot restore on a stopped service also starts it. During opkg remove or upgrade, a straggler can start the old runtime between prerm and file replacement.


**Root cause:** reload doubles as a 'repair incomplete runtime' path, and stop does not revoke outstanding background reload triggers.


**Affected files:** `forkop/files/usr/lib/service/lifecycle.uc`, `forkop/files/usr/lib/service/initd.uc`, `forkop/files/usr/lib/singbox/ruleset_cache.uc`

**Dependencies:** Related to the stop-serialization finding.


**Proposed fix:** (a) Decide whether a reload may start a stopped service. Proposed: only for an explicit restore, and otherwise skip or queue when the runtime was stopped cleanly (shutdown_correctly=1 or an explicit stopped marker). (b) Make stop_main terminate ruleset-refresh workers by identity and clear or keep reload.pending according to (a).


**Tests needed:** A lifecycle test: with the runtime stopped (forkop-running false) and shutdown_correctly=1, `reload ruleset-cache` must not call start_impl. A stop test asserting that reload.pending and refresh workers are handled.


**Risk:** Changing reload semantics could hide real repair needs (runtime crashed while intended running); distinguish 'stopped by user' from 'crashed'.


---

<a id="uc-057"></a>

## UC-057 · P3 · S3 — Глобальный reload.lock удерживается во время долгого сетевого I/O (обновление списков и подписок), блокируя применение DNS-failover и восстановление runtime

**Severity:** P3<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A7 locks<br>
**Sources:** process-locks#10<br>
**Original title:** Global reload.lock is held across long network I/O (list and subscription updates), blocking DNS-failover apply and runtime recovery for the duration<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** components/updates.uc:3940-3948 list_update takes RELOAD_LOCK_DIR (wait 300) before dns_probe_passed (3902-3933: up to 10 attempts x (dig timeout 3 s + sleep 3 s)) and all downloads, releasing it only at 3820; :4342-4351 the subscription update holds it across downloads. service/lifecycle.uc:1621-1622 dns_failover_apply `acquire-runtime-dir-lock-wait ... "2"` fails fast (returns 2); singbox/dns_failover.uc:229-235 treats that as a failed switch and retries on the next active interval.


**Reproduction:** Code path analysis.


**Expected:** The global runtime lock is held only for runtime mutation.


**Actual:** Recovery actions are blocked or failed by a lock held for network I/O.


**Impact:** When the active main DNS dies while a scheduled list or subscription update runs (the update's own DNS probe or downloads then stall on the dead resolver), DNS failover cannot switch servers until the update releases the lock, which takes at least ~60 s and several minutes with slow downloads. LAN DNS stays broken for that time. Starts attempted meanwhile are deferred after 30 s without a retry (initd.uc:604-607 returns before mark_start_retry).


**Root cause:** reload.lock doubles as the 'service proxy must stay up while downloading' guard.


**Affected files:** `forkop/files/usr/lib/components/updates.uc`, `forkop/files/usr/lib/service/lifecycle.uc`, `forkop/files/usr/lib/service/initd.uc`

**Dependencies:** The detached-start fix makes start deferral more frequent.


**Proposed fix:** Let dns_failover_apply wait longer or preempt, or have list and subscription workers release reload.lock during pure download phases and re-acquire it only for the apply step (the candidate or snapshot design already separates prepare and apply). Schedule a start retry on a lock-deferral.


**Tests needed:** dns_failover test: with reload.lock held by a live list-worker stub, a failover apply is eventually applied (or waits) instead of repeatedly failing. An initd test: a lock deferral schedules a retry.


**Risk:** Releasing the lock mid-update needs care so a reload cannot pull the service proxy away mid-download (retry logic exists).


---

<a id="uc-058"></a>

## UC-058 · P3 · S3 — Очистка устаревшего nfqws убивает любой процесс, чья строка `ps w` содержит устаревший путь (две копии, выполняется при каждом start/reload)

**Severity:** P3<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A6 process identity<br>
**Sources:** process-locks#11<br>
**Original title:** Legacy nfqws cleanup kills any process whose `ps w` line contains the legacy path (two copies, runs on every start/reload)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** providers/nfqueue/runtime.uc:331-342 `needle = cfg.legacy_runtime_base + "/nfq/nfqws"; for (line in ps w) if (index(line, needle) >= 0) kill fields[0]`, called from start_runtime (485) on every zapret start. config/validator.uc:1886-1903 is a duplicate, run from check_provider_requirements (1918-1919) via lifecycle validate_start_config (check-requirements). The base is /var/run/forkop/zapret-runtime (core/constants.uc:124).


**Reproduction:** Code reading.


**Expected:** Only processes executing the legacy nfqws binary are signalled.


**Actual:** A substring match on the ps output selects processes to TERM.


**Impact:** On every start or reload, an unrelated process whose command line contains '/var/run/forkop/zapret-runtime/nfq/nfqws' gets SIGTERM, for example `tail -f .../nfqws.log`, a grep or editor session, or a support script. No identity check (invariant 13); this is legacy-migration code that never retires.


**Root cause:** The legacy cleanup was written before process_identity existed.


**Affected files:** `forkop/files/usr/lib/providers/nfqueue/runtime.uc`, `forkop/files/usr/lib/config/validator.uc`

**Dependencies:** None.


**Proposed fix:** Match /proc/<pid>/exe == legacy_base + '/nfq/nfqws' (exact executable path) instead of a substring of the ps line. Keep one copy (the runtime one) and drop the validator duplicate.


**Tests needed:** zapret_runtime_owner.sh: a foreign `sleep` whose argv contains the legacy path must survive start-runtime and check-requirements.


**Risk:** Low.


---

<a id="uc-059"></a>

## UC-059 · P3 · S4 — Если reload восстановления при откате autotune падает, LKG переносится на кандидата, только что не прошедшего проверку в production

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** A11 rollback (apply.uc -> config/snapshots.uc restore)<br>
**Sources:** autotune#3<br>
**Original title:** Autotune rollback whose restore reload fails moves LKG to the candidate that just failed production verification<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** apply.uc:601 `let restored = snapshots([ "restore", audit.pre_snapshot ]);`; snapshots.uc:354-356 `let before = read_config(); ... let pre = create("automatic", "pre-restore", false, [ id ]);` (snapshot of the current = candidate config); snapshots.uc:342-345 `else if (reload_ran(detect_queued)) { ... else if (!atomic(LKG, pre.snapshot.id + "\n")) ... else result = { status: "recovered" ...`; apply.uc:611-614 then only marks needs_attention


**Expected:** LKG keeps pointing at the verified pre-apply snapshot


**Actual:** LKG := pre-restore snapshot of the verification-failed candidate


**Impact:** Verification of candidate X fails, so rollback restores the pre-apply config. If validation or reload of that config fails (a transient sing-box or nfqws start failure), do_restore puts X back and writes LKG = pre-restore snapshot = X. LKG was the verified pre-apply snapshot. It now names a config that failed autotune's production check, and any later LKG-based recovery or restore-last-known-good goes to the failing strategy. This violates invariant 3.


**Root cause:** The restore transaction assumes the config being replaced was working/LKG. For an autotune rollback it is an unconfirmed, failed candidate.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `forkop/files/usr/lib/autotune/apply.uc`

**Dependencies:** Overlaps the snapshots/restore area auditor


**Proposed fix:** In guarded_replace's recovered branch (snapshots.uc:342-345), move LKG to `pre` only when `before` is the current LKG content (fingerprint equal). Otherwise leave LKG untouched. The existing restore behaviour from a confirmed config is unchanged.


**Tests needed:** tests/autotune_apply.sh: verification fails + restore reload stub fails -> assert LKG == pre-apply snapshot id and phase needs_attention


**Risk:** Low. The condition only narrows when LKG moves.


**Verification:** confirmed → P3

**Verification evidence:**

I traced the chain in the code and reproduced it.
- apply.uc:575 `if (!valid_hash(fp) || lkg_fingerprint() != fp) return "config_not_last_known_good";`. Before the apply, LKG holds exactly the pre-apply user config.
- The apply reload of candidate X runs under the guard, and do_apply leaves LKG alone (snapshots.uc:364-368, "LKG is left untouched on success: the caller confirms it after its own checks"). Verification then fails: apply.uc:738 `if (!v.ok) return rollback_to(audit, p, "verification_failed");`.
- apply.uc:601 `let restored = snapshots([ "restore", audit.pre_snapshot ]);` leads to do_restore. There, snapshots.uc:354 `let before = read_config();` reads X, and snapshots.uc:356 `let pre = create("automatic", "pre-restore", false, [ id ]);` makes a snapshot of X.
- guarded_replace, snapshots.uc:336: the validator or reload of the pre-apply content fails. snapshots.uc:340 writes X back. snapshots.uc:342 `else if (reload_ran(detect_queued))` succeeds. snapshots.uc:344 `atomic(LKG, pre.snapshot.id + "\n")` then points LKG at the pre-restore snapshot of X, and snapshots.uc:345 returns `recovered`.
- apply.uc:611-614 only sets needs_attention (`verification_failed:rollback_recovered`) and does not touch LKG.
- This contradicts autotune's own documented contract. apply.uc:733 says "LKG still points at the pre-apply state; `rollback` restores it", and apply.uc:773-775 says "only a verified apply moves it". The LKG fallback in rollback(), apply.uc:776-779, depends on that promise.
- No test covers the double fault. tests/autotune_apply.sh test 13 uses reload plan "0 1 1", which gives runtime_rollback_failed and never reaches the recovered branch.
- tests/config_snapshots.sh:83-92 pins the ordinary-restore behaviour: a recovered restore moves LKG to the pre-restore snapshot even when `before` is an unconfirmed config.


**Verification reproduction:**

I built a scratch harness from the setup in tests/autotune_apply.sh (lines 10-242: the real apply.uc, snapshots.uc, process identity and nfqws stand-in, with stubbed reload, validator, nft and curl). I ran it in WSL with a private TMPDIR. Scripts are in scratch/audit-verify-rollback-lkg\ (run.sh, run_cf.sh).

Scenario: PROD_PLAN=reset (verification fails) with reload plan "0 1 0".
- The reload log showed 0, 1, 0: the candidate reload succeeded, the restore reload failed, and the put-back reload succeeded.
- apply result: {status:"needs_attention", reason:"verification_failed:rollback_recovered", rollback:{status:"recovered", reason:"target_reload_failed", guard:"inactive"}}.
- The config hash afterwards equals the plan's candidate_hash (21928edc…).
- LKG before: 1790606715_547007355 (automatic, last-known-working, hash 013212ef… = pre-apply).
- LKG after: 1790606716_941802098 (automatic, **pre-restore**, hash 21928edc… = **candidate**).
- snapshots.uc list shows is_lkg=true on the candidate's pre-restore snapshot and false on both pre-apply copies.
- apply.uc status: resolved:false, diagnosis:"candidate_active", pre_snapshot_present:true.

Retention side check:
- Original run, then 9 manual snapshots: both pre-apply copies are evicted, and operator rollback fails with `pre_apply_snapshot_missing`.
- Counterfactual with LKG put back to the pre-apply snapshot, then the same 9 manual snapshots: rollback also fails, with `rollback_not_started:pre_restore_snapshot_failed` (retention is full).
- By calculation, the two outcomes differ only when exactly 8 manual snapshots are created in the window. So retention is not a meaningful extra harm.


**Verification notes:**

**Severity: P3, not P2**
The finding is real, but it needs a double fault:
- the candidate fails verification,
- then the pre-apply config fails validation or reload,
- then the put-back reload of the candidate succeeds.

The outcome is reported, not hidden:
- The phase is needs_attention, so invariant 5 holds.
- autoapply is blocked while the record is unresolved (manager.uc:348 `apply_unresolved`).
- Operator rollback() uses the recorded before-autotune snapshot, not LKG. When it succeeds it points LKG back at that snapshot (tests/autotune_apply.sh:804).

The real effects are narrower:
- The History "Last known good" badge sits on a "Before restore" snapshot of the rejected candidate.
- LKG retention protection moves off the pre-apply copies.
- rollback's LKG fallback (apply.uc:771-779) stops working if the before-autotune snapshot is deleted. The user can delete it from History because it is not LKG.

The candidate is the config that is actually running, and it reloaded coherently. Forkop's general LKG meaning is "last config that reloaded or started successfully". The invariant-3 framing therefore only partly fits: the other candidate for LKG is a config whose validation or reload has just failed.

**The window is bounded anyway**
lifecycle.uc:401-405 (finish_reload_status, no-guard check only) and lifecycle.uc:2169-2173 (`start`, which confirms unconditionally) will confirm the running candidate as LKG at the next successful reload or boot. The same happens for an unverified candidate after interrupted_after_apply. Any snapshots-only fix therefore only narrows the window. Keeping LKG off an unverified or failed candidate for the whole unresolved period would also need lifecycle confirm-working to skip while an unresolved autotune record has config=candidate. That is a product decision.

**The proposed fix is wrong as written**
It would move LKG to `pre` only when `before` matches the current LKG content. That breaks the pinned test at tests/config_snapshots.sh:83-92, where `before` (8.8.8.8, unconfirmed) differs from the LKG content (1.1.1.1) and the test asserts that LKG moves to the pre-restore snapshot. It would also leave LKG on a restore target that has just failed validation or reload, which is itself an invariant-3 problem.

**Better minimal fix, scoped to autotune**
- rollback_to (apply.uc:601) passes an explicit option to the restore, for example `restore <id> keep-lkg` or a dedicated operation, so that the recovered branch (snapshots.uc:342-345) leaves LKG unchanged. A new operation name would also have to be added to active_entry's list at snapshots.uc:76 and the mode whitelist at snapshots.uc:404.
- Alternatively, make the rollback source independent of LKG: protect audit.pre_snapshot from retention and from deletion while the autotune record is unresolved.
- Fix the comments at apply.uc:733 and apply.uc:773-775 either way.
- Test to add in tests/autotune_apply.sh: PROD_PLAN=reset with reload plan "0 1 0", then assert needs_attention and whichever LKG outcome is chosen.

**Related variant (low)**
The same recovered branch runs for an operator rollback of an unverified candidate (interrupted_after_apply or lkg_confirm_failed records). rollback_to (apply.uc:603-609) then says "the restore changed nothing" and puts the previous record back, even though LKG has moved to the candidate.

**Line references**
All of the finding's line references are correct: apply.uc:601 and 611-614, snapshots.uc:342-345 and 354-356.

**Checked and found correct**
- stale_reason ties LKG to the pre-apply config (apply.uc:575).
- do_apply and the guard keep the candidate reload from confirming LKG.
- A verified apply confirms LKG only for the exact verified fingerprint (apply.uc:741-746).
- needs_attention is not masked.
- autoapply is blocked while unresolved.

product_decision: true.


---

<a id="uc-060"></a>

## UC-060 · P3 · S4 — История: каждый apply autotune пишет два события autotune_apply (первое сообщает об успехе до проверки); откат записывается как 'restore' вопреки дизайну H.6

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** A11 history<br>
**Sources:** autotune#4, snapshots#7<br>
**Original title:** History: each autotune apply records two autotune_apply events (the first says success before verification); rollback is recorded as 'restore' contrary to design H.6<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** config/snapshots.uc:432-437 `else if (mode == "apply") { ... if (answer.started) ... "record", "autotune_apply", answer.status == "success" ? "success" ...`; manager.uc:450 `if (o.history != null) history("autotune_apply", o.history, record.trigger, aggregate.candidate);`; snapshots.uc:427-430 rollback restore records kind 'restore'; diagnostics/health.uc:17-18 EVENT_KINDS has no autotune_rollback; history/model.ts:138-139 an event without trigger is titled generically; docs/design/STAGE6_UX_DESIGN.md:824 'Apply / rollback обязательно пишутся своим kind (autotune_apply, autotune_rollback), а не restore'; tests/autotune_apply.sh header: health is a stand-in; autoapply/manual tests use a stand-in apply.uc


**Expected:** One autotune_apply event with the verified outcome; rollback as autotune_rollback


**Actual:** Two autotune_apply events per apply, the first 'success' at reload time; rollback shown as generic restore


**Impact:** For a rolled-back apply the history shows 'Autotune apply - Succeeded', 'Restore - Succeeded', 'Autotune: automatic apply of X - Recovered'. The first event claims success for a change that failed verification (UI presents a reload success as an apply success). Apply counts in the history are doubled, and the rollback is not identifiable as autotune.


**Root cause:** snapshots.uc gained its own autotune_apply record, and the manager later added one with trigger/candidate. Tests stub health/apply, so the duplication is invisible.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `forkop/files/usr/lib/autotune/manager.uc`, `forkop/files/usr/lib/autotune/apply.uc`, `forkop/files/usr/lib/diagnostics/health.uc`, `fe-app-forkop/src/forkop/tabs/history/model.ts`

**Dependencies:** None


**Proposed fix:** Record exactly one autotune_apply event per transaction, after verification. Drop the record in snapshots.uc apply mode and let apply.uc record the terminal outcome (manager passes trigger/candidate, or manager keeps recording and apply.uc records only when invoked directly). Add an 'autotune_rollback' event kind for rollback_to/rollback, and a UI label.


**Tests needed:** An apply test with the real health.uc: exactly one autotune_apply event per apply (applied / rolled_back / needs_attention) and an autotune_rollback event on rollback


**Risk:** Low


### Also reported as snapshots#7 (P3): Autotune apply writes duplicate and premature history events ('Autotune apply: Success' before verification)

**Evidence:** snapshots.uc:435-437 records `autotune_apply` with the transaction status (no trigger/candidate) as soon as snapshots.uc apply returns. manager.uc:450 records `autotune_apply` again with the real outcome, trigger and candidate. A verification rollback additionally records `restore success` (apply.uc:601 -> snapshots.uc:429). autotune_manual_apply.sh stubs apply.uc, and autotune_apply.sh stubs health.uc, so the duplicate is untested.


**Proposed fix:** Drop the autotune_apply record in snapshots.uc apply mode (apply.uc/manager.uc own the outcome), or record it only when the transaction ended in failure/needs_attention and manager.uc is not the caller. Optionally tag the rollback restore so History groups it under the apply.


---

<a id="uc-061"></a>

## UC-061 · P3 · S4 — Reload службы из UI сообщает 'completed', хотя init.d только поставил reload в очередь

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** service_action_async/status contract (queued vs done)<br>
**Sources:** cli-contract#2<br>
**Original title:** UI service-action reload reports 'completed' when init.d only queued the reload<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/initd.uc:746-754 reload_service returns 0 for a queued (skip) plan. service/ui.uc:1367-1374 service_action_worker runs `SERVICE_INIT reload` and passes status 0 to finish_service_action_after_command. :1351-1352: the service is already running, so `service_action_wait_for_expected_state` passes and the job ends as 'Service reload completed'. The URLTest save flow (dashboard initController.ts:1321-1331) then refreshes and toasts success.


**Expected:** The job reports queued/busy; the UI shows 'reload queued, will apply after the running update'.


**Actual:** Job {success:true, message:'Service reload completed'} for a reload that did not run.


**Impact:** The admin clicks reload (or saves URLTest settings, which triggers a reload) while a list/subscription update or an automatic latency batch holds the reload lock. The UI says the reload completed although the new config is only applied later (after the lock holder finishes). The dashboard refresh shows the old runtime right after a 'success'.


**Root cause:** The same rc-0 overload of init.d reload as in the P1 restore finding.


**Affected files:** `forkop/files/usr/lib/service/initd.uc`, `forkop/files/usr/lib/service/ui.uc`, `forkop/files/etc/init.d/forkop`

**Dependencies:** Shares its root cause with the P1 snapshot restore finding.


**Proposed fix:** Let `initd.uc reload-service` signal 'queued' distinctly: it already prints 'queued' for list-content; do this for all reasons or use a dedicated exit code. service_action_worker should then finish the job with a queued/busy outcome (message key 'reload_queued') instead of success. Alternatively, UI-tracked reloads could wait for the lock (acquire-runtime-dir-lock-wait) as start does.


**Tests needed:** tests/ui_runtime_job.sh: FORKOP_SERVICE_INIT stub that marks pending and exits 0 → job must not be success/'completed'.


**Risk:** init.d exit-code changes affect procd/rc.common callers. Prefer a stdout token plus the UI-tracked env (FORKOP_UI_ACTION_TRACKED) so that ordinary callers keep rc 0.


---

<a id="uc-062"></a>

## UC-062 · P3 · S4 — config_snapshot_diff молча обрезает список на 100 изменениях; подтверждение восстановления занижает объём изменений

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** config_snapshot_diff output schema<br>
**Sources:** cli-contract#6<br>
**Original title:** config_snapshot_diff silently truncates at 100 changes; the restore confirmation understates the change set<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** config/snapshots.uc:292 `if (length(result) >= 100) break;` with no total/truncated field. FE history/initController.ts:243-252 builds 'and %d more' from `rows.length - MAX_RESTORE_PREVIEW` (MAX 8). The 'Changes since this snapshot' table shows at most 100 rows.


**Expected:** The truncation is visible to the user.


**Actual:** Array capped at 100 elements, no indicator.


**Impact:** Restoring a snapshot that differs in more than 100 options shows 'and 92 more', although more change. The destructive confirm dialog understates the change set, and the diff modal hides the rest without notice.


**Root cause:** A hard cap was added without a schema field.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `fe-app-forkop/src/forkop/tabs/history/initController.ts`, `fe-app-forkop/src/forkop/tabs/history/model.ts`

**Proposed fix:** Emit a trailing marker or change the schema to {changes, total, truncated}, and let the FE render 'more than 100 changes'.


**Tests needed:** tests/config_snapshots.sh fixture-diff with more than 100 changed options; FE model test.


**Risk:** Schema change: FE and backend ship together in the same release; keep the array form and add a marker for compatibility.


---

<a id="uc-063"></a>

## UC-063 · P3 · S4 — Diff снимка показывает *** для опции, отсутствующей в одной из сторон (известный пункт HW-проверки)

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** config/snapshots.uc diff masking<br>
**Sources:** snapshots#8, cli-contract#7, ui-css-a11y-i18n#10<br>
**Original title:** Snapshot diff shows *** for an option absent in one side (known hardware item)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-2

**Evidence:** snapshots.uc:286-290 `let before_value = a == null ? "" : a.value; ... before: safe_value(option, before_value)`. safe_value (206-212) accepts only `{1,32}`/`{1,45}` values and returns '***' for everything else, including ''. It is pinned by tests/config_snapshots.sh `diff('', lines("option action 'x'"))` -> `before: '***'`. model.ts:212-215 diffValue already renders ''/undefined as '—', but never receives them for scalars.


**Expected:** An absent option is shown as absent ('—' / 'not set'), while present values stay masked.


**Actual:** An absent option is shown as '***'.


**Impact:** Rows such as 'Alloha · mixed_proxy_enabled *** ***' (hardware probe) carry no information: the user cannot tell 'added' or 'removed' from 'changed secret'.


**Root cause:** Absent is modelled as the empty string, and the masking allowlist rejects empty strings.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `fe-app-forkop/src/forkop/tabs/history/model.ts`, `fe-app-forkop/src/forkop/types.ts`, `tests/config_snapshots.sh`, `fe-app-forkop/src/forkop/tabs/history/initController.ts`

**Proposed fix:** Options, as a product decision: (A, recommended) emit null for an absent scalar side (`before: a == null ? null : safe_value(...)`) and render null as '—'/'not set' in the UI; (B) treat '' as safe for every option, which conflates absent with empty; (C) add before_present/after_present flags. Absence reveals only the option name, which is already shown, so no secret is exposed. Update the pinned assertions in tests/config_snapshots.sh.


**Tests needed:** config_snapshots.sh: absent->present and present->absent for a masked and an allowlisted option. history model test: null rendering.


### Also reported as cli-contract#7 (P3): KNOWN (hardware P3): snapshot diff renders absent values as '***'

**Evidence:** config/snapshots.uc:286-290 `let before_value = a == null ? "" : a.value; ... before: safe_value(option, before_value)`; :206-211 safe_value returns "***" for anything not allowlisted, including the empty string.


**Proposed fix:** Emit null (or before_absent/after_absent flags) when the side is absent; the FE renders 'not set'.


### Also reported as ui-css-a11y-i18n#10 (P3): Snapshot diff shows '***' for a value absent from one side, suggesting a hidden secret (known HW item, behaviour pinned by a test)

**Evidence:** forkop/files/usr/lib/config/snapshots.uc:206-211 'function safe_value(option, raw) { if (index([ "enabled", "action", ...], option) >= 0 && match(raw, /^[A-Za-z0-9_-]{1,32}$/) != null) return raw; ... return "***"; }': an absent value ('') fails the {1,32} match and becomes '***'. tests/config_snapshots.sh:178-183 asserts before: '***', after: 'x' for an added 'action'. Shown in History > changes and in the page/settings.js:170-176 apply notification


**Proposed fix:** Return a distinct marker for absent values (e.g. null, rendered as _('not set')) and keep '***' only for present, non-allowlisted values. Update config_snapshots.sh accordingly. Showing absence does not reveal a secret value


---

<a id="uc-064"></a>

## UC-064 · P3 · S4 — Хук 'snapshot-first Save & Apply' в Settings — мёртвый код: LuCI никогда не вызывает forkopMap.handleSaveApply

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** frontend/settings page<br>
**Sources:** frontend-arch#0<br>
**Original title:** Settings 'snapshot-first Save & Apply' hook is dead code: LuCI never calls forkopMap.handleSaveApply<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** luci-app-forkop/.../view/forkop/page/settings.js:92-93 `const originalHandleSaveApply = forkopMap.handleSaveApply; forkopMap.handleSaveApply = async function (ev, mode) {` and :148 `originalHandleSaveApply.call(this, ev, mode)`; EntryPoint (page/settings.js:83-238) defines only load/render. LuCI luci.js view: `handleSaveApply(ev, mode) { return this.handleSave(ev).then(() => { classes.ui.changes.apply(mode == '0'); }); }` with handleSave -> DOM.callClassMethod(map,'save'). In form.js (24.10 and master), CBIMap has no handleSaveApply method, so originalHandleSaveApply is undefined. tests/luci_readonly_view.sh:103-106 only regex-matches the source text.


**Reproduction:** Code path: LuCI footer 'Save & Apply' -> view.handleSaveApply (luci.js) -> handleSave -> map.save(); ui.changes.apply(). No code path reaches forkopMap.handleSaveApply.


**Expected:** Save & Apply takes a pre-apply snapshot (and aborts on busy/failure), then reports whether the Forkop reload was confirmed, as the design and commit 78877c17 state.


**Actual:** Clicking Save & Apply runs LuCI's default view.handleSaveApply. The snapshot/confirmation code never executes. If it did run, it would throw a TypeError at settings.js:148 because originalHandleSaveApply is undefined.


**Impact:** Save & Apply on Settings never takes the automatic pre-apply snapshot and never refuses to apply while a snapshot operation is busy. It never marks the service 'reloading' and never shows the 'Configuration applied successfully / Runtime reload has not been confirmed; check History and recovery' notice. When a reload fails, the user sees only LuCI's generic 'Configuration changes applied'. The designed safeguard and warning (STAGE6_UX_DESIGN.md A.1 'Save & Apply hook') are missing. The backend guards still hold: reload takes its own automatic snapshot (service/lifecycle.uc:1689), and concurrent_change checks in snapshots.uc.


**Root cause:** The override is attached to the form.Map instance, but LuCI dispatches footer buttons to the view (EntryPoint), and form.Map has no handleSaveApply. Carried over from the pre-78877c17 forkop.js, which had the same pattern.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/page/settings.js`, `tests/luci_readonly_view.sh`

**Proposed fix:** Wire the hook on the view. Add `handleSaveApply(ev, mode)` to the page/settings.js EntryPoint that: (1) calls snapshotCreate('automatic') and aborts on busy or failure as the current code does; (2) calls `view.prototype.handleSaveApply.call(this, ev, mode)`; (3) confirms the reload only after the apply finishes, for example by polling get_health_status.last_reload until timestamp > previousReloadAt, with a deadline. The current code checks immediately, and LuCI resolves before ui.changes.apply completes, so it would always report 'not confirmed'. Remove the forkopMap.handleSaveApply override.


**Tests needed:** A node test that loads page/settings.js with a LuCI view stub whose base handleSaveApply records calls. Invoke the view's handleSaveApply and assert snapshotCreate('automatic') runs before the base apply, and that the apply is skipped when the snapshot result is busy or failed. Replace the regex-only assertion.


**Verification:** confirmed → P3

**Verification evidence:**

The hook is dead code. In LuCI, the footer's Save & Apply button calls the view's handleSaveApply, never form.Map's.

1. page/settings.js:92-93 puts the override on the Map instance: `const originalHandleSaveApply = forkopMap.handleSaveApply; forkopMap.handleSaveApply = async function (ev, mode) {`. EntryPoint (settings.js:83-238) defines only load() and render(), and `return view.extend(EntryPoint)` (line 240). So the view inherits LuCI's default handleSaveApply.

2. I checked upstream LuCI sources (openwrt/luci master, openwrt-24.10, openwrt-23.05; copies in scratch/audit-verify-saveapply/):
   - form.js has no `handleSaveApply` member in any of the three branches (rg finds 0 hits).
   - luci.js defines it only on the view. In 24.10 it is at 2040-2043: `handleSaveApply(ev, mode) { return this.handleSave(ev).then(() => { classes.ui.changes.apply(mode == '0'); }); }`.
   - handleSave (1996-2001) only calls `DOM.callClassMethod(map, 'save')`.
   - The footer (2130-2138) is `this.handleSaveApply ? new classes.ui.ComboButton(... click: classes.ui.createHandlerFn(this, 'handleSaveApply'))`, where `this` is the view.
   - So nothing ever reads `forkopMap.handleSaveApply`, and `originalHandleSaveApply` is undefined.

3. The pattern goes back to commit 337c6922 (2026-06-06, the old forkop.js) and was carried into page/settings.js by 78877c17. The pre-78877c17 forkop.js also had no view-level handleSaveApply, so this hook has never run.

4. tests/luci_readonly_view.sh:103-106 only checks the source with `assert.match(settingsSource, /forkopMap\.handleSaveApply = async function/ ...)` and `/snapshotCreate\("automatic"\)[\s\S]*originalHandleSaveApply\.call/`. That gives false assurance.

5. The design doc says to hook the view: docs/design/STAGE6_UX_DESIGN.md:309 "Save & Apply hook со снимком нужно вынести в общий helper и подключить во view Настроек". The code attaches it to the Map instead.

Why the severity drops from P2 to P3: no safety invariant breaks, and most of what is lost was never effective.
- When the backend reloads it still runs snapshots.uc create automatic (service/lifecycle.uc:1689). Correction to the finding: that snapshot reads /etc/config/forkop *after* LuCI's UCI commit, so it holds the new config, not the pre-apply one (snapshots.uc:188-205, `read_config()`).
- The pre-apply config is normally still protected. After each successful start or reload, lifecycle.uc:402-403 and :2172 call `confirm-working`, which saves the working config as LKG. Retention trimming never removes LKG (snapshots.uc:164-185). The earlier before-reload snapshots also stay (dedupe, RETENTION=10).
- The frontend snapshot would add a new restore point only when /etc/config/forkop was edited outside Forkop without a reload, and the earlier config was never confirmed.
- The busy refusal was check-then-act anyway: the snapshot lock is released before the apply. The backend already fails restore/apply on `concurrent_change` (snapshots.uc:328, 358, 386).
- The confirmation/warning notice would barely be visible even if wired. LuCI ui.js 24.10:5078-5089 reloads the page `L.env.apply_display` seconds after the apply succeeds (`window.location = window.location.href.split('#')[0]`), which wipes any notification.
- LuCI's "Configuration changes applied." refers to the UCI apply. It does not claim Forkop runtime success, so invariants 5 and 15 are not violated. What remains is missing feedback, dead code, dead i18n strings and a misleading test. That is P3.


**Verification reproduction:**

I ran a Node reproduction on Windows (node 24): scratch/audit-verify-saveapply/repro.js, pointed at the wt-ultracode tree. It loads the real page/settings.js with the same require-directive loader that tests/luci_readonly_view.sh uses. The view base reproduces the handleSave/handleSaveApply/footer behaviour of LuCI 24.10 luci.js, and the form.Map stub has no handleSaveApply, like the real form.js. Output:

```
EntryPoint own handleSaveApply: false
forkopMap own handleSaveApply: true
CBIMap prototype handleSaveApply: undefined
footer Save & Apply calls: ["map.save","ui.changes.apply:true"]   <- snapshotCreate never called
direct override call threw: TypeError: Cannot read properties of undefined (reading 'call')
calls before throw: ["snapshotCreate:automatic","getHealthStatus","store.set:reloading"]
```

The upstream check was `rg -n "handleSaveApply"` over form.js and luci.js from master, openwrt-24.10 and openwrt-23.05, downloaded from raw.githubusercontent.com/openwrt/luci. form.js has 0 hits; luci.js has hits only in the view class. I also fetched ui.js 24.10 to confirm that apply() returns nothing and the page reloads after a successful apply (5078-5089, 5144).

I did not need a router. The dispatch is fully determined by the LuCI source.


**Verification notes:**

Line references in the finding are correct: settings.js:92-93, :148, EntryPoint 83-238, test 103-106.

Corrections to the finding's reasoning:
1. "Backend guards still hold: reload takes its own automatic snapshot" is imprecise. The lifecycle.uc:1689 snapshot is taken after the UCI commit, so it contains the new config, even though it is labelled "before-reload". The pre-apply config survives because of LKG (confirm-working at lifecycle.uc:402-403 and :2172) and earlier deduped snapshots, not because of that reload snapshot.
2. Part (3) of the proposed fix (poll get_health_status.last_reload with a deadline, then show a notice) will not work as described. LuCI's ui.changes.apply reloads the page after the apply is confirmed (ui.js 24.10:5086-5089, delay `L.env.apply_display`). That reload aborts the poll and removes any notification. The confirmation has to survive the reload. One way is to store {applyStartedAt, previousReloadAt, snapshotId} in sessionStorage before calling the base apply, then check health.last_reload on the next render. Another is to drop the toast and point to History, which is design H/K "toast from history".
3. The global "Unsaved changes" indicator in the LuCI header bypasses any view hook. The design already records this as a known limitation (STAGE6_UX_DESIGN.md:310). The fix should not claim to cover it.
4. If the override were ever called, it would first create the snapshot and set the store's forkopStatus to "reloading", then throw at line 148. The UI status would then stay stuck on "reloading" until the next get_ui_state poll. This is moot today because the code is unreachable.

Minimal fix:
- Remove the forkopMap override.
- Add `handleSaveApply(ev, mode)` to EntryPoint:
  - Call `snapshotCreate("automatic")`. Abort with the existing busy/failure notices if the status is not created or existing.
  - Otherwise return `this.super('handleSaveApply', [ev, mode])` (the LuCI Class idiom) or `view.prototype.handleSaveApply.call(this, ev, mode)`.
- Handle the reload confirmation separately, as in note 2.
- Replace the regex assertions in tests/luci_readonly_view.sh with a behavioural test. Load page/settings.js with a view stub whose base handleSaveApply records calls, then assert:
  - `snapshotCreate('automatic')` runs before the base apply;
  - the base apply is skipped when the status is busy or failed;
  - the Map instance has no own handleSaveApply.

Product decision: not needed for wiring the snapshot. Whether to keep the post-apply toast (given the page reload) or move it to History is a small UX choice the design has already covered.


---

<a id="uc-065"></a>

## UC-065 · P3 · S4 — Восстановление снимка History от старого релиза обходит миграцию конфигурации (возвращаются выведенные mirror/rulesets; applied_migrations откатывается)

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** uci-global<br>
**Sources:** uci-global#2, snapshots#12<br>
**Original title:** Restoring a History snapshot saved by an older release bypasses config migration (retired mirror/rulesets come back; applied_migrations reverted)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-16

**Evidence:** snapshots.uc:351-362 do_restore -> guarded_replace (snapshots.uc:323-349) writes target.content verbatim, then only runs validator.uc validate-runtime and reload. There are no references to migration.uc in snapshots.uc. Migration runs only in package postinst (build.sh:300,438,461). Snapshots persist across upgrades in /etc/forkop/config-snapshots (retention 10) and record forkop_version, but the UI never uses it (no forkop_version use in tabs/history). core/constants.uc:16-29 uses mirror_base_url as-is (no legacy-mirror normalisation at runtime). migration.uc:1318-1319 notes retired rulesets 'cause every list update to fail with a remote 404'.


**Reproduction:** wsl bash scratch/audit-a3/migrate_old_snapshot.sh


**Expected:** Restored configuration is brought to the running release's schema/data (or the restore is refused), exactly as a package upgrade would do.


**Actual:** Scratch repro (audit-a3/migrate_old_snapshot.sh): for pre-upgrade content, migrate-fixture reports changed=true (mirror_base_url -> infotechtg, retired rule_set_with_subnets deleted, mirror.51343.ru list URLs rewritten, 4 migration IDs added). snapshots.uc restores that content without any of these.


**Impact:** Invariant 17 (compatibility without migration/adapter). After restoring a pre-upgrade snapshot, component and list downloads point at the retired mirror (mirror.51343.ru), retired b4geoip SRS URLs come back (list updates fail with 404), and applied_migrations/config_version revert. The validator passes, so it is reported as a successful restore, and nothing self-heals until the next package upgrade. The apk feeds already point at the new mirror, so UCI and feeds disagree.


**Root cause:** Config migration is tied to package installation only. Snapshot restore is a second way to install old-format config and has no adapter.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `forkop/files/usr/lib/config/migration.uc`, `fe-app-forkop/src/forkop/tabs/history/initController.ts`

**Dependencies:** The same gap applies to autotune apply's use of guarded_replace only if an old-format candidate is ever produced (not currently).


**Proposed fix:** In guarded_replace/do_restore, after atomic(CONFIG, content) and before validate-runtime, run `ucode -L LIB migration.uc migrate` (forkop mode). It is idempotent and a no-op for current content. On failure, treat it like a validation failure and roll back. The restore result 'changes' should be the diff against the post-migration file. Alternatively (weaker), refuse or warn when snapshot.forkop_version differs from the running version.


**Tests needed:** tests/config_snapshots.sh: restore a snapshot whose content has mirror_base_url https://mirror.51343.ru and a retired b4geoip URL, and assert the post-restore config is migrated and applied_migrations contains all IDs. Assert that a current-format restore is byte-identical.


**Risk:** Medium-low. It touches the restore transaction, but migrate is idempotent and runs under the existing guard/rollback.


**Verification:** confirmed → P3

**Verification evidence:**

The mechanism is real, but the failure the finding describes cannot happen at 07872084. It is a latent gap: it becomes real with the first config migration added after the snapshot feature ships.

What the code does:
- forkop/files/usr/lib/config/snapshots.uc:351-362. do_restore calls `guarded_replace(before, target.content, pre, ...)`.
- guarded_replace (snapshots.uc:323-349) runs `atomic(CONFIG, content)`, then `validator.uc validate-runtime`, then `reload_ran()`. Nothing else touches the content.
- snapshots.uc never references migration.uc.
- config/validator.uc has no check on mirror, applied_migrations or config_version, so old-format content passes validation.
- The only callers of migration.uc migrate are the package postinst scripts: build.sh:300, 438 and 461, and forkop/Makefile:55. install.sh:2765 calls only migrate-podkop.
- The History tab (fe-app-forkop/src/forkop/tabs/history/*.ts, excluding tests) never reads snapshot.forkop_version. There is no version gate or warning.
- migration.uc:1432-1440 gates each migration only by its ID in applied_migrations. A restored file that lacks an ID stays unmigrated until the next package postinst.

Why the concrete scenario cannot happen yet:
- snapshots.uc was added in f38a2759 (2026-09-26). That commit is not in origin/main and is in no release tag (latest release is 1.0.26).
- Every migration in the tree is older than the snapshot feature:
  - own_dependency_mirror_v1 and mirror_infotechtg_ru_v1 (360d4699, 2026-09-09)
  - retired_secondary_rulesets_v2 (910bfbaf, 2026-09-03)
  - secondary_rulesets_mirror_v1 (eaad3bb2, 2026-09-02)
- On any install or upgrade into a snapshot-capable build, postinst runs `migration.uc migrate && mirror-migration.sh && forkop package_postinst`. Snapshots are only created later, by lifecycle reload (lifecycle.uc:1689, create automatic) or by the UI.
- So no real snapshot can contain mirror.51343.ru, retired b4geoip URLs, or be missing any of the 9 current migration IDs.
- The finding's impact claims (retired mirror returns, list updates fail with 404, apk feeds disagree with UCI) cannot be reached on a device today.

When it will trigger: release N ships snapshots, and release N+1 adds migration M. Restoring a manual snapshot from N on N+1 then silently reverts M's data and removes M's ID. The validator passes, the restore reports status success, and nothing self-heals until the next upgrade's postinst. This breaks invariant 17 as soon as M exists.


**Verification reproduction:**

I wrote a scratch script (scratch/audit-verify-snapshot-migration/repro.sh) and ran it in WSL with a private mktemp dir. It uses the same stubs as tests/config_snapshots.sh, plus a ucode stub that logs every nested module call.

Steps:
1. Create a manual snapshot of a config with mirror_base_url 'https://mirror.51343.ru' and only 'interface_sections' in applied_migrations.
2. Replace the live config with migrated content (infotechtg mirror, own_dependency_mirror_v1 in applied_migrations).
3. Run `snapshots.uc restore <id>`.

Result:
- The restore returned status "success".
- The config after restore is byte-for-byte the old content: `option mirror_base_url 'https://mirror.51343.ru'`, own_dependency_mirror_v1 gone from applied_migrations.
- The nested calls were only `nft/apply.uc ensure-dpi-transition-guard`, `config/validator.uc validate-runtime`, `nft/apply.uc remove-dpi-transition-guard` and `diagnostics/health.uc record restore success`. The script printed "MIGRATION NOT INVOKED".

Reachability was checked with git history, not at runtime:
- `git log --diff-filter=A` on snapshots.uc
- `git log -S<migration id>` for each migration
- `git merge-base --is-ancestor f38a2759 origin/main`, which reported NOT in origin/main
- `git tag --contains f38a2759`, which is empty

No router or network was used.


**Verification notes:**

Severity: lowered from P2 to P3 because the finding's concrete impact cannot happen today. It should be fixed before the first release that adds a migration after the snapshot feature ships, or that release should include the guard. It would then be P2-class. The fix is cheap now.

Corrections to the proposed fix:
1. `migration.uc migrate` does more than rewrite UCI. migrate_runtime (migration.uc:1642-1657) also runs ensure_runtime_cache_format(), remove_legacy_server_country_cache() and remove_cache_path() for removed caches, and it commits through a UCI cursor, not through snapshots.uc's FORKOP_CONFIG_FILE and atomic(). Running it inside guarded_replace mixes two writers. It would also run on every autotune rollback restore, which is a no-op but has side effects.
2. The proposed test expects "applied_migrations contains all IDs" after the restore. That would fail: mirror_infotechtg_ru_v1 is added by mirror-migration.sh (lines 217-219), not by migration.uc. mirror-migration.sh is not gated by that ID and reruns on every postinst anyway.
3. After a migrating restore, the LKG pointer names a snapshot whose content differs from the live config. confirm-working later creates a new snapshot, so this is harmless but worth knowing.

Better minimal fix, fail-closed (invariant 18):
- In do_restore, before guarded_replace, parse the applied_migrations list from target.content with the existing options() helper. Refuse with status failed, reason "snapshot_needs_migration" if any ID in migration.uc's MIGRATIONS is missing.
- This needs the ID list exported from migration.uc (module_exports already exists) or a migration.uc sub-command that checks a file.
- Optionally show snapshot.forkop_version in the History tab.
- If migrating on restore is preferred instead, do it in memory. Export a text-to-text helper from migration.uc built on migrate_model, apply it to target.content before atomic(CONFIG, ...), and compute diff/changes against the migrated text. That keeps the single atomic write under the guard. Choosing between refusing and auto-migrating is a small product decision.

Test to add to tests/config_snapshots.sh: restoring a snapshot whose content lacks a current migration ID either migrates it or is refused, and a current-format restore stays byte-identical.

Related gap outside snapshots (context only, not part of this finding): any other way to put old-format config in place without a package postinst, such as a sysupgrade or LuCI backup restore of /etc/config/forkop, also skips migration.


### Also reported as snapshots#12 (P3): Restoring a snapshot from an older Forkop version bypasses config migrations

**Evidence:** do_restore writes target.content verbatim (snapshots.uc:359). Migrations run only in package postinst (build.sh:438, 461), and lifecycle must not migrate (tests/config_validation_owner.sh:58). Each snapshot stores forkop_version (snapshots.uc:198-200), but restore never compares it, and snapshotRows (model.ts:201-222) does not show it. The migrations include own_dependency_mirror_v1 (migration.uc:1380-1404, rewrites mirror.51343.ru URLs) and retired_secondary_rulesets.


**Proposed fix:** Product decision: (a) run `config/migration.uc migrate` on the restored file inside the guarded transaction before validation; (b) warn in the restore dialog when snapshot.forkop_version differs from the running version; (c) refuse cross-version restores.


---

<a id="uc-066"></a>

## UC-066 · P3 · S4 — UI восстановления показывает события needs_attention и failed как 'In progress' и не даёт указаний по восстановлению

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** frontend History & Recovery / Overview<br>
**Sources:** snapshots#6<br>
**Original title:** Recovery UI shows needs_attention and failed events as 'In progress' and gives no recovery guidance<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** health.uc:180 `recovery: { pending: guard || failed, ... }`, where failed = last event status 'failure' (164). model.ts:68-72 `health.recovery.pending ? { value: _('In progress'), tone: 'loading' }`. overview.ts:97 'Traffic that needs DPI bypass may be blocked until recovery completes.' The restore guard is never removed by stop/restart (lifecycle.uc:1086 removes only ForkopTableDpiGuard), so only a successful restore clears it.


**Expected:** A terminal needs_attention state is labelled as needing action, with the next step named.


**Actual:** 'Last recovery: In progress' (spinner) while the guard is left in place or the last event failed.


**Impact:** After a restore ends needs_attention, or after any failed reload/start/autotune run, History shows a loading 'Last recovery: In progress' although nothing is running and operator action is required. Overview implies recovery completes on its own. Invariant 5 is not violated (nothing is shown as success), but the terminal state is presented as transient.


**Root cause:** recovery.pending mixes 'guard active' and 'last event failed', and the UI maps it to the loading tone.


**Affected files:** `fe-app-forkop/src/forkop/tabs/history/model.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/overview.ts`, `luci-app-forkop/po/templates/forkop.pot`, `luci-app-forkop/po/ru/forkop.po`

**Proposed fix:** Show 'Needs attention' (error tone) when recovery.pending is true. Add guidance in the Overview/History text: 'restore the last known good snapshot' (restore guard), 'restart the service' (lifecycle guard).


**Tests needed:** history/tests/model.test.ts: guard active -> needs-attention label and error tone; last reload failure -> not 'In progress'.


---

<a id="uc-067"></a>

## UC-067 · P3 · S4 — Снимок 'before-reload' подписан 'Before applying changes', но содержит новую, возможно сбойную конфигурацию

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** snapshot semantics / UI wording<br>
**Sources:** snapshots#9<br>
**Original title:** The 'before-reload' snapshot is labelled 'Before applying changes' but contains the new, possibly failing configuration<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:** lifecycle.uc:1689 `module_success(LIB_DIR + "/config/snapshots.uc", [ "create", "automatic" ])` runs at the start of reload(), after uci commit has already written the edited file (the procd config trigger fires after commit). snapshots.uc:415 reason 'before-reload'. model.ts:175-176 `case 'before-reload': return _('Before applying changes');`. forkop.po:419-420 'Перед применением изменений'.


**Expected:** The label describes the snapshot content (the configuration being applied).


**Actual:** The label suggests the pre-change state.


**Impact:** A user who wants to undo their latest change picks the newest 'Before applying changes' snapshot. Restoring it re-applies the same (possibly failed) configuration. The pre-change configuration is the previous snapshot, usually carrying the LKG badge. The label invites exactly the wrong choice in a recovery situation.


**Root cause:** The reason name describes timing ('before the reload ran'), and the UI translated it as 'before the change'.


**Affected files:** `fe-app-forkop/src/forkop/tabs/history/model.ts`, `luci-app-forkop/po/templates/forkop.pot`, `luci-app-forkop/po/ru/forkop.po`

**Proposed fix:** Rename the label, for example 'Applied configuration' / 'Применённая конфигурация' or 'At reload'. Optionally mark whether that reload succeeded (it later became LKG).


**Tests needed:** history model test for the new label and translations.


---

<a id="uc-068"></a>

## UC-068 · P3 · S4 — Restore игнорирует staged (незакоммиченные) изменения UCI: reload проверяет цель плюс staged-дельты, а LKG фиксирует чистую цель

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** config/snapshots.uc do_restore<br>
**Sources:** snapshots#10<br>
**Original title:** Restore ignores staged (uncommitted) UCI changes: reload validates target plus staged deltas, LKG claims the pure target<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** do_restore (snapshots.uc:351-363) has no staged-changes check. The lifecycle and validator read through libuci cursors (core/uci.uc:270 `require("uci").cursor()`, default save dir /tmp/.uci). autotune/apply.uc:567-568 documents this and refuses: 'Pending LuCI/uci changes would ride along: reload reads through them.' Restore is started from the History page while the LuCI header can hold unsaved changes.


**Expected:** The restore runs only on a clean UCI save dir, as autotune apply does.


**Actual:** The restore proceeds regardless of staged changes.


**Impact:** With unsaved LuCI edits pending: the restore validates and loads target plus staged deltas, so those edits become live without being committed. LKG is set to the pure target, which never ran alone. A delta may make a good target fail and trigger a rollback. A later 'Save & Apply' merges the stale deltas into the restored file.


**Root cause:** The staged-change guard was added to autotune only.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `fe-app-forkop/src/forkop/tabs/history/initController.ts`

**Proposed fix:** Refuse the restore with {status:'failed', reason:'uncommitted_uci_changes'} when /tmp/.uci/forkop is non-empty (same check as apply.uc/manager.uc uncommitted_changes). The UI asks the user to save or revert pending changes first.


**Tests needed:** config_snapshots.sh with FORKOP-overridable save dir containing a delta -> restore refused, no mutation.


---

<a id="uc-069"></a>

## UC-069 · P3 · S4 — Нечитаемый autotune-apply.json трактуется как отсутствие записанного apply (fail open): пропадают needs_attention и путь отката

**Severity:** P3<br>
**Stage:** S4 (Снимки, восстановление, LKG, recovery)<br>
**Area:** A8 corrupt state handling<br>
**Sources:** persistence#8<br>
**Original title:** An unreadable autotune-apply.json is treated as 'no recorded apply' (fails open): needs_attention and the rollback path disappear<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** autotune/apply.uc:210 `function state_read() { return read_json(STATE_FILE); }` returns null for both missing and corrupt files. apply() :648-653 performs the unresolved check only `if (type(previous) == "object")`. rollback() :762-763 returns 'no_recorded_apply'. status() :793-806 omits `resolved` when the state is null. manager.uc:348 blocks only `if (type(s.state) == "object" && s.resolved === false)`. Compare autotune/state.uc:47-53, which marks a corrupt file as recovered_from.


**Expected:** An unreadable record fails closed and is shown as needing attention.


**Actual:** A corrupt record is indistinguishable from no record.


**Impact:** If the apply record is corrupted (e.g. zero-length after a power cut, see the fsync finding), an unresolved or needs_attention apply stops being reported, the autonomous worker no longer blocks on it, and the operator loses the one-click rollback (invariant 5). Mutation stays blocked by stale_reason (LKG/guard checks), so production is not changed unsafely.


**Root cause:** read_json() folds a parse error into null, and callers treat null as 'absent'.


**Affected files:** `forkop/files/usr/lib/autotune/apply.uc`

**Proposed fix:** Distinguish missing from unreadable: if the file exists but does not parse to an object, return { phase: 'needs_attention', reason: 'apply_state_unreadable' }. Status should then report resolved=false (the blocker then applies) and keep the corrupt file as .corrupt for inspection.


**Tests needed:** autotune_recovery.sh: a garbage autotune-apply.json must make status resolved=false, block manager runs with apply_unresolved, and refuse a new apply.


---

<a id="uc-070"></a>

## UC-070 · P3 · S5 — config.json sing-box публикуется неатомарно через `mv` между файловыми системами (unlink + копирование) и перезаписывается при каждом переходе DNS-failover

**Severity:** P3<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A8 generated config<br>
**Sources:** persistence#4<br>
**Original title:** sing-box config.json is published with a cross-filesystem `mv` (unlink + copy), not atomically, and is rewritten on every DNS-failover transition<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** singbox/runtime.uc:188-189 `temp_path()` -> `mktemp` (/tmp, tmpfs). :687 `command_success_from_args([ "mv", "-f", temp_file_path, config_path ])`; the default config_path is /etc/sing-box/config.json (etc/config/forkop:46), on the overlay. Restores at :706 and :831 use the same cross-fs mv from /tmp. busybox mv on EXDEV unlinks the destination and then copies (no rename, no fsync). DNS failover: dns_failover.uc:207-228 -> lifecycle.uc:1616-1668 -> runtime.uc:769-825 patch_dns_config rewrites the file on each failover/recovery (threshold 3 x 10 s, recovery check every 60 s, dns_failover.uc:261-312). By contrast, components/action.uc:1326-1339 move_file_portable stages next to the target and renames.


**Expected:** rename() from a temp file in the same directory.


**Actual:** Destination is unlinked, then copied; the old file is gone before the new one is complete.


**Impact:** A crash or ENOSPC during the copy leaves config.json missing or truncated. Forkop regenerates it on the next start, so the effect is transient. A flapping upstream DNS causes a full config rewrite on flash every ~30-90 s, plus a sing-box restart.


**Root cause:** The temp file is created in /tmp, a different filesystem from config_path.


**Affected files:** `forkop/files/usr/lib/singbox/runtime.uc`, `forkop/files/usr/lib/singbox/dns_failover.uc`

**Proposed fix:** In save_config_file/restore, copy to `config_path + ".forkop-new.<pid>"` in the target dir, then fs.rename (reuse the move_file_portable pattern). Optionally add hysteresis or a minimum dwell time to failover recovery to bound rewrites.


**Tests needed:** Unit: save_config_file must stage in dirname(config_path) (assert no mv from /tmp). DNS failover fixture: count config rewrites under an alternating health pattern.


---

<a id="uc-071"></a>

## UC-071 · P3 · S5 — Откат reload dnsmasq перезаписывает /etc/config/dhcp целиком через `cp` из бэкапа (неатомарно, в обход блокировки UCI, с потерей параллельных правок dhcp)

**Severity:** P3<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A8 dnsmasq config<br>
**Sources:** persistence#5<br>
**Original title:** dnsmasq reload rollback overwrites /etc/config/dhcp with a whole-file `cp` backup (not atomic, bypasses the UCI lock, loses concurrent dhcp edits)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/lifecycle.uc:142 DNSMASQ_CONFIG_FILE=/etc/config/dhcp; :590-604 snapshot_dnsmasq_reload_config `cp /etc/config/dhcp <mktemp>`; :606-615 restore_dnsmasq_reload_config `cp dns_reload_backup DNSMASQ_CONFIG_FILE` then restart dnsmasq; called from abort_reload :1265 after dnsmasq was reconfigured (:1966-1981).


**Expected:** An atomic, scoped rollback that never discards foreign edits.


**Actual:** In-place cp of a stale whole-file backup.


**Impact:** If a reload fails after the dnsmasq step (cron refresh or state write failure), any dhcp change committed during the reload (e.g. a static lease added in LuCI) is silently reverted. A crash or ENOSPC during the cp leaves a truncated /etc/config/dhcp, which breaks LAN DHCP/DNS on the next dnsmasq start.


**Root cause:** The reload rollback snapshots the entire dhcp file instead of Forkop's own options.


**Affected files:** `forkop/files/usr/lib/service/lifecycle.uc`

**Proposed fix:** Roll back through the UCI operations Forkop already owns (dns/apply.uc restore/configure with force) instead of a whole-file copy. If a file copy is kept, write to /etc/config/.dhcp.forkop.<pid>, sync, rename, and only when the current file hash equals the hash recorded right after Forkop's own commit (compare-and-swap).


**Tests needed:** Reload failure fixture: modify an unrelated dhcp section during the reload; after the failure that change must survive and Forkop's options must be restored.


---

<a id="uc-072"></a>

## UC-072 · P3 · S5 — Постоянный кэш списков (flash, до 8 MiB) полностью перезаписывается при каждом успешном обновлении, даже без изменений; у интервала нет нижней границы

**Severity:** P3<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A9 flash wear<br>
**Sources:** persistence#6<br>
**Original title:** Persistent list cache (flash, up to 8 MiB) is fully rewritten on every successful list update even when nothing changed; the interval has no lower bound<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** components/updates.uc:3995-4000 `let cache_persisted = ok && persist_list_cache(completed_at);` runs regardless of generation_changed. :1025-1081 persist_list_cache copies every file into /etc/forkop/list-cache.stage, writes the manifest and timestamp, and swaps dirs, with no comparison against the persistent manifest (the runtime path has one at :997-1003). The cap is 8 MiB (:33). The interval is free-form: the UI hint suggests '30m' (luci .../settings.js:516-549) and the validator only checks the duration format (validator.uc:871-886); cron can run every minute (updates.uc:1320-1340). Scratch repro_list_persist.sh: the persistent file inode changes on the second persist with identical content.


**Reproduction:** wsl bash scratch/audit-atomicity/repro_list_persist.sh


**Expected:** Flash is written only when the list content changed (the timestamp alone may be updated).


**Actual:** Full copy and dir swap on every successful update.


**Impact:** With update_interval=30m the whole list cache is rewritten on flash 48 times a day even when the lists are unchanged (up to ~0.4 GB/day at the cap). With the default of 1 day it is one full rewrite per day.


**Root cause:** The unchanged-generation short-circuit exists for the runtime generation only.


**Affected files:** `forkop/files/usr/lib/components/updates.uc`

**Proposed fix:** In persist_list_cache: if the persistent generation is valid and list_generation_manifest_content_equal(persistent.manifest, runtime.manifest), atomically replace only last-success.timestamp (tmp + rename inside the active dir) and return true. Optionally enforce a minimum update_interval (e.g. 1h).


**Tests needed:** tests/list_cache.sh: persisting an identical generation twice must keep the file inodes and update only the timestamp.


---

<a id="uc-073"></a>

## UC-073 · P3 · S5 — history.jsonl: оборванная последняя строка поглощает следующее записанное событие; дозапись и ротация выполняются без блокировки

**Severity:** P3<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A8 persistent journal<br>
**Sources:** persistence#7<br>
**Original title:** history.jsonl: a torn last line swallows the next recorded event; append and rotation are unlocked<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** diagnostics/health.uc:93-96 `fs.open(HISTORY_FILE, "a"); file.write(sprintf("%J\n", event))` appends without ensuring the previous line ends with a newline. :76-88 history_events drops unparsable lines. :97-110 rotation reads all records, then writes tmp and renames with no lock, so an event appended by another process between the read and the rename is lost. Scratch repro_history_torn.sh: after a torn line '{"kind":"reload","status":"succ', `record restore success` produces a merged invalid line, and `history` returns only the earlier 'start' event. tests/history_journal.sh:60-62 covers only a newline-terminated corrupt line.


**Reproduction:** wsl bash scratch/audit-atomicity/repro_history_torn.sh


**Expected:** A torn record costs at most that record.


**Actual:** The first event after a torn line is lost.


**Impact:** After a power cut mid-append, the next significant event (e.g. a restore or autotune_apply) is missing from the persistent history. Rarely, a concurrent event is dropped during rotation.


**Root cause:** A line-oriented append without a terminator check, plus an unlocked read-modify-write rotation.


**Affected files:** `forkop/files/usr/lib/diagnostics/health.uc`

**Proposed fix:** Before appending, if the file is non-empty and does not end with '\n', write a leading '\n'. Serialize append+rotation with an flock on a /var/run lock file (as autotune/manager.uc:218-226 does).


**Tests needed:** tests/history_journal.sh: an unterminated last line followed by a record must keep the new event; concurrent record calls around the cap must not lose events.


---

<a id="uc-074"></a>

## UC-074 · P3 · S5 — Восстановление состояния autotune переименовывает повреждённый файл до записи замены; сбой записи теряет recovered_at (cooldown) и бюджет apply

**Severity:** P3<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A8 corrupt state handling<br>
**Sources:** persistence#9<br>
**Original title:** Autotune state recovery renames the corrupt file away before the replacement is written; a failed write loses recovered_at (cooldown) and the apply budget<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** autotune/state.uc:78-89 write(): `fs.rename(STATE_FILE, STATE_FILE + ".corrupt"); if (state.recovered_at == null) state.recovered_at = time(); ... return write_atomic(STATE_FILE, text, 0600);`. If write_atomic fails, no state.json exists. read() :47-53 then returns empty() without recovered_from (data == null), so recovered_at is null. autoapply.uc:45-49 lifts the 'state_recovered' cooldown, and applies_today starts from zero. manager.uc:231-238 with_state ignores the write result.


**Expected:** The recovery marker (recovered_at) is either durably written or the corrupt file is still present.


**Actual:** The corrupt file is removed before the recovery marker is durable.


**Impact:** A corrupt state file plus one failed flash write (transient ENOSPC, e.g. during a large list staging) silently turns 'recovered, wait a cooldown' into 'fresh install'. This is fail-open against invariant 18. It is mitigated because hysteresis confirmations are also lost and apply.uc must persist its own state before mutating.


**Root cause:** Operations run in the wrong order in write().


**Affected files:** `forkop/files/usr/lib/autotune/state.uc`, `forkop/files/usr/lib/autotune/manager.uc`

**Proposed fix:** Write the new state to tmp first, then rename the old file to .corrupt, then rename tmp to state.json. Alternatively copy the corrupt file (not rename) and rename over it only after the new tmp is complete. Make with_state propagate the write failure so run_locked aborts.


**Tests needed:** autotune_recovery.sh: corrupt state + failing write (read-only dir) must still report state_recovered on the next read.


---

<a id="uc-075"></a>

## UC-075 · P3 · S5 — Воркер autotune дважды каждые 15 минут перезаписывает state.json на flash, пока заблокирован (например, needs_attention)

**Severity:** P3<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A9 flash wear<br>
**Sources:** persistence#10<br>
**Original title:** Autotune worker rewrites state.json on flash twice every 15 minutes while it is blocked (e.g. needs_attention)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** autotune/manager.uc:56 CRON_SCHEDULE '*/15'; :58 RETRY_SECONDS=900. run_locked :502 begin_run writes worker={state:'running',...} (:471-495) before :511 `let reason = blocker();`. When blocked, :573 sets next_run_at = now()+900, and merge (:382-404) writes again. blocker (:341-349) includes dpi_guard_present and apply_unresolved, which persist until the operator acts. state.uc write-if-changed (:86-87) does not help because timestamps always change.


**Expected:** No flash writes for runs that do nothing.


**Actual:** Two flash writes per blocked tick.


**Impact:** About 192 flash rewrites of state.json per day (several to tens of KB each) for as long as a needs_attention/guard state is left unresolved (can be days).


**Root cause:** The crash-detection marker is written before the cheap blocker check.


**Affected files:** `forkop/files/usr/lib/autotune/manager.uc`

**Proposed fix:** Check blocker() (read-only) before begin_run. When blocked, record the skip and the retry next_run_at in /var/run (or persist next_run_at only if it moves by more than an hour) and do not touch the flash state.


**Tests needed:** autotune scheduler test: with apply_unresolved, if-due must not modify state.json mtime.


---

<a id="uc-076"></a>

## UC-076 · P3 · S5 — Общие системные файлы перезаписываются на месте (rt_tables, фиды пакетов); откат зеркала игнорирует ошибки и всегда сообщает об успехе

**Severity:** P3<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A8 system files<br>
**Sources:** persistence#11<br>
**Original title:** Shared system files are overwritten in place (rt_tables, package feeds); mirror rollback ignores failures and always claims success<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/package.uc:108-124 `fs.writefile(RT_TABLES_PATH, join("\n", lines))` at every prerm (upgrade/remove); nft/apply.uc:1344-1354 `write_text_file(path, data + table_id ...)` at the first start after install; both write /etc/iproute2/rt_tables directly (truncate + write). mirror-migration.sh:116 `cp "$temporary" "$repository_file"` (also :193, :202); rollback :56 `cp "$backup" "$destination" 2>/dev/null || true`, then :66 always prints 'package feeds and keys were restored'.


**Expected:** Atomic replacement; truthful rollback reporting.


**Actual:** In-place truncating writes; unconditional success message.


**Impact:** A crash or ENOSPC during an upgrade can truncate rt_tables (entries from other packages lost) or opkg/apk feeds (package management broken). If the rollback cp fails, the user is told the feeds were restored.


**Root cause:** Direct writefile/cp onto the live file.


**Affected files:** `forkop/files/usr/lib/service/package.uc`, `forkop/files/usr/lib/nft/apply.uc`, `forkop/files/usr/share/forkop/mirror-migration.sh`

**Proposed fix:** Write to `<file>.forkop.<pid>` in the same dir, then mv/rename (as full-uninstall.sh:99-103 already does). In mirror-migration rollback, track cp failures and print a different message plus a non-zero status when any restore failed.


**Tests needed:** package_contract/mirror migration tests: assert replacement via a same-dir temp, and that a failing rollback cp changes the message and status.


---

<a id="uc-077"></a>

## UC-077 · P3 · S6 — Восстановление при отсутствующем/пустом конфиге в package_postinst недостижимо: предшествующие шаги миграции и миграции зеркала падают без конфига

**Severity:** P3<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** package lifecycle / upgrade ordering<br>
**Sources:** packaging#4<br>
**Original title:** package_postinst's missing/empty-config recovery can never run: the migration and mirror-migration steps before it fail on a missing config<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** package.uc:202-214 restores /etc/config/forkop from /usr/share/forkop/defaults when missing or empty (tested in isolation by package_lifecycle.sh case 3). In the real chain (build.sh:300-302, :438, :461; Makefile:55-57) it runs only after `migration.uc migrate` and `mirror-migration.sh`. mirror-migration.sh:216 `"$UCI_BIN" -q set "$SETTINGS_SECTION.mirror_base_url=..."` under `set -eu`. Scratch check with the OpenWrt uci CLI (scratch/audit-a26/uci_missing.sh): missing package -> `set rc=1`, empty file -> `set rc=1`, settings present -> `set rc=0`.


**Reproduction:** `: > /etc/config/forkop; opkg install --force-reinstall forkop_<v>.ipk` -> postinst fails at mirror-migration; config stays empty.


**Expected:** A missing or empty config is replaced by packaged defaults before migrations run.


**Actual:** Recovery code is unreachable in the chain it was written for.


**Impact:** When the config file is absent or 0 bytes at install/upgrade time (user deleted it, power-loss truncation, apk keeping the file absent and writing .apk-new), the chain aborts before the defaults are restored. Forkop stays stopped with no config, and apk/opkg report a script error.


**Root cause:** Step ordering in the maintainer scripts.


**Affected files:** `build.sh`, `forkop/Makefile`, `forkop/files/usr/lib/service/package.uc`, `forkop/files/usr/share/forkop/mirror-migration.sh`

**Dependencies:** Combine with the known-P2 fix to the same chain.


**Proposed fix:** Restore the config first. Split the restore into its own step, e.g. `forkop package_postinst restore-config` (or a package.uc mode) run before `migration.uc migrate`, or make mirror-migration.sh skip its uci writes when `uci -q get forkop.settings` fails.


**Tests needed:** Chain-level test: empty /etc/config/forkop + fake uci CLI; run the postinst sequence; assert defaults restored and exit 0.


**Risk:** Low


---

<a id="uc-078"></a>

## UC-078 · P3 · S6 — Аварийное восстановление dnsmasq в package.uc запускает `ucode dns/apply.uc` без -L и всегда падает (No module named 'core.uci')

**Severity:** P3<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** package prerm<br>
**Sources:** packaging#6<br>
**Original title:** package.uc failsafe dnsmasq restore runs `ucode dns/apply.uc` without -L and always fails (No module named 'core.uci')<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** package.uc:147-149 `command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]); if (path_exists(DNS_APPLY_UC)) command_success_from_args([ "ucode", DNS_APPLY_UC, "failsafe-restore" ]);`; dns/apply.uc:4 `let uci = require("core.uci");`. Scratch run (scratch/audit-a26/noL.sh, cwd=/): without -L `Runtime error: No module named 'core.uci' could be found ... rc=254`; with `-L <lib>` rc=0. Every other caller passes -L (bin/forkop:42).


**Reproduction:** `cd / && ucode /usr/lib/forkop/dns/apply.uc failsafe-restore; echo $?`


**Expected:** The fallback performs the failsafe restore.


**Actual:** The fallback always exits 254.


**Impact:** The second-line dnsmasq restore in prerm is dead code. If the primary `forkop restore_dnsmasq` fails, dnsmasq may keep pointing at Forkop's DNS after the package is removed, and the failure is silent.


**Root cause:** Missing module search path.


**Affected files:** `forkop/files/usr/lib/service/package.uc`

**Dependencies:** None


**Proposed fix:** `[ "ucode", "-L", env("FORKOP_LIB", "/usr/lib/forkop"), DNS_APPLY_UC, "failsafe-restore" ]`.


**Tests needed:** package_lifecycle.sh: without PACKAGE_TEST_MODE, fake BIN restore failing, assert dns/apply.uc failsafe-restore ran successfully; or a static check that every `"ucode", <path>.uc` call includes -L.


**Risk:** None


---

<a id="uc-079"></a>

## UC-079 · P3 · S6 — Полное удаление оставляет /etc/forkop-backups/configuration.tar.gz (полный конфиг с секретами), хотя UI обещает удалить настройки

**Severity:** P3<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** full uninstall<br>
**Sources:** packaging#8<br>
**Original title:** Full uninstall leaves /etc/forkop-backups/configuration.tar.gz (full config with secrets) although the UI promises removal of settings<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-10

**Evidence:** action.uc:2385 `save_forkop_configuration_backup("/etc/config", "/etc/forkop-backups")` (tar of /etc/config/forkop, :2329). full-uninstall.sh:116-117 `for directory in /etc/forkop /etc/sing-box /tmp/sing-box /usr/lib/forkop /usr/share/forkop /www/luci-static/resources/view/forkop` (no /etc/forkop-backups). luci-app-forkop/po/ru/forkop.po:2501 msgid "Remove Forkop X, sing-box, their settings and cache, and restore the original device repositories?"


**Reproduction:** Install a release via the version picker, then Full uninstall; `ls /etc/forkop-backups` still lists configuration.tar.gz.


**Expected:** All Forkop settings, including backups, are removed, or the UI states which ones are kept.


**Actual:** The backup archive survives uninstall.


**Impact:** After a completed Full uninstall the router still stores the Forkop config (subscription URLs, proxy credentials) in /etc/forkop-backups, contrary to the confirmation text. It is also included in any later full-overlay backup.


**Root cause:** The backup directory (added in 1.0.26) was not added to the uninstall path list.


**Affected files:** `forkop/files/usr/lib/full-uninstall.sh`

**Dependencies:** None


**Proposed fix:** Add /etc/forkop-backups to the directory list in full-uninstall.sh:116. If keeping it for reinstall is intended, say so explicitly in the confirmation text instead.


**Tests needed:** full_uninstall_cleanup.sh: create /etc/forkop-backups/configuration.tar.gz in the fake root and assert removal.


**Risk:** None


---

<a id="uc-080"></a>

## UC-080 · P3 · S6 — Остаток F-008: путь по умолчанию 'install latest' в приложении по-прежнему ставит пакеты без проверки SHA-256

**Severity:** P3<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** self-update supply chain<br>
**Sources:** packaging#9<br>
**Original title:** Residual of F-008: the default 'install latest' in-app path still installs packages without SHA-256 verification<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** action.uc:2383-2389 `if (selected != null) { verify_selected_release_downloads(...); ... }`, so only the version-picker path verifies. The latest path uses resolve_forkop_release -> updater.uc:237-266 forkop_release_plan, which emits only names/URLs; downloads are checked only with file_nonempty (:636-645) and installed with `apk add --allow-untrusted` (:405-410). ops/hosting/prepare-release.sh already writes `sha256` for every asset into updates/latest.json. AUDIT_VALIDATION.md classifies F-008 as TECHNICAL_DEBT, not fixed.


**Reproduction:** Serve a latest.json whose sha256 does not match the asset; the in-app 'Install latest' proceeds to apk/opkg.


**Expected:** Every in-app install verifies SHA-256 like install.sh.


**Actual:** Digest is verified only for explicitly selected versions.


**Impact:** A tampered or partially replaced asset on the release host is installed with root maintainer scripts via the most common update button, while the picker path and install.sh would reject it.


**Root cause:** The 1.0.26 digest check was added only to the new picker path.


**Affected files:** `forkop/files/usr/lib/components/action.uc`, `forkop/files/usr/lib/components/updater.uc`

**Dependencies:** Known F-008 (technical debt)


**Proposed fix:** Emit the asset sha256 from forkop_release_plan (the fields are already in latest.json) and call the same check as verify_selected_release_downloads for the latest path; fail closed on a missing digest.


**Tests needed:** Probe test: latest.json with sha256 X, downloaded file hash Y -> action_fail before any package manager call.


**Risk:** Low


---

<a id="uc-081"></a>

## UC-081 · P3 · S6 — Каждая установка/обновление пакета Forkop молча переключает официальные фиды OpenWrt на зеркало и заново доверяет его ключу, даже если пользователь вернул официальные фиды

**Severity:** P3<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** mirror-migration.sh<br>
**Sources:** packaging#10<br>
**Original title:** Every Forkop package install/upgrade silently re-points official OpenWrt feeds to the mirror and re-trusts the mirror key, even after the user restored official feeds<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-3

**Evidence:** mirror-migration.sh:4 `MIGRATION_ID="mirror_infotechtg_ru_v1"` is only written (:217-220), never checked. :176-205 unconditionally rewrites `/etc/apk/repositories`, `repositories.d/distfeeds.list` or `/etc/opkg/distfeeds.conf` from downloads.openwrt.org to MIRROR_BASE_URL, installs `/etc/apk/keys/forkop-mirror.pem` (a global apk trust key) and forkop.list. :115 keeps the first `.pre-forkop-mirror` backup forever. Run from every postinst (build.sh:301/438/461).


**Reproduction:** Restore official distfeeds, upgrade Forkop, inspect distfeeds: mirror URLs are back.


**Expected:** A one-time migration, or an explicit opt-out that is respected.


**Actual:** The migration re-runs in full on every package script invocation.


**Impact:** A user who reverted to official OpenWrt feeds (for example because the mirror was down) gets them rewritten on the next Forkop update without being asked, and every upgrade depends on the mirror (the root of the known P2).


**Root cause:** The migration marker is recorded but never consulted.


**Affected files:** `forkop/files/usr/share/forkop/mirror-migration.sh`

**Dependencies:** Known P2


**Proposed fix:** Decide the policy. Either run the feed rewrite only when MIGRATION_ID is not yet applied or when the feeds still point at a retired mirror (51343), or keep re-applying but log it clearly and let the user opt out (setting such as settings.manage_package_feeds=0).


**Tests needed:** mirror_migration.sh: applied marker + official feeds -> no rewrite (if policy chosen).


**Risk:** Policy change affects users on stale mirrors; tests own_mirror_migration.sh/openwrt24_mirror_contract.sh pin the current behaviour.


---

<a id="uc-082"></a>

## UC-082 · P3 · S6 — Два рецепта сборки пакетов разошлись: forkop/Makefile (SDK) не ставит forkop-torrserver-direct и имеет иную семантику скриптов пакета, чем build.sh

**Severity:** P3<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** packaging<br>
**Sources:** map#3, packaging#7<br>
**Original title:** Два рецепта сборки пакетов разошлись: forkop/Makefile (SDK) не ставит forkop-torrserver-direct и имеет другую семантику скриптов пакета, чем build.sh<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-21

**Evidence:** build.sh:193 `install -m 0755 ".../etc/init.d/forkop-torrserver-direct" ...` (релизные артефакты собираются build.sh: .github/workflows/build.yml:106). Package/forkop/install в forkop/Makefile ставит только `./files/etc/init.d/forkop`. components/action.uc:2538 `if (!file_exists(TORRSERVER_DIRECT_INIT) ...) action_fail(... "TorrServer Direct service is not available")`. Хуки из Makefile обёрнуты в сгенерированные OpenWrt default_postinst/default_prerm (enable/start/disable/stop init-скриптов пакета), а тело prerm в Makefile написано на ucode (`#!/usr/bin/ucode`), тогда как default_prerm подключает prerm-pkg из sh. build.sh пишет собственные control-скрипты без default_* (build.sh:297-314, 435-463). Тесты только grep'ают Makefile (package_contract.sh, package_lifecycle.sh:48-53, constants_owner.sh:39) и никогда его не собирают.


**Reproduction:** Сравнить forkop/Makefile Package/forkop/install с build.sh build_backend_root.


**Expected:** Один источник истины для содержимого пакета и его хуков.


**Actual:** Две сборочные схемы с разными наборами файлов и разной семантикой скриптов пакета; синхронизацию никто не проверяет.


**Impact:** Пакет, собранный из OpenWrt feed/SDK по forkop/Makefile, ведёт себя иначе, чем релизный: нет TorrServer Direct; скорее всего, другое поведение enable/start при установке (включение и запуск init-скриптов через default_postinst, в отличие от install.sh с «сначала проверьте правила»); ucode-тело prerm может не выполниться при подключении из sh. Код рабочего пути не затронут.


**Root cause:** build.sh появился как самостоятельный сборщик ipk/apk, а исходные Makefile SDK сохранили и частично закрепили grep-тестами, но не поддерживали в паритете.


**Affected files:** `forkop/Makefile`, `luci-app-forkop/Makefile`, `build.sh`, `tests/package_contract.sh`, `tests/package_lifecycle.sh`

**Dependencies:** Связано с находкой о семантике удаления torrserver-direct.


**Proposed fix:** Решить, поддерживается ли вообще путь через SDK. Если нет — удалить forkop/Makefile и luci-app-forkop/Makefile вместе с grep-тестами на них. Если да — довести Makefile до паритета (добавить init-скрипт torrserver, prerm на sh, вызывающий `/usr/bin/forkop package_prerm`) и добавить тест, сравнивающий списки устанавливаемых файлов Makefile и build_backend_root.


**Tests needed:** Проверка паритета списков файлов (Makefile install и build_backend_root). Если Makefile остаётся — sh-синтаксис (sh -n) для тела prerm.


### Also reported as packaging#7 (P3): SDK/feed build path (forkop/Makefile) produces broken lifecycle scripts and behaves differently from build.sh packages

**Evidence:** forkop/Makefile:42-49 `define Package/forkop/prerm` / `#!/usr/bin/ucode` / `if (getenv("IPKG_INSTROOT") == null ...`. OpenWrt 24.10 package-pack.mk writes it as prerm-pkg, which default_prerm sources with sh (`( . "$root/usr/lib/opkg/info/${pkgname}.prerm-pkg" )`, functions.sh) for IPK, and inlines it into the sh pre-deinstall (`cat "$(ADIR)/prerm-pkg"; echo default_prerm`) for APK, which is an sh syntax error. The SDK postinst always calls default_postinst, which runs `"$i" enable` (fresh install) and `"$i" start` for every /etc/init.d file. Makefile:64-82 does not install etc/init.d/forkop-torrserver-direct (build.sh:193 does). Makefile:8 accepts only x.y.z; build.sh:18 also accepts x.y.z-N. tests/package_lifecycle.sh:48-49 pins `#!/usr/bin/ucode` in the Makefile.


**Proposed fix:** Make the Makefile hooks shell wrappers that mirror build.sh semantics without default_postinst side effects, e.g. prerm `[ -n "$${IPKG_INSTROOT}" ] || /usr/bin/forkop package_prerm "$$1" >/dev/null 2>&1; true`. Install forkop-torrserver-direct. Either accept the SDK's default_postinst enable/start or document/remove the SDK path; update package_lifecycle.sh accordingly. Alternatively drop forkop/Makefile support (product decision).


---

<a id="uc-083"></a>

## UC-083 · P3 · S6 — Удаление пакета и полное удаление не останавливают и не отключают forkop-torrserver-direct; ссылки в rc.d остаются висеть

**Severity:** P3<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** packaging / uninstall<br>
**Sources:** map#4, packaging#5<br>
**Original title:** Удаление пакета и полное удаление не останавливают и не отключают forkop-torrserver-direct; ссылки в rc.d остаются висеть<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** Хуки бэкенда в build.sh вызывают только `/usr/bin/forkop package_prerm` (build.sh:305-312, 442-455) без default_prerm; service/package.uc:178-189 prerm_cleanup вызывает только `command_success_from_args([ INIT_PATH, "stop" ])` для /etc/init.d/forkop (без disable, torrserver не упоминается). full-uninstall.sh:78-87 останавливает и отключает только forkop и sing-box; :120-127 удаляет /etc/init.d/forkop, но не /etc/init.d/forkop-torrserver-direct и её ссылки rc.d. etc/init.d/forkop-torrserver-direct: `START=100`, `STOP=9`, procd instance `torrserver/direct.uc worker` с respawn. torrserver/direct.uc:68 enabled() читает forkop.settings.torrserver_direct_enabled; worker (:117-129) крутится, пока включено.


**Reproduction:** Статически: в package.uc и full-uninstall.sh нет ни одного упоминания torrserver (rg -i torrserver).


**Expected:** Удаление пакета останавливает и отключает все init-службы, которые пакет поставляет, и убирает их nft-состояние.


**Actual:** Вторая служба в пакете бэкенда в хуках удаления никогда не останавливается и не отключается.


**Impact:** Если TorrServer Direct был включён, то после `opkg remove forkop` / `apk del forkop` (/etc/config/forkop сохраняется как conffile) procd-воркер продолжает работать из загруженного скрипта и держит nft-таблицу ForkopTorrServerDirect, которая помечает трафик TorrServer меткой 0x08000000, хотя Forkop уже удалён. /etc/rc.d/S100forkop-torrserver-direct, K9... и S99forkop остаются висящими ссылками. При полном удалении конфиг удаляется, и воркер сам удаляет свою таблицу в течение 60 с, но ссылки rc.d остаются.


**Root cause:** Кастомные хуки пакета заменяют default_prerm OpenWrt, но включают только жизненный цикл основной службы forkop. Службу torrserver добавили позже, и хуки удаления на неё не обновили.


**Affected files:** `forkop/files/usr/lib/service/package.uc`, `forkop/files/usr/lib/full-uninstall.sh`, `build.sh`, `forkop/files/usr/lib/torrserver/direct.uc`

**Proposed fix:** В service/package.uc prerm_cleanup (для action remove) и в full-uninstall.sh (фаза stop) вызвать `/etc/init.d/forkop-torrserver-direct stop` и `disable` (у stop_service уже есть `direct.uc remove`), а для forkop при удалении выполнять `disable`.


**Tests needed:** full_uninstall_cleanup.sh: fixture с исполняемым /etc/init.d/forkop-torrserver-direct → ожидаются вызовы stop и disable. package_lifecycle.sh: prerm remove вызывает stop/disable для torrserver-direct.


### Also reported as packaging#5 (P3): forkop-torrserver-direct is never stopped/disabled on removal or full uninstall and never restarted on upgrade; its worker caches UCI and re-adds its nft table until reboot

**Evidence:** full-uninstall.sh:77-87 stop phase handles only /etc/init.d/forkop and sing-box; the removal lists at :116-129 do not include forkop-torrserver-direct or its /etc/rc.d links. package.uc:183-194 prerm_cleanup stops only INIT_PATH. torrserver/direct.uc:119-130 `while (enabled()) { ... if (info.available && (... || !active(info))) apply_rule(info) ... system("sleep 60"); }`; enabled() (:68) uses core.uci, whose cursor and loaded_packages are cached for the process lifetime (core/uci.uc:11-12, 282-296, 319-332), so deleting /etc/config/forkop never ends the loop. Only `/etc/init.d/forkop-torrserver-direct stop` removes the table (init.d:18-20, used by action.uc:2558-2559).


**Proposed fix:** In package.uc prerm_cleanup and full-uninstall.sh stop phase run `[ -x /etc/init.d/forkop-torrserver-direct ] && /etc/init.d/forkop-torrserver-direct stop` (plus `disable` on remove/uninstall). In package_postinst, restart it when settings.torrserver_direct_enabled=1. Optionally have the worker re-read config each loop (fresh `uci -q get` or a new cursor).


---

<a id="uc-084"></a>

## UC-084 · P3 · S6 — Защита полного удаления неполна: команды config/snapshot/autotune-policy и DNS-failover не блокируются, а удаление не ждёт транзакций снимков и autotune

**Severity:** P3<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** A7 locks / full_uninstall<br>
**Sources:** process-locks#12, snapshots#13, cli-contract#12<br>
**Original title:** Full-uninstall guard is incomplete: config/snapshot/autotune-policy and DNS-failover commands are not blocked, and uninstall does not wait for snapshot or autotune transactions<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** usr/bin/forkop:259-266 blocks only start/main/restart/reload/enable/service_action_async/component_action*/subscription_*/list_*/autotune_run*/autotune_if_due/autotune_apply*. It does not block config_snapshot_restore/create/delete, urltest_override_save/reset, autotune_policy_set/target_set/target_remove, dns_failover_apply or clash_api set_group_proxy. full-uninstall.sh:77-87,112-140 stops and removes files without taking the snapshot or autotune locks. snapshots.uc:330-347: when a restore's reload fails (the CLI refuses `forkop reload` during uninstall), the restore rewrites /etc/config/forkop and keeps the ForkopConfigRestoreDpiGuard table.


**Reproduction:** Code reading.


**Expected:** Full uninstall is exclusive with every configuration mutation.


**Actual:** Config and snapshot transactions are unguarded against a concurrent full uninstall.


**Impact:** A restore, snapshot create or autotune apply in flight or issued (for example from another LuCI tab) during full uninstall can re-create /etc/config/forkop or /etc/forkop/config-snapshots after the files phase. It can also leave an nft guard table and a needs_attention state behind a 'complete' uninstall. Low likelihood; the leftover guard only drops provider-marked packets.


**Root cause:** The CLI block list is maintained by hand and misses newer commands.


**Affected files:** `forkop/files/usr/bin/forkop`, `forkop/files/usr/lib/full-uninstall.sh`

**Dependencies:** None.


**Proposed fix:** Add the mutating commands to the CLI block list. In full-uninstall.sh, wait for (or refuse while) live snapshot or autotune lock owners before the stop phase.


**Tests needed:** full_uninstall.sh: with the uninstall lock present, every mutating CLI command returns non-zero (table-driven over command_spec).


**Risk:** Low.


### Also reported as snapshots#13 (P3): config_snapshot_restore/create/delete are not blocked during full uninstall

**Evidence:** forkop:259-263: the full-uninstall blocklist contains start, reload, autotune_apply and others, but not config_snapshot_restore/create/delete. During uninstall `reload` is refused (returns 1), so a restore's target reload and rollback reload both fail -> needs_attention with ForkopConfigRestoreDpiGuard left installed. ensure_root() can recreate /etc/forkop/config-snapshots after the files phase.


**Proposed fix:** Add config_snapshot_create, config_snapshot_delete and config_snapshot_restore to the full-uninstall blocklist in /usr/bin/forkop.


### Also reported as cli-contract#12 (CLEANUP): The full-uninstall gate is a hand-maintained list that misses config and crontab writers; the help text omits UI-used commands

**Evidence:** forkop:259-266: the gate list does not include config_snapshot_restore/create/delete, urltest_override_save/reset, autotune_policy_set/target_set/target_remove, latency_test_async or dns_failover_apply. autotune_policy_set → cron_sync writes `*/15 * * * * /usr/bin/forkop autotune_if_due` into the crontab (autotune/manager.uc:178-198, :278-281) regardless of service or uninstall state. show_help (forkop:53-143) omits get_history, get_readonly_config_sections, get_dashboard_runtime_metadata, urltest_override_*, dns_failover_apply, dnsmasq_restore/restore_dnsmasq, package_*, luci_postinst. An unknown command prints help to stdout with rc 1 (forkop:268-271).


**Proposed fix:** Derive the gate from a per-command 'mutating' flag in command_spec (a 4th element) and gate all mutating commands. Print usage to stderr for unknown commands. List the public UI commands in the help text.


---

<a id="uc-085"></a>

## UC-085 · P3 · S6 — Текст управляемого init-скрипта sing-box существует в трёх копиях; они разошлись в `procd_set_param file`

**Severity:** P3 (изменено при ревью плана; по аудиту и проверке — CLEANUP)<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** duplicate generator<br>
**Sources:** map#7<br>
**Original title:** Текст управляемого init-скрипта sing-box существует в трёх копиях; они разошлись в `procd_set_param file`<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** singbox/runtime.uc:395-425 managed_service_text() — без `procd_set_param file` (строку намеренно убрали в e6de2112 «Release 1.0.14 with controlled runtime transitions», diff: `-        "    procd_set_param file \"$config_file\"\n" +`). components/action.uc:829-856 managed_sing_box_service_text() и config/validator.uc:1795-1832 managed_sing_box_service_script() по-прежнему содержат `"    procd_set_param file \"$config_file\"\n"`. Кто пишет: action.uc:1385/1398/1841 (установка, обновление, откат компонента), validator.uc:1996 (если службы нет), runtime.uc:465 (при каждом configure-service во время start/reload, если выставлен маркер compressed).


**Reproduction:** rg -n 'procd_set_param file' forkop/files/usr/lib


**Expected:** Один текст скрипта, принадлежащий одному модулю.


**Actual:** Три копии текста init-скрипта, одна отличается.


**Impact:** После установки или обновления сжатого варианта sing-box-extended в /etc/init.d/sing-box лежит вариант с `file`, пока следующий старт или reload Forkop не перепишет его. В этом окне `/etc/init.d/sing-box start|reload` при изменившемся config.json заставляет procd перезапустить sing-box вне контролируемого перехода Forkop, чего и избегали в 1.0.14. Практическое влияние небольшое, сами копии расходятся уже сейчас.


**Root cause:** Исправление 1.0.14 затронуло только одну из трёх вставленных копией.


**Affected files:** `forkop/files/usr/lib/singbox/runtime.uc`, `forkop/files/usr/lib/components/action.uc`, `forkop/files/usr/lib/config/validator.uc`

**Proposed fix:** Оставить один генератор (например, режим `managed-service-text`/`install-managed-service` в singbox/runtime.uc) и вызывать его из action.uc и validator.uc.


**Tests needed:** Статический тест: `procd_open_instance` для sing-box встречается ровно в одном модуле; либо все генераторы выдают байт-в-байт одинаковый текст.


---

<a id="uc-086"></a>

## UC-086 · P3 · S7 — Проверка DNS в Diagnostics использует разошедшуюся копию разбора URL (core/helpers.uc) и неверно разбирает IPv6 DNS-серверы: ложная ошибка Bootstrap DNS

**Severity:** P3<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** duplicate helpers / diagnostics<br>
**Sources:** map#2<br>
**Original title:** Проверка DNS в Diagnostics использует разошедшуюся копию разбора URL (core/helpers.uc) и неверно разбирает IPv6 DNS-серверы: ложная ошибка Bootstrap DNS<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** diagnostics/runtime.uc:1246-1248 `function url_host(value) { return helper_output("url-get-host", [ value ]); }` → core/helpers.uc:264-279 url_authority/url_get_host: `let colon = index(authority, ":"); print(colon >= 0 ? substr(authority, 0, colon) : authority` (скобок нет, берётся первое двоеточие). Использование: runtime.uc:1354-1357 `let dns_server_host = url_host(dns_server); ... let bootstrap_dns_required = !core_ip.valid_ip(dns_server_host);` и :1371-1374 bootstrap_check_domain = dns_server_host. Рабочий разбор в других местах: core/url.uc:92-114 host() (обрабатывает [v6] и v6 без скобок); config/validator.uc:888-908 (dns_server_value_valid принимает IPv6 через core_url.host); singbox/dns.uc:100,137 runtime_url.host. Воспроизведено через ucode: `2606:4700:4700::1111` → helpers=`2606` valid_ip=0 против core.url=`2606:4700:4700::1111` valid_ip=1; `[2606:4700:4700::1111]:53` → helpers=`[2606`.


**Reproduction:** Скрипт в scratchpad audit-archmap/urlhost.sh (только чтение), выполнен через WSL ucode; результат приведён в evidence.


**Expected:** Для IP-литерала (v4 или v6) основного DNS bootstrap не требуется, как и в сгенерированном конфиге sing-box.


**Actual:** check_dns_available сообщает bootstrap_dns_required=1 и bootstrap_dns_status=0 для IPv6-литерала основного DNS.


**Impact:** Инвариант 15 (наблюдаемое состояние показано неверно): если основной DNS — IPv6-литерал, который валидатор принимает, а генератор использует без bootstrap, карточка DNS в Diagnostics всё равно помечает bootstrap как обязательный. При одном bootstrap-сервере она делает `dig <bootstrap> 2606 A`, получает сбой и показывает строку «Bootstrap DNS» с ошибкой, а общий итог — не all-good (runDnsCheck.ts:47-62, getDnsCheckPresentation.ts:10-12).


**Root cause:** Две независимые реализации разбора хоста из URL: core/url.uc (обновлялась под IPv6) и legacy core/helpers.uc (не обновлялась). Diagnostics по-прежнему вызывает старую.


**Affected files:** `forkop/files/usr/lib/diagnostics/runtime.uc`, `forkop/files/usr/lib/core/helpers.uc`

**Proposed fix:** В diagnostics/runtime.uc заменить helper_output("url-get-host") на require("core.url").host() — тот же разбор, что у валидатора и генератора. После этого в core/helpers.uc можно удалить режимы, которые никто в рабочем коде не использует (в проде вызываются только version-at-least, server-inbound-tag, url-get-host).


**Tests needed:** diagnostics_status.sh: выполнить check-dns-available с заглушкой dig и dns_server='2606:4700:4700::1111' (и в скобочной форме с портом) → bootstrap_dns_required == 0. Юнит-тест, что url_host в diagnostics совпадает с core.url.host на наборе кейсов.


---

<a id="uc-087"></a>

## UC-087 · P3 · S7 — Приведение регистра IDN в config/domain.uc неполное: заглавные украинские, белорусские, польские, турецкие и греческие метки с ударением дают неверный punycode (найдено дифф-проверкой A28)

**Severity:** P3<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** domain parser (A28 finding)<br>
**Sources:** tests#5<br>
**Original title:** IDN case folding in config/domain.uc is incomplete: uppercase Ukrainian, Belarusian, Polish, Turkish and accented Greek labels get wrong punycode (found by the A28 differential check)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/files/usr/lib/config/domain.uc:36-56 unicode_lower_codepoint() lowercases only ASCII, U+00C0-00DE, U+0401 (Ё), U+0410-042F and U+0391-03AB. Callers: config/rule.uc:4, nft/apply.uc:8, routing/rulesets.uc:5, config/migration.uc:12. Differential against Node url.domainToASCII (UTS46) with scratch/audit-tests/idn_diff.sh gives 8 DIFFs, e.g. 'Їжак.укр' forkop=xn--2za6frar.xn--j1amh vs xn--80aln7i.xn--j1amh; 'Іграшка.укр' xn--1za8fak0b8a7c vs xn--80aah3a2a3c8e; 'Ґанок', 'ЄВРОПА', 'Ўсход', 'ΕΛΛΆΔΑ', 'ŁÓDŹ', 'ÇALIŞ'. Lowercase inputs all match. The frontend validator accepts these values (fe-app-forkop/src/validators/validateDomain.ts uses new URL()) and stores the original text.


**Reproduction:** bash scratch/audit-tests/idn_diff.sh (wsl) -> 'differences: 8'


**Expected:** suffix_to_ascii(x) == url.domainToASCII(x) for the letters the UI accepts.


**Actual:** Uppercase non-Russian Cyrillic/Latin-Ext/Greek-tonos labels are punycoded without case folding.


**Impact:** A user enters a rule domain with an uppercase letter outside the supported ranges (e.g. 'Їжак.укр'). The generated sing-box/nft domain is a punycode label that no DNS query ever carries, so the rule silently never matches and the traffic takes the wrong route.


**Root cause:** The hand-written case map covers only the scripts that were tested (Russian, Latin-1, basic Greek).


**Affected files:** `forkop/files/usr/lib/config/domain.uc`

**Proposed fix:** Extend unicode_lower_codepoint: U+0400-040F -> +0x50; U+0490-04BF even -> +1 (Ґ and friends); Latin Extended-A U+0100-017F pairs (even -> odd, with the usual exceptions); Greek with tonos U+0386 -> 03AC, U+0388-038A -> +0x25, U+038C -> 03CC, U+038E-038F -> +0x3F. Alternatively, lowercase in the LuCI form with String.prototype.toLowerCase before saving. Add the differential property test described in tests_needed.


**Tests needed:** Differential property test: node generates N seeded random labels from Latin/Latin-1/Latin-Ext-A/Cyrillic (incl. Ukrainian and Belarusian letters)/Greek, in mixed case, and compares domain.uc suffix_to_ascii with url.domainToASCII (skip the UTS46 special cases ß/ς/ı/İ explicitly).


---

<a id="uc-088"></a>

## UC-088 · P3 · S7 — Сигнатура reload по умолчанию считает отсутствующий dns_type равным 'doh', а runtime — 'udp'

**Severity:** P3<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** uci-global<br>
**Sources:** uci-global#5<br>
**Original title:** Reload signature defaults a missing dns_type to 'doh' while the runtime defaults it to 'udp'<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/state.uc:1645 `signature_add_value(body, "settings.dns_type", option(settings, "dns_type", "doh"))`, versus singbox/dns.uc:50 `dns_type: option(settings, "dns_type", "udp")`, validator.uc:929 'udp', settings.js dns_type default 'udp' and etc/config 'udp'.


**Reproduction:** wsl bash scratch/audit-a3/dns_type_signature.sh


**Expected:** signature(absent) == signature(udp).


**Actual:** Scratch repro (audit-a3/dns_type_signature.sh): signature(absent)=signature(doh)=5bec1d46..., signature(udp)=7d9513c0...; dns.uc state_template({}).dns_type = 'udp'.


**Impact:** When dns_type is absent (CLI deletion or hand-edited/legacy config) and the admin then sets 'doh', the sing-box signature is unchanged. The reload plan skips sing-box regeneration, so the runtime keeps plain UDP DNS while the UI shows DoH, until a restart.


**Root cause:** A stale default copied from upstream podkop (DoH default).


**Affected files:** `forkop/files/usr/lib/service/state.uc`

**Proposed fix:** Use the 'udp' default in state.uc:1645.


**Tests needed:** Add a sing-box-signature-fixture assertion to the reload signature tests: absent dns_type equals explicit udp.


**Risk:** Very low (one extra reload for configs lacking dns_type after upgrade).


---

<a id="uc-089"></a>

## UC-089 · P3 · S7 — badwan_reload_delay принимает любой текст и заодно молча задаёт задержку для reload при изменении конфигурации

**Severity:** P3<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** uci-global<br>
**Sources:** uci-global#7<br>
**Original title:** badwan_reload_delay accepts any text; it also silently sets the delay for config-change reloads<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** settings.js:446-460 validates only non-empty (`if (!value) return _('Delay value cannot be empty')`). initd.uc:774-778 passes it through (`let delay = option(settings, "badwan_reload_delay", "2000")`). init.d/forkop:111-112 `PROCD_RELOAD_DELAY="$event"` is applied to every trigger, including config.change (initd.uc:780). procd.sh _procd_add_timeout uses `[ "$PROCD_RELOAD_DELAY" -gt 0 ]`.


**Reproduction:** Set Interface Monitoring Delay to '2s', save, then inspect `ubus call service list '{"name":"forkop"}'` triggers (no delay entry).


**Expected:** Only a bounded integer in ms is accepted.


**Actual:** Non-numeric values are accepted and turn the reload debounce off.


**Impact:** '2s' (the sing-box duration style used everywhere else on the page) makes the numeric test fail, so the delay becomes 0 and reloads fire immediately on interface up and config change. A large number delays every config-change reload by that many ms. It is labelled as an interface-monitoring option only.


**Root cause:** Missing validation. procd's delay parameter is shared across all triggers.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js`, `forkop/files/usr/lib/service/initd.uc`

**Proposed fix:** Validate integer milliseconds in the UI (e.g. 0-60000). In trigger_plan, fall back to 2000 when the value is not ^[0-9]+$.


**Tests needed:** initd trigger-plan fixture test with badwan_reload_delay='2s' should print delay 2000.


**Risk:** Very low.


---

<a id="uc-090"></a>

## UC-090 · P3 · S7 — Опции подписки UA/HWID/hide записываются миграцией и документированы, но runtime жёстко использует 'auto' (перенесённый пользовательский User-Agent молча игнорируется)

**Severity:** P3<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** uci-global<br>
**Sources:** uci-global#9<br>
**Original title:** Subscription UA/HWID/hide options are written by migration and documented, but the runtime hard-codes 'auto' (a migrated custom User-Agent is silently ignored)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-17

**Evidence:** connections.uc:549-555 `function subscription_auto_user_agent(section, value) { return true; }` and subscription_auto_hwid likewise. connections.uc:564-570 hide_* always return true (since b14f3a33). migration.uc:690-698 still writes auto_user_agent '0' plus user_agent from podkop 'url | UA' entries, and auto_hwid/hide_urltest_group_outbounds/hide_detour_outbounds. etc/config/forkop:68-81 documents auto_user_agent '0' / user_agent 'CustomAgent/1.0'. validator.uc:1308-1316 validate_subscription_request_profile is dead. getDashboardSections.ts:257-266 passes the dead fields through.


**Reproduction:** Migrate a podkop config with subscription_urls 'https://sub/x | Clash/1.0' and fetch: the User-Agent header is not Clash/1.0.


**Expected:** Options are either effective or not written or documented.


**Actual:** The options are persisted but ignored.


**Impact:** Migration semantic change: a podkop user whose provider needs a specific User-Agent keeps it in UCI, but it is never sent (subscription/cache.uc falls back to the Happ UA, the cached UA or 'sing-box'). The provider may return another format or refuse. The config example and types imply these options work.


**Root cause:** The runtime feature was removed (b14f3a33) without updating the migration and the documentation.


**Affected files:** `forkop/files/usr/lib/config/connections.uc`, `forkop/files/usr/lib/config/migration.uc`, `forkop/files/etc/config/forkop`, `forkop/files/usr/lib/config/validator.uc`, `fe-app-forkop/src/forkop/methods/custom/getDashboardSections.ts`

**Proposed fix:** Decide: either honour an explicit user_agent (auto_user_agent='0') as the first candidate in user_agent_candidates, or stop writing these options in migrate_subscription_url_item_settings, log a migration notice, and remove them from the default example, types.ts and the dead validator branch.


**Tests needed:** tests/config_migration.sh: podkop 'url | UA' entry -> the chosen behaviour (honoured, or dropped with a notice).


**Risk:** Low.


---

<a id="uc-091"></a>

## UC-091 · P3 · S7 — У интервалов обновления списков нет нижней границы: '1m' или '1s' принимаются, а '100ms' проходит валидатор как 0 с

**Severity:** P3<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** uci-global<br>
**Sources:** uci-global#12<br>
**Original title:** List update intervals have no lower bound: '1m' or '1s' is accepted, and '100ms' passes the validator as 0 s<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-18

**Evidence:** settings.js:10-12 isSingBoxDuration accepts ns/us/ms/s/m/h/d. validator.uc:840-870 `return total <= 0 ? null : int(total + 0.5)` returns 0 (not null) for '100ms', so validate_duration_option passes. generator.uc:180-192 passes the raw string as the sing-box remote rule_set update_interval. components/updates.uc:1320-1325 runs a due check every minute for seconds <= 60, and list_update_due_status (updates.uc:1691-1703) is then always due. The same applies to component_update_check_interval, which has no backend validation at all.


**Reproduction:** Set List Update Frequency to 1m and save. The crontab gets '* * * * * forkop list_update_if_due' and lists refresh every minute.


**Expected:** A sane minimum interval is enforced consistently.


**Actual:** Any positive duration, including sub-second values, is accepted.


**Impact:** A plausible entry such as '1m' or '5m' re-downloads every remote list and rule set every 1-5 minutes via cron, and sing-box refetches remote rule sets at that period. This is extra load on the router CPU/flash and the mirror.


**Root cause:** Only the format is validated, not the range.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js`, `forkop/files/usr/lib/config/validator.uc`, `forkop/files/usr/lib/components/updates.uc`

**Proposed fix:** Enforce a minimum (e.g. >= 1h for lists and component checks, matching the autotune LIMITS style) in the UI validate, validator.uc validate_list_update_settings (duration_to_seconds_value >= 3600) and a component interval check. Treat 0 s as invalid.


**Tests needed:** Validator fixture: update_interval '100ms' and '1m' are rejected; '1h' is accepted.


**Risk:** Low. Existing configs with small values would start failing validation, so migrate or clamp them.


---

<a id="uc-092"></a>

## UC-092 · P3 · S7 — Валидатор принимает включённое правило Connection без источников; ошибка проявляется только при генерации

**Severity:** P3<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#7<br>
**Original title:** Validator accepts an enabled Connection rule with no sources; failure only appears at generation<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** validator.uc:1430-1491 validate_rule for connections checks urltests, priority groups, subscriptions and outbound_json, but never has_connection_sources. generator.uc:2281-2282 `if (length(selector_tags) == 0) runtime_generate_unsupported("connection section has no usable outbounds")`. The UI default action is connection (section.js:6874), and the modal has no 'at least one source' check.


**Reproduction:** Add a rule with only a community list, leave Where-to empty, Save & Apply.


**Expected:** Validation rejects it with an actionable message.


**Actual:** gen_check.sh: {action:connection, community_lists:[youtube]} gives validator OK and generator FAIL.


**Impact:** A new rule with conditions but no connection source (or the DPI-conversion case) passes the pre-apply validation and fails the reload with a generator error instead of a clear validation message.


**Root cause:** The source-presence check exists only in the generator.


**Affected files:** `forkop/files/usr/lib/config/validator.uc`

**Proposed fix:** In validate_rule, for enabled connection actions, fail_validation when !connections.has_connection_sources(section). Optionally add a UI-side check in the Where-to step.


**Tests needed:** config_validator_runtime.sh case: enabled connection without sources fails validation.


**Risk:** Configs that are disabled or have sources are unaffected.


---

<a id="uc-093"></a>

## UC-093 · P3 · S7 — Миграция выведенного b4geoip удаляет IP-наборы, не сопоставляя их с существующими эквивалентами из community-списков

**Severity:** P3<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#13<br>
**Original title:** Retired-b4geoip migration drops IP sets without mapping them to existing community equivalents<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-13

**Evidence:** migration.uc:1320-1352 migrate_retired_secondary_rulesets deletes cloudflare/hetzner/ovh/digitalocean/... entries. The same services exist as community lists (core/constants.uc:118 COMMUNITY_SERVICES includes cloudflare cloudfront digitalocean hetzner ovh).


**Reproduction:** Fixture with rule_set_with_subnets [.../cloudflare.srs]: after migrate it is gone and nothing replaces it.


**Expected:** Semantics preserved where an equivalent exists, or the user is told.


**Actual:** Entries are removed.


**Impact:** After upgrade, rules lose those IP matches, and a rule whose only condition was a retired set matches nothing. The routing change is silent.


**Root cause:** Cleanup migration focused on the 404 failures.


**Affected files:** `forkop/files/usr/lib/config/migration.uc`, `tests/fixtures/retired-secondary-rulesets.json`

**Proposed fix:** Product choice: map retired ids with an equivalent to community_lists, and record a history/notice for dropped ids without an equivalent.


**Tests needed:** config_migration.sh mapping case.


**Risk:** Adds matches the user did not explicitly select.


---

<a id="uc-094"></a>

## UC-094 · P3 · S7 — Устаревшие значения list domain_regex/domain_keyword, не прошедшие нормализацию, молча отбрасываются и не валидируются

**Severity:** P3<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#14<br>
**Original title:** Legacy list domain_regex/domain_keyword values failing normalization are silently dropped and never validated<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** config/domain.uc:292-295 regex_to_ascii returns null for any value containing ',' or whitespace. rule_conditions.uc:57-72 drops nulls silently. validator.uc:1493-1497 validates only option domain, list domain_suffix and domain_suffix_text, not legacy domain_keyword/domain_regex lists.


**Reproduction:** Fixture rule with domain_regex list containing a comma quantifier.


**Expected:** A validation error, not a silent drop.


**Actual:** regex_check2.sh: list domain_regex ['^a{1,3}\.example$'] produces domain_regex [].


**Impact:** A legacy regex such as ^a{1,3}\.example$ silently stops matching. After a UI edit it lands in the combined text, where the validator then rejects the whole config.


**Root cause:** Legacy readers normalize without validation.


**Affected files:** `forkop/files/usr/lib/config/validator.uc`

**Proposed fix:** Validate legacy domain_keyword/domain_regex lists in validate_rule with the same normalizers, and fail closed with a clear message.


**Tests needed:** legacy_domain_list.sh case.


**Risk:** May reject configs that currently apply with the value silently ignored.


---

<a id="uc-095"></a>

## UC-095 · P3 · S7 — Мёртвые/несогласованные метаданные настроек: enable_output_network_interface только в UI, скрытый dns_failover_failure_threshold не в сигнатуре reload, застывший config_version, разный дефолт проверок компонентов

**Severity:** P3 (изменено при ревью плана; по аудиту и проверке — CLEANUP)<br>
**Stage:** S7 (Валидация и нормализация конфигурации)<br>
**Area:** uci-global<br>
**Sources:** uci-global#16<br>
**Original title:** Dead or inconsistent settings metadata: UI-only enable_output_network_interface, hidden dns_failover_failure_threshold missing from the reload signature, frozen config_version, default mismatch for component checks<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-20

**Evidence:** enable_output_network_interface is read nowhere in the backend (only settings.js and etc/config). singbox/route.uc:19 and runtime.uc:843 use output_network_interface unconditionally, relying on LuCI deleting it via depends. dns_failover_failure_threshold is consumed by dns_failover.uc:264 but is absent from state.uc:1641-1686, so a CLI change is not applied by reload. migration.uc:1445-1446 pins config_version at '1.0.5' forever, so a future release_at_most() gate would misfire. settings.js component_update_check_enabled `o.default = "0"` vs etc/config '1' and migration.uc:1200-1205 forcing '1'. validator.uc:1308-1316 validate_subscription_request_profile is unreachable.


**Expected:** Each option has a single effective meaning.


**Actual:** As described.


**Impact:** CLI or hand-edited configs behave differently from what the flags suggest. It is a future-maintenance trap.


**Root cause:** Incremental evolution.


**Affected files:** `forkop/files/usr/lib/singbox/route.uc`, `forkop/files/usr/lib/service/state.uc`, `forkop/files/usr/lib/config/migration.uc`, `luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js`, `forkop/files/usr/lib/config/validator.uc`

**Proposed fix:** Honour enable_output_network_interface in route.uc/runtime.uc (or drop the flag). Add dns_failover_failure_threshold to the sing-box signature. Document that applied_migrations, not config_version, is the migration tracker (or bump config_version to the release). Align the UI default with the shipped default. Remove dead validator code.


**Tests needed:** Signature fixture for the threshold change. A route fixture with enable flag 0 and the interface set.


**Risk:** Low.


---

<a id="uc-096"></a>

## UC-096 · P3 · S8 — Резолвер возвращает определённого владельца для IPv6-целей, DNS-порта и FakeIP-литерала без домена вместо undecidable

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** routing<br>
**Sources:** routing#1<br>
**Original title:** Resolver returns a decided owner for IPv6 targets, the DNS port, and a FakeIP literal with no domain instead of undecidable<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:**

routing/resolve.uc:128-143 in_prefix/cidr_contains parse IPv4 only (`/^([0-9.]+)(\/([0-9]+))?$/`), so IPv6 ip_cidr and source_ip_cidr give false and are counted as "no".
resolve.uc:144-146/156: is_fakeip covers only 198.18.0.0/15, while the generator also hands out FakeIP6 fc00::/18 (singbox/constants.uc:33, generator.uc:457-458).
resolve.uc:188-192, 207-217: a real-address connection is matched by "the sniffed domain", but sniffing runs only on tproxy-in (route.uc:21,29), so IPv6 real-address connections (tproxy6-in) are never sniffed.
resolve.uc:240-247 skips every action other than route/reject, including `{ action: "hijack-dns", port: 53 }` (route.uc:30, no inbound restriction).
resolve.uc:207-221: with host "" and fakeip true no destination matcher can hit, so the result is final/direct.
route_trace.uc:37-41 accepts IPv6 literals and AAAA answers (route_trace.uc:122-123), and the CLI accepts any port.


**Reproduction:** wsl bash <scratch>/audit-routing/trace_v6.sh. Full matrix: <scratch>/audit-routing/run_perm.sh (perm2.uc).


**Expected:** sing-box routes 2a00:1450:4001::1 through vpn6-out. A real IPv6 youtube connection is not sniffed on tproxy6-in, so the ip_cidr rule gives vpn6-out. Port 53 is hijack-dns. The resolver should either model these cases correctly or return undecidable.


**Actual:**

Scratch trace_v6.sh on a generated config with [vpn6: connection, ip_cidr 2a00:1450::/32][yt: zapret, youtube.com]:
- `route_trace 2a00:1450:4001::1 '' TCP 443` gives rule null / no_rule_matched / direct-out.
- youtube.com with an AAAA real answer gives rule 'yt' / zapret.
- youtube.com TCP 53 with a FakeIP answer gives rule 'yt' / zapret.
The permutation harness found 25,932 decided-but-wrong answers, all on IPv6 targets, port 53, uppercase keywords or the single-port range.


**Impact:** Diagnostics (the site check and the route_trace CLI) shows a wrong route marked 'simulated'. Examples: 'Direct · No rule matched' for an IPv6 address that sing-box routes through a VPN rule, 'Zapret rule' for an IPv6 real-address connection that sing-box cannot sniff, and a rule owner for port-53 traffic that sing-box hijacks as DNS. This breaks the 'never guessed' rule (invariant 18) for the canonical resolver. Autotune is not affected: it only uses IPv4, FakeIP with a host, and TCP/443.


**Root cause:** The resolver was extracted from the IPv4/TCP/443 autotune model and reused for general Diagnostics input without guarding inputs outside that model. IPv6 and DNS hijack were never modelled.


**Affected files:** `forkop/files/usr/lib/routing/resolve.uc`, `fe-app-forkop/src/forkop/tabs/diagnostic/siteCheck.ts`, `tests/helpers/route_owner/cases.js`, `tests/helpers/route_owner/apply_owner.golden.json`

**Dependencies:** The IPv6 part interacts with the separate finding about sniff and QUIC rules existing only on tproxy-in.


**Proposed fix:** Minimal fail-closed change in resolve.uc. In route_owner (or target), return undecidable when t.ip or t.source is not IPv4 (reason e.g. 'ipv6_not_modelled'), or when t.fakeip is true and host is "" ('fakeip_domain_unknown'). Treat hijack-dns as a final action: if rule_matches(filter_keys(r,["action"]), t) is not "no", return undecidable with reason 'dns_hijack'. Add the matching reason texts to siteCheck.ts undecidedReasonText. Alternatively, model IPv6 properly: IPv6 CIDRs, the tproxy6-in inbound, and no sniffing on it.


**Tests needed:** New cases in cases.js and the golden file: IPv6 target with an IPv6 ip_cidr rule; IPv6 real address with a domain rule; port 53 FakeIP target; FakeIP literal without a host. All must be non-decided. route_trace.sh: an IPv6 literal gives rule.status undecidable.


**Risk:** Low. The change only turns wrong answers into undecidable ones.


---

<a id="uc-097"></a>

## UC-097 · P3 · S8 — Генератор применяет sniffing и disable_quic только к IPv4 tproxy inbound, поэтому QUIC через IPv6 FakeIP не отклоняется, а трафик на реальные IPv6-адреса не сниффится

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** routing<br>
**Sources:** routing#2<br>
**Original title:** Generator applies sniffing and disable_quic only to the IPv4 tproxy inbound, so IPv6 FakeIP QUIC is not rejected and IPv6 real-address traffic is not sniffed<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:**

singbox/route.uc:21 `let sniff_inbounds = [ runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.DNS_INBOUND_TAG ];`
route.uc:45 `push(result.rules, { action: "reject", inbound: runtime_constants.TPROXY_INBOUND_TAG, protocol: "quic" });`
Section rules use both inbounds (generator.uc:420-422 `[ TPROXY_INBOUND_TAG, TPROXY_INBOUND6_TAG ]`).
FakeIP6 is handed out (generator.uc:457-458 inet6_range) and tproxied (nft/apply.uc:910-915).
The dual-stack commit c73521f0 added tproxy6-in but did not change route.uc.
Scratch output: `{ "action": "sniff", "inbound": [ "tproxy-in", "dns-in" ] }`, `{ "action": "reject", "inbound": "tproxy-in", "protocol": "quic" }`.


**Reproduction:** Generate any config (for example <scratch>/audit-routing/src_only.sh) and inspect route.rules[0] and route.rules[3].


**Expected:** The same sniffing and QUIC policy on both tproxy inbounds, so IPv4 and IPv6 connections to the same destination are routed the same way.


**Actual:** Generated config: sniff and QUIC reject list only tproxy-in, while all section route rules list tproxy-in and tproxy6-in.


**Impact:** On a dual-stack LAN (disable_quic=1 is the default), AAAA queries for rule domains get FakeIP6 answers and QUIC over IPv6 is not rejected. It goes to the rule's outbound. With a TCP-only zapret strategy, which is exactly what autotune applies, QUIC is not desynced, so pages are blocked or slow until the browser falls back to TCP. IPv4 QUIC is rejected in the same setup. Real-address IPv6 connections captured by IPv6 ip_cidr, fully_routed IPv6 devices or port-only rules are never sniffed. Domain rules placed above them therefore apply to IPv4 but not IPv6 (for example, a bypass domain rule above a fully-routed VPN device bypasses on IPv4 but routes through the VPN on IPv6).


**Root cause:** IPv6 support (c73521f0) updated the section rule inbounds but missed the base route rules in singbox/route.uc.


**Affected files:** `forkop/files/usr/lib/singbox/route.uc`, `tests/sing_box_runtime.sh`

**Dependencies:** None


**Proposed fix:** Build both rules from the dual inbound list: add TPROXY_INBOUND6_TAG to sniff_inbounds, and set the QUIC reject rule's inbound to [TPROXY_INBOUND_TAG, TPROXY_INBOUND6_TAG].


**Tests needed:** sing_box_runtime.sh: the sniff rule includes tproxy6-in, and the QUIC reject rule includes tproxy6-in when disable_quic=1.


**Risk:** Low. It enables for IPv6 the behaviour IPv4 already has. On a hardware run, confirm that clients fall back to TCP over IPv6.


---

<a id="uc-098"></a>

## UC-098 · P3 · S8 — Одиночный диапазон портов 'N-N' (принимаемый UI и валидатором) выдаётся как невалидный port_range sing-box 'N'

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** routing<br>
**Sources:** routing#3<br>
**Original title:** Single-port range 'N-N' (accepted by the UI and validator) is emitted as an invalid sing-box port_range 'N'<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:**

singbox/generator.uc:2930-2933 `push(port_ranges, start == end ? as_string(start) : sprintf("%d:%d", start, end));`
config/rule.uc:243-249 normalize_port_condition_value accepts '443-443'.
validator.uc:1016-1021 uses it.
section.js:4980-5004 validatePortCondition accepts start == end.
config/rule.uc:251-263 normalize_port_range_value would give '443:443' but the generator does not use it.
Scratch port_range.sh output: `"port_range": [ "443", "8000:8080" ]`.


**Reproduction:** wsl bash <scratch>/audit-routing/port_range.sh


**Expected:** port [443] or port_range ["443:443"].


**Actual:** ports '443-443' produces port_range ["443"].


**Impact:** A rule the UI and validator accept makes `sing-box check` fail: sing-box port_range items must be 'start:end', otherwise it reports a bad port range. The reload is aborted (runtime.uc:658-668, fail-closed). The user sees a sing-box parse error instead of a validation message, and every other config change is blocked until the port is edited. The resolver's port_matches also rejects the value.


**Root cause:** The generator has its own port normalization, and its start == end branch returns a bare port into the range list.


**Affected files:** `forkop/files/usr/lib/singbox/generator.uc`

**Dependencies:** None


**Proposed fix:** In add_port_matchers, push `start` into `ports` when start == end, or use rule_config.normalize_port_range_value for all ranges. Remove the duplicate normalization.


**Tests needed:** sing_box_runtime.sh or route_list_alternatives.sh: ports ['443-443'] produces port [443] or port_range ['443:443'], never a range without ':'.


**Risk:** None


---

<a id="uc-099"></a>

## UC-099 · P3 · S8 — Ключевое слово домена в смешанном регистре сохраняется как введено: sing-box его никогда не сопоставит, а резолвер утверждает, что совпадение есть

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** routing<br>
**Sources:** routing#4<br>
**Original title:** Mixed-case domain keyword is kept as typed: sing-box never matches it, but the resolver claims it matches<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:**

config/domain.uc:273-289: keyword_to_ascii returns an ASCII value unchanged (`if (!has_non_ascii) return value;`).
Scratch: `keyword:YouTube` produces `"domain_keyword": [ "YouTube" ]`.
section.js:4200-4210: validateKeyword accepts uppercase.
resolve.uc:217 `if (host != "" && index(host, lc(d)) >= 0) hit();` lower-cases the keyword.
sing-box's DomainKeywordItem lower-cases only the host and compares keywords as configured (upstream behaviour; the sing-box source is not available locally).


**Reproduction:** <scratch>/audit-routing/port_range.sh (keyword output). Permutation harness scenario c_kwU.


**Expected:** The generated keyword is 'youtube' and matches. Otherwise the resolver should agree with sing-box that it does not match.


**Actual:** Config [c_kwU: connection, keyword:YouTube][z_yt: zapret, youtube.com]: the resolver says c_kwU owns www.youtube.com (FakeIP).


**Impact:** The user's keyword rule silently never matches. Diagnostics reports that rule as the owner. Autotune groups may classify a target as 'routed_through_connection' or 'not_a_dpi_rule' and drop it, while sing-box actually routes it through a later DPI rule.


**Root cause:** keyword_to_ascii only converts non-ASCII keywords (via punycode) and does not lower-case ASCII ones.


**Affected files:** `forkop/files/usr/lib/config/domain.uc`, `forkop/files/usr/lib/routing/resolve.uc`

**Dependencies:** None


**Proposed fix:** Lower-case ASCII keywords in keyword_to_ascii (generation path), which matches the case-insensitive intent already used for domains and suffixes. The resolver then stays correct. Optionally normalize the value in the UI as well.


**Tests needed:** Generator test: keyword:YouTube produces domain_keyword ['youtube']. Resolver case with a mixed-case keyword in the generated config.


**Risk:** Changes routing for existing configs with uppercase keywords: they start to match, as the user intended.


---

<a id="uc-100"></a>

## UC-100 · P3 · S8 — Резолвер игнорирует перехват nft для доменов с реальным адресом: правило 'dns' выше правила маршрутизации того же домена отключает маршрутизацию, а Diagnostics считает её действующей

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** routing<br>
**Sources:** routing#5<br>
**Original title:** Resolver treats a real-address domain match as if sing-box sees the connection, ignoring nft interception; a 'dns' rule placed above a routing rule for the same domain disables that routing while Diagnostics claims it applies<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:**

resolve.uc:188-192 ('a real-address connection is matched by ip_cidr and by the sniffed domain') and 207-217 (host used for non-FakeIP targets).
route_trace.uc:70-71 always passes the domain as host.
DNS rules are emitted in section order (generator.uc:3255-3256). A dns-action section's rule (generator.uc:2875-2888) therefore precedes a later section's FakeIP rule (generator.uc:2656-2659).
nft/apply.uc:1896-1897: dns sections add no interception, and a domain-only connection rule adds none either.
Scratch dns_before.sh: DNS rules list `server: d-dns-server, domain_suffix example.com` before `server: fakeip-server, domain_suffix example.com`, while the route rule sends example.com to v-out.


**Reproduction:** wsl bash <scratch>/audit-routing/dns_before.sh


**Expected:** Undecidable (or 'direct: not intercepted'). The configuration should also warn that v's domain routing is inert.


**Actual:** [d: dns, example.com via 8.8.8.8][v: connection, example.com]: route_trace example.com (router dig returns a real IP) gives decided, rule v, Connection.


**Impact:** Clients get real IPs for example.com, which are not intercepted and go direct. The site check says 'Connection · rule «v»' (simulated), which hides a silent config trap. The same false positive can occur for any real-address answer whose IP is not in nft interception sets.


**Root cause:** The resolver models only the sing-box stage. Whether a real-address connection enters sing-box at all is decided by nft sets, which the resolver cannot see.


**Affected files:** `forkop/files/usr/lib/routing/resolve.uc`, `forkop/files/usr/lib/diagnostics/route_trace.uc`, `forkop/files/usr/lib/config/validator.uc`, `tests/route_trace_owner.sh`

**Dependencies:** The resolver change can be done without the product decision.


**Proposed fix:** Resolver: for non-FakeIP targets, a decision that depends on a domain matcher returns undecidable (for example 'real_address_interception_unknown'), unless the caller passes proof that the address is intercepted. Keep ip_cidr decisions. Separately, as a product decision, add a validator or UI warning when a dns-action rule's domains are shadowed by, or shadow, a routing rule's domains. Note that route_trace_owner.sh (the gosuslugi.ru bypass on a real address) pins the current behaviour.


**Tests needed:** Resolver case: real address plus domain-only rule gives non-decided. Validator or UI test for the shadowed-domain warning, if adopted.


**Risk:** More 'Rule not calculated' results in the site check for real-address answers.


---

<a id="uc-101"></a>

## UC-101 · P3 · S8 — Извлечение IP из rule-set для nft игнорирует invert, логику AND, ограничения network и source, поэтому bypass-правила пускают по быстрому пути не те адреса

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** routing<br>
**Sources:** routing#6<br>
**Original title:** Rule-set IP extraction for nft ignores invert, AND logic, network and source constraints, so bypass rules fast-path the wrong addresses<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:**

routing/rulesets.uc:391-438: collect_ip_cidr_nft_outputs adds `rule.ip_cidr` for every rule and child. It never checks `invert`, `network`, `source_ip_cidr`, or sibling non-IP conditions of an `and` rule.
nft/apply.uc:1965-1981 feeds the result into the section's priority sets, and the bypass verdict is accept (695-699).
Scratch ruleset_invert.sh on {ip_cidr 1.2.3.0/24, invert:true}, AND(domain_suffix only.example, ip_cidr 5.6.7.0/24), {9.9.9.0/24, network udp}, {8.8.8.0/24, source_ip_cidr .50} produced all four CIDRs as unconditional subnet entries.


**Reproduction:** wsl bash <scratch>/audit-routing/ruleset_invert.sh


**Expected:** Only CIDRs whose rule matches on destination IP alone (with an optional port constraint) are extracted.


**Actual:** All CIDRs are extracted regardless of rule semantics.


**Impact:** For a bypass rule using a custom JSON rule-set (rule_set_with_subnets) with such rules, nft bypasses those IPs for every device and protocol before sing-box. With invert:true it bypasses exactly the addresses sing-box would not bypass. Later routing rules (VPN, DPI) for those IPs never see the traffic. For capture rules the over-extraction only sends extra traffic to sing-box, which is harmless.


**Root cause:** The extractor was written for simple list rule-sets and treats every ip_cidr as an unconditional destination match.


**Affected files:** `forkop/files/usr/lib/routing/rulesets.uc`

**Dependencies:** None


**Proposed fix:** In collect_ip_cidr_nft_outputs, skip rules with invert, and skip rules with any non-destination condition (source_ip_cidr, network, protocol, domain* inside an AND). Descend only into logical 'or' rules. For bypass sections, a missing fast path is safe because sing-box's own rule still applies.


**Tests needed:** A unit test of extract-ip-cidr-nft with invert, AND, network and source rules.


**Risk:** Low. It only affects custom rule-sets with complex rules.


---

<a id="uc-102"></a>

## UC-102 · P3 · S8 — Включённое правило с единственным условием — фильтром устройств (source_ip_cidr) — не порождает ни route-правила, ни перехвата и молча ничего не делает

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** routing<br>
**Sources:** routing#7<br>
**Original title:** An enabled rule whose only condition is the device filter (source_ip_cidr) generates no route rule and no interception, so it silently does nothing<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:**

generator.uc:3059-3064: has_route_matchers excludes source_ip_cidr, and with no ports and no lists no rule is pushed.
nft/apply.uc:668-671: section_needs_priority_sets requires fully_routed, IP or port-only matchers.
validator.uc:1388-1500 has no 'no conditions' check.
Scratch src_only.sh: sections 'srconly' (bypass, source only) and 'vpn' (connection, source only) produce no route rules, only the outbound 'vpn-out'.


**Reproduction:** wsl bash <scratch>/audit-routing/src_only.sh


**Expected:** The user is told the rule matches nothing.


**Actual:** The rule is accepted, shown as enabled, and has no effect.


**Impact:** A user who sets only 'Device filter' (section.js:7782-7786, 'Apply section rules only to the specified local IP addresses') on a VPN rule, expecting device routing, gets nothing and no warning. 'Forced device routing' (fully_routed_ips) is the working option. Generator and resolver agree; this is a UX gap only.


**Root cause:** The device filter only narrows other conditions by design, but nothing reports a rule that has no conditions to narrow.


**Affected files:** `forkop/files/usr/lib/config/validator.uc`, `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`

**Dependencies:** None


**Proposed fix:** Add a validator warning or error, or a UI hint, for enabled routing rules without destination, port, list or fully-routed conditions. Suggest 'Forced device routing'.


**Tests needed:** Validator test for a rule with no conditions, if adopted.


**Risk:** A hard validation error could block existing configs, so a warning is preferred.


---

<a id="uc-103"></a>

## UC-103 · P3 · S8 — Проверка сайта винит 'an earlier rule', когда неразрешимо собственное правило resolve или списка владельца; любой сайт ByeDPI или resolve_real_ip — 'not calculated'

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** routing<br>
**Sources:** routing#8<br>
**Original title:** The site check blames 'an earlier rule' when the undecidable rule is the owner's own resolve rule or list rule; every ByeDPI or resolve_real_ip site is 'not calculated'<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:**

route.uc:67-91 and generator.uc:2972-2979 emit the section's own resolve rule (always for byedpi, and for connection rules with resolve_real_ip_for_routing) directly before its route rule, with identical matchers.
resolve.uc:241-245 returns undecidable 'resolve_rule' as soon as it matches.
siteCheck.ts:34-41: 'an earlier rule uses a list or pattern…' and 'an earlier rule re-resolves the address…'.


**Reproduction:** Code reading, plus the permutation harness (c_res scenarios are undecidable).


**Expected:** Decided as ByeDPI rule b, or at least a truthful reason.


**Actual:** [b: byedpi, domain_suffix example.com]: route_trace www.example.com (FakeIP) gives undecidable resolve_rule, with the text 'an earlier rule re-resolves…'.


**Impact:** Any FakeIP target owned by a ByeDPI rule, or by a resolve_real_ip connection rule, always shows 'Rule not calculated: an earlier rule re-resolves the address', even when no earlier rule exists. List-only rules show 'an earlier rule uses a list' for their own list. This misleads troubleshooting.


**Root cause:** The resolver treats every resolve action as 'above the owner', without recognising the owner's own paired resolve rule.


**Affected files:** `forkop/files/usr/lib/routing/resolve.uc`, `fe-app-forkop/src/forkop/tabs/diagnostic/siteCheck.ts`

**Dependencies:** None


**Proposed fix:** Resolver: when a resolve rule is immediately followed by a route rule whose matchers (with action, server and outbound removed) equal the resolve rule's matchers, skip the resolve rule for the decision; the following rule then decides. Reword the siteCheck texts to 'a rule on the path' or report the owning section.


**Tests needed:** Resolver case: a resolve rule followed by an identical-matcher route rule is decided. The existing case resolve_above_owner_fakeip (different section) stays undecidable.


**Risk:** Low. The paired rule has identical matchers, so the route is determined regardless of the resolve result.


---

<a id="uc-104"></a>

## UC-104 · P3 · S8 — Точные совпадения по метке в mangle_output зависят от порядка регистрации хуков относительно других output-хуков с приоритетом -150

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** nft/apply.uc mangle_output<br>
**Sources:** nft#1<br>
**Original title:** Exact-mark matches in mangle_output depend on hook registration order vs other priority -150 output hooks<br>
**Confidence:** low<br>
**Hardware required:** yes<br>
**Product decision:** no

**Evidence:** nft/apply.uc:883 `mangle_output { type route hook output priority -150 }`. :918 `meta mark 0x08000000 counter return` (exact). :1038-1039 `meta mark 0x01000001 meta l4proto tcp counter queue num 4000 bypass` (exact). fw4's `mangle_output` (priority mangle = -150) and iptables-nft `ip mangle OUTPUT` (-150, where mwan3 hooks) have the same priority. The kernel orders equal-priority hooks by registration: nf_hook_entries_grow inserts a new hook before existing ones with priority >=, so the last registered runs first. After a `fw4 reload`, fw4's -150 chain precedes ForkopTable.


**Reproduction:** Router with pbr: a policy for a zapret-routed IP, then `fw4 reload`, then compare queue counters of `meta mark 0x01000001 ... queue` before and after.


**Expected:** Classification by Forkop's own mark bits, independent of foreign bits and hook order.


**Actual:** If a foreign output chain at -150 runs first and ORs bits into the mark, Forkop's exact matches fail. Examples: pbr `meta mark set meta mark & 0xff00ffff | 0x10000` for a policy covering zapret destinations, or mwan3 `--set-xmark 0x100/0x3f00`. Zapret traffic (0x01010001) is not queued, so DPI bypass is silently not applied, and router-originated capture is skipped. The DPI guard (masked 0xff000000) and the ip rule (0x04000000/0x04000000) are masked and unaffected.


**Impact:** Silent loss of the zapret/zapret2 desync for the affected destinations after a firewall reload on routers that also run pbr, mwan3 or fw4 mark rules. Autotune verification would report traffic_dpi_queue failure, but normal status does not. sing-box traffic is unaffected because the global capture sets are empty (see the CLEANUP finding).


**Root cause:** Exact equality instead of a mask on Forkop-owned bits. The -150 priority ties with the standard mangle priority.


**Affected files:** `forkop/files/usr/lib/nft/apply.uc`, `forkop/files/usr/lib/autotune/apply.uc`, `tests/nft_apply.sh`, `tests/autotune_contract.sh`

**Proposed fix:** Match only Forkop-owned bits. Bypass: `meta mark & 0xff000000 == 0x08000000 return`. Queues: `meta mark & 0xff0001ff == 0x0100000N`. contract.uc bypass_rule already accepts masked mark matches. Priority cannot move below -150 because the probe chains need production after -151.


**Tests needed:** nft_apply.sh asserts masked rules. autotune_contract.sh keeps N6_bypass_other_mark semantics with a masked bypass. autotune/apply.uc queue_rule_counter must parse the masked JSON form.


---

<a id="uc-105"></a>

## UC-105 · P3 · S8 — Флаг enabled разбирается с учётом регистра в генераторе/nft и без учёта в runtime nfqws/резолвере, что сдвигает индексы очередей и стратегий zapret

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** provider index derivation<br>
**Sources:** nft#2<br>
**Original title:** Enabled flag parsed case-sensitively in generator/nft and case-insensitively in nfqws runtime/resolver, shifting zapret queue and strategy indexes<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** core/common.uc:117-122 bool_option compares the raw value (`value == "1" || "true" || "yes" || "on"`), used by singbox/generator.uc:170-172 and 3206-3214 and nft/apply.uc:1022. providers/nfqueue/runtime.uc:18-21 and 148-154 use `lc()`; routing/resolve.uc:90-93 and providers/rules.uc:68-71 also use lc. Scratch enabled_case.sh: with sections a(enabled='On', zapret) and b('1', zapret), nft/apply.uc emits `meta mark 0x01000001 ... queue num 4000` for b; common.bool_option('On')=false, while lc-based parsing gives true.


**Reproduction:** scratch/audit-a5/enabled_case.sh


**Expected:** One shared definition of 'enabled provider section' and its index.


**Actual:** The generator and nft give rule b index 1 (mark 0x01000001, queue 4000). The nfqws runtime starts rule a's strategy on queue 4000 and b's on 4001, so b's traffic is desynced with a's strategy. Status shows outbounds_configured=false (not ready), while the traffic is still processed with the wrong strategy.


**Impact:** Wrong DPI strategy for a rule after a hand edit or a uci CLI value with capitals (On, TRUE, Yes). The validator does not reject such values. The UI also treats any value other than '0' as enabled.


**Root cause:** Five independent implementations of enabled-section and index derivation.


**Affected files:** `forkop/files/usr/lib/core/common.uc`, `forkop/files/usr/lib/providers/nfqueue/runtime.uc`, `forkop/files/usr/lib/nft/apply.uc`, `forkop/files/usr/lib/singbox/generator.uc`, `forkop/files/usr/lib/routing/resolve.uc`

**Proposed fix:** Normalise enabled with lc() in core/common.bool_option, or make the validator reject non-canonical boolean values. Better: make nfqueue/runtime.uc, nft/apply.uc and generator.uc use one shared helper for the provider index.


**Tests needed:** Fixture with a mixed-case enabled value: assert identical index, mark and queue from the generator, nft, nfqws runtime and resolver.


---

<a id="uc-106"></a>

## UC-106 · P3 · S8 — Верификатор DPI guard принимает только JSON-представление с `&`; на nft < 1.1.0 ensure-dpi-transition-guard падает и оставляет непроверяемый guard

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** nft/apply.uc DPI guard<br>
**Sources:** nft#3<br>
**Original title:** DPI guard verifier accepts only the `&` JSON rendering; on nft < 1.1.0 ensure-dpi-transition-guard fails and leaves an unverifiable guard behind<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** nft/apply.uc:1686-1700 dpi_guard_rule_mark requires `test.left["&"]` with mask 4278190080. nft/apply.uc:1759-1764 ensure: absent, then create, then state must be valid. config/snapshots.uc:299-301 and 325 call restore_guard(false) and return `guard_unavailable`. Real nft 1.0.9 (scratch guard_json.sh) renders the rule as `{"match": {"left": {"meta": {"key": "mark"}}, "right": {"prefix": {"addr": 16777216, "len": 8}}}}`. The state is `invalid`, ENSURE_FAIL, and table ForkopConfigRestoreDpiGuard remains. tests/dpi_restore_guard_verify.sh:11-14 pins only the nft 1.1.6 rendering. nftables 1.1.0 changelog lists 'Remove prefix notation from mark' (https://www.mail-archive.com/netfilter-announce@lists.netfilter.org/msg00265.html).


**Reproduction:** scratch/audit-a5/guard_json.sh (unshare -rn, nft 1.0.9): install, then state=invalid; ensure then fails and the table remains.


**Expected:** A guard Forkop just created is recognised in either rendering. If verification fails, the guard this call created is removed, or the result is needs_attention with guard active.


**Actual:** On nftables < 1.1.0, every config restore and autotune apply returns failed/guard_unavailable. The guard it just created stays installed, silently drops all zapret/zapret2 route-marked traffic, blocks further restores (state invalid) and makes autotune refuse (guard_active). Stop does not remove it.


**Impact:** Supported OpenWrt 24.10 (nft 1.1.1) and 25.12 (nft 1.1.6) render `&` and are unaffected. Manual installs on older nft (OpenWrt 23.05, nft 1.0.8) lose restore and autotune apply, and DPI breaks after the first attempt. The failure result also understates the active guard (invariant 5, 6 spirit).


**Root cause:** Structural JSON validation of a single nft rendering. The failure path of `ensure` does not undo its own creation.


**Affected files:** `forkop/files/usr/lib/nft/apply.uc`, `tests/dpi_restore_guard_verify.sh`

**Proposed fix:** In dpi_guard_rule_mark, also accept `{prefix: {addr: 0x01000000|0x02000000, len: 8}}` on a meta-mark match. In nft_dpi_transition_guard_ensure, if state was absent, this call created the table and verification fails, delete it before returning false.


**Tests needed:** dpi_restore_guard_verify.sh: add the prefix-form fixture as valid, and a case where ensure created a table it cannot verify and must remove it.


---

<a id="uc-107"></a>

## UC-107 · P3 · S8 — NFT-диагностика ошибается: таблицы Forkop считаются чужой маркировкой, счётчик mangle_output засчитывается bypass-правилом, статистика показывает всегда пустые устаревшие наборы

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** diagnostics parsing nft output<br>
**Sources:** nft#6<br>
**Original title:** NFT diagnostic misreports: Forkop's own tables flagged as foreign marking, mangle_output counter satisfied by the bypass rule, set statistics show always-empty legacy sets<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** diagnostics/runtime.uc:1449-1460 excludes only NFT_TABLE_NAME. ForkopTorrServerDirect (torrserver/direct.uc:94-96 `meta mark set 0x08000000`) and ForkopAutotuneProbe (`meta mark set`) therefore set rules_other_mark_exist=1. The UI (fe runNftCheck.ts:38-46, 101-106) then shows 'Additional marking rules found' as a warning. diagnostics/status.uc:919-934 treats any counter line not 'packets 0 bytes 0' as counters OK. mangle_output rule 3 `meta mark 0x08000000 counter return` (nft/apply.uc:918) counts all sing-box egress. diagnostics/runtime.uc:724-741 prints element counts of forkop_subnets, forkop_ports and forkop_ip_ports, which are never populated (scratch common_sets.sh).


**Expected:** Forkop-owned tables are excluded or labelled. Output counters come from capture rules. Statistics cover the forkop_rule_* sets.


**Actual:** The check shows a warning whenever TorrServer Direct is enabled or autotune runs. 'Rules mangle output counters' passes even if no router-originated capture ever happened. Set statistics show 0 elements while the per-section sets hold the data.


**Impact:** Misleading diagnostics (invariant 15 spirit): false warnings and a vacuous pass.


**Root cause:** Diagnostics predate per-section sets and the auxiliary Forkop tables.


**Affected files:** `forkop/files/usr/lib/diagnostics/runtime.uc`, `forkop/files/usr/lib/diagnostics/status.uc`, `fe-app-forkop/src/forkop/tabs/diagnostic/checks/runNftCheck.ts`

**Proposed fix:** Exclude tables with the Forkop prefix (ForkopTorrServerDirect, ForkopAutotuneProbe, *DpiGuard) or report them separately. Count only rules containing `meta mark set` in mangle_output and priority_output_rules. List forkop_rule_* set sizes.


**Tests needed:** diagnostics fixture with ForkopTorrServerDirect present: rules_other_mark_exist=0; a bypass-only counter must not satisfy mangle_output counters.


---

<a id="uc-108"></a>

## UC-108 · P3 · S8 — Повторное применение TorrServer Direct неатомарно (удаление таблицы, затем отдельный nft -f) и пишет в фиксированный путь в /tmp

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** torrserver/direct.uc<br>
**Sources:** nft#7<br>
**Original title:** TorrServer Direct re-apply is not atomic (delete table, then separate nft -f) and writes a fixed /tmp path<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** torrserver/direct.uc:84 `remove_rule()` = `nft delete table inet ForkopTorrServerDirect`. :91 remove_rule() before :92-99 `/tmp/forkop-torrserver-direct.nft` + `nft -f`. The worker re-applies whenever the cgroup changes or the rule is inactive (:118-129).


**Expected:** One transaction: `add table; delete table; add table; add chain; add rule` in a single `nft -f` from mktemp.


**Actual:** Between the two transactions, TorrServer sockets are unmarked. New TorrServer connections are then classified by Forkop, and are TPROXYed into sing-box if they match capture sets. The ruleset file lives at a predictable path that root writes through fs.writefile, which follows symlinks.


**Impact:** Brief misrouting of TorrServer traffic, the opposite of the feature's intent. Symlink clobber is possible only if an unprivileged local user exists.


**Root cause:** Separate delete and create.


**Affected files:** `forkop/files/usr/lib/torrserver/direct.uc`

**Proposed fix:** Build a single batch `add table inet T` / `delete table inet T` / `add table ...` / chain / rule, written to a mktemp file. Delete the table separately only on failure.


**Tests needed:** torrserver test: apply issues exactly one nft -f containing the delete and add, and no standalone delete on success.


---

<a id="uc-109"></a>

## UC-109 · P3 · S8 — Start глобально отключает iptables-хуки br_netfilter и никогда их не восстанавливает

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** nft/apply.uc ensure_bridge_netfilter_disabled<br>
**Sources:** nft#8<br>
**Original title:** Start disables br_netfilter iptables hooks globally and never restores them<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-19

**Evidence:** nft/apply.uc:1439-1450 `sysctl -w net.bridge.bridge-nf-call-iptables=0` and `...ip6tables=0`, called at start (lifecycle.uc:882). No counterpart exists in stop_main (lifecycle.uc:1055-1105) or uninstall.


**Expected:** Record the prior value and restore it on stop, or document the requirement.


**Actual:** A system-wide kernel setting changed by Forkop persists after stop or uninstall until reboot.


**Impact:** Users relying on bridged-traffic filtering (br_netfilter) lose it silently while Forkop is installed, and after removal until reboot.


**Root cause:** Inherited upstream behaviour. TPROXY on bridged traffic conflicts with br_netfilter.


**Affected files:** `forkop/files/usr/lib/nft/apply.uc`, `forkop/files/usr/lib/service/lifecycle.uc`

**Proposed fix:** Product decision: either restore the saved value on stop, or refuse or warn when br_netfilter is in use.


**Tests needed:** Stub sysctl: stop restores the recorded value.


---

<a id="uc-110"></a>

## UC-110 · P3 · S8 — Воркер TorrServer Direct проверяет torrserver_direct_enabled через кэшированный UCI-курсор, поэтому restore или отключение через CLI не замечаются

**Severity:** P3<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** uci-global<br>
**Sources:** uci-global#11<br>
**Original title:** TorrServer Direct worker checks torrserver_direct_enabled through a cached UCI cursor, so restore or CLI disable is never noticed<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** torrserver/direct.uc:68 `function enabled() { return trim(uci.get(CONFIG_NAME + ".settings.torrserver_direct_enabled")) == "1"; }` uses core.uci, which loads a package once per process (core/uci.uc:282-300 loaded_packages) and reuses one cursor (libuci keeps the loaded package in memory). The loop in direct.uc:121 `while (enabled())` therefore never sees a change. Forkop reload and snapshot restore do not touch forkop-torrserver-direct (no torrserver reference in service/ or config/snapshots.uc).


**Reproduction:** Code reasoning based on libuci/ucode cursor semantics. Could not run the ucode uci module in WSL.


**Expected:** Disabling the option in config removes the rule within one poll interval.


**Actual:** The worker keeps the rule for as long as it runs.


**Impact:** After restoring a snapshot taken before TorrServer Direct was enabled (or after `uci set ...=0`), the nft socket bypass stays active. status() (a fresh process) reports enabled=0 while active=1, so the UI shows the feature as off while TorrServer traffic still bypasses the tunnel, until a reboot or a manual toggle.


**Root cause:** The long-running worker uses a process-lifetime UCI cache.


**Affected files:** `forkop/files/usr/lib/torrserver/direct.uc`, `forkop/files/usr/lib/core/uci.uc`

**Proposed fix:** Read the flag with a fresh cursor per iteration (or reload the package before get). Additionally, reconcile TorrServer Direct (`init enable/restart` or `stop/disable` from the flag) at the end of reload and restore.


**Tests needed:** Unit test with a cursor stub that verifies the worker re-reads config. A reload/restore integration test for the flag.


**Risk:** Low.


---

<a id="uc-111"></a>

## UC-111 · P3 · S9 — UI показывает причину сбоя измерения 'candidate_bypassed' как положительный результат

**Severity:** P3<br>
**Stage:** S9 (Autotune)<br>
**Area:** A11 frontend Autotune page<br>
**Sources:** autotune#5<br>
**Original title:** UI shows the measurement-failure reason 'candidate_bypassed' as a positive finding<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** isolation.uc:962 `if (record.queued == null || record.queued < record.rule_packets) return "candidate_bypassed";` (the candidate's queue missed packets, so the run is invalid, status failed); fe-app-forkop/src/forkop/tabs/autotune/model.ts:106-107 `case 'candidate_bypassed': return _('The target is reachable only through a bypass strategy.');`; po/ru/forkop.po:3260-3261 'Цель доступна только со стратегией обхода.'


**Expected:** An explanation that the measurement was invalid


**Actual:** 'The target is reachable only through a bypass strategy.'


**Impact:** A target whose tune was invalidated (fail-open queue, no usable data) is shown with warning tone as if the target needs bypass. This presents a failed measurement as an observed result (invariant 15).


**Root cause:** Reason code misinterpreted in the UI mapping


**Affected files:** `fe-app-forkop/src/forkop/tabs/autotune/model.ts`, `luci-app-forkop/po/templates/forkop.pot`, `luci-app-forkop/po/ru/forkop.po`

**Dependencies:** None


**Proposed fix:** Map candidate_bypassed to a text such as 'The check was invalid: a strategy did not process every packet. It will be repeated.' and group it with the other 'no usable result' reasons.


**Tests needed:** model.test.ts: targetReasonText('candidate_bypassed') is a measurement-invalid text


**Risk:** None


---

<a id="uc-112"></a>

## UC-112 · P3 · S9 — Итог apply в карточке группы: 'failed' отображается как 'Outcome unknown', а любой needs_attention — как 'Rollback did not finish', даже если отката не было

**Severity:** P3<br>
**Stage:** S9 (Autotune)<br>
**Area:** A11 frontend Autotune page<br>
**Sources:** autotune#6<br>
**Original title:** Group card apply outcome: 'failed' shows as 'Outcome unknown', and every needs_attention shows as 'Rollback did not finish' even when no rollback ran<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** model.ts:217-240 applyOutcomeView handles applied/rolled_back/no_change_required/not_applied/stale/busy/needs_attention and falls through to `{ label: _('Outcome unknown'), tone: 'error' }`; apply.uc:698-707 refuse('failed', 'apply_failed:...') when the transaction is proven not started; apply.uc:714-724 failed/reload_failed_recovered with config restored; apply.uc:741-753 needs_attention for config_changed_during_verification / lkg_confirm_failed (verified candidate live, no rollback)


**Expected:** Labels match the proven outcome


**Actual:** failed -> 'Outcome unknown' (error); needs_attention(lkg_confirm_failed) -> 'Rollback did not finish'


**Impact:** After a proven no-change failure, e.g. snapshot_retention_full, the card shows a red 'Outcome unknown'. After a verified apply whose LKG confirm failed, it shows 'Rollback did not finish'. Both misstate what happened, and the second sends the user to recovery for the wrong reason.


**Root cause:** The outcome mapping is by status only; the reasons are ignored


**Affected files:** `fe-app-forkop/src/forkop/tabs/autotune/model.ts`

**Dependencies:** None


**Proposed fix:** Add 'failed' -> 'Not applied, the previous configuration is kept' (or 'Service reload failed, restored' for reload_failed_recovered). Split needs_attention by reason: rollback_* / apply_* -> 'Rollback did not finish'; lkg_confirm_failed / config_changed_during_verification -> 'Applied and checked, but not confirmed as working configuration'.


**Tests needed:** model.test.ts for groupCards lastApply with failed and needs_attention reasons


**Risk:** None


---

<a id="uc-113"></a>

## UC-113 · P3 · S9 — Запись политики/целей autotune не сериализована с выполняющимся apply: коммит во время проверки приводит к needs_attention

**Severity:** P3<br>
**Stage:** S9 (Autotune)<br>
**Area:** A11 manager / apply race<br>
**Sources:** autotune#7<br>
**Original title:** Autotune policy/target writes are not serialized with an in-flight apply: a commit during verification forces needs_attention<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** manager.uc:253-263 uci_apply checks only uncommitted changes, then `uci ... commit forkop`, with no worker, lock or transaction check; apply.uc:741-745 `if (fingerprint(fs.readfile(CONFIG_FILE)) != candidate.fingerprint) { ... needs_attention ... "config_changed_during_verification"`; initController.ts:77-79 locked() covers only this page's own jobs, and resumeApply (initController.ts:264-273) ignores scheduled applies (worker.kind != 'apply')


**Expected:** The policy write is refused (or deferred) until the transaction ends


**Actual:** A policy commit during verification -> needs_attention + counted failure


**Impact:** While a scheduled auto apply is verifying, an admin changing mode, interval or targets on the Autotune page (or another admin, or the CLI) commits /etc/config/forkop. The verified candidate then ends as needs_attention: counted against the daily limit, cooled down, recorded as a history failure, LKG not confirmed, and the UI shows 'Rollback did not finish'.


**Root cause:** The manager write commands only protect against staged LuCI changes and never check the Stage 5 transaction window


**Affected files:** `forkop/files/usr/lib/autotune/manager.uc`, `fe-app-forkop/src/forkop/tabs/autotune/initController.ts`

**Dependencies:** None


**Proposed fix:** In uci_apply, refuse with 'apply_in_progress' while the apply.uc transaction is active (autotune lock held and autotune-apply.json phase non-terminal, or worker.phase == 'applying'). In the UI, treat status.worker.phase == 'applying' as locked.


**Tests needed:** A manager test: policy-set while the apply stand-in holds the lock in phase verifying -> refused; a UI locked() test for a scheduled apply


**Risk:** Low


---

<a id="uc-114"></a>

## UC-114 · P3 · S9 — Ручные запуски 'Check now' засчитываются в подтверждения гистерезиса, на которые опирается автономный apply

**Severity:** P3<br>
**Stage:** S9 (Autotune)<br>
**Area:** A11 hysteresis / manual vs auto<br>
**Sources:** autotune#8<br>
**Original title:** Manual 'Check now' runs advance the hysteresis confirmations that autonomous apply relies on<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-11

**Evidence:** manager.uc:538-543 hysteresis.observe(...) runs for every trigger (manual runs included); autoapply.uc:37 only the apply itself requires trigger 'schedule'; policy.uc:33 confirmations min 2


**Expected:** Confirmations reflect results spread over time as the policy interval implies


**Actual:** 3 manual runs in 10 min -> ready -> the next scheduled run applies


**Impact:** In auto mode an admin clicking 'Check all now' N times within minutes marks the group ready, and the next scheduled run applies after a single further observation. The temporal robustness that 'N runs in a row' (interval 6 h) is meant to give can be bypassed within minutes.


**Root cause:** Hysteresis does not distinguish trigger or timing


**Affected files:** `forkop/files/usr/lib/autotune/manager.uc`, `forkop/files/usr/lib/autotune/hysteresis.uc`

**Dependencies:** None


**Proposed fix:** Product choice: count only scheduled observations toward readiness for autonomous apply, or require a minimum spacing, e.g. >= interval/2 between counted confirmations. Manual runs would still update results and reset on change.


**Tests needed:** A hysteresis/scheduler test for manual observations vs readiness


**Risk:** Low


---

<a id="uc-115"></a>

## UC-115 · P3 · S9 — Строка cron autotune не синхронизируется при изменении autotune.mode через восстановление снимка или CLI с последующим reload

**Severity:** P3<br>
**Stage:** S9 (Autotune)<br>
**Area:** uci-global<br>
**Sources:** uci-global#10<br>
**Original title:** Autotune cron line is not re-synced when autotune.mode changes via snapshot restore or CLI plus reload<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** The cron line is written only by manager.uc:278-281 (policy_set of 'mode') and lifecycle.uc:809-819 refresh_cron (called at start, lifecycle.uc:955, and on reload only when plan.needs_cron_refresh, lifecycle.uc:1983). state.uc:1464-1482 cron_signature_body covers list/component/subscription intervals only, not autotune.mode.


**Reproduction:** With mode off, restore a snapshot that has mode 'auto'. The crontab has no forkop-autotune line.


**Expected:** The cron line follows autotune.mode after any config change that is applied by reload.


**Actual:** The cron line reflects the mode set by the last policy_set or start, not the current config.


**Impact:** When a restored snapshot (or `uci set forkop.autotune.mode=auto; forkop reload`) turns autotune on, no '# forkop-autotune' cron line is installed until the next service start. The Autotune page shows mode 'Automatic' (possibly with a stale next_run_at), but nothing runs. The reverse direction is harmless because if_due re-checks the mode.


**Root cause:** The autotune schedule lives outside the reload signature system.


**Affected files:** `forkop/files/usr/lib/service/state.uc`, `forkop/files/usr/lib/service/lifecycle.uc`

**Proposed fix:** Add autotune mode to cron_signature_body (read the 'autotune' section), or run `manager.uc cron-sync` unconditionally at the end of reload (idempotent, writes only on change).


**Tests needed:** Reload plan fixture: autotune mode off->auto changes the cron signature (or the reload calls cron-sync).


**Risk:** Very low.


---

<a id="uc-116"></a>

## UC-116 · P3 · S10 — Применение настроек URLTest маскирует неудачный reload сообщением 'URLTest settings saved'

**Severity:** P3<br>
**Stage:** S10 (Контракты CLI/API и семантика ошибок)<br>
**Area:** FE use of service action job result (two-level success)<br>
**Sources:** cli-contract#3<br>
**Original title:** URLTest settings apply masks a failed reload as 'URLTest settings saved'<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/tabs/dashboard/initController.ts:1327-1329 `const result = await ForkopShellMethods.waitServiceActionJob(jobId); ... if (!result.success) throw new Error('reload failed');` checks only the RPC-level success. waitServiceActionJob returns success:true with data.success:false for a finished failed job (methods/shell/index.ts:573-588). Compare serviceControl.ts:19-24, which also checks `result.data.success === false`.


**Expected:** Error toast ('settings saved but reload failed'), and the modal stays open.


**Actual:** Success toast after a failed reload job.


**Impact:** The URLTest override is committed (config/urltest_override.uc commits UCI) and the reload job fails, e.g. 'Service reload failed' or 'did not reach expected state'. The modal still closes with a success toast, so a failed runtime apply is presented as success (invariant 5 spirit).


**Root cause:** The job-status contract has RPC-level and job-level success. This caller handles only the first.


**Affected files:** `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`

**Proposed fix:** After waitServiceActionJob, also throw when `result.data.success === false` (reuse runForkopServiceAction('reload'), which already implements both checks).


**Tests needed:** Vitest for the URLTest save flow with a mocked waitServiceActionJob returning {success:true,data:{success:false}}.


**Risk:** None.


---

<a id="uc-117"></a>

## UC-117 · P3 · S10 — nolog() никогда не печатает: CLI-диагностика теряет вердикт и текст ошибок

**Severity:** P3<br>
**Stage:** S10 (Контракты CLI/API и семантика ошибок)<br>
**Area:** diagnostics/runtime.uc CLI text output<br>
**Sources:** cli-contract#4<br>
**Original title:** nolog() never prints: CLI diagnostics lose their verdict and error text<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** diagnostics/runtime.uc:376-378 `function stdout_is_tty() { return command_success_from_args([ "test", "-t", "1" ]); }`. command_success (:122-124) appends `>/dev/null 2>&1`, so `test -t 1` always tests /dev/null. nolog (:380-385) returns early. Used 24 times, e.g. check_proxy :684 `nolog(masked_response_ip + " - should match proxy IP")`, :640-648, check_nft :713-722, show_sing_box_config :798-801, show_config :856-858, check_logs :760-768.


**Reproduction:** Scratch ...scratch/audit-cli-rpc/tty_probe.sh


**Expected:** Human-readable progress and verdict lines on a terminal.


**Actual:** Reproduced under a pty (`script -qc`): the runtime.uc-style check prints 'NOT TTY' while a direct `test -t 1` prints 'TTY'.


**Impact:** `forkop check_proxy` in a terminal prints only the masked config and never the egress-IP verdict or the failure reasons. check_nft/show_config/show_sing_box_config/check_logs failures exit 1 with no output. The UI gets an empty error string, for example when the sing-box config is missing.


**Root cause:** The TTY probe runs with stdout redirected to /dev/null.


**Affected files:** `forkop/files/usr/lib/diagnostics/runtime.uc`

**Proposed fix:** `return system("test -t 1") == 0;` (no redirect; system() inherits stdout) or use `fs.stdout.isatty()`. Keep the non-TTY path silent, which the UI JSON parsing relies on.


**Tests needed:** A unit test of stdout_is_tty under `script` (pty) and under a pipe.


**Risk:** None for UI paths (always non-TTY).


---

<a id="uc-118"></a>

## UC-118 · P3 · S10 — Операции чтения clash_api завершаются с кодом 0 при ошибках транспорта и sing-box; формат ответа об ошибке различается по действиям

**Severity:** P3<br>
**Stage:** S10 (Контракты CLI/API и семантика ошибок)<br>
**Area:** clash_api RPC contract<br>
**Sources:** cli-contract#9<br>
**Original title:** clash_api read operations exit 0 on transport and sing-box errors; failure envelopes differ per action<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** diagnostics/runtime.uc:1570-1573 `function clash_json_output(args) { print(status_output([ "stdin-json" ], command_output(...))); return 0; }` is used by get_proxies/get_connections/get_proxy_latency/get_group_latency. When sing-box is down the output is empty and rc is 0; sing-box error bodies {"message":...} pass through with rc 0. Other actions use {error} (runtime.uc:1593-1597 via status.uc:951-953), {success:false,error,message} (status.uc:1612-1622), {success:false,http_code,body} (status.uc:1591-1601), {success:false,count,failed} (status.uc:1671-1680). get_proxy_latencies counts a failure only when stdin-json rejects the output, so a valid error JSON is never counted (runtime.uc:1817).


**Expected:** rc≠0 and one error envelope.


**Actual:** rc 0 with empty or error JSON.


**Impact:** Latency jobs for group/proxy always end 'completed'. get_proxies with sing-box down yields success:false with an empty error in callBaseMethod. proxy_list progress reports failed=0 while every proxy errored. Each caller has to know a different error shape.


**Root cause:** The stdin-json pass-through was designed for read-only display, then reused for job success.


**Affected files:** `forkop/files/usr/lib/diagnostics/runtime.uc`, `forkop/files/usr/lib/diagnostics/status.uc`

**Dependencies:** Complements the P2 latency URL finding.


**Proposed fix:** Return 1 from clash_json_output when curl produced no JSON. For delay endpoints, treat a body without numeric 'delay' (or with 'message') as a failure and count it in get_proxy_latencies. Converge on {success:false,error:<code>,message} for all clash_api failures.


**Tests needed:** diagnostics_status.sh: get_proxy_latency with an error body → rc 1; get_proxy_latencies counts an error body as failed; get_proxies with empty curl output → rc 1.


**Risk:** The FE checks data.message today; after the change, error bodies arrive as success:false. Verify runSectionsCheck and dashboard latency parsing.


---

<a id="uc-119"></a>

## UC-119 · P3 · S10 — Busy, неверный ввод и forbidden сообщаются английским свободным текстом или общими ошибками; RU UI показывает ошибки на смеси языков

**Severity:** P3<br>
**Stage:** S10 (Контракты CLI/API и семантика ошибок)<br>
**Area:** backend error-concept unification / A16<br>
**Sources:** cli-contract#10<br>
**Original title:** Busy, invalid input and forbidden are reported as English free text or generic failures; the RU UI shows mixed-language errors<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/ui.uc:1386-1403 busy and invalid input as `action_start_response(false, "", "Another service action is already running")` (no reason code). FE serviceTransition.ts:94-99 shows `${_('Service action failed')}: ${detail}` with the raw backend text. components/action.uc:2584-2585 busy becomes a job failure 'Another component action is already running'; :2629-2630 invalid component/action is only detected inside the async job (updates.uc:2592-2637 does not validate). snapshots.uc:420-425 deleting the LKG snapshot or an invalid id → {status:'failed'} with no reason; create with a bad kind → {status:'failed'}. None of these msgids exist in po/ru/forkop.po (grep count 0 for 'Another service action is already running', 'Another latency test is already running', 'Another component action is already running', 'Forkop startup is still in progress').


**Expected:** Machine-readable reason codes with localized UI text.


**Actual:** Free-text English messages; busy shown as failure.


**Impact:** A Russian UI shows e.g. 'Не удалось выполнить действие: Another service action is already running'. Busy is presented as failure; invalid input and forbidden cannot be told apart from backend faults; CLI scripts cannot branch on a code.


**Root cause:** There is no shared error envelope; each module invented its own.


**Affected files:** `forkop/files/usr/lib/service/ui.uc`, `forkop/files/usr/lib/components/updates.uc`, `forkop/files/usr/lib/components/action.uc`, `forkop/files/usr/lib/config/snapshots.uc`, `fe-app-forkop/src/forkop/tabs/diagnostic/serviceTransition.ts`, `luci-app-forkop/po/ru/forkop.po`

**Proposed fix:** Add a stable `reason` code to action_start_response, job states, component/subscription job errors and snapshot failures (busy, startup_in_progress, invalid_action, invalid_job, not_found, lkg_protected, invalid_kind, unknown_component_action). Map the codes to _() strings in the FE and keep message as a fallback. Validate component/action in component_action_async before starting the job.


**Tests needed:** Contract tests per command asserting a reason field for busy and invalid input; an FE mapping test.


**Risk:** Additive field, backward compatible.


---

<a id="uc-120"></a>

## UC-120 · P3 · S10 — Результаты действий со службой обрабатываются непоследовательно: busy показывается как сбой, нет паузы для временных ошибок, сбой восстановленного задания игнорируется

**Severity:** P3<br>
**Stage:** S10 (Контракты CLI/API и семантика ошибок)<br>
**Area:** frontend/service actions<br>
**Sources:** frontend-arch#11<br>
**Original title:** Service-action outcomes handled inconsistently: busy shown as failure, no transient grace, restored-job failure ignored<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** methods/shell/index.ts:573-594 waitServiceActionJob returns on the first `!response.success` (no createTransientRpcGraceTracker, unlike latency 652-681 and subscription 915-940); the timeout after 2 min is returned as an error. shared/serviceControl.ts:10-27 throws, so the error toast shows 'Service action failed: …' (dashboard/initController.ts:143-145). The backend busy text 'Another service action is already running' (service/ui.uc:1398) is shown raw and untranslated as a failure. diagnostic/initController.ts:293-307 followServiceActionState ignores the wait result (catch never fires), then acks the job.


**Expected:** Unified status concepts: busy is a warning, timeout is 'not confirmed', failure is an error, and every finished failure is surfaced.


**Actual:** busy, timeout and failure all render as 'Service action failed: <raw backend text>'; a restored job's failure is dropped.


**Impact:** A restart that is still running (slow start above 2 min, or a lost RPC reply) is reported as failed. A busy refusal is shown as a red failure in English. If the page that started an action was reloaded, a failed restart/start is acknowledged silently, with no action-level notice (only the health event later).


**Root cause:** The service path predates the grace/ownership logic added for latency, subscription and component jobs.


**Affected files:** `fe-app-forkop/src/forkop/methods/shell/index.ts`, `fe-app-forkop/src/forkop/tabs/shared/serviceControl.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/initController.ts`

**Proposed fix:** Add transient-RPC grace to waitServiceActionJob. Map the 'already running' start refusal to a translated warning 'Another service action is running'. On timeout, say 'still running, see status' rather than failure. In followServiceActionState, show a toast when the finished job has success:false.


**Tests needed:** waitServiceActionJob with one transient failure then success resolves success; followServiceActionState with a finished success:false job emits a toast.


---

<a id="uc-121"></a>

## UC-121 · P3 · S11 — Принудительное обновление runtime-состояния присоединяется к более старому текущему опросу, и переключатель автозапуска ложно сообщает 'Could not change autostart'

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/runtime state<br>
**Sources:** frontend-arch#4<br>
**Original title:** A forced runtime-state refresh joins an older in-flight poll, so the autostart toggle reports a false 'Could not change autostart'<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** runtimeUiState.service.ts:77-79 `if (runtimeUiStateRefreshPromise) { return runtimeUiStateRefreshPromise; }` applies even for force:true. serviceControl.ts:45-54 setForkopAutostart awaits `refreshRuntimeUiState({ force: true })` then returns `Boolean(store.get().servicesInfoWidget.data.forkopEnabled)`. dashboard/initController.ts:161-162 shows 'Could not change autostart' on mismatch. The 1 s background poll (runtimeUiState.service.ts:40-57) is in flight T/(T+1000 ms) of the time. The coalescing is pinned by services/tests/runtimeUiState.service.test.ts 'coalesces concurrent refreshes into one RPC call'.


**Reproduction:** scratch/audit-frontend\build\fe-app-forkop\src\forkop\tabs\shared\audit_autostart_repro.test.ts -> 'AUTOSTART_READBACK: false router enabled = 1'


**Expected:** A forced refresh issued after a mutation always observes the post-mutation state.


**Actual:** Scratch vitest: a poll starts (reads enabled=0), `enable` runs, the forced refresh joins the poll, and the read-back is false while the router has enabled=1.


**Impact:** Toggling autostart on the Overview shows an error toast in roughly 10-30% of clicks although the change succeeded; the card corrects itself about 1 s later. The same stale read-back affects the other post-mutation forced refreshes (service actions, component/updates mount), making the state briefly wrong.


**Root cause:** Promise coalescing does not distinguish requests issued before and after the mutation.


**Affected files:** `fe-app-forkop/src/forkop/services/runtimeUiState.service.ts`, `fe-app-forkop/src/forkop/tabs/shared/serviceControl.ts`, `fe-app-forkop/src/forkop/services/tests/runtimeUiState.service.test.ts`

**Proposed fix:** When force=true and a refresh is in flight, chain a single follow-up refresh after the in-flight one and return it. Concurrent forced callers share that follow-up, so coalescing is kept. Update the coalescing test to allow the one queued follow-up.


**Tests needed:** The reproduction as a unit test: an in-flight poll resolving the old state, then setForkopAutostart(true), must return true.


---

<a id="uc-122"></a>

## UC-122 · P3 · S11 — Сбои опроса никогда не помечают данные как устаревшие: последнее состояние службы и данные узлов показываются бессрочно без предупреждения

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/stale data<br>
**Sources:** frontend-arch#5<br>
**Original title:** Poll failures never mark data as stale: the last service state and node data are shown indefinitely without a warning<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** runtimeUiState.service.ts:91-107: on `!response.success` or catch the store is left untouched (logger only). servicesInfoWidget.failed is set only by fetchServicesInfo at mount (fetchers/fetchServicesInfo.ts:48-68), so getServiceAvailability never becomes 'unavailable' after the first success. dashboard/initController.ts:280-292: a failed sections refresh keeps old data with `failed: current.data.length === 0`. ui/asyncState.ts isStale() is never used in production.


**Expected:** Stale data is labelled, or the state switches to 'unavailable'.


**Actual:** Last good values are shown with no indicator after repeated failures.


**Impact:** If get_ui_state starts failing (rpcd hung, 3 s timeout under load, router unreachable), Overview keeps 'Forkop X is running / sing-box is running'. Monitoring→Nodes keeps the last selected nodes and latencies with no staleness hint, even if the service stopped meanwhile.


**Root cause:** The periodic refresh path swallows failures; the unified isStale helper is unused.


**Affected files:** `fe-app-forkop/src/forkop/services/runtimeUiState.service.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/partials/renderSections.ts`

**Proposed fix:** Track lastSuccessAt and consecutive failures in runtimeUiState. After N failures or more than about 5 s, set servicesInfoWidget.failed=true; the existing 'State unavailable' path already renders that. Add a stale flag to sectionsWidget on refresh failure and render an 'outdated since hh:mm' hint.


**Tests needed:** runtimeUiState test: after a success then 3 failed polls, servicesInfoWidget.failed is true; dashboard test: a failed refresh sets the stale flag while keeping data.


---

<a id="uc-123"></a>

## UC-123 · P3 · S11 — Сбои probe/RPC подаются как отрицательные наблюдаемые результаты (проверка сайта, матрица связности, проверка FakeIP)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/diagnostics error mapping<br>
**Sources:** frontend-arch#6<br>
**Original title:** Probe/RPC failures are presented as negative observed results (site check, connectivity matrix, FakeIP check)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** connectivityMatrix.ts:128-130 `if (!response.success || !response.data?.status) return { state: 'invalid', message: _('The router rejected this check') };` covers rpcd timeouts too (connectivityTest has a 10 s timeout and no allowNonZeroWithStdout, index.ts:479-484). siteCheck.ts:146-171 siteConclusion treats any non-'done' result as 'The site did not open from the router…' plus a DPI hint 'the strategy does not work with your provider'. checks/runFakeIPCheck.ts:26-28,64-68: routerFakeIPResponse.success=false shows 'Sing-box FakeIP DNS does not work' (error).


**Reproduction:** scratch/audit-frontend\build\fe-app-forkop\src\forkop\tabs\diagnostic\tests\audit_sitecheck_repro.test.ts


**Expected:** A failed check is shown as 'could not check', distinct from invalid input and from an observed failure.


**Actual:** Scratch vitest with connectivityTest -> {success:false,error:'Operation timed out'}: probe gives {state:'invalid', message:'The router rejected this check'} and the conclusion reads 'The site did not open from the router… the strategy does not work with your provider.'


**Impact:** A timeout or rpcd error is reported as an invalid input or an observed failure. The site-check conclusion says the site did not open and blames the DPI strategy even though no probe ran. That contradicts the page's own rule 'A conclusion never claims more than the router could establish'.


**Root cause:** A single fallback branch conflates invalid_input, transport failure and timeout.


**Affected files:** `fe-app-forkop/src/forkop/tabs/diagnostic/connectivityMatrix.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/siteCheck.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/checks/runFakeIPCheck.ts`, `fe-app-forkop/src/forkop/methods/shell/index.ts`

**Proposed fix:** Use allowNonZeroWithStdout for connectivityTest and map `{error:'invalid_input'}` to the invalid state. Add a separate 'failed' RowResult ('The check could not run') for transport errors. siteConclusion must claim 'did not open' only when result.state==='done'. In the FakeIP check, render a router RPC failure as a warning 'Could not check'.


**Tests needed:** connectivityMatrix/siteCheck tests for a transport failure versus {error:'invalid_input'}; FakeIP test for a router RPC failure.


---

<a id="uc-124"></a>

## UC-124 · P3 · S11 — Список Settings→Components пуст после Save (повторный рендер формы создаёт новый пустой контейнер)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/settings lifecycle<br>
**Sources:** frontend-arch#7<br>
**Original title:** Settings→Components list is blank after Save (the form re-render creates a fresh empty container)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** updates.js:9-16 `o.cfgvalue = () => { main.UpdatesTab.initController(); return main.UpdatesTab.render(); }`, and render() returns an empty #fkp_updates-components (updates/render.ts). LuCI form.js CBIMap.save ends with `.then(this.renderContents.bind(this))`, so all options re-render. renderUpdatesComponents runs only on mount or on store diffs (updates/initController.ts:1419-1432); initController is a no-op after the first call (1539-1545). The active tab does not change, so TabService does not remount.


**Expected:** Component cards are re-rendered into the new container.


**Actual:** After map.save → renderContents, #fkp_updates-components is a new empty div with nothing to populate it.


**Impact:** Clicking Save, or Save & Apply with no Forkop reload, while on the Components tab leaves it empty until the user switches tabs or some store value changes.


**Root cause:** The controller renders by element id only on store/tab events, and a form re-render emits neither.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/updates.js`, `fe-app-forkop/src/forkop/tabs/updates/initController.ts`

**Proposed fix:** Have render() or cfgvalue schedule a renderUpdatesComponents() once the new container is attached (e.g., queueMicrotask/onMount on the new element) when the controller is already mounted.


**Tests needed:** Controller test: after mount, replace the container element and call render()/cfgvalue again; the cards must reappear without a store change.


---

<a id="uc-125"></a>

## UC-125 · P3 · S11 — Адрес прямого контроллера Clash берётся из window.location.hostname; LuCI через туннель или прокси обращается к чужому контроллеру

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/clash WS+HTTP fallback<br>
**Sources:** frontend-arch#9<br>
**Original title:** Direct Clash controller address is derived from window.location.hostname; tunnelled or proxied LuCI talks to a foreign controller<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** helpers/getClashApiUrl.ts:6-25: canUseDirectClashApi only requires non-https; getClashWsUrl `ws://${hostname}:9090`, getClashHttpUrl `http://${hostname}:9090`. getDashboardSections.ts:148-178 fetches `${getClashHttpUrl()}/proxies` with `Authorization: Bearer <router secret>`. Dashboard and Monitoring WS use the same host (4595075c).


**Expected:** The UI only shows data it can attribute to the router.


**Actual:** The controller is chosen by page hostname only.


**Impact:** When LuCI is opened through an SSH tunnel (http://127.0.0.1:8080) on a PC running Clash Verge or mihomo (default controller :9090), the Overview traffic, Nodes groups and Monitoring connections show the PC's local Clash data as router data. The router's controller secret is sent to that local service. Actions (switch node, close connection) then go through RPC to the router with IDs that do not exist there.


**Root cause:** The assumption that the page host is the router's controller host.


**Affected files:** `fe-app-forkop/src/helpers/getClashApiUrl.ts`, `fe-app-forkop/src/forkop/methods/custom/getDashboardSections.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`, `fe-app-forkop/src/forkop/tabs/monitoring/initController.ts`

**Proposed fix:** Use the direct controller only when location.hostname equals the router's controller address reported by the backend (e.g., include the service_address/controller host in get_ui_capabilities). Otherwise use rpcd. Alternatively verify identity through a backend-provided nonce before trusting the socket.


**Tests needed:** getClashApiUrl unit tests: hostname localhost or a hostname not matching the router's reported address makes canUseDirectClashApi false.


---

<a id="uc-126"></a>

## UC-126 · P3 · S11 — Модальное окно просмотра логов вызывает check_logs подряд (каждые 250 мс) и продолжает, пока вкладка скрыта

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/poll load<br>
**Sources:** frontend-arch#10<br>
**Original title:** The log viewer modal runs check_logs back to back (250 ms) and keeps doing so while the tab is hidden<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** diagnostic/initController.ts:614-622 `renderModal(..., { getText: getLatestLogs, refreshMs: 250, initialAutoRefresh: true, ...})`; renderModal.ts:193-205 setInterval(requestRefresh, refreshMs) with pendingRefresh re-triggering right after each response (158-167); refreshText checks only body.isConnected, not document.hidden.


**Expected:** Bounded refresh rate, paused when not visible.


**Actual:** Continuous RPCs while the modal is open.


**Impact:** While 'View logs' is open, the router spawns /usr/bin/forkop check_logs (ucode + logread filter) continuously, 4/s or bounded by latency, even in a background tab. That adds CPU load on the router during troubleshooting.


**Root cause:** An aggressive interval with no visibility gate.


**Affected files:** `fe-app-forkop/src/forkop/tabs/diagnostic/initController.ts`, `fe-app-forkop/src/partials/modal/renderModal.ts`

**Proposed fix:** Use refreshMs of 2000 or more and skip refreshes while document.hidden (resume on visibilitychange).


**Tests needed:** renderModal test with fake timers: no getText calls while document.hidden; rate is at most 1 per refreshMs.


---

<a id="uc-127"></a>

## UC-127 · P3 · S11 — Метки, зависящие от конфигурации, заморожены на время жизни страницы (кэш uci.load, однократная загрузка маршрутов в Monitoring)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/stale data<br>
**Sources:** frontend-arch#12<br>
**Original title:** Config-derived labels are frozen for the page lifetime (uci.load cache, one-shot Monitoring route load)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** methods/custom/getConfigSections.ts:5-8 `await uci.load(FORKOP_UCI_PACKAGE); return await uci.sections(...)`. LuCI uci.load skips packages already in state.values, and shell.detectAccess already loaded it, so getDashboardSections (every 10 s, getDashboardSections.ts:1393-1394) always uses the page-load config. monitoring/initController.ts:1845-1856 loadRouteDisplayNames (rule labels, dpi_provider/dpi_strategy) runs only in onPageMount (2091-2093).


**Expected:** Config-derived facts track the saved configuration within one refresh interval.


**Actual:** Config snapshot as of page load.


**Impact:** After an autotune auto-apply or a rules edit in another tab, Monitoring connection details keep showing the old 'DPI strategy: X (From configuration)', and Overview/Nodes keep the old group set and labels until a reload. The data is presented as current configuration without a staleness hint.


**Root cause:** LuCI uci client caching and a mount-only load.


**Affected files:** `fe-app-forkop/src/forkop/methods/custom/getConfigSections.ts`, `fe-app-forkop/src/forkop/tabs/monitoring/initController.ts`

**Proposed fix:** On read-only status pages, fetch config through a fresh call: uci.unload before uci.load when there are no local changes, or use get_readonly_config_sections. Refresh Monitoring route names periodically, or when history or ui_state reports a new reload/autotune_apply event.


**Tests needed:** getConfigSections test: a second call after a config change returns new sections; monitoring test: route names refresh after a reload event.


---

<a id="uc-128"></a>

## UC-128 · P3 · S11 — Глубокая ссылка diagnostics#host=<name> при открытии страницы автоматически запускает DNS/HTTPS-проверку с роутера

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/deep links<br>
**Sources:** frontend-arch#13<br>
**Original title:** diagnostics#host=<name> deep link auto-runs a router-originated DNS/HTTPS probe on page open<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:** diagnostic/siteCheck.ts:291-296 `const host = readPageParams().host; if (host && !input.value) { input.value = host.slice(0, 253); button.click(); }`, which runs route_trace and connectivity_test (both in the RO ACL).


**Expected:** Router-originated network actions require a user gesture.


**Actual:** The probe runs on page load from URL data.


**Impact:** A link opened by any logged-in user, including read-only, e.g. …/forkop/diagnostics#host=tracker.example, immediately makes the router resolve and HTTPS-connect to that host. This tells the link author the router's egress IP for that route without any user click. It is a small information leak and runs on every reload of the URL.


**Root cause:** Convenience auto-run on deep link.


**Affected files:** `fe-app-forkop/src/forkop/tabs/diagnostic/siteCheck.ts`

**Proposed fix:** Pre-fill the field from the hash but require an explicit click, or auto-run only when navigated from Monitoring (e.g., a one-shot sessionStorage token set by the Monitoring link).


**Tests needed:** siteCheck test: a hash with host pre-fills but does not call routeTrace/connectivityTest.


---

<a id="uc-129"></a>

## UC-129 · P3 · S11 — Monitoring -> Nodes and groups показывает бесконечный скелетон загрузки при остановленном Forkop X (CSS остановленного состояния нацелен на удалённую обёртку)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/monitoring-nodes<br>
**Sources:** ui-cleanup-deadcode#0<br>
**Original title:** Monitoring -> Nodes and groups shows an endless loading skeleton when Forkop X is stopped (stopped-state CSS targets a removed wrapper)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/tabs/dashboard/styles.ts:37-40 "/* ... the nodes section hides while Forkop X is stopped. */ .fkp_dashboard-page--service-stopped .fkp_dashboard-page__content { display: none; }"; dashboard/initController.ts:884 "container?.classList.toggle('fkp_dashboard-page--service-stopped', stopped)" then :886-888 stopDashboardDataUpdates(); dashboard/render.ts:21 renderNodes() renders #dashboard-sections-grid with NO .fkp_dashboard-page__content wrapper (wrapper deleted in f02d8a0a); store.service.ts:293-294 sectionsWidget initial "loading: true"; initController.ts:229-232 fetchDashboardSectionsOnce "if (getDashboardServiceAvailability() === 'stopped') return false;"; renderSections.ts:581 "if (props.loading) return renderLoadingState();". Contrast: Connections view has an explicit stopped state (monitoring/initController.ts:1323-1327 'Forkop service is stopped. Start the service to display connections.'). grep: rg 'dashboard-page__content' fe-app-forkop/src -> only styles.ts:38


**Reproduction:** Stop Forkop X; open Services -> Forkop X -> Monitoring -> 'Nodes and groups'.


**Expected:** Nodes view states that Forkop X is stopped (as Connections view does) and hides/greys stale node data.


**Actual:** Nodes view with stopped service: permanent loading skeleton (fresh load) or stale cards (stop while open).


**Impact:** Open admin/services/forkop/monitoring#view=nodes with Forkop X stopped: the grid shows the skeleton forever with no explanation (looks like a hang). If the service stops while the view is open, stale node cards/latencies stay visible and their actions silently no-op (handlers return early when stopped). Misleading state, low risk.


**Root cause:** Stage 6.5 (f02d8a0a) moved node selection into Monitoring and dropped the fkp_dashboard-page__content wrapper, but kept the CSS-only stopped-state hook that depended on it; no JS stopped state was added.


**Affected files:** `fe-app-forkop/src/forkop/tabs/dashboard/styles.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/render.ts`

**Dependencies:** None


**Proposed fix:** In renderSectionsWidget (dashboard/initController.ts:1805) render an explicit empty/neutral state (renderEmptyState(_('Forkop X is stopped'), hint, Start action or link to Overview)) when getDashboardServiceAvailability()==='stopped'; delete the dead .fkp_dashboard-page--service-stopped .fkp_dashboard-page__content rule (styles.ts:37-40).


**Tests needed:** vitest: dashboard controller with servicesInfoWidget.forkopRunning=0 on the Nodes host renders a stopped message, not the skeleton; router check: stop service, open monitoring#view=nodes.


**Risk:** Low; UI-only.


---

<a id="uc-130"></a>

## UC-130 · P3 · S11 — Тосты успеха действий с компонентами показывают сырые английские сообщения бэкенда; translate() скрывает 'Forkop has been installed' от извлечения строк

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** frontend/localization<br>
**Sources:** ui-cleanup-deadcode#2, ui-css-a11y-i18n#16<br>
**Original title:** Component-action success toasts show raw English backend messages; translate() hides 'Forkop has been installed' from extraction<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** updates/initController.ts:487 "showToast(result.message, 'success', 5000)", :504 "showToast(result.message, 'success', 1200)", :514 "showToast(result.message, 'success')" where result.message comes from backend components/action.uc:1191 "label + \" package has been installed\"", :1236, :1262 "Zapret-Manager has been installed from the Forkop mirror", :1307 "package has been removed", :1725, :1889, :1968, :2435 "Forkop has been installed". Frontend: methods/shell/index.ts:29-31 "function translate(message) { return typeof _ === 'function' ? _(message) : message; }" and :836 "message: translate('Forkop has been installed')" - extract-calls.js only collects _() literals, so the msgid is absent from po/templates/forkop.pot and po/ru/forkop.po (replica extraction: key missing).


**Reproduction:** RU UI -> Settings -> Components -> update sing-box -> toast text in English.


**Expected:** All user-visible toast text localized.


**Actual:** English backend strings in RU toasts; 'Forkop has been installed' untranslatable.


**Impact:** RU users see English success toasts after every component install/remove/self-update (e.g. 'sing-box-extended has been installed'); the one frontend-authored string can never be translated.


**Root cause:** Backend returns human prose instead of a code, frontend shows it verbatim; wrapper function defeats the literal-only extractor.


**Affected files:** `fe-app-forkop/src/forkop/tabs/updates/initController.ts`, `fe-app-forkop/src/forkop/methods/shell/index.ts`, `luci-app-forkop/po/templates/forkop.pot`, `luci-app-forkop/po/ru/forkop.po`

**Dependencies:** Stage 6.10 localization.


**Proposed fix:** Build success text in the frontend from result.component/action (e.g. _('%s has been installed') / _('%s has been removed') with componentDisplayName) and ignore backend prose for toasts; replace translate('...') with a literal _('...') (or keep the guard but call _ with a literal) and re-run locales:actualize.


**Tests needed:** vitest for handleComponentActionResult toast text in RU mock; luci_localization check that no toast passes backend prose.


**Risk:** Low.


### Also reported as ui-css-a11y-i18n#16 (P3): Component install/remove results show raw English backend messages; the translate() wrapper keeps the one frontend message out of the catalog

**Evidence:** updates/initController.ts:487 showToast(result.message, 'success', 5000), :504, :514 'showToast(result.message, \'success\')', :541-553 error message = response.data.message. Backend messages are English, e.g. components/action.uc:1191 'label + " package has been installed"' and :1307 'label + " package has been removed"'. methods/shell/index.ts:29-31 'function translate(message) { return typeof _ === \'function\' ? _(message) : message; }' used at :836 translate('Forkop has been installed'); extract-calls.js only matches callee '_', and grep finds no msgid "Forkop has been installed" in ru/forkop.po


**Proposed fix:** Compose success toasts on the frontend from component and action, e.g. _('%s installed') / _('%s removed') with the localized component title; keep backend text only as technical detail for failures. Replace translate('...') with _('...') so it is extracted


---

<a id="uc-131"></a>

## UC-131 · P3 · S11 — Settings>Components: строки действий карточек не переносятся, и 'Choose version' выходит за пределы карточки Forkop X (известный пункт HW-проверки)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A19 responsive CSS<br>
**Sources:** ui-css-a11y-i18n#0<br>
**Original title:** Settings>Components: card action rows cannot wrap, so 'Choose version' overflows the Forkop X card (known HW item)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/tabs/updates/styles.ts:144-149 '.fkp_updates-page__component__actions-main { ... flex-wrap: nowrap; gap: 6px; }'; styles.ts:165-168 '.fkp_updates-page__component__variants-buttons { display: flex; flex-wrap: nowrap; }'; styles.ts:91-98 '.fkp_updates-page__component__info-row { ... white-space: nowrap; }'; updates/initController.ts:1279-1296 pushes renderButton({ text: _('Choose version') }) into primaryButtons, rendered in one actions-main row at :1317. HW measurement 11-settings/overflow-measure.json: overflowPx 70 @1440 and 90 @768


**Reproduction:** Settings > Components at 1440 or 768 with RU locale; Forkop X card with 'Проверить обновление', 'Обновить', 'Выбрать версию'


**Expected:** Buttons wrap inside the card at every width (design J.8: 'Кнопочные ряды — flex-wrap: wrap')


**Actual:** Row min-content width = sum of the button widths (buttons are nowrap in LuCI themes); the row overflows the card


**Impact:** At 1440 (3 columns) and 768 (2 columns, because the 760px breakpoint does not fire) the third button spills over the neighbouring card title (seen in components-768.png). The same happens on the zapret/zapret2/byedpi cards once an update is found: 'Проверить обновление' + 'Обновить' + 'Удалить' with icons, about 400px in a card about 340px wide


**Root cause:** Explicit flex-wrap:nowrap on the component action rows, plus a third button ('Choose version') added to the same row without re-checking the width


**Affected files:** `fe-app-forkop/src/forkop/tabs/updates/styles.ts`

**Dependencies:** The Russian button labels ('Проверить обновление', 'Выбрать версию')


**Proposed fix:** Change actions-main and variants-buttons to 'flex-wrap: wrap'. Replace 'white-space: nowrap' on info-row with 'flex-wrap: wrap' so the value can use its overflow-wrap:anywhere. No markup change is needed


**Tests needed:** A vitest style assertion like observability.test.ts:621 checking that actions-main and variants-buttons use 'flex-wrap: wrap'; re-measure at 1440/1024/768 on the router


**Risk:** Very low; CSS only


---

<a id="uc-132"></a>

## UC-132 · P3 · S11 — Settings>Rules при 768: ячейка действий не переносится, часть колонок фиксированной ширины, нет правила для узких экранов — таблица на 21px шире страницы (известный пункт HW-проверки)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A19 responsive CSS<br>
**Sources:** ui-css-a11y-i18n#1<br>
**Original title:** Settings>Rules at 768: the row-actions cell never wraps, some columns have fixed widths and there is no narrow rule, so the table is 21px wider than the page (known HW item)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/styles.ts:38-42 '#cbi-${FORKOP_CBI_PREFIX}-section .cbi-section-actions > div { display: inline-flex; align-items: center; gap: 4px; }'. LuCI renders that td with class 'nowrap' (form.js renderRowActions: 'td cbi-section-table-cell nowrap cbi-section-actions') and puts ☰ + Edit ('Изменить') + Delete ('Удалить') in it. section.js:6811 'o.width = "6rem"' (Enable column) and :6827 'o.width = "8rem"' (Action column). Grep finds no media query for #cbi-forkop-section anywhere. HW overflow-measure.json 768: vw 753, tableRight 774, maxDeleteRight 763


**Reproduction:** Settings > Rules at 768x1024, RU, 11 rules (settings-768-0.png)


**Expected:** No page-level horizontal scroll at 768 (design J.6, 'горизонтальный скролл допустим только внутри контейнера')


**Actual:** The table's min-content width (actions cell about 222px, never wraps, + 96px + 128px fixed + name/conditions/devices) exceeds the 753px content area


**Impact:** At 768 the page scrolls horizontally and 'Удалить' is partly clipped at the right edge; design G.6/J.6 require cards or reduced columns at ≤768 and at most one visible button plus ⋯ per row


**Root cause:** The Forkop override makes the actions container inline-flex (which never wraps) inside LuCI's nowrap cell, and nothing in Forkop CSS handles the rules grid below 900px


**Affected files:** `fe-app-forkop/src/styles.ts`, `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`

**Dependencies:** The LuCI GridSection markup (renderRowActions)


**Proposed fix:** Minimal fix: add '@media (max-width: 899px)' with '#cbi-forkop-section .cbi-section-actions { white-space: normal } #cbi-forkop-section .cbi-section-actions > div { flex-wrap: wrap; justify-content: flex-end }', drop the fixed 6rem/8rem widths (or apply them only at ≥900px), and optionally hide the Devices column at ≤1279px as J.6 prescribes


**Tests needed:** A style assertion for the narrow media rule; router check of document.scrollWidth == viewport width at 768 with 11 rules


**Risk:** Low; row actions may wrap onto two lines at narrow widths


---

<a id="uc-133"></a>

## UC-133 · P3 · S11 — Диалог полного удаления (и подтверждение смены версии) оставляет фокус на оверлее вместо Cancel (известный пункт HW-проверки)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A20 accessibility<br>
**Sources:** ui-css-a11y-i18n#2<br>
**Original title:** The Full removal dialog (and the version-change confirmation) leaves focus on the overlay instead of Cancel (known HW item)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/tabs/updates/fullUninstall.ts:93-113 calls 'ui.showModal(_('Full removal'), E('div', {}, [... E('div', { class: 'right' }, [cancel, confirm])]))' and never calls cancel.focus(). LuCI ui.js showModal ends with 'modalDiv.focus();'. By contrast ui/confirmAction.ts:68 'cancelButton.focus?.();'. The same pattern is in releaseSelector.ts:38-61 (confirmVersionChange)


**Reproduction:** Settings > Components > 'Удалить Forkop X полностью' and check document.activeElement


**Expected:** document.activeElement is the Cancel ('Отмена') button


**Actual:** document.activeElement is #modal_overlay after the dialog opens


**Impact:** Keyboard and screen-reader users land on the dialog container. The destructive dialog does not follow the Stage 6 rule 'Cancel is the default focus' used by every other confirmation


**Root cause:** A hand-rolled modal that does not reuse the focus handling of confirmAction


**Affected files:** `fe-app-forkop/src/forkop/tabs/updates/fullUninstall.ts`, `fe-app-forkop/src/forkop/tabs/updates/releaseSelector.ts`

**Dependencies:** LuCI ui.showModal behaviour


**Proposed fix:** Call 'cancel.focus()' right after ui.showModal in confirmRemoval, and focus Cancel in confirmVersionChange the same way. Keep the dialog itself: it needs the progress area


**Tests needed:** A vitest with a fake ui.showModal asserting that the Cancel button's focus() is called for confirmRemoval and confirmVersionChange


**Risk:** None


---

<a id="uc-134"></a>

## UC-134 · P3 · S11 — Escape не работает в диалогах confirmAction и других собственных модальных окнах; код предполагает, что LuCI закрывает их по Escape

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A20 accessibility<br>
**Sources:** ui-css-a11y-i18n#3<br>
**Original title:** Escape does nothing in confirmAction dialogs and the other custom modals; the code assumes LuCI closes on Escape<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** LuCI ui.js cancelModal: 'if (ev.key == \'Escape\') { const btn = modalDiv.querySelector(\'.right > button, .right > .btn, .button-row > .btn\'); if (btn) btn.click(); }'. hideModal only removes the CSS class and does not detach the content. fe-app-forkop/src/forkop/ui/confirmAction.ts:54 puts its buttons in 'fkp-confirm__actions' (not .right), and :61-66 comment 'A modal closed by LuCI itself (Escape, navigation) counts as cancel' relies on '!content.isConnected', which LuCI's Escape/hideModal never causes. The same non-matching containers are used in autotune/initController.ts:380 (modalActions 'fkp-confirm__actions'), dashboard/initController.ts:1411/1258 ('fkp_dashboard-page__urltest-details__footer') and releaseSelector.ts:118-120 (the error-state Close button is appended outside .right). While versions load, releaseSelector.ts:68-70 shows a modal with no button at all for up to RELEASES_TIMEOUT_MS = 75_000


**Reproduction:** Overview > ⋯ > Остановить…, press Escape: the dialog stays


**Expected:** Escape cancels (resolves false), as the code comment claims


**Actual:** Pressing Escape in these dialogs has no effect; the confirmAction promise stays pending


**Impact:** No Escape to cancel for Stop Forkop, Close all connections, Restore/Delete snapshot, Remove component, autotune apply/auto mode, the policy and target editors, and the URLTest editor. With an unreachable mirror, the version selector traps the user for up to 75 s. No accidental confirmation is possible (safe direction)


**Root cause:** The button containers do not match LuCI's cancelModal selector, and the unit test (ui/tests/states.test.ts:146-170) simulates an external close by setting content.isConnected=false, which real LuCI never does


**Affected files:** `fe-app-forkop/src/forkop/ui/confirmAction.ts`, `fe-app-forkop/src/forkop/tabs/autotune/initController.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`, `fe-app-forkop/src/forkop/tabs/updates/releaseSelector.ts`

**Dependencies:** LuCI ui.js cancelModal/hideModal semantics (verified on openwrt/luci master)


**Proposed fix:** In confirmAction wrap the buttons as E('div', { class: 'right fkp-confirm__actions' }, [cancelButton, confirmButton]) so LuCI's Escape clicks Cancel (first). Do the same for modalActions and the URLTest footers, keeping Cancel/Close first (in the URLTest editor Cancel is currently last). In releaseSelector render a Cancel inside .right while loading, and put the error Close inside .right. Fix the misleading comment


**Tests needed:** A vitest that renders confirmAction and asserts the Cancel button is the first match of '.right > button' (or a direct Escape simulation with LuCI's selector logic); the same for modalActions


**Risk:** Low. The button order must stay Cancel-first so Escape never confirms


---

<a id="uc-135"></a>

## UC-135 · P3 · S11 — Ошибки согласования русского множественного числа в текстах политики autotune; хелпер плюрализации во фронтенде не подключён (известный пункт HW-проверки)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A21 localization<br>
**Sources:** ui-css-a11y-i18n#4, autotune#10<br>
**Original title:** Russian plural agreement bugs in the autotune policy texts; no plural helper wired into the frontend (known HW item)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/tabs/autotune/initController.ts:182 _('At most %d change(s) per day; a rolled back strategy waits %s.').replace('%d', String(status.policy.max_applies_per_day)) and :620 _('up to %d automatic change(s) per day'). ru/forkop.po: msgstr 'Не больше %d изменений в сутки; ...' and 'до %d автоизменений в сутки'. The default max_applies_per_day is 1 (forkop/files/usr/lib/autotune/policy.uc:28). LuCI provides N_(n, s, p) (cbi.js:167), but fe-app-forkop/extract-calls.js only matches the callee '_', generate-pot.js emits no msgid_plural, and luci.d.ts declares no N_


**Reproduction:** DPI autotune page, default policy; Mode > Automatic confirmation


**Expected:** Correct Russian agreement for 1, 2-4 and 5+


**Actual:** A fixed genitive plural whatever the number


**Impact:** The default policy shows 'до 1 автоизменений в сутки' and 'Не больше 1 изменений в сутки' in the policy summary and in the confirmation for switching on automatic mode


**Root cause:** A number interpolated into one translated form; the i18n pipeline supports only _()


**Affected files:** `fe-app-forkop/src/forkop/tabs/autotune/initController.ts`, `luci-app-forkop/po/ru/forkop.po`, `luci-app-forkop/po/templates/forkop.pot`, `fe-app-forkop/locales/forkop.ru.po`, `fe-app-forkop/locales/forkop.pot`, `fe-app-forkop/locales/calls.json`

**Dependencies:** None


**Proposed fix:** Minimal fix without tooling changes: reword to the 'Label: value' pattern already used across the catalog, for example msgid 'Automatic changes per day: up to %d' → 'Автоизменений в сутки: до %d' and 'Changes per day: at most %d; a rolled back strategy waits %s.' → 'Изменений в сутки: не больше %d; ...'. Only add N_() once the locale scripts support msgid_plural


**Tests needed:** Extend tests/luci_localization.sh with the new msgid/msgstr pairs; optionally reject msgids containing '(s)'


**Risk:** None


### Also reported as autotune#10 (P3): KNOWN (hardware report): Russian plural agreement in autotune policy texts

**Evidence:** initController.ts:182 `_('At most %d change(s) per day; a rolled back strategy waits %s.')` and :620 `_('up to %d automatic change(s) per day')`; po/ru/forkop.po:323-324 'Не больше %d изменений в сутки', :3458-3459 'до %d автоизменений в сутки'; also po/ru:1226-1227 'каждые %s' gives 'каждые 1 ч' / 'каждые 1 дн.'


**Proposed fix:** Use LuCI N_(n, singular, plural) for count strings, or rephrase number-first ('Лимит автоизменений в сутки: %d', 'Интервал: %s')


---

<a id="uc-136"></a>

## UC-136 · P3 · S11 — Единицы байтов и задержки захардкожены на английском: prettyBytes B/KB/MB, '/s' и 'ms' в Overview (известный пункт HW-проверки)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A21 localization<br>
**Sources:** ui-css-a11y-i18n#5<br>
**Original title:** Byte and latency units are hardcoded in English: prettyBytes B/KB/MB, '/s' and 'ms' in Overview (known HW item)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/helpers/prettyBytes.ts:3 const UNITS = ['B', 'KB', 'MB', 'GB', ...] and :6 'return n + \' B\''; dashboard/overview.ts:214 'live += ` · ↓ ${prettyBytes(input.traffic.down)}/s ↑ ${prettyBytes(input.traffic.up)}/s`'; overview.ts:228 'latency: selected.latency ? `${selected.latency} ms` : _('no data')' although the msgid '%d ms' → '%d мс' exists and is used elsewhere (renderSections.ts:487). prettyBytes feeds Monitoring (initController.ts:329), subscription traffic (renderSections.ts:59) and the Overview


**Reproduction:** Overview > Routing card, and Monitoring traffic columns, in RU


**Expected:** Localized units (Б, КБ, МБ, КБ/с, мс)


**Actual:** English unit abbreviations in the RU UI


**Impact:** Russian UI shows 'КБ' nowhere; it shows '4.2 MB/s', '310 KB', '48 ms' next to Russian text (the design mock-up uses 'МБ/с', 'КБ/с', 'мс')


**Root cause:** The units were never passed through _()


**Affected files:** `fe-app-forkop/src/helpers/prettyBytes.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/overview.ts`, `luci-app-forkop/po/ru/forkop.po`, `luci-app-forkop/po/templates/forkop.pot`

**Dependencies:** None


**Proposed fix:** Translate units in prettyBytes (e.g. const UNITS = [_('B'), _('KB'), _('MB'), ...], or msgids '%s KB'); add _('%s/s') for rates; use _('%d ms').replace('%d', ...) in overview.ts:228


**Tests needed:** Unit test of prettyBytes with a stubbed _; a luci_localization.sh pair check for the unit msgids


**Risk:** Low; prettyBytes is also used where _ may be undefined in tests (stub needed)


---

<a id="uc-137"></a>

## UC-137 · P3 · S11 — msgid 'Download' общий для кнопки-глагола и существительного трафика, поэтому Monitoring показывает 'Скачать' рядом с 'Отправлено' (известный пункт HW-проверки)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A21 localization<br>
**Sources:** ui-css-a11y-i18n#6<br>
**Original title:** The msgid 'Download' is shared by a verb button and a traffic noun, so Monitoring shows 'Скачать' next to 'Отправлено' (known HW item)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** partials/modal/renderModal.ts:253 renderButton({ text: _('Download') }) (verb: download the text as a file); monitoring/render.ts:101 E('option', { value: 'download' }, _('Download')) and monitoring/initController.ts:1034 [_('Download'), formatBytes(connection.download)] (noun: bytes received). ru.po: 'Download' → 'Скачать', 'Upload' → 'Отправлено'


**Reproduction:** Monitoring > sort select, RU


**Expected:** A matching noun pair such as 'Получено' / 'Отправлено'


**Actual:** The sort shows 'Скачать' next to 'Отправлено'


**Impact:** The sort options read 'Скачать / Отправлено' and connection details show 'Скачать: 12 KB'; inconsistent and ungrammatical


**Root cause:** One msgid is used for two parts of speech


**Affected files:** `fe-app-forkop/src/forkop/tabs/monitoring/render.ts`, `fe-app-forkop/src/forkop/tabs/monitoring/initController.ts`, `luci-app-forkop/po/ru/forkop.po`, `luci-app-forkop/po/templates/forkop.pot`

**Dependencies:** None


**Proposed fix:** Use separate noun msgids for traffic, e.g. _('Received') → 'Получено' and _('Sent') → 'Отправлено' (or 'Downloaded'/'Uploaded'), in render.ts:101-102 and initController.ts:1034-1035; keep 'Download' → 'Скачать' for the button. LuCI _() supports a context argument, but the Forkop extractor ignores it, so a distinct msgid is the simple fix


**Tests needed:** A luci_localization.sh pair check for the new msgids


**Risk:** None


---

<a id="uc-138"></a>

## UC-138 · P3 · S11 — Подвал карточки Nodes and groups показывает сырой тип outbound Clash (например, 'Direct') (известный пункт HW-проверки)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A21 localization / raw enums<br>
**Sources:** ui-css-a11y-i18n#7<br>
**Original title:** The Nodes-and-groups card footer shows the raw Clash outbound type (e.g. 'Direct') (known HW item)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/tabs/dashboard/partials/getOutboundFooterLabel.ts:3-9 'return (outbound.urlTestInfo?.selectedName || outbound.priorityInfo?.selectedName || outbound.description || outbound.type);' where type comes from the Clash API proxies (getDashboardSections.ts:930,1040 'type: childEntry?.value?.type || \'\''); rendered at renderSections.ts:478-481


**Reproduction:** Monitoring > Узлы и группы with an interface-based connection rule


**Expected:** A localized or meaningful label ('Напрямую' or 'awg1')


**Actual:** 'Direct' in the footer of the interface node card


**Impact:** Interface outbounds (sing-box 'direct' bound to awg1) show the English 'Direct' in the Russian UI, although msgid 'Direct' → 'Напрямую' exists (connectionView.ts:118). 'Selector' would likewise be raw


**Root cause:** The final fallback is the raw backend enum


**Affected files:** `fe-app-forkop/src/forkop/tabs/dashboard/partials/getOutboundFooterLabel.ts`

**Dependencies:** None


**Proposed fix:** Map non-protocol Clash types before falling back: 'Direct' → _('Direct') (or the bound interface name when known), 'Selector' → _('Selector'); keep protocol names (VLESS, Shadowsocks, WireGuard) as technical names


**Tests needed:** Extend dashboard/partials/tests/renderSections.test.ts with type 'Direct' → the translated label; keep the 'VLESS' fallback case


**Risk:** None


---

<a id="uc-139"></a>

## UC-139 · P3 · S11 — В Overview нет карточки 'Autotune DPI', требуемой дизайном G.1 / этапом 6.9 (известный пункт HW-проверки)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A19 layout / design conformance<br>
**Sources:** ui-css-a11y-i18n#9, autotune#11<br>
**Original title:** Overview has no 'Autotune DPI' card required by design G.1 / stage 6.9 (known HW item)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/tabs/dashboard/overviewCards.ts:14-20 'interface OverviewViewModel { warning; state; routing; recovery; event; }' and :236-250 renderOverview grid = [renderStateCard, renderRoutingCard, renderRecoveryCard, renderEventCard]; dashboard/initController.ts:172-199 never loads autotune status; grep -i autotune in tabs/dashboard/*.ts finds nothing


**Reproduction:** Open Overview


**Expected:** 5 cards per G.1 (State, Routing, Autotune DPI, Recovery, Last event)


**Actual:** 4 cards


**Impact:** The Overview does not surface autotune mode, pending recommendations or the last/next run, although the accepted design places this card between Routing and Recovery


**Root cause:** Stage 6.9 wired autotune into its own page but not into the Overview view model


**Affected files:** `fe-app-forkop/src/forkop/tabs/dashboard/overviewCards.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/overview.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`, `fe-app-forkop/src/forkop/tabs/dashboard`

**Dependencies:** The autotune status RPC being readable by read-only users (check the ACL)


**Proposed fix:** Add an 'autotune' field to OverviewViewModel filled from the existing autotune status call (mode, groups/targets count, pending recommendation, last/next run), and a read-only card with a link to the autotune page


**Tests needed:** A vitest for the overview view model covering the autotune card states (off, recommend with a pending item, auto) in admin and read-only


**Risk:** Low; one more poll, reuse the existing status call


### Also reported as autotune#11 (P3): KNOWN (hardware report): Overview has no 'Autotune DPI' card (design G.1 / 6.9)

**Evidence:** fe-app-forkop/src/forkop/tabs/dashboard/** contains no autotune reference (rg -i autotune -> none); docs/design/STAGE6_UX_DESIGN.md:420-440 (G.1 card 'Автоподбор DPI') and :1029 (6.9 'связи с Обзором')


**Proposed fix:** Add an Overview card fed by autotune_status (read ACL already allows it): mode, groups/targets count, pending or ready recommendations, last/next run, an unresolved-apply warning, and a link to the Autotune page


---

<a id="uc-140"></a>

## UC-140 · P3 · S11 — Overview, Autotune и History перерисовывают целые блоки внутри role=status на каждом опросе или тике трафика, что сбрасывает фокус клавиатуры и перегружает скринридеры

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A20 accessibility<br>
**Sources:** ui-css-a11y-i18n#11<br>
**Original title:** Overview, Autotune and History re-render whole blocks inside role=status on every poll or traffic tick, which destroys keyboard focus and floods screen readers<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** dashboard/render.ts:13 E('div', { id: 'dashboard-overview', role: 'status' }, ...). dashboard/initController.ts:1929-1936 re-renders on 'diff.bandwidthWidget || diff.systemInfoWidget || ...'; bandwidthWidget is set on every Clash /traffic WS message (:640-658, about 1/s) or every CLASH_RPC_POLL_INTERVAL_MS = 2000 (:62). renderOverviewCards (:172-199) ends with 'container.replaceChildren(view)' and skips only when '.fkp-menu[open]'. autotune/render.ts:14 'autotune-state' role=status contains the mode buttons (autotune/initController.ts:657-671) and is refreshed every REFRESH_INTERVAL_MS = 15000 via replace() (:81-85); history/render.ts:13 'history-state' role=status, 15 s. Monitoring replaces the table on every connections message (monitoring/initController.ts:1394) but offers Pause


**Reproduction:** Overview with traffic flowing: Tab to 'Все события' and wait 2 s; focus is gone


**Expected:** Focus survives data refreshes; only meaningful status changes are announced


**Actual:** Focus is lost roughly every second on the Overview; the whole live region is re-announced


**Impact:** A keyboard user who tabs to 'Мониторинг', 'Все события' or ⋯ on the Overview loses focus to <body> within about 1 s; the same happens on the autotune mode buttons every 15 s. Screen readers re-announce the whole Overview (4 cards) on every traffic tick


**Root cause:** Wholesale DOM replacement on high-frequency updates, combined with live-region roles on large containers


**Affected files:** `fe-app-forkop/src/forkop/tabs/dashboard/render.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`, `fe-app-forkop/src/forkop/tabs/autotune/render.ts`, `fe-app-forkop/src/forkop/tabs/autotune/initController.ts`, `fe-app-forkop/src/forkop/tabs/history/render.ts`

**Dependencies:** None


**Proposed fix:** Remove role=status from the large containers (keep it on a short summary line or the warning only). In renderOverviewCards, skip or defer replaceChildren while document.activeElement is inside the container (same guard as the open-menu check), or update only the traffic text node for bandwidth ticks. Apply the same focus guard in autotune/history replace()


**Tests needed:** A vitest that renderOverviewCards does not replace children while a descendant has focus; a role audit test that role=status is not set on containers holding interactive controls


**Risk:** Low; data shown while focused may be up to one refresh stale


---

<a id="uc-141"></a>

## UC-141 · P3 · S11 — Выбор узла в Nodes and groups возможен только кликом (div с обработчиком click), с клавиатуры он недоступен

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A20 accessibility<br>
**Sources:** ui-css-a11y-i18n#12<br>
**Original title:** Choosing a node in Nodes and groups is click-only (a div with a click handler), so it cannot be done from the keyboard<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/tabs/dashboard/partials/renderSections.ts:406-416 'return E(\'div\', { class: className, \'aria-busy\': ..., \'aria-disabled\': ..., click: () => canChooseOutbound && onChooseOutbound(section.sectionName, section.code, outbound.code) }, ...)'. No role, tabindex or keydown; a scan of all E() calls found this as the only non-interactive element with a click handler (the section.js:1118 span has role/tabindex/keydown). onChooseOutbound is used only here (dashboard/initController.ts:1888)


**Reproduction:** Monitoring > Узлы и группы, Tab through the page: node cards are skipped


**Expected:** Operable with Tab plus Enter or Space (design J.3 action rules)


**Actual:** The card cannot be focused or activated by keyboard


**Impact:** Admins using the keyboard or assistive technology cannot switch the active node of a Selector group, an admin action with no alternative path


**Root cause:** A div used as a button


**Affected files:** `fe-app-forkop/src/forkop/tabs/dashboard/partials/renderSections.ts`

**Dependencies:** None


**Proposed fix:** Give the card role='button', tabindex='0' when canChooseOutbound, aria-pressed for the selected node, and a keydown handler for Enter and Space calling the same handler (stopPropagation already exists on the inner buttons)


**Tests needed:** A vitest rendering a selectable outbound and asserting role/tabindex and that the Enter key calls onChooseOutbound


**Risk:** None


---

<a id="uc-142"></a>

## UC-142 · P3 · S11 — Метки форм не связаны с элементами управления (диалоги политики/целей Autotune, редактор URLTest, таблица связности)

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A20 accessibility<br>
**Sources:** ui-css-a11y-i18n#13<br>
**Original title:** Form labels are not associated with their controls (Autotune policy/target dialogs, URLTest editor, connectivity table)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** autotune/initController.ts:345-351 'function field(label, control, hint) { return [ E(\'label\', {}, label), control, ... ]; }' (a sibling label with no 'for'; controls have name but no id); dashboard/initController.ts:1315-1319 'E(\'label\', {}, label), control' (same); diagnostic/connectivityMatrix.ts:146-151 wraps the control in a label, but diagnostic/styles.ts:348 '.fkp-conn__cell-label { display: none; }' above 860px removes the label text from the accessibility tree, and the column header is role='presentation' (:296). The Type select (:211-216) has no placeholder fallback


**Reproduction:** DPI autotune > Политика with a screen reader


**Expected:** Every form control has a programmatic label


**Actual:** Inputs and selects have no accessible name


**Impact:** Screen readers announce unnamed 'edit'/'combo box' fields in the autotune policy (interval, confirmations, confidence, changes per day, cooldown, probes), the target editor, the URLTest editor and the reachability rows; clicking a label does not focus its field


**Root cause:** The labels are only visual: siblings with no 'for', or hidden with display:none


**Affected files:** `fe-app-forkop/src/forkop/tabs/autotune/initController.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/styles.ts`

**Dependencies:** None


**Proposed fix:** Wrap each control inside its <label> (E('label', {}, [text, control])) or set id/for. In connectivityMatrix use a visually-hidden class (like .fkp-visually-hidden in monitoring/styles.ts) instead of display:none at desktop


**Tests needed:** A vitest asserting that each control produced by field()/row() sits inside a label or has a matching for/id


**Risk:** Low; check the grid layout of .fkp-autotune__form after wrapping


---

<a id="uc-143"></a>

## UC-143 · P3 · S11 — Тосты не озвучиваются вспомогательными технологиями, тосты ошибок исчезают через 3 с, а тост успеха имеет низкий контраст

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A20 accessibility<br>
**Sources:** ui-css-a11y-i18n#14<br>
**Original title:** Toasts are not announced to assistive technology, error toasts disappear after 3 s, and the success toast has low contrast<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/helpers/showToast.ts:1-27 creates the '.toast-container' div without role or aria-live, with 'duration: number = 3000'. Errors use the default, e.g. updates/initController.ts:553 'showToast(message, \'error\')' and :606, :788. styles.ts:152,161 '.toast { color: #fff }' '.toast-success { background-color: #28a745; }' (white on #28a745 is about 3.1:1, below the 4.5:1 AA ratio for 14px text)


**Reproduction:** Trigger a component action failure and listen with a screen reader


**Expected:** Announced, readable toasts with enough time for errors


**Actual:** Silent toasts that disappear quickly


**Impact:** Results of component install/remove failures and other action errors vanish in 3 s and are never read by screen readers; design J.3 says 'Результат всегда виден'


**Root cause:** A minimal toast helper without accessibility semantics


**Affected files:** `fe-app-forkop/src/helpers/showToast.ts`, `fe-app-forkop/src/styles.ts`

**Dependencies:** None


**Proposed fix:** Create the container with role='status' aria-live='polite' (or a separate role='alert' region for errors); default error duration to about 8 s or until dismissed; darken the success background (e.g. #1e7e34)


**Tests needed:** A vitest for showToast asserting the container role/aria-live and the error duration


**Risk:** None


---

<a id="uc-144"></a>

## UC-144 · P3 · S11 — 29 сообщений валидации URL VLESS/VMess/Trojan захардкожены на английском и показываются в редакторе правил

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A21 localization<br>
**Sources:** ui-css-a11y-i18n#15<br>
**Original title:** 29 VLESS/VMess/Trojan URL validation messages are hardcoded in English and shown in the rule editor<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** validators/validateVlessUrl.ts:10 'message: \'Invalid VLESS URL: must start with vless://\'' (15 literals), validateTrojanUrl.ts:29-58 (7), validateVmessUrl.ts:25-63 (7). Only the 'parsing failed' / 'must start with' variants use _(). section.js:7093-7094 'const validation = main.validateProxyUrl(value); return validation.valid ? true : validation.message;' shows them as LuCI field errors. The sibling validators (Shadowsocks, Socks, Hysteria, Dns, Domain) all wrap their messages in _()


**Reproduction:** Rule editor > Where to > Connection URL = 'vless://@host:443', shows an English error


**Expected:** Localized messages


**Actual:** English validation errors in the RU UI


**Impact:** A Russian admin entering a malformed vless:// link sees 'Invalid VLESS URL: missing UUID' in English


**Root cause:** Messages missed in the validator files


**Affected files:** `fe-app-forkop/src/validators/validateVlessUrl.ts`, `fe-app-forkop/src/validators/validateTrojanUrl.ts`, `fe-app-forkop/src/validators/validateVmessUrl.ts`, `luci-app-forkop/po/ru/forkop.po`, `luci-app-forkop/po/templates/forkop.pot`

**Dependencies:** None


**Proposed fix:** Wrap all these messages in _() and regenerate the locales (yarn locales:actualize), then translate them


**Tests needed:** Add a luci_localization.sh lint that no validators/*.ts 'message:' is a bare string literal


**Risk:** None


---

<a id="uc-145"></a>

## UC-145 · P3 · S11 — Даты и время форматируются по локали браузера, а не по языку интерфейса LuCI

**Severity:** P3<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A21 localization<br>
**Sources:** ui-css-a11y-i18n#17<br>
**Original title:** Dates and times are formatted with the browser locale, not the LuCI UI language<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** ui/time.ts:16 'new Date(timestampSeconds * 1000).toLocaleString()'; autotune/initController.ts:88, history/model.ts:19, diagnostic/statusLabels.ts:67, monitoring/initController.ts:1016, diagnostic/partials/renderRunAction.ts:53 (all toLocaleString() with no locale); dashboard/partials/renderSections.ts:76 toLocaleDateString(undefined, ...). The LuCI bootstrap header sets '<html lang="{{ dispatcher.lang }}">'


**Reproduction:** Browser language en-US, LuCI language ru; open History


**Expected:** The date format follows the LuCI language


**Actual:** The date format follows navigator.language


**Impact:** With LuCI in Russian and an en-US browser, History, Autotune and Diagnostics show '9/28/2026, 2:10:00 PM' among Russian text; the reverse happens with an English UI on a Russian browser


**Root cause:** No locale argument; duplicated local helpers


**Affected files:** `fe-app-forkop/src/forkop/ui/time.ts`, `fe-app-forkop/src/forkop/tabs/autotune/initController.ts`, `fe-app-forkop/src/forkop/tabs/history/model.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/statusLabels.ts`, `fe-app-forkop/src/forkop/tabs/monitoring/initController.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/partials/renderRunAction.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/partials/renderSections.ts`

**Dependencies:** None


**Proposed fix:** Add one shared helper, formatDateTime(ts) = new Date(ts*1000).toLocaleString(document.documentElement.lang || undefined), and use it in all these places. This also removes 4 duplicate formatTime helpers


**Tests needed:** A unit test for the helper with a stubbed documentElement.lang


**Risk:** None


---

<a id="uc-146"></a>

## UC-146 · P3 · S12 — get_ui_state (глобальный опрос UI, 1 Гц) запускает shell и `readlink` для каждой записи /proc, поэтому стоимость опроса растёт с числом процессов

**Severity:** P3<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** A23 performance<br>
**Sources:** quality#0<br>
**Original title:** get_ui_state (1 Hz global UI poll) spawns a shell plus `readlink` for every /proc entry, so poll cost grows with process count<br>
**Confidence:** high<br>
**Hardware required:** yes<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/services/runtimeUiState.service.ts:7-8 `RUNTIME_UI_STATE_IDLE_POLL_INTERVAL_MS = 1000; ..._ACTIVE_POLL_INTERVAL_MS = 500`, started for every Forkop page by core.service.ts:117 `startRuntimeUiStatePolling()`. forkop/files/usr/lib/service/ui.uc:1095 `forkop_running()`, which (ui.uc:870-878) spawns `ucode state.uc forkop-stably-running`. state.uc:946-950 forkop_stably_running -> sing_box_current_owned_service_runtime (624-628) -> sing_box_runtime_provenance (603-612) -> sing_box_process_count (584-592) `for (let exe_path in fs.glob("/proc/[0-9]*/exe")) ... pid_is_sing_box(parts[2])`. pid_is_sing_box (state.uc:475-481) `command_trimmed_output_from_args([ "readlink", "/proc/" + pid + "/exe" ])` is a popen of /bin/sh. The same check done in-process: service/package.uc:71-77 `sing_box_exe_path(as_string(fs.readlink(exe_path)))`. The poll is repeated by diagnostics/health.uc:207-209 (get-ui-state again) every 10 s from dashboard/initController.ts:1949 and every 15 s from history. Measured (scratchpad audit-perf-shell-ucode/scale.sh, count_ui_state.sh, WSL x86): the ownership probe takes 140-169 ms with 77-84 processes and 363-398 ms with 277. One full `forkop get_ui_state` with only 35 processes spawned 63 wrapped programs (43 readlink, 6 ucode, 4 ubus) and took 281 ms.


**Reproduction:** wsl bash scratch/audit-perf-shell-ucode/scale.sh (start 200 extra `sleep` processes and the probe time roughly doubles). count_ui_state.sh lists every spawn for one get_ui_state.


**Expected:** Poll cost independent of the number of system processes, with no subprocess needed to read a symlink.


**Actual:** Each get_ui_state spawns about N+25 programs and 6 ucode interpreters, where N = /proc entries. Duration grows linearly with process count (~1.1 ms per process on x86).


**Impact:** Router CPU is consumed continuously while any Forkop LuCI page is visible, per open tab and per user. Estimate for MT7986 (4x A53) with 150-250 /proc entries: roughly 0.5-1.5 s of CPU per poll, i.e. a large share of one core at 1 Hz, doubled during service actions. That is exactly when a reload also needs CPU. If a poll exceeds GET_UI_STATE_RPC_TIMEOUT_MS=3000 (methods/shell/index.ts:20), the browser gives up and starts the next poll 1 s later while the old backend chain is still running: chains overlap and the UI state flaps to failure. The PID churn (~200-400 new PIDs/s) also wraps the 32768 PID space within minutes, which makes the kill -0 liveness problem in another finding far more likely.


**Root cause:** The ownership check reads /proc/<pid>/exe through a forked `readlink` for every process instead of the ucode fs.readlink builtin.


**Affected files:** `forkop/files/usr/lib/service/state.uc`, `forkop/files/usr/lib/service/ui.uc`, `forkop/files/usr/lib/diagnostics/health.uc`, `fe-app-forkop/src/forkop/services/runtimeUiState.service.ts`

**Dependencies:** None. Multiplies with the per-poll costs in the next findings.


**Proposed fix:** In state.uc, replace the three readlink popens (pid_is_sing_box:480, pid_has_current_sing_box_exe:484, pid_has_deleted_sing_box_exe:488) with `as_string(fs.readlink("/proc/" + pid + "/exe"))`, as package.uc:74 already does. The semantics are the same: the kernel link text including ' (deleted)', and null -> '' for kernel threads. Optionally apply the same change to components/action.uc:2223 (upgrade path, not hot).


**Tests needed:** New backend test: put a PATH-wrapped `readlink` that logs calls, run `state.uc sing-box-current-owned-service-runtime` with a fake sing-box process and assert zero readlink calls. The existing current/deleted exe fixture tests (sing-box-exe-kind-fixture, runtime_state_predicates.sh, singbox_stale_procd_pid.sh) must still pass.


**Risk:** Low: same data source and same return values; no behaviour change for kernel threads or deleted executables.


**Verification:** confirmed → P3

**Verification evidence:**

The code path is as described.
- The UI poll `ui.uc:1095` calls `forkop_running()` at `ui.uc:870-878`, which runs `module_success(state.uc, ["forkop-stably-running", ...])`.
- `state.uc:946-947` `forkop_stably_running` calls `sing_box_current_owned_service_runtime()` (624-628), which calls `sing_box_runtime_provenance()` (603-612), which calls `sing_box_process_count()` (584-592): `for (let exe_path in fs.glob("/proc/[0-9]*/exe")) ... pid_is_sing_box(parts[2])`.
- `pid_is_sing_box` at `state.uc:480` is `command_trimmed_output_from_args([ "readlink", "/proc/" + pid + "/exe" ])`, which goes through `command_output_from_args` (90-101) and `fs.popen` (/bin/sh -c). That is one spawn per /proc entry, including kernel threads. `pid_has_current_sing_box_exe` (484) and `pid_has_deleted_sing_box_exe` (488) use the same pattern.
- The scan runs only when procd reports a live sing-box PID, because of the short-circuit at 606. So it runs on every poll in the normal running state.
- The same check already exists in-process at `service/package.uc:71-77` `sing_box_exe_path(as_string(fs.readlink(exe_path)))`. `fs.readlink` on `/proc/<pid>/exe` is also used in production by `core/process_identity.uc:99`, `autotune/apply.uc:382` and `autotune/isolation.uc:449`, so the builtin is available on the target.
- No test stubs `readlink` through PATH. The tests use real copied binaries, e.g. `tests/runtime_state_predicates.sh:147` `cp "$(command -v sleep)" .../sing-box`. The fix therefore does not break any fixtures.
- Frontend: `runtimeUiState.service.ts:7-8` (1000/500 ms). Polls are serialized: the next setTimeout is scheduled only in `.finally` (41-57). Polling is skipped while the document is hidden (72-74). It starts from `core.service.ts` via `startRuntimeUiStatePolling()`. `health.uc:208` runs `ucode ... ui.uc get-ui-state` again. The dashboard calls it every 10 s (`initController.ts:1949`) and the history page every 15 s (`history/initController.ts:25,424`).
- Real-hardware evidence from the router validation of this exact commit (`hardware-validation-stage6-07872084/06-readonly/trace-*.json`, browser-measured):
  - single `get_ui_state` calls took 748, 783, 796, 1091, 1297 and 1371 ms;
  - single `clash_api` ucode calls took 179-387 ms;
  - `uci.get` took 45 ms.
  So one UI-state poll costs about 0.75-1.4 s on the GL-MT6000, and a visible tab runs them back to back with a 1 s gap.


**Verification reproduction:**

Scratch dir `scratch/audit-verify-readlink\`: `verify.sh`, `compare.uc`, `popen_scan.uc`, `fs_scan.uc`. It ran in WSL with a private mktemp dir and killed only the PIDs it started.

1. **Spawn count.** A PATH-wrapped logging `readlink` was used, with two fake sing-box processes (a copied `sleep`, and a second copy whose file was deleted). Running `ucode state.uc sing-box-process-count` printed `proc_exe_entries=40 sing_box_count=2 readlink_calls=38`. That is one readlink process per /proc entry; the two extra entries were the probe's own `ls`/`wc`.
2. **Same results.** `compare.uc` checked shell readlink against `as_string(fs.readlink())` on every /proc entry: `total=38 empty=27 deleted=1 mismatches=0`. The ' (deleted)' suffix and ''-on-failure behave identically.
3. **Scaling** (average of 5 runs, x86 WSL):

| Measurement | 40 entries | 240 entries (after 200 extra `sleep`) |
|---|---|---|
| `state.uc sing-box-process-count` | 91 ms | 336 ms |
| popen readlink scan alone | 43 ms | 266 ms |
| `fs.readlink` scan | 2 ms | 3 ms |

   The popen cost is about 1.1 ms per process. At 240 entries it is about 80% of the state.uc run time, and the fs.readlink version stays flat.

The router itself was not contacted, as the rules require. The share of the 0.75-1.4 s hardware poll time that the scan takes on the MT7986 is therefore an estimate, not a measurement.


**Verification notes:**

**Confirmed.** Every UI-state poll forks one shell+`readlink` per /proc entry. The cost grows linearly with process count, and the fix is trivial and behaviour-preserving.

**Severity lowered P2 -> P3.** This is a performance-only problem. It is limited to visible tabs (the poll is paused on hidden documents) and serialized within a tab. No functional failure was shown: the hardware maximum of 1.37 s is under the 3 s RPC timeout, and no safety invariant is involved. It is still a cheap, high-value fix. It would become P2 only if on-device profiling showed timeouts or real throughput loss for sing-box or nfqws while LuCI is open.

**Corrections to the impact text:**
1. "UI state flaps to failure" on timeout is wrong. `runtimeUiState.service.ts:93-96` returns `undefined` when `!response.success` and never touches the store, so a timed-out poll leaves the UI showing the last known state (stale), not a failure. The overlap part does hold: `withTimeout` (`helpers/executeShellCommand.ts`) is a client-side race, so the backend keeps running while the next poll starts 1 s later. But this needs a poll of more than 3 s, which was not observed.
2. The PID-churn rate is overstated. The poll period is poll duration + 1 s, not 1 s. On the router that is about 2 s, so roughly (N+25)/2, about 90 new PIDs/s at N≈150. The 32768 PID space then wraps in about 6 minutes, not "within minutes at 200-400/s". The amplification of the PID-reuse finding still stands.
3. "0.5-1.5 s CPU per poll" is the whole get_ui_state chain, not the readlink scan alone. On hardware the total wall time is 0.75-1.4 s including TLS/network and the other ~25 spawns (6 ucode interpreters). On x86 the scan was about 50-80% of the state.uc run time depending on process count.

**Extra callers of the same scan:**
- `lifecycle.uc` 1066/1372/1703/2069 (sing-box-process-conflict), and 1383/2086 and `wait_forkop_stable_start` (state.uc:952-963, once per second during start).
- `ui.uc` `service_action_wait_for_expected_state` (1147/1157, once per second during service actions).
- `diagnostics/runtime.uc` 1176 (get_status) and 1932/1996 (automatic latency test).

**Minimal fix (unchanged from the proposal):** in `state.uc:480/484/488`, replace `command_trimmed_output_from_args([ "readlink", "/proc/" + pid + "/exe" ])` with `as_string(fs.readlink("/proc/" + pid + "/exe"))`, the same as `package.uc:74`. Keep the digit check in `pid_is_sing_box`. No shell is involved any more, so the quoting concern goes away too. Optionally make the same change at `components/action.uc:2223` (upgrade path).

**Test to add:** a PATH-wrapped logging readlink plus a copied-sleep 'sing-box', then assert that `state.uc sing-box-process-count` returns the right count with zero readlink calls. Keep `tests/sing_box_deleted_identity.sh` and `tests/runtime_state_predicates.sh` green.

`product_decision=false`.


---

<a id="uc-147"></a>

## UC-147 · P3 · S12 — get_ui_state также на каждом опросе перечитывает базу пакетов и выгружает всю таблицу nft (со всеми элементами наборов)

**Severity:** P3<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** A23 performance<br>
**Sources:** quality#2<br>
**Original title:** get_ui_state also re-reads the package database and dumps the full nft table (with all set elements) on every poll<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/files/usr/lib/service/ui.uc:896-904 installed_sing_box_package_name(): `command_output_from_args([ "apk", "list", "--installed", "--manifest" ])`, falling back to `opkg list-installed`. It is called from capability_flags ui.uc:1038 on every current_ui_state_json (ui.uc:1094) while sing-box is installed. state.uc:914-917 `command_success_from_args([ "nft", "list", "table", "inet", nft_table ])` is only an existence test (output goes to /dev/null), yet it serializes all interval-set elements loaded by nft/apply.uc:464-465 (`nft add element ... subnets`).


**Reproduction:** count_ui_state.sh shows 1 apk + 1 opkg + 1 nft spawn per poll.


**Expected:** Package identity is re-read only when the binary or package db changes, and the table existence check does not serialize set elements.


**Actual:** One apk (or opkg) run and one full nft table dump per get_ui_state.


**Impact:** On every 1 Hz poll the installed apk database (25.12) or opkg status file (24.10) is parsed, and the whole ForkopTable is dumped. With large remote subnet lists that is thousands of set elements. Estimated tens to hundreds of ms of CPU per poll on A53 on top of the first finding; also runs inside health.uc every 10 s.


**Root cause:** The capability and runtime predicates were written for one-shot use and are reused by a 1 Hz poller.


**Affected files:** `forkop/files/usr/lib/service/ui.uc`, `forkop/files/usr/lib/service/state.uc`

**Dependencies:** Complements the readlink finding (same poll).


**Proposed fix:** Cache sing_box_package next to the existing sing-box version cache (ui.uc:941-1023), keyed by sing_box_signature() plus the mtime of /lib/apk/db/installed or /usr/lib/opkg/status. Use `nft -t list table inet <table>` (terse: omits set contents; nftables >= 0.9.1) for the existence test.


**Tests needed:** apk/opkg stubs counting calls: a second get-ui-state with an unchanged signature must not call them, and the output must stay identical (extend tests/ui_sing_box_probe.sh). nft stub asserting that `-t` is used.


**Risk:** Low. The cache must be invalidated on package changes; the signature plus db mtime covers component actions.


---

<a id="uc-148"></a>

## UC-148 · P3 · S12 — Каждый вызов clash_api порождает 3 лишних интерпретатора ucode, временный файл и повторный разбор JSON; воркер Priority вызывает его каждые 5 с на группу, круглосуточно

**Severity:** P3<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** A23 performance<br>
**Sources:** quality#3<br>
**Original title:** Every clash_api call spawns 3 extra ucode interpreters, a temp file and a JSON re-parse; the Priority worker triggers it every 5 s per group, 24/7<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** diagnostics/runtime.uc:1575-1580 clash_api_url() -> `module_output(SINGBOX_RUNTIME_UC, [ "service-listen-address" ])` (new ucode plus ubus/ip lookups). runtime.uc:1589-1591 clash_urlencode -> status.uc `url-encode` (new ucode). runtime.uc:1570-1573 clash_json_output -> status_capture stdin -> module_capture_stdin 145-162 (`mktemp`, temp file holding the whole response, new ucode status.uc, which only parses and re-prints it: status.uc:944-949). singbox/priority.uc:189-201 module_capture (mktemp + ucode runtime.uc clash-api) is used by clash_probe 224-235. Defaults: active_check_interval 5s, recovery 15s (priority.uc:145-150). Frontend HTTPS/websocket-fallback polls: monitoring/initController.ts:96 CONNECTIONS_RPC_POLL_INTERVAL_MS = 1500 and dashboard/initController.ts:62 CLASH_RPC_POLL_INTERVAL_MS = 2000 (get_connections).


**Reproduction:** wsl bash scratch/audit-perf-shell-ucode/count_latency.sh


**Expected:** One interpreter per clash_api request.


**Actual:** 4 ucode interpreters and a temp file per latency probe or connections poll.


**Impact:** One Priority probe = 4 ucode interpreter starts, 2 mktemp, 2 ubus and 1 curl (measured 92 ms on x86 WSL; estimated ~0.3-0.5 s CPU on A53). This runs with the UI closed, every 5 s per Priority group. On fallback, the recovery check every 15 s probes each higher-priority outbound. Under HTTPS LuCI the Monitoring and Dashboard pollers push the whole /connections JSON through a temp file and two extra parses every 1.5-2 s.


**Root cause:** Helpers that are pure string/JSON operations are implemented as separate status.uc/singbox runtime.uc CLI modes and invoked via fork/exec.


**Affected files:** `forkop/files/usr/lib/diagnostics/runtime.uc`, `forkop/files/usr/lib/singbox/priority.uc`

**Dependencies:** The curl-timeout finding touches the same functions; fix them together.


**Proposed fix:** In runtime.uc: do URL-encoding in-process, and replace clash_json_output's status.uc round trip with an in-process `json()` + `sprintf("%J")` inside try (same validation). Resolve the listen address once per process, for example by caching module_output or requiring the singbox runtime helper. The Priority worker can keep its single module_capture, which then costs 1 interpreter instead of 4.


**Tests needed:** Existing clash_api/priority tests must pass unchanged. Add a spawn-count assertion with a PATH-wrapped ucode for `runtime.uc clash-api get_proxy_latency` (expect 0 nested ucode).


**Risk:** Low. Output format must stay byte-compatible (sprintf %J plus newline, as status.uc write_json).


---

<a id="uc-149"></a>

## UC-149 · P3 · S12 — Запрос только для чтения `service-listen-address` пишет предупреждение в syslog при каждом вызове (каждый опрос UI и probe Priority), если задан service_listen_address

**Severity:** P3<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** A25 ucode quality<br>
**Sources:** quality#4<br>
**Original title:** The read-only `service-listen-address` query logs a syslog warning on every call, i.e. every UI poll and every Priority probe, when service_listen_address is set<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/files/usr/lib/singbox/runtime.uc:572-577 `if (configured != "") { log_message("service_listen_address is set manually; automatic listen-address detection is skipped", "warn"); ...}`. log_message 341-344 runs `logger -t forkop`. Mode 985-990 is invoked by diagnostics/runtime.uc:1576 (clash_api_url: every clash_api call and clash-api-ready, i.e. every get_ui_state poll through state.uc:931-937) and by runtime.uc:1084 and 1292. The fallback branch logs `[error] Failed to determine the listening IP address...` (runtime.uc:592) per call. The option is supported (state.uc:1666 includes it in the service signature).


**Reproduction:** wsl bash scratch/audit-perf-shell-ucode/listen_log.sh


**Expected:** Read-only queries do not write to syslog; the warning is emitted once per config generation.


**Actual:** 3 calls of `runtime.uc clash-api-ready` produce 3 `logger -t forkop [warn] service_listen_address is set manually...` invocations.


**Impact:** With the option set, syslog gets a warn line every second while any Forkop page is open, plus one per Priority probe (every 5 s per group) permanently. The logd ring buffer is overwritten within minutes and real sing-box/Forkop errors are evicted before support can collect them. In the fallback case each line is an [error], which the log watcher turns into a new error toast every 10 s (logNotificationDeduper.service.ts:72-74; lines are unique through timestamps).


**Root cause:** A diagnostic message intended for configuration generation is inside a helper that the read-only query mode reuses.


**Affected files:** `forkop/files/usr/lib/singbox/runtime.uc`

**Dependencies:** None


**Proposed fix:** Log only at the config-generation call site (runtime.uc:868). Give service_listen_address_value a `quiet` flag (or split it) and use the quiet variant in the `service-listen-address` mode at runtime.uc:985-990.


**Tests needed:** logger stub test: `singbox/runtime.uc service-listen-address` with the option set must not call logger; config generation still logs once.


**Risk:** None.


---

<a id="uc-150"></a>

## UC-150 · CLEANUP · S1 — Список снимков раскрывает сессиям только для чтения несолёный SHA-256 всего конфига с секретами, при этом UI его не использует

**Severity:** CLEANUP<br>
**Stage:** S1 (Граница read-only, ACL и секреты)<br>
**Area:** snapshot metadata / RO exposure<br>
**Sources:** snapshots#15<br>
**Original title:** Snapshot list exposes an unsalted SHA-256 of the whole secret-bearing config to read-only sessions, and the UI does not use it<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** snapshots.uc:146 metadata `config_hash: snapshot.config_hash`, returned by `config_snapshot_list` (ACL read line 21). The frontend never reads config_hash (only types.ts:79).


**Expected:** Only the metadata the UI needs.


**Actual:** The full config hash is visible to read-only sessions.


**Impact:** Low. It is a hash, not a secret, but it gives read-only users an offline oracle for guessing a low-entropy secret when the rest of the file is known. Invariant 2 hygiene.


**Root cause:** Internal integrity metadata reused as API output.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `fe-app-forkop/src/forkop/types.ts`

**Proposed fix:** Drop config_hash from list output (keep it in the file for integrity checks), or return a short truncated prefix.


**Tests needed:** history_journal.sh / config_snapshots.sh list shape assertion.


---

<a id="uc-151"></a>

## UC-151 · CLEANUP · S2 — Секции urltest_override остаются сиротами при удалении правила и не валидируются

**Severity:** CLEANUP<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#16<br>
**Original title:** urltest_override sections are orphaned on rule deletion and not validated<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** config/urltest_override.uc:55-68 creates `config urltest_override` with rule/tag and commits UCI directly from the Dashboard (fe-app-forkop/src/forkop/tabs/dashboard/initController.ts:1333-1346), outside the Settings pre-apply snapshot flow. configureSectionSection handleRemove (section.js:7852-7859) does not remove overrides of the deleted rule. validator.uc ignores this section type.


**Expected:** Overrides live and die with their rule.


**Actual:** Orphaned sections remain.


**Impact:** A later rule reusing the name inherits stale URLTest overrides. Config changes from the dashboard get no pre-apply snapshot.


**Root cause:** Override storage was added separately from the rule lifecycle.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `forkop/files/usr/lib/config/urltest_override.uc`, `forkop/files/usr/lib/config/validator.uc`

**Proposed fix:** Clean up urltest_override sections for rule=<id> in handleRemove, validate them in the validator, and route the dashboard save through the snapshot-before-apply path.


**Tests needed:** Rule deletion removes overrides.


**Risk:** Low.


---

<a id="uc-152"></a>

## UC-152 · CLEANUP · S2 — Доступность провайдеров хранится в трёх местах; копия в shell никогда не обновляется

**Severity:** CLEANUP<br>
**Stage:** S2 (Сохранение конфигурации в LuCI (round-trip правил))<br>
**Area:** frontend/state stores<br>
**Sources:** frontend-arch#16<br>
**Original title:** Provider availability kept in three stores; the shell copy is never refreshed<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** shell.js:14-22,62-84 uiCapabilities (loaded once; `if (uiCapabilities.loaded) return` at 159-161), store.diagnosticsSystemInfo.*_installed (uiState.service.ts:95-125, refreshed every poll), section.js:449-529 actionProvidersAvailabilityState (event + store subscription). settings.js receives shell.uiCapabilities (page/settings.js:209-219), and nothing listens for FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT in shell.js.


**Expected:** One store.


**Actual:** Three copies with different refresh rules.


**Impact:** After installing or removing Zapret in Components, the Settings download/DNS-detour choices still use the page-load availability until reload. Together with the choice-filtering finding, this widens the window for silent rewrites.


**Root cause:** The shell was added in 78877c17 alongside the existing store and event.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/shell.js`, `luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js`, `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`

**Proposed fix:** Make store.diagnosticsSystemInfo the single source; derive shell.uiCapabilities from it via store.subscribe, or pass a getter to settings.js.


**Tests needed:** After a store update of zapret_installed, the settings choices reflect it without reload.


---

<a id="uc-153"></a>

## UC-153 · CLEANUP · S0 — ShellCheck в CI пропускает два скрипта роутера в forkop/files/usr и падает только на ошибках

**Severity:** CLEANUP<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** A24 shell quality<br>
**Sources:** quality#8<br>
**Original title:** ShellCheck CI misses the two router-side shell scripts under forkop/files/usr and only fails on errors<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** D-5

**Evidence:** .github/workflows/shellcheck.yml `paths:` lists build.sh, install.sh, ops/**/*.sh, forkop/files/etc/init.d/**, uci-defaults and tests. It omits forkop/files/usr/lib/full-uninstall.sh and forkop/files/usr/share/forkop/mirror-migration.sh, so a change touching only them does not trigger the workflow. The job runs `shellcheck --severity=error`.


**Reproduction:** Inspect the workflow path filters.


**Expected:** Every shipped shell script is checked on change.


**Actual:** Edits to these scripts alone are not shellchecked.


**Impact:** The destructive full-uninstall script and the package-feed rewriting script can regress without static checking.


**Root cause:** Path filter not updated when the scripts were added.


**Affected files:** `.github/workflows/shellcheck.yml`

**Dependencies:** None


**Proposed fix:** Add 'forkop/files/usr/**/*.sh' to both push and pull_request path filters. Optionally raise the level to --severity=warning with the existing disables (both scripts are clean at warning level except the intentional fd 1000 SC3023).


**Tests needed:** None (CI config).


**Risk:** None


---

<a id="uc-154"></a>

## UC-154 · CLEANUP · S0 — Многие проверки грепают исходный текст production-кода; негативные grep и извлечение функций через sed/awk становятся пустыми или хрупкими после безобидного рефакторинга

**Severity:** CLEANUP<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** implementation-detail tests<br>
**Sources:** tests#9<br>
**Original title:** Many assertions grep production source text; negative greps and sed/awk function extraction become vacuous or brittle after harmless refactors<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** Roughly 405 grep assertions target production source files (top: runtime_state_owner.sh 41, installer_owner.sh 36, components_updater_job.sh 33, list_update_reload_policy.sh 25, initd_state.sh 25). latency_reload_serialization.sh:14-60 is entirely source-string greps (e.g. 'grep -Fq 'completed % batch_size == 0' "$DIAGNOSTICS_UC"', 'if grep -Fq 'attempt < 20' ...; then fail'). Negative forms hide grep's exit 2 for a missing file: 'if grep -n -E '...' "$BYEDPI_RUNTIME_UC" >/dev/null 2>&1; then fail' (byedpi_runtime_owner.sh:37 and ~50 more). An empty extracted range makes a check pass: ui_runtime_job.sh:66 'if sed -n '/^function ensure_dir(/,/^}/p' "$UI_UC" | grep -Fq 'mkdir", "-p'; then fail'; runtime_state_predicates.sh:142; subscription_cache_state.sh:72. Function-range extraction for probes: dpi_restore_guard_verify.sh:41 and dpi_transition_guard.sh:28 (awk between nft_dpi_transition_guard and nft_rebuild_runtime_from_uci), dpi_reload_faults.sh:71 and :128-131 (line-order check).


**Expected:** Behavioural assertions; any remaining source checks fail loudly when their anchor disappears.


**Actual:** About 405 source-text assertions, some of which can become vacuous.


**Impact:** Renaming a function or moving a file silently turns a 'must not' check into a pass (all targets exist today, verified by script). Equivalent rewrites of correct code break positive greps. Concurrency properties such as latency/reload serialization are asserted by spelling, not by behaviour.


**Root cause:** 'Ownership' contracts were enforced by grepping text instead of observable behaviour.


**Affected files:** `tests/latency_reload_serialization.sh`, `tests/ui_runtime_job.sh`, `tests/runtime_state_predicates.sh`, `tests/subscription_cache_state.sh`, `tests/byedpi_runtime_owner.sh`, `tests/dpi_restore_guard_verify.sh`, `tests/dpi_transition_guard.sh`, `tests/dpi_reload_faults.sh`

**Proposed fix:** Minimal hardening: before each negative source grep, assert '[ -f "$FILE" ] || fail' and that the extracted range is non-empty ('[ -n "$src" ] || fail "anchor moved"'). Longer term, replace string checks with behavioural fixtures where the module exposes a fixture mode (as automatic_latency_pending.sh already does).


**Tests needed:** A meta-check (tests/helpers) that every negative-grep target exists and every sed/awk range is non-empty.


---

<a id="uc-155"></a>

## UC-155 · CLEANUP · S0 — core/uci.uc учитывает общую переменную окружения UCI_STATE как тестовый бэкдор; dns_apply.sh ставит в PATH заглушку 'uci', которую production никогда не вызывает

**Severity:** CLEANUP<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** test hooks in production / dead stub<br>
**Sources:** tests#10<br>
**Original title:** core/uci.uc honours a generic UCI_STATE env var as a test backdoor; dns_apply.sh installs a PATH 'uci' stub that production never calls<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/files/usr/lib/core/uci.uc:8 'const UCI_STATE_FILE = getenv("FORKOP_UCI_STATE_FILE") || getenv("UCI_STATE") || "";'. When it is set, every get/set/commit goes to a flat file instead of /etc/config (fixture_enabled(), :261). tests/dns_apply.sh:27-118 writes bin/uci, yet dns/apply.uc uses core.uci (the test itself asserts at :137 that apply.uc must not shell out to uci). The stub is used only by the test's own uci_get helper (:145-148), a second implementation of the state_* file format.


**Expected:** Only a Forkop-namespaced hook; one implementation of the fixture format.


**Actual:** UCI_STATE switches production storage; the stub duplicates the fixture format.


**Impact:** A generic, non-namespaced env var switches production UCI access to a flat file. If it is ever inherited (a user shell, a procd environment, another tool's convention), Forkop would read and write the wrong store (low likelihood). The dead stub can drift from core/uci.uc state_* semantics (add_list/del_list), and the test's own reads would then disagree with production.


**Root cause:** The test harness convention leaked into the production module.


**Affected files:** `forkop/files/usr/lib/core/uci.uc`, `tests/dns_apply.sh`

**Proposed fix:** Accept only FORKOP_UCI_STATE_FILE (update the 18 tests that export UCI_STATE). In dns_apply.sh, read the state file directly or through 'ucode -e require("core.uci").get(...)' and drop the PATH uci stub.


**Tests needed:** grep guard that production modules read only FORKOP_-prefixed test hooks.


---

<a id="uc-156"></a>

## UC-156 · CLEANUP · S0 — A28: добавить дешёвые property/перестановочные тесты для резолвера маршрутов, гистерезиса, диапазонов mark/mask, выбора, нормализации конфига и маппинга статусов

**Severity:** CLEANUP<br>
**Stage:** S0 (Тестовая инфраструктура и достоверность тестов)<br>
**Area:** A28 property tests<br>
**Sources:** tests#11<br>
**Original title:** A28: add cheap property/permutation tests for the route resolver, hysteresis, mark/mask ranges, selection, config normalization and status mapping<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** Current coverage is example-based. routing_resolve.sh + route_owner_regression.sh: 29 hand-written cases (helpers/route_owner/cases.js). autotune_hysteresis.sh:28-37: 8 fixed sequences. mark_ranges.sh:48-55: only FakeIP/outbound vs Tailscale and zapret ranges vs FakeIP/outbound/Tailscale. It does not cover Zapret vs Zapret2 ranges, the desync marks 0x40000000/0x20000000, the probe mark 0x48000000, or the DPI-guard classifier 'meta mark & 0xff000000 == 0x01000000/0x02000000' (nft/apply.uc:1672-1673, 1683-1684). autotune_select.sh #11: permutations of one fixed measurement set. The status set emitted by autotune/apply.uc (not_applicable, direct_not_applicable, ready, busy, verified, observed, stale, no_change_required, rolled_back, needs_attention) is not cross-checked against the UI mappings.


**Expected:** Seeded property tests pin the invariants across generated inputs.


**Actual:** Example-based coverage only; properties are implicit.


**Impact:** Metamorphic properties (first-match, order independence, fail-closed defaults, bit-range disjointness) protect safety invariants 5, 7, 8 and 11 across inputs the examples do not cover. The domain-parser differential already found a real defect (see the IDN finding).


**Root cause:** Tests were written per scenario during staged development.


**Affected files:** `tests/routing_resolve.sh`, `tests/helpers/route_owner/run_resolver.js`, `tests/autotune_hysteresis.sh`, `tests/mark_ranges.sh`, `tests/autotune_select.sh`, `tests/config_migration.sh`, `fe-app-forkop/src/forkop/tabs/autotune/tests/model.test.ts`

**Proposed fix:** No new frameworks: node generates seeded cases, ucode evaluates them in one process, node asserts. (1) Resolver: for random rule lists, appending rules after the first decided owner, or inserting rules with a non-tproxy inbound or network=udp before it, never changes the result. Inserting an undecidable matcher (rule_set/domain_regex/source_ip_cidr) before the owner yields status 'undecidable', never a different decided owner. domain_suffix case and leading-dot variants follow the documented semantics. (2) Hysteresis model check over random observation streams: count <= required; ready implies >= required confident same-candidate recommendations since the last reset; a fingerprint change implies count <= 1; two consecutive inconclusive runs imply pending == null; autoapply.decide().apply implies result.candidate == group.pending.candidate. (3) Marks: enumerate constants.uc shell-env plus the isolation/apply marks; check pairwise bit and range disjointness; every zapret/zapret2 route mark is classified by the guard mask as its provider and no FakeIP/outbound/desync/probe mark is. (4) Selection: seeded random measurement sets -> permutation invariance; adding a failed candidate never changes the selection; improving a candidate's success count never makes it lose to a candidate it beat. (5) Config normalization: migrate(migrate(x)) == migrate(x) and unknown/hidden options preserved for every fixture (invariant 16); snapshots.uc/resolve.uc UCI parsers vs the real uci CLI (differential; needs uci in CI). (6) Status mapping: every apply.uc status/phase string goes through applyOutcomeView/applyResultView; only 'applied' may give tone 'success'; needs_attention and unknown give error+attention.


**Tests needed:** As listed in proposed_fix; each fits in one test file with a fixed seed (e.g. 500 generated cases) and runs in under 2 s.


---

<a id="uc-157"></a>

## UC-157 · CLEANUP · S3 — Очистка: мёртвый путь SIGHUP, конфликтующий префикс имён временных файлов, пять разошедшихся хелперов блокировок

**Severity:** CLEANUP<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** A6/A7 cleanup<br>
**Sources:** process-locks#13<br>
**Original title:** Cleanup: dead SIGHUP path, colliding temp-name prefix, five divergent lock helpers<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** service/state.uc:491-499,2062-2063 hup_sing_box_runtime (exe check without ticks) has no callers. autotune/manager.uc:458-462 remove_stale_apply_dirs deletes every /tmp/forkop-autotune-apply.*, a prefix also used for apply.uc:101 sha_text temp files, so a CLI-run apply.uc concurrent with a manager run can lose its hash file. Lock helpers are duplicated with different semantics in state.uc:299-354, initd.uc:186-240, ui.uc:815-853, components/action.uc:258-286 and full-uninstall.sh:148-172.


**Reproduction:** n/a


**Expected:** A single lock implementation and no dead signalling paths.


**Actual:** Dead code and duplicated helpers.


**Impact:** Maintenance risk. The duplicated helpers already diverged (ui.uc has the empty-pid grace, the others do not).


**Root cause:** Incremental evolution.


**Affected files:** `forkop/files/usr/lib/service/state.uc`, `forkop/files/usr/lib/autotune/manager.uc`, `forkop/files/usr/lib/autotune/apply.uc`

**Dependencies:** The lock TOCTOU finding.


**Proposed fix:** Delete hup-sing-box-runtime. Give apply.uc temp files a distinct prefix. Consolidate the lock helpers into one module (see the lock TOCTOU finding).


**Tests needed:** None beyond the lock-helper unit tests.


**Risk:** Low.


---

<a id="uc-158"></a>

## UC-158 · CLEANUP · S3 — Дублирующиеся парсеры /proc/<pid>/stat: два используют index(") ") (первое совпадение), а process_identity — rindex; протестирован только основной парсер

**Severity:** CLEANUP<br>
**Stage:** S3 (Блокировки, идентичность процессов, сериализация lifecycle)<br>
**Area:** duplicate helpers / process identity (invariant 14)<br>
**Sources:** tests#8<br>
**Original title:** Duplicate /proc/<pid>/stat parsers: two use index(") ") (first match) while process_identity uses rindex; only the core parser is tested<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** core/process_identity.uc:20 and :33 'let marker = rindex(stat, ") ");' (correct for a comm containing ') '). service/state.uc:503 'let marker = index(stat, ") ");' (process_start_ticks, used by sing-box provenance at :605-633, :743, :885) and components/action.uc:2213 upgrade_sing_box_ticks() do the same with index. tests/process_identity.sh exercises only the core module.


**Expected:** One stat parser that splits at the last ') '.


**Actual:** Three parsers, two of them split at the first ') '.


**Impact:** A process whose comm contains ') ' (settable via prctl or the executable name) shifts the fields in the two index() parsers, so the start ticks are misread. All uses compare ticks for equality, so the misread value mismatches and the process is treated as 'different' (fail-safe). There is no known unsafe outcome, but PID-reuse logic is implemented three times with different parsing.


**Root cause:** The helper was copied instead of imported.


**Affected files:** `forkop/files/usr/lib/service/state.uc`, `forkop/files/usr/lib/components/action.uc`, `forkop/files/usr/lib/core/process_identity.uc`

**Proposed fix:** Make service/state.uc and components/action.uc call process_identity.start_ticks() (or a shared parse_stat(text) exported by core/process_identity.uc).


**Tests needed:** Property test of the shared parse_stat(text) over synthetic stat lines with comm values '(a) b)', 'x y', ') ', '(( ', 16-char names: the start-ticks field and ppid must equal what the constructed line encodes.


---

<a id="uc-159"></a>

## UC-159 · CLEANUP · S5 — Идентичные перезаписи, устаревшие временные файлы и путь стирания crontab

**Severity:** CLEANUP<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** A9 flash wear / hygiene<br>
**Sources:** persistence#12<br>
**Original title:** Identical rewrites, stale temp files and a crontab erase path<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** singbox/runtime.uc:462-467 install_managed_service_script() runs on every configure_service (each start, lifecycle.uc:922) when the compressed variant is set, rewriting identical /etc/init.d/sing-box. components/updates.uc:1637-1650 write_crontab_text runs `crontab tmp` unconditionally on every start (lifecycle.uc:809-820) and stop (:822-829). updates.uc:1661 and :1677 `fs.readfile(CRONTAB_FILE) || ""` turns a read error into an empty crontab and writes it back (manager.uc:185-186 refuses in that case). ruleset_cache.uc:472-474 mark_binary_valid(current) rewrites an identical .validated file in /etc/forkop/ruleset-cache on each unchanged refresh. Temp files never cleaned after a crash: snapshots.uc:51 ('/etc/config/forkop.<s>.<ns>.tmp', '/etc/forkop/config-snapshots/*.tmp'), apply.uc:213, state.uc:70, health.uc:106, runtime.uc:428 ('/etc/init.d/sing-box.forkop.<pid>'). generator.uc:81-82 and subscription/cache.uc:514-516 do not unlink the temp file when writefile fails. full-uninstall.sh:47-50,61-62 leaves the status JSON on flash in /www if the device reboots within 300 s.


**Expected:** Write only when changed; clean own temp files; never erase foreign cron lines.


**Actual:** Identical rewrites; leftover temp files; crontab erase on read failure.


**Impact:** Small but avoidable flash writes per start/stop and refresh, leftover files on the overlay, and a narrow path that erases the user's cron jobs on a read error.


**Root cause:** Missing compare-before-write and temp-file hygiene.


**Affected files:** `forkop/files/usr/lib/singbox/runtime.uc`, `forkop/files/usr/lib/components/updates.uc`, `forkop/files/usr/lib/singbox/ruleset_cache.uc`, `forkop/files/usr/lib/config/snapshots.uc`, `forkop/files/usr/lib/autotune/apply.uc`, `forkop/files/usr/lib/autotune/state.uc`, `forkop/files/usr/lib/diagnostics/health.uc`, `forkop/files/usr/lib/singbox/generator.uc`, `forkop/files/usr/lib/subscription/cache.uc`, `forkop/files/usr/lib/full-uninstall.sh`

**Proposed fix:** Compare before writing (init script text, crontab text vs current, .validated signature). Use `readfile == null && stat != null -> refuse` in updates.uc as manager.uc does. On startup (e.g. snapshots/state init), glob-remove own '*.tmp'/'*.tmp.<pid>' files older than a few minutes. Unlink the temp on writefile failure.


**Tests needed:** Start twice with an unchanged config: /etc/init.d/sing-box and crontab mtimes unchanged; an unreadable crontab stub must make refresh fail without writing.


---

<a id="uc-160"></a>

## UC-160 · CLEANUP · S5 — Runtime-флаг shutdown_correctly хранится в постоянном конфиге и перезаписывается при каждом start/stop

**Severity:** CLEANUP<br>
**Stage:** S5 (Персистентность, crash safety, износ flash)<br>
**Area:** uci-global<br>
**Sources:** uci-global#15<br>
**Original title:** Runtime flag shutdown_correctly is stored in the persistent config and rewritten on every start/stop<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** lifecycle.uc:539, 1016 and 1476 `config_set(CONFIG_NAME + ".settings.shutdown_correctly", ...)` followed by config_commit. It needs exclusions in lifecycle.uc:217-228 external_config_fingerprint and autotune/apply.uc:113-120. It is still part of the snapshot hash and content (snapshots.uc:188-205), so a restore re-installs the flag value from snapshot time. Consumers: dns/apply.uc:233 and 255, initd.uc:401-409.


**Expected:** UCI holds user configuration only.


**Actual:** The same runtime fact lives in UCI and influences config identity.


**Impact:** Flash writes and a /etc/config/forkop commit on every start/stop (which also commits any CLI-staged /tmp/.uci changes). Snapshot hash and dedupe are coupled to runtime state, and fingerprint exclusions have to be maintained in several places.


**Root cause:** Inherited from podkop.


**Affected files:** `forkop/files/usr/lib/service/lifecycle.uc`, `forkop/files/usr/lib/dns/apply.uc`, `forkop/files/usr/lib/service/initd.uc`, `forkop/files/usr/lib/autotune/apply.uc`, `forkop/files/etc/config/forkop`

**Proposed fix:** Move the flag to a state file (e.g. /etc/forkop/state/shutdown_correctly written atomically). Keep reading the UCI value once for compatibility and delete it via a named migration.


**Tests needed:** The existing lifecycle/dnsmasq tests must keep passing with the new storage, plus a migration test.


**Risk:** Medium (touches crash-recovery logic). Do it later, carefully.


---

<a id="uc-161"></a>

## UC-161 · CLEANUP · S6 — forkop-torrserver-direct использует трёхзначный START=100 и однозначный STOP=9, которые rc.d сортирует не в тот конец

**Severity:** CLEANUP<br>
**Stage:** S6 (Пакеты: установка, обновление, удаление)<br>
**Area:** init script ordering<br>
**Sources:** packaging#12<br>
**Original title:** forkop-torrserver-direct uses three-digit START=100 and single-digit STOP=9, which rc.d sorts to the wrong end<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/files/etc/init.d/forkop-torrserver-direct:3-4 `START=100` `STOP=9`. rcS iterates `/etc/rc.d/S*` in byte order. Scratch check (scratch/audit-a26/rcorder.sh): start order `S00sysfixtime, S100forkop-torrserver-direct, S10boot, ...`; stop order `..., K99umount, K9forkop-torrserver-direct`.


**Reproduction:** `/etc/init.d/forkop-torrserver-direct enable; ls /etc/rc.d | sort`


**Expected:** Runs after Forkop at boot and early at shutdown, as the values intend.


**Actual:** Runs first at boot and last at shutdown.


**Impact:** The service starts before S10boot (before kmodloader/uci-defaults) instead of after Forkop, and stops after umount. The worker's 60 s polling hides this, so there is no functional failure today.


**Root cause:** OpenWrt START/STOP are compared as strings.


**Affected files:** `forkop/files/etc/init.d/forkop-torrserver-direct`

**Dependencies:** None


**Proposed fix:** Use two-digit values, e.g. START=99 (or 98) and STOP=10.


**Tests needed:** Static check: START/STOP in all init scripts match ^[0-9]{2}$.


**Risk:** None


---

<a id="uc-162"></a>

## UC-162 · CLEANUP · S8 — Start повторно заполняет наборы nft вживую (неатомарно) сразу после атомарного коммита кандидата

**Severity:** CLEANUP<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** lifecycle start / singbox init-config<br>
**Sources:** nft#11<br>
**Original title:** Start re-populates nft sets live (non-atomic) right after the atomic candidate commit<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** lifecycle.uc:941-948 populates sets inside the candidate and commits. lifecycle.uc:950 singbox_init_config passes nft_populate_enabled (default 1, lifecycle.uc:64, 131). singbox/runtime.uc:903-918 then runs nft-populate-runtime-sets-from-uci again with FORKOP_NFT_BATCH_FILE now empty (lifecycle_env at :307 reads the reset variable), issuing live `nft add element` commands.


**Expected:** A single population inside the candidate.


**Actual:** A second, non-transactional pass adds the same elements again.


**Impact:** Longer start and a needless failure point. Currently idempotent because the same inputs are added to auto-merge sets.


**Root cause:** The populate hook predates the candidate batch.


**Affected files:** `forkop/files/usr/lib/service/lifecycle.uc`, `forkop/files/usr/lib/singbox/runtime.uc`

**Proposed fix:** Pass populate '0' to init-config from start_impl (the reload path already uses 0).


**Tests needed:** service_start test: no live nft add element after candidate commit.


---

<a id="uc-163"></a>

## UC-163 · CLEANUP · S8 — Проверка наличия ip rule сопоставляет 'lookup <table>' и 'fwmark X/X' на разных строках и зависит от имени в rt_tables

**Severity:** CLEANUP<br>
**Stage:** S8 (Маршрутизация и nft dataplane)<br>
**Area:** nft/apply.uc tproxy rule detection<br>
**Sources:** nft#12<br>
**Original title:** ip-rule presence check matches 'lookup <table>' and 'fwmark X/X' on different lines and depends on the rt_tables name<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** nft/apply.uc:1291-1312 has_tproxy_marking_rule_text sets has_lookup and has_fwmark independently across all lines of `ip rule list`. lifecycle.uc:1091-1094 and state.uc:913-916 rely on it. Detection fails when the rt_tables entry is gone (`lookup 105`).


**Expected:** Per-rule match on priority 105, fwmark/mask and table id, preferably via `ip -j rule`.


**Actual:** False positive when one rule has `lookup forkop` and another has the fwmark. False negative when rt_tables lacks the name.


**Impact:** Low; it matters in edge cases such as stale rules after a refused stop.


**Root cause:** Text parsing across lines.


**Affected files:** `forkop/files/usr/lib/nft/apply.uc`

**Proposed fix:** Parse `ip -j rule` and match a single object with priority 105, fwmark 0x4000000/0x4000000 and table forkop or 105.


**Tests needed:** nft_apply.sh cases for split lines and for numeric table 105.


---

<a id="uc-164"></a>

## UC-164 · CLEANUP · S11 — Общая константа BREAKPOINTS не используется; страницы используют 5 разных наборов брейкпоинтов

**Severity:** CLEANUP<br>
**Stage:** S11 (Frontend: состояние, UX, i18n, a11y, адаптивность)<br>
**Area:** A19 responsive CSS<br>
**Sources:** ui-css-a11y-i18n#18<br>
**Original title:** The shared BREAKPOINTS constant is unused; pages use 5 different breakpoint sets<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** forkop/ui/styles.ts:1-11 'export const BREAKPOINTS = { medium: 1279, narrow: 899, phone: 599 }' (re-exported in ui/index.ts:7, never imported). Media queries in use: updates/styles.ts:33,39 (1100/760), dashboard/styles.ts:93,99,283,712 (900/560/700/560), diagnostic/styles.ts:354,397 (860/560), monitoring/styles.ts:673,762 (900/520), autotune/history 599


**Reproduction:** Settings > Components at 768


**Expected:** One breakpoint scale


**Actual:** Inconsistent breakpoints; an unused constant


**Impact:** At 768 the Components grid stays 2-column because of the 760 cutoff, which contributes to the button overflow. The 3 JS columns placed into a 2-column grid leave a large empty gap before Packet Steering (components-768.png). Design J.8/P2-11 asked for unified breakpoints


**Root cause:** The Stage 6.0 foundation added the constant but did not migrate the existing pages


**Affected files:** `fe-app-forkop/src/forkop/tabs/updates/styles.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/styles.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/styles.ts`, `fe-app-forkop/src/forkop/tabs/monitoring/styles.ts`, `fe-app-forkop/src/forkop/ui/styles.ts`

**Dependencies:** None


**Proposed fix:** Align the page media queries to 1279/899/599; for updates use 1279 → 2 columns and 899 → 1 column, or render the cards in a single auto-fit grid instead of 3 fixed JS columns


**Tests needed:** A style test that every @media max-width in *styles.ts is one of 1279/899/599


**Risk:** Low; recheck each page at 1440/1024/768


---

<a id="uc-165"></a>

## UC-165 · CLEANUP · S12 — Дублирующиеся production-хелперы классификации DNS/FakeIP в manager.uc и apply.uc

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** A11<br>
**Sources:** autotune#12<br>
**Original title:** Duplicated production DNS/FakeIP classification helpers in manager.uc and apply.uc<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** manager.uc:130-139 production_dns (dig +short, valid_ipv4, is_fakeip all-answers) duplicates apply.uc:288-294; words/normalize duplicated in catalog.uc:50-53, apply.uc:107-111, dpi_strategy.uc:13; tcp443_profile exists only in apply.uc:161-172 (needed by groups; see the not-applicable finding)


**Expected:** One implementation


**Actual:** Two copies


**Impact:** The group classification and the plan could diverge if one copy changes (FakeIP decision, answer parsing)


**Root cause:** Incremental stages


**Affected files:** `forkop/files/usr/lib/autotune/manager.uc`, `forkop/files/usr/lib/autotune/apply.uc`

**Dependencies:** None


**Proposed fix:** Move production_dns and tcp443_profile to a shared autotune module (e.g. routing/resolve.uc or a new autotune/production.uc) and use it in both


**Tests needed:** Existing groups/apply tests


**Risk:** Low


---

<a id="uc-166"></a>

## UC-166 · CLEANUP · S12 — Мёртвые фронтенд-обёртки и дублирующиеся клиенты валидатора стратегий

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** FE ↔ CLI wrappers<br>
**Sources:** cli-contract#13, frontend-arch#15<br>
**Original title:** Dead frontend wrappers and duplicate strategy-validator clients<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** methods/shell/index.ts:245-254 getOutboundMetadata/getSubscriptionMetadata, :346-347 checkSingBoxLogs, :352-355 getUiCapabilities have no callers (grep). Strategy validation is implemented twice: methods validateDpiStrategy (:486-497, used by dpiPlayground.ts), and three hand copies in section.js:5132-5163, 5577-5608, 5989-6020 with their own caches. The section.js copies parse an empty stdout (for example a CLI loader failure during self-update, rc 1) as `{valid:false,message:''}` and cache it for the session (section.js:5137-5150).


**Expected:** One validator client; transient failures are not cached.


**Actual:** Unused wrappers; failures cached as invalid.


**Impact:** Maintenance drift. A transient backend failure marks a strategy invalid with an empty message until the page reloads.


**Root cause:** Legacy LuCI views predate the TS methods layer.


**Affected files:** `fe-app-forkop/src/forkop/methods/shell/index.ts`, `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json`, `fe-app-forkop/src/forkop/services/readonlyCommandGuard.ts`

**Proposed fix:** Remove the unused FE wrappers (keep the CLI commands, which are public API). Have section.js treat `code != 0 && !stdout` as 'validation unavailable' (not cached) instead of invalid.


**Tests needed:** None beyond lint; optionally a section.js validator unit test.


**Risk:** None.


### Also reported as frontend-arch#15 (CLEANUP): Dead and duplicate RPC wrappers

**Evidence:** ForkopShellMethods getOutboundMetadata (index.ts:245), getSubscriptionMetadata (250), getClashApiProxyLatencies (288), checkSingBoxLogs (346), componentActionStatus (733) have no callers in src, views or tests. validate_*_strategy_json is wrapped twice with different failure semantics: section.js:5112-5163 (direct fs.exec + permanent cache) and index.ts:486-497 validateDpiStrategy (playground). get_ui_state is called both via getUiState and a raw callBaseMethod in isComponentActionStillRunning (index.ts:143-163).


**Proposed fix:** Delete the unused wrappers (and the RO ACL entry if no other consumer exists). Route section.js strategy validation through one shared wrapper with the corrected caching.


---

<a id="uc-167"></a>

## UC-167 · CLEANUP · S12 — Единый слой async/status используется только в тестах; контроллеры сами реализуют обработку loading/timeout/stale/forbidden

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** frontend/architecture<br>
**Sources:** frontend-arch#14<br>
**Original title:** Unified async/status layer is test-only; controllers roll their own loading/timeout/stale/forbidden handling<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** No production imports of createAsyncLoader/isStale (ui/asyncState.ts), renderAsyncState/renderForbiddenState/timeoutMessage (ui/states.ts), or describeStatus/toSemantic/DOMAIN_MAP (ui/status.ts:145-206); only ui/tests/*.test.ts use them (rg over src excluding tests).


**Expected:** A single used implementation.


**Actual:** Dead abstractions.


**Impact:** 'One lifecycle for every asynchronous block' is documented but not applied. Timeout, stale and forbidden states have no consistent UI (see the stale and failure findings), and the DOMAIN_MAP can drift from real usage unnoticed.


**Root cause:** The Stage 6 status layer was introduced but only partially wired.


**Affected files:** `fe-app-forkop/src/forkop/ui/asyncState.ts`, `fe-app-forkop/src/forkop/ui/states.ts`, `fe-app-forkop/src/forkop/ui/status.ts`

**Proposed fix:** Either adopt createAsyncLoader/renderAsyncState in history/autotune/overview loaders (they already follow the same phases), or delete the unused exports and their tests.


**Tests needed:** None beyond the adopting controllers.


---

<a id="uc-168"></a>

## UC-168 · CLEANUP · S12 — providers/rules.uc — модуль-сирота с продублированной логикой mark/queue/rule-index, закреплённый тестами вместо рабочих копий

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** dead code / duplicate module<br>
**Sources:** map#5, map#6, nft#10<br>
**Original title:** providers/rules.uc — модуль-сирота с продублированной логикой mark/queue/rule-index, закреплённый тестами вместо рабочих копий<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** Во всём дереве providers/rules.uc упоминают только tests/helpers_owner.sh:11,68,97 (`fail "providers/rules.uc must own UCI rule counting"`, `fail "providers/rules.uc mark math changed"`) и tests/provider_rules.sh. Нет ни require, ни пути в usr/lib, usr/bin, build.sh, install.sh (скрипт cycles.cjs: `NO PRODUCTION REFERENCE: providers/rules.uc`). Рабочие копии: providers/nfqueue/runtime.uc:148-190 (enabled_sections, parse_number, route_mark_value, route_mark_hex, queue_number) и nft/apply.uc:1004-1011 nft_provider_mark_hex, :1013-1045.


**Reproduction:** rg -n 'providers/rules|providers\.rules' по всему дереву.


**Expected:** Тесты проверяют рабочую логику mark/queue.


**Actual:** Модуль без вызывающих в рабочем коде, при этом тесты требуют его существования.


**Impact:** Иллюзия покрытия: «mark math» и подсчёт правил тестируются на мёртвом модуле, а две рабочие копии (разные: nft/apply отвергает index<1 и неразбираемую базу, nfqueue/runtime — нет) могут разойтись незаметно. Сейчас неверного поведения нет.


**Root cause:** Остаток после миграции shell → ucode; вызывающие перешли на встроенные копии, а модуль и тесты «владельца» остались.


**Affected files:** `forkop/files/usr/lib/providers/rules.uc`, `tests/provider_rules.sh`, `tests/helpers_owner.sh`, `forkop/files/usr/lib/providers/nfqueue/runtime.uc`, `forkop/files/usr/lib/nft/apply.uc`, `tests/zapret_runtime_owner.sh`, `forkop/files/usr/lib/singbox/constants.uc`

**Proposed fix:** Удалить providers/rules.uc и перенаправить provider_rules.sh / helpers_owner.sh на рабочие функции (либо сделать так, чтобы nfqueue/runtime.uc и nft/apply.uc делали require одной общей библиотеки).


**Tests needed:** Юнит-тесты для nfqueue/runtime.uc route_mark_hex/queue_number и nft/apply.uc nft_provider_mark_hex на одних и тех же входных данных.


### Also reported as map#6 (CLEANUP): Мёртвый режим create-nft-rules в providers/nfqueue/runtime.uc — неатомарный дубликат правил вывода провайдера из nft/apply.uc

**Evidence:** providers/nfqueue/runtime.uc:671-688 create_nft_rules: `command_success_from_args([ "nft", "add", "rule", "inet", NFT_TABLE_NAME, "mangle_output", ... "queue", "num", queue, "bypass" ])` (ошибки игнорируются, записывает прямо в рабочую таблицу); отдаётся на :712. Единственная ссылка — tests/zapret_runtime_owner.sh:97 (`'mode == "create-nft-rules"'` должен существовать). Рабочий эквивалент — nft/apply.uc:1013-1045 nft_create_provider_output_rules_from_sections (батч кандидата, проверка ошибок), вызывается на :1579-1580.


**Proposed fix:** Удалить режим create-nft-rules и create_nft_rules() из nfqueue/runtime.uc, убрать его из списка режимов в zapret_runtime_owner.sh.


### Also reported as nft#10 (CLEANUP): Dead duplicate provider nft, mark and queue code; mark constants defined in four places

**Evidence:** providers/nfqueue/runtime.uc:671-687 `create-nft-rules` has no production caller (rg). If invoked, it would append desync returns and queue rules after the fakeip marking rules and ignore failures. It is pinned by tests/zapret_runtime_owner.sh:57, 97. providers/rules.uc (count, index, mark and queue math) has no production caller, only tests/helpers_owner.sh and provider_rules.sh. Marks are defined in core/constants.uc:62-63, 137-143, 160-165 (env-overridable), singbox/constants.uc:31, 41-42 (hardcoded), nft/apply.uc:1672-1673, 1683-1684 (DPI guard hardcoded 0x01000000/0x02000000, mask 0xff000000) and torrserver/direct.uc:8.


**Proposed fix:** Delete create-nft-rules and providers/rules.uc (and their pinning tests). Have singbox/constants.uc and the DPI guard import the values from core/constants.uc.


---

<a id="uc-169"></a>

## UC-169 · CLEANUP · S12 — Устаревшая команда `forkop uninstall` — третий путь удаления без вызывающих; удаляет файлы пакета в обход менеджера пакетов

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** duplicate architecture / uninstall<br>
**Sources:** map#8, packaging#11<br>
**Original title:** Устаревшая команда `forkop uninstall` — третий путь удаления без вызывающих; удаляет файлы пакета в обход менеджера пакетов<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:** forkop/files/usr/bin/forkop:62 help `uninstall Remove Forkop files installed outside opkg/apk`, :154 command entry; service/lifecycle.uc:2113-2152 uninstall(): `rm -rf /usr/lib/forkop`, remove_file(SERVICE_INIT), remove_file(BIN_PATH), удаляет через менеджер пакетов только luci-i18n-forkop-ru/luci-app-forkop. rg: вызывающих нет ни в UI, ни в install.sh, ни в тестах. Параллельные пути: full_uninstall (components/uninstall.uc → full-uninstall.sh), prerm пакета (service/package.uc). `uninstall` не входит в список блокировки полного удаления в bin/forkop:260-263.


**Reproduction:** rg -n "'uninstall'|\"uninstall\"" → только таблица диспетчера и lifecycle.


**Expected:** Одна поддерживаемая процедура удаления (full_uninstall) и хуки пакета.


**Actual:** Три независимые процедуры удаления, одна из них — сирота.


**Impact:** На системе, где Forkop установлен пакетом, `forkop uninstall` удаляет файлы пакета, при этом пакет forkop остаётся зарегистрированным: база пакетов становится несогласованной, фиды зеркала не восстанавливаются, torrserver-direct не трогается. Есть риск расхождения из-за трёх реализаций удаления.


**Root cause:** Команда унаследована от установщиков эпохи podkop; после появления full_uninstall её не убрали.


**Affected files:** `forkop/files/usr/bin/forkop`, `forkop/files/usr/lib/service/lifecycle.uc`

**Proposed fix:** Перенаправить `uninstall` на `full_uninstall` или удалить команду (решение за продуктом, т.к. это видимая пользователю команда CLI).


**Tests needed:** Если команда остаётся: тест, что `forkop uninstall` отказывает, когда forkop зарегистрирован как пакет.


### Also reported as packaging#11 (CLEANUP): Legacy `forkop uninstall` deletes package-owned files without checking package ownership and misses newer paths

**Evidence:** lifecycle.uc:2113-2150 uninstall(): `rm -rf /usr/lib/forkop`, removes SERVICE_INIT, BIN_PATH, menu/ACL json, and only removes the luci packages via the package manager (:2126-2127), with no check whether the `forkop` package itself is installed. It does not handle /etc/init.d/forkop-torrserver-direct or /usr/share/forkop. Exposed as CLI `forkop uninstall` (bin/forkop:62,154) and via the admin write ACL exec on /usr/bin/forkop; not used by the UI.


**Proposed fix:** Refuse when `apk info -e forkop` / opkg-installed forkop succeeds (point to full_uninstall), or delete the command in favour of full_uninstall.


---

<a id="uc-170"></a>

## UC-170 · CLEANUP · S12 — Глобальные наборы захвата (forkop_subnets/6, forkop_ports, forkop_ip_ports/6) никогда не заполняются; 22 ссылающихся на них правила мертвы

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** nft/apply.uc runtime base<br>
**Sources:** nft#9<br>
**Original title:** Global capture sets (forkop_subnets/6, forkop_ports, forkop_ip_ports/6) are never populated; 22 rules referencing them are dead<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** All population paths write to per-section sets: nft_populate_runtime_set_for_section (nft/apply.uc:1893-1924), nft_add_subnet_file_for_section (:1926-1937), json rulesets (:1962-1978), community and discord (:2006-2040). The common_set parameters are threaded through but unused. Scratch common_sets.sh shows only `forkop_rule_*` sets receive elements. Rules at nft/apply.uc:896-907 (mangle) and :959-968 (mangle_output) match these always-empty sets. tests/nft_apply.sh:240-267 pins them.


**Expected:** Only live rules.


**Actual:** 12 prerouting and 10 output rules evaluated per packet that can never match. Diagnostics report these sets.


**Impact:** Complexity, per-packet cost and misleading diagnostics. It also hides that sing-box egress is safe only because these sets are empty.


**Root cause:** Leftover from before per-section priority sets.


**Affected files:** `forkop/files/usr/lib/nft/apply.uc`, `forkop/files/usr/lib/service/lifecycle.uc`, `forkop/files/usr/lib/components/updates.uc`, `forkop/files/usr/lib/diagnostics/runtime.uc`, `tests/nft_apply.sh`

**Proposed fix:** Remove the global set rules and sets, keeping the fakeip-range rules, and update tests/nft_apply.sh and diagnostics. The bypass-first contract is unaffected.


**Tests needed:** nft_apply.sh expectations updated; real-nft candidate check.


---

<a id="uc-171"></a>

## UC-171 · CLEANUP · S12 — Долгоживущие воркеры каждую секунду форкают `sleep 1` через shell вместо встроенного sleep() в ucode

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** A25 ucode quality<br>
**Sources:** quality#7<br>
**Original title:** Long-lived workers fork `sleep 1` through a shell every second instead of using the ucode sleep() builtin<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** singbox/dns_failover.uc:315 `command_success_from_args([ "sleep", "1" ]);` inside worker while(true). singbox/priority.uc:421 `system("sleep 1");` inside worker while(true). ucode builtin sleep(ms) exists (verified: sleep(200) blocks 200 ms).


**Reproduction:** Code inspection.


**Expected:** In-process sleep.


**Actual:** sh + sleep forked every second per worker.


**Impact:** About 2 process spawns per second per worker, 24/7 (sh + sleep): background CPU and PID churn with no benefit.


**Root cause:** Shell-era idiom carried into ucode.


**Affected files:** `forkop/files/usr/lib/singbox/dns_failover.uc`, `forkop/files/usr/lib/singbox/priority.uc`

**Dependencies:** None


**Proposed fix:** Use `sleep(1000)` in these two worker loops. Leave the state.uc/ui.uc transition loops unchanged, because tests stub `sleep` via PATH there (tests/singbox_stale_procd_pid.sh:34, remote_list_bootstrap_dns.sh:54).


**Tests needed:** Existing priority/dns_failover tests. Confirm none stub `sleep` for these workers.


**Risk:** Minimal. SIGTERM from stop_runtime still interrupts the ucode sleep (default signal action terminates the process).


---

<a id="uc-172"></a>

## UC-172 · CLEANUP · S12 — Дублирующиеся хелперы с разной семантикой: разбор 'enabled' секций, разбиение портов и слов

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** routing<br>
**Sources:** routing#9<br>
**Original title:** Duplicate helpers with divergent semantics: section 'enabled' parsing, and port and word splitting<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:**

resolve.uc:90-93 enabled(): case-insensitive, and "" means disabled.
core/common.uc:117-122 bool_option (generator and nft): case-sensitive.
Monitoring initController.ts:234: `section.enabled !== '0'`.
autotune/policy.uc:109 has its own copy.
resolve.uc:115-124 rule_scope counts with words() (whitespace), while the combined domain text is comma/space separated (rule_config.text_list_values 'comma-space').
generator.uc:2906-2940 duplicates config/rule.uc port normalization (the source of the single-port range bug).


**Reproduction:** Code reading


**Expected:** One parser.


**Actual:** Four different parsers for 'enabled'.


**Impact:** A hand-edited `option enabled 'ON'` is disabled for the generator and nft but enabled for the resolver and Monitoring. The resolver's zapret index then shifts; the tag cross-check fails closed, so autotune reports 'dpi_identity_unproven' and Monitoring lists the rule. Plan scope counts are wrong for comma-separated domain text (plan JSON only).


**Root cause:** The resolver was extracted with self-contained helpers so it would stay pure.


**Affected files:** `forkop/files/usr/lib/routing/resolve.uc`, `forkop/files/usr/lib/autotune/policy.uc`, `fe-app-forkop/src/forkop/tabs/monitoring/initController.ts`, `forkop/files/usr/lib/singbox/generator.uc`

**Dependencies:** None


**Proposed fix:** Use one shared enabled/bool reader (core.common) in resolve.uc, policy.uc and the frontend. Count scope with rule_config.text_list_values. Use rule_config port normalization in the generator.


**Tests needed:** Resolver case with enabled 'ON' or 'false' matching the generator's reading.


**Risk:** Low


---

<a id="uc-173"></a>

## UC-173 · CLEANUP · S12 — Мёртвый тип события 'recovery' никогда не записывается

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** history journal<br>
**Sources:** snapshots#14<br>
**Original title:** Dead event kind 'recovery' is never recorded<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** health.uc:17 EVENT_KINDS includes 'recovery', and model.ts:28-33 and :108 handle it, but no caller records it (only health.uc record kind values: start, reload, restore, autotune_*, snapshot_*). docs/design/STAGE6_UX_DESIGN.md:111 notes 'Kind recovery не пишет никто'.


**Expected:** No unused event kinds.


**Actual:** The kind is accepted but never produced.


**Impact:** Dead branches in the backend and UI. Readers may assume boot or package recovery is journalled.


**Root cause:** The event kind was planned but never wired.


**Affected files:** `forkop/files/usr/lib/diagnostics/health.uc`, `fe-app-forkop/src/forkop/tabs/history/model.ts`

**Proposed fix:** Either remove 'recovery' from EVENT_KINDS and the UI mappings, or start recording it where the package-set recovery completes.


**Tests needed:** history model test update.


---

<a id="uc-174"></a>

## UC-174 · CLEANUP · S12 — Фронтенд-тесты статусов не могут упасть, а тестируемый DOMAIN_MAP из ui/status.ts (toSemantic/describeStatus) не используется ни одной страницей

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** frontend tests<br>
**Sources:** tests#7, ui-cleanup-deadcode#3<br>
**Original title:** Frontend status tests cannot fail, and the tested ui/status.ts DOMAIN_MAP (toSemantic/describeStatus) is used by no page<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** fe-app-forkop/src/forkop/ui/tests/status.test.ts:131-135 'expect(statusLabel(status)).toBeTruthy(); expect(statusTone(status)).toBeTruthy();' while ui/status.ts:150-171 has 'default: return _('Unknown')' and statusTone has 'default: return 'neutral''. tabs/diagnostic/tests/localization.test.ts:18-19 'expect(domainListLabel(key)).toBeTruthy()' while constants.ts domainListLabel falls back to the key. toSemantic/describeStatus (ui/status.ts:145,198) have no caller outside tests (rg); the autotune page uses tabs/autotune/model.ts applyOutcomeView/applyResultView. DOMAIN_MAP maps unknown raw values to 'unknown' with a neutral tone, whereas model.ts defaults to error/attention.


**Expected:** The tests fail when a status or list loses its specific label.


**Actual:** The assertions pass for any implementation that returns a non-empty fallback.


**Impact:** Removing a label case (e.g. needs_attention) still passes, because the label becomes 'Unknown'. status.test.ts:9-96 mirrors DOMAIN_MAP verbatim, so it gives confidence about a mapping no page uses. If a page later adopts describeStatus, an unrecognised backend status would show as neutral instead of failing closed (invariant 5).


**Root cause:** toBeTruthy was used against functions that always return a truthy fallback.


**Affected files:** `fe-app-forkop/src/forkop/ui/status.ts`, `fe-app-forkop/src/forkop/ui/tests/status.test.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/tests/localization.test.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/statusLabels.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/partials/renderCheckSection.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/tests/observability.test.ts`, `fe-app-forkop/src/forkop/tabs/history/model.ts`, `fe-app-forkop/src/forkop/tabs/autotune/initController.ts`

**Proposed fix:** Assert statusLabel(s) !== statusLabel('unknown') for every known status and that labels are distinct; assert domainListLabel(key) !== key for translated built-in lists. Either delete toSemantic/describeStatus/DOMAIN_MAP, or wire them in with a fail-closed default.


**Tests needed:** Distinct-label property over the SemanticStatus union and DOMAIN_LIST_OPTIONS keys.


### Also reported as ui-cleanup-deadcode#3 (CLEANUP): Two status vocabularies: ui/status.ts 'single' domain map is used only by tests while Diagnostics keeps its own dictionary (labels already diverge)

**Evidence:** ui/status.ts:1-4 "One status vocabulary for every Forkop page"; DOMAIN_MAP (:45), toSemantic (:145), describeStatus (:198), CONTEXT_LABELS have no non-test caller (TS findReferences: describeStatus internal=0 tests=5; rg 'toSemantic|describeStatus' src -> only status.ts + ui/tests/status.test.ts). Diagnostics uses its own tabs/diagnostic/statusLabels.ts:17 checkStatus + own StatusTone type (:5), rendered via renderCheckSection.ts:15,73,106,166. statusLabels.ts:36 eventStatus, :51 healthStatus, :66 formatTime have no production caller (only tabs/diagnostic/tests/observability.test.ts:88). Drift today: check 'unsupported' -> statusLabels 'Not available for checking'/tone neutral vs status.ts DOMAIN_MAP.check.unsupported -> 'Not supported'/tone muted. Design docs/design/STAGE6_UX_DESIGN.md:902-903 requires status.ts to be the only module and statusLabels.ts checkStatus/eventStatus/healthStatus to be removed. formatTime is also triplicated (autotune/initController.ts:87, history/model.ts:18, statusLabels.ts:66).


**Proposed fix:** Make checkStatus delegate to describeStatus('check', state) (add CONTEXT_LABELS.check.unsupported if the longer wording is wanted) and use ui/status StatusTone; delete eventStatus/healthStatus/statusLabels.formatTime and their test cases; move the shared formatTime into ui/time.ts.


---

<a id="uc-175"></a>

## UC-175 · CLEANUP · S12 — Мёртвые опции и код в цепочке rule/outbound

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** uci-rules<br>
**Sources:** uci-rules#15<br>
**Original title:** Dead options and code in the rule/outbound chain<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** section.js:4216 writeOptionalDurationOption has no callers. *_interval_disabled flags are read only by the podkop migration (migration.uc:545-562). connections.uc:520-548 subscription_auto_user_agent/auto_hwid/hide_urltest_group_outbounds/hide_detour_outbounds are hard-coded `return true` (b14f3a33), yet migration.uc:688-699 still writes auto_user_agent/user_agent/auto_hwid/hide_*, and etc/config/forkop documents them. validator.uc:1308-1316 validate_subscription_request_profile is unreachable. priority_level: UI writes country/server_name/regex (section.js:2216-2218), while connections.uc:854-866 prefers include_countries/include_outbounds/include_regex, which nothing writes.


**Expected:** Single canonical representation.


**Actual:** Dead or duplicate paths exist.


**Impact:** Misleading config surface: user_agent/hwid have no effect, and alias pairs could shadow UI edits if both are set.


**Root cause:** Features were retired without cleanup.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`, `forkop/files/usr/lib/config/connections.uc`, `forkop/files/usr/lib/config/migration.uc`, `forkop/files/usr/lib/config/validator.uc`, `forkop/files/etc/config/forkop`

**Proposed fix:** Remove the dead helper and the unreachable validator branch, stop writing the dead options in migration and the example config, and pick one canonical name for priority level includes.


**Tests needed:** Existing migration tests adjusted.


**Risk:** Low.


---

<a id="uc-176"></a>

## UC-176 · CLEANUP · S12 — Неиспользуемые экспорты фронтенда, базовые модули, обёртки, иконки и поля store

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** frontend/dead-code<br>
**Sources:** ui-cleanup-deadcode#4<br>
**Original title:** Unused frontend exports, foundation modules, wrappers, icons and store fields<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:** TS LanguageService findReferences (non-test refs outside declaring file = 0): ui/asyncState.ts:55 createAsyncLoader and :112 isStale (tests only); ui/states.ts:93 renderAsyncState (tests only), :59 renderForbiddenState (no refs); ui/styles.ts:7 BREAKPOINTS (only re-exported ui/index.ts:7); diagnostic/partials/renderCheckSection.ts:63 checkDetailsOpen (no refs); diagnostic/helpers/maskDiagnostics.ts:241 maskSupportReportText (tests only; last caller removed in b05e8a54 when support report became backend-raw); helpers/isCopyableProxyLink.ts:4 (tests only; stale vi.mock in forkop/methods/custom/tests/getDashboardSections.test.ts:27); icons renderCircleStopIcon24, renderCirclePlayIcon24, renderBookOpenTextIcon24, renderLinkIcon24 (rg -> only definition + icons/index.ts:12,13,18,20); validators/bulkValidate.ts:3 exported by main.ts:16 but no view uses main.bulkValidate (it ships in main.js:286); main.ts:22 showToast and :28 confirmAction exported but no view uses them; ForkopShellMethods members with zero callers: checkSingBoxLogs (shell/index.ts:346), componentActionStatus (:733), getClashApiProxyLatencies (:288), getOutboundMetadata (:245), getSubscriptionMetadata (:250) - these ship in the bundle; store trafficTotalWidget (store.service.ts:152) written at dashboard/initController.ts:690,728,773 but never read after the Overview rewrite; tabService.all (core.service.ts:65) never read.


**Reproduction:** node scratch/audit-deadcode/unused-exports.cjs (TS findReferences) or rg -n '<symbol>' fe-app-forkop/src luci-app-forkop/htdocs --glob '!main.js'


**Expected:** Only reachable code and tests for reachable code.


**Actual:** ~15 exported symbols/members with no production caller.


**Impact:** Maintenance noise and false test coverage (asyncState/states/status tests pass for code no page runs); dead wrappers keep stale ACL grants alive; every WS traffic message writes an unread store slice.


**Root cause:** Stage 6 page rewrites replaced callers without removing providers; 6.0 foundation primitives were not adopted.


**Affected files:** `fe-app-forkop/src/forkop/ui/asyncState.ts`, `fe-app-forkop/src/forkop/ui/states.ts`, `fe-app-forkop/src/forkop/ui/styles.ts`, `fe-app-forkop/src/forkop/ui/index.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/partials/renderCheckSection.ts`, `fe-app-forkop/src/forkop/tabs/diagnostic/helpers/maskDiagnostics.ts`, `fe-app-forkop/src/helpers/isCopyableProxyLink.ts`, `fe-app-forkop/src/helpers/index.ts`, `fe-app-forkop/src/icons/index.ts`, `fe-app-forkop/src/validators/bulkValidate.ts`, `fe-app-forkop/src/main.ts`, `fe-app-forkop/src/forkop/methods/shell/index.ts`, `fe-app-forkop/src/forkop/services/store.service.ts`, `fe-app-forkop/src/forkop/services/core.service.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/initController.ts`, `fe-app-forkop/src/forkop/methods/custom/tests/getDashboardSections.test.ts`

**Dependencies:** Finding on RO ACL grants (dead wrappers).


**Proposed fix:** Delete checkDetailsOpen, maskSupportReportText(+test), isCopyableProxyLink(+test,+stale mock), the 4 icons, bulkValidate and the unused main.ts exports, the 5 dead ForkopShellMethods members, trafficTotalWidget and tabService.all. For createAsyncLoader/isStale/renderAsyncState/renderForbiddenState/BREAKPOINTS either adopt them in pages (design J.5/J.8) or delete them - design/product choice.


**Tests needed:** Remove/adjust the corresponding unit tests; run vitest + tsc + build.


**Risk:** Very low (most symbols are already tree-shaken).


---

<a id="uc-177"></a>

## UC-177 · CLEANUP · S12 — Мёртвые CSS-селекторы, оставшиеся после переписывания страниц

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** frontend/css<br>
**Sources:** ui-cleanup-deadcode#5, ui-css-a11y-i18n#19<br>
**Original title:** Dead CSS selectors left by page rewrites<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** Class-usage scan of all styles.ts/view <style> blocks vs rendered class strings (literal + template-prefix): never rendered: diagnostic/styles.ts:61,65 .fkp-diag-section-title (last use removed b66df934), :146-155 .fkp-diag-facts and :156-162 .fkp-diag-events (removed 698e6229); dashboard/styles.ts:91 .fkp-overview__section-title and :38 .fkp_dashboard-page__content (removed f02d8a0a; see Nodes finding), :671-692 .fkp_dashboard-page__urltest-details__copy-button/__copy-placeholder (removed 3aefd832); monitoring/styles.ts:418 .fkp_monitoring-page__cell-main, :424 __cell-secondary, :442 __network (removed f02d8a0a). Proof: rg -n 'fkp-diag-facts|fkp-diag-events|fkp-diag-section-title|fkp-overview__section-title|fkp_dashboard-page__content|urltest-details__copy|cell-main|cell-secondary|monitoring-page__network' fe-app-forkop/src luci-app-forkop/htdocs --glob '!main.js' -> only the style definitions.


**Reproduction:** node scratch/audit-deadcode/dead-css.cjs


**Expected:** Only selectors for rendered classes.


**Actual:** 11 class selectors never rendered.


**Impact:** Dead rules ship in the injected global stylesheet and mislead future CSS fixes (e.g. the stopped-state rule).


**Root cause:** Rewrites (25903e9d, f02d8a0a, b66df934, 698e6229, 3aefd832) changed markup without pruning CSS.


**Affected files:** `fe-app-forkop/src/forkop/tabs/diagnostic/styles.ts`, `fe-app-forkop/src/forkop/tabs/dashboard/styles.ts`, `fe-app-forkop/src/forkop/tabs/monitoring/styles.ts`, `fe-app-forkop/src/styles.ts`, `luci-app-forkop/htdocs/luci-static/resources/view/forkop/page/settings.js`

**Dependencies:** None


**Proposed fix:** Delete the listed rule blocks (including the .fkp-diag-facts entry in the 399 media query).


**Tests needed:** None (visual smoke at 1440/1024/768).


**Risk:** None.


### Also reported as ui-css-a11y-i18n#19 (CLEANUP): Stale or dead global CSS selectors for the Settings map

**Evidence:** fe-app-forkop/src/styles.ts:24-26 '#cbi-${FORKOP_CBI_PREFIX}-settings > h3 { display: none; }', but page/settings.js:207-215 now renders the tabs as TypedSections of types settings_dns/settings_network/settings_lists/settings_service (ids cbi-forkop-settings_dns, ...), so the rule matches nothing and the DNS tab shows a duplicate 'DNS' h3 (settings-1440-1.png) while Rules hides its h3. styles.ts:34-36 '#cbi-forkop-section > .cbi-section-remove { margin-bottom: -32px; }': the rules section is a GridSection, which never renders .cbi-section-remove (LuCI form.js renders it only in TypedSection/NamedSection)


**Proposed fix:** Set tab.hidetitle = true in settingsTab() (page/settings.js), or delete the stale selector; remove the .cbi-section-remove rule


---

<a id="uc-178"></a>

## UC-178 · CLEANUP · S12 — Шесть недостижимых функций в написанном вручную section.js

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** luci-views/dead-code<br>
**Sources:** ui-cleanup-deadcode#6<br>
**Original title:** Six unreachable functions in the hand-written section.js<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** Babel top-level reachability over luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js: currentSectionGroupChoices (:1676, 1 ref = definition; callers removed d9fe7e96) which alone uses currentSectionGroupValues (:1640) and sectionGroupDisplayName (:1661); subscriptionUserAgentChoices (:2090, removed b14f3a33); writeOptionalDurationOption (:4216) and getDuplicateTextListErrors (:4292) (callers removed f088cd2c). grep -c per name in section.js = 1 for the four roots.


**Reproduction:** node scratch/audit-deadcode/views_dead.cjs


**Expected:** No dead code in views.


**Actual:** Unreachable functions retained.


**Impact:** ~150 lines of dead UCI-writing/validation code in the largest hand-written view; writeOptionalDurationOption still encodes a '<key>_disabled' convention that nothing writes any more, which misleads config round-trip reviews.


**Root cause:** Callers removed in earlier refactors without removing helpers.


**Affected files:** `luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js`

**Dependencies:** None


**Proposed fix:** Delete the six functions (check getDuplicateValueText remains referenced).


**Tests needed:** luci view syntax/lint; settings smoke.


**Risk:** None.


---

<a id="uc-179"></a>

## UC-179 · CLEANUP · S12 — ~1000 строк CLI-режимов внутренних модулей-хелперов без вызывающих в production; тесты проверяют эти мёртвые копии вместо рабочего кода

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** backend/dead-code<br>
**Sources:** ui-cleanup-deadcode#7<br>
**Original title:** ~1000 lines of internal helper-module CLI modes with no production caller; tests exercise these dead copies instead of the live code<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** Mode reachability (dispatch branch roots = modes invoked as a string literal by any production .uc/bin/init/install file): core/helpers.uc 28/32 modes dead, 34/49 functions reachable only from them (~350 lines) - production uses only version-at-least (components/action.uc:520, diagnostics/runtime.uc:1509) and url-get-host (runtime.uc:1247); diagnostics/status.uc 26/67 modes dead (~300 lines: dns-check-json, nft-check-json, sing-box-check-json, fakeip-check-json, system-info-json, service-status-json, ui-capabilities-json, server-* , firewall-port-*, strip-leading-v, ...); components/updater.uc 25/57 modes dead (~340 lines incl. updates-job-refresh-plan, updates-set-running-job-pid, updates-mark-stale-job-state, updates-finish-job-state, release-by-tag). Tests pin the dead copies: tests/components_updater_job.sh:470-486 test updater.uc 'updates-job-refresh-plan' while production uses components/updates.uc:1811 subscription_job_refresh_plan and :2376 refresh_component_running_job_state; tests/core_helpers.sh:35-58 test the helpers.uc tag allocator (outbound-tag/inbound-tag) while production allocates via singbox/constants.uc tag() (covered separately by tests/outbound_tags.sh); tests/diagnostics_status.sh tests dead status.uc modes service-status-json/server-listen-requires-firewall. helpers.uc also carries its own valid_ipv4/valid_ipv4_cidr/url_*/text_list_values/sing_box_version_is_extended/default_reserved_runtime_tags duplicating core/ip.uc, core/url.uc, config/rule.uc, singbox/runtime.uc and singbox/constants.uc RESERVED_TAGS (different reserved set).


**Reproduction:** python scratch/audit-deadcode/mode_reach.py diagnostics/status.uc core/helpers.uc components/updater.uc


**Expected:** Helper modules expose only modes something calls; tests exercise production paths.


**Actual:** Dead helper modes kept and tested.


**Impact:** False test assurance: a regression in the live job-staleness or tag logic is not caught by the tests that look like they cover it; reviewers can edit the wrong copy. Large surface for no runtime value.


**Root cause:** Leftover shell-to-ucode bridge modes from the shell era; production moved logic into owning modules (updates.uc, singbox/constants.uc, status owners) without pruning.


**Affected files:** `forkop/files/usr/lib/core/helpers.uc`, `forkop/files/usr/lib/diagnostics/status.uc`, `forkop/files/usr/lib/components/updater.uc`, `tests/components_updater_job.sh`, `tests/core_helpers.sh`, `tests/diagnostics_status.sh`

**Dependencies:** None


**Proposed fix:** Delete dead modes and the functions only they reach; re-point tests/components_updater_job.sh and tests/core_helpers.sh to the production functions (updates.uc job refresh, singbox/constants.uc tag via require) and drop status.uc dead-mode tests.


**Tests needed:** After pruning: tests targeting updates.uc job refresh (pid reuse/grace) and singbox/constants.uc tag reservation.


**Risk:** Low; internal modules, not the public /usr/bin/forkop CLI. Confirm no external script (ops/, docs) invokes these modes (none found by grep).


---

<a id="uc-180"></a>

## UC-180 · CLEANUP · S12 — Мёртвые дублирующиеся цепочки функций в diagnostics/runtime.uc и config/validator.uc, плюс отдельные мёртвые хелперы

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** backend/dead-code<br>
**Sources:** ui-cleanup-deadcode#8<br>
**Original title:** Dead duplicate function chains in diagnostics/runtime.uc and config/validator.uc, plus single dead helpers<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** Per-file transitive reachability (roots = top-level code + export object): diagnostics/runtime.uc 16 unreachable functions (~290 lines, :343-630): firewall_show_data, valid_public_ipv4/ipv6/ip, push_unique, network_status_ip_addresses, get_wan_ip_addresses (:478), server_inbound_tag (:541, sole prod caller of helpers.uc server-inbound-tag), server_required_inbound_proto, server_runtime_type_for_protocol, server_listen_requires_firewall, firewall_required_protocols_open, server_required_port_conflict_owners, server_required_ports_listening, resolve_public_host_ips, public_host_flags - live copies are in diagnostics/status.uc (:563, :721, :765, :812). config/validator.uc:1731-1793 sing_box_extended_marker_set, get_sing_box_version, sing_box_version_is_extended, sing_box_is_extended, sing_box_output_has_build_tag, sing_box_supports_tailscale unreachable (owner is singbox/runtime.uc:259-334; tests/helpers_owner.sh:88 only checks *.sh so it misses this ucode copy). Singles (grep -w shows definition only): diagnostics/status.uc:66 parse_json_object, providers/byedpi/runtime.uc:74 command_exists, service/lifecycle.uc:213 command_start_without_procd_lock, singbox/generator.uc:1233 selector_group_for_outbound and :3216 section_by_name, singbox/runtime.uc:632 first_nonblank_line, nft/apply.uc:245 valid_ipv4, :249 valid_ipv4_cidr, :1451 community_service_has_subnet_list, components/updates.uc:759 recover_persistent_list_cache_transaction and :763 recover_runtime_list_generation_transaction (live path calls recover_list_generation_transaction directly at :771,:779), config/domain.uc:365 valid_suffix (exported :375, no importer).


**Reproduction:** python scratch/audit-deadcode/uc_reach.py


**Expected:** No unreachable functions; one owner per concern.


**Actual:** ~40 unreachable top-level ucode functions.


**Impact:** Two divergent-looking copies of server-exposure and sing-box-variant logic; a fix applied to the dead copy has no effect.


**Root cause:** Logic migrated to owner modules (status.uc, singbox/runtime.uc) without deleting originals.


**Affected files:** `forkop/files/usr/lib/diagnostics/runtime.uc`, `forkop/files/usr/lib/config/validator.uc`, `forkop/files/usr/lib/diagnostics/status.uc`, `forkop/files/usr/lib/providers/byedpi/runtime.uc`, `forkop/files/usr/lib/service/lifecycle.uc`, `forkop/files/usr/lib/singbox/generator.uc`, `forkop/files/usr/lib/singbox/runtime.uc`, `forkop/files/usr/lib/nft/apply.uc`, `forkop/files/usr/lib/components/updates.uc`, `forkop/files/usr/lib/config/domain.uc`, `tests/helpers_owner.sh`

**Dependencies:** None


**Proposed fix:** Delete the unreachable functions; keep status.uc and singbox/runtime.uc as owners; extend helpers_owner.sh to forbid sing-box variant helpers outside singbox/runtime.uc in *.uc too.


**Tests needed:** Existing backend suite; owner-guard test extension.


**Risk:** None.


---

<a id="uc-181"></a>

## UC-181 · CLEANUP · S12 — Пустой restore_list_nft_snapshot, никогда не задаваемый list_nft_snapshot_file и мёртвая fatal-ветка, закреплённые grep-тестом, заявляющим откат nft

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** backend/list-update<br>
**Sources:** ui-cleanup-deadcode#9<br>
**Original title:** No-op restore_list_nft_snapshot, never-set list_nft_snapshot_file and a dead fatal branch, pinned by a grep test that claims nft rollback<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** components/updates.uc:3654-3658 "function restore_list_nft_snapshot() { // ... rollback is only disposal of the uncommitted batch. return true; }" - never called (grep -rn restore_list_nft_snapshot forkop -> definition only); :105 "let list_nft_snapshot_file = \"\";" is only ever reset (:3666-3667), never assigned a path; finish_list_nft_snapshot (:3660-3669) always returns ok=true so :3830 "if (!applied && !nft_restored) log_message(\"Failed to restore nftables after an aborted list update\", \"fatal\")" is unreachable. tests/list_update_reload_policy.sh:121-122 "grep -Fq 'function restore_list_nft_snapshot()' ... || fail 'an aborted list transaction must restore the active nftables table'".


**Reproduction:** grep -n 'list_nft_snapshot_file\|restore_list_nft_snapshot\|nft_restored' forkop/files/usr/lib/components/updates.uc


**Expected:** Test pins the actual isolation mechanism.


**Actual:** Dead no-op + dead branch + misleading test.


**Impact:** The test asserts a rollback property by the existence of a dead no-op; if the real mechanism (candidate batch via FORKOP_NFT_BATCH_FILE, updates.uc:1225-1226, never touching the active table) regressed, this test would still pass.


**Root cause:** List updates switched to candidate-batch isolation; the old snapshot/restore scaffolding and its string test were left behind.


**Affected files:** `forkop/files/usr/lib/components/updates.uc`, `tests/list_update_reload_policy.sh`

**Dependencies:** None


**Proposed fix:** Delete restore_list_nft_snapshot, list_nft_snapshot_file and the nft_restored branch; replace the grep with a behavioural test that an aborted list update leaves 'nft list table inet forkop' unchanged (stubbed nft) or at least greps for the FORKOP_NFT_BATCH_FILE candidate path.


**Tests needed:** Behavioural abort test for list update nft isolation.


**Risk:** None.


---

<a id="uc-182"></a>

## UC-182 · CLEANUP · S12 — nft/apply.uc содержит собственные копии парсеров списков из config/rule.uc (риск расхождения между наборами nft и sing-box/валидатором)

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** backend/duplicate-helpers<br>
**Sources:** ui-cleanup-deadcode#10<br>
**Original title:** nft/apply.uc keeps private copies of config/rule.uc list parsers (drift risk between nft sets and sing-box/validator)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** nft/apply.uc:163 strip_list_comment, :178 text_list_values, :269 normalize_domain_subnet_value, :279 filter_domain_subnet_values are body-identical to config/rule.uc:10, :15, :118, :128 (duplicate scan: 1 variant each); config/rule.uc already exports text_list_values and normalize_domain_subnet_value (:322-338) and nft/apply.uc already does 'let rule_config = require("config.rule")' (:7). Same text_list_values/strip_list_comment also copied in config/migration.uc:862-880 and core/helpers.uc:356-384 (dead).


**Reproduction:** python scratch/audit-deadcode/dup_helpers.py text_list_values filter_domain_subnet_values


**Expected:** Single owner (config/rule.uc).


**Actual:** 4 copies of the same list parser.


**Impact:** A future parsing fix (new separator/comment rule, IDN handling) applied to config/rule.uc (used by validator.uc:389, generator.uc:2910, rule_conditions.uc) but not to nft/apply.uc would put different subnets into nft sets than sing-box rules expect -> traffic silently not intercepted or wrongly intercepted.


**Root cause:** Modules were written as standalone scripts and copied helpers.


**Affected files:** `forkop/files/usr/lib/nft/apply.uc`, `forkop/files/usr/lib/config/rule.uc`, `forkop/files/usr/lib/config/migration.uc`

**Dependencies:** None


**Proposed fix:** In nft/apply.uc delegate to rule_config.text_list_values / rule_config.normalize_domain_subnet_value (export filter_domain_subnet_values from rule.uc) and delete the local copies; leave migration.uc frozen copy only if migration must not depend on current parsing (document it).


**Tests needed:** Existing nft/rule tests; add one asserting nft and rule_config produce identical subnet lists for a mixed text input.


**Risk:** Low (identical today).


---

<a id="uc-183"></a>

## UC-183 · CLEANUP · S12 — Runtime-константы определены в 3+ местах с несогласованным переопределением через env; три константы не используются

**Severity:** CLEANUP<br>
**Stage:** S12 (Мёртвый код и производительность)<br>
**Area:** backend/constants<br>
**Sources:** ui-cleanup-deadcode#11<br>
**Original title:** Runtime constants defined in 3+ places with inconsistent env-override behaviour; three unused constants<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** DNS inbound address 127.0.0.42: core/constants.uc:86 (env SB_DNS_INBOUND_ADDRESS), dns/apply.uc:7, service/state.uc:19, service/ui.uc:37, diagnostics/runtime.uc:36 (all getenv override), core/netstat.uc:3 and singbox/dns.uc:16 (literal/other env), singbox/constants.uc:17 'const DNS_INBOUND_ADDRESS = "127.0.0.42"' (NO env override) which the generator uses for the sing-box listen (singbox/generator.uc:465). FakeIP/tag constants: core/constants.uc:77-79, core/helpers.uc:8-16, singbox/constants.uc:7-9 with different reserved sets (helpers.uc:510 default_reserved_runtime_tags vs singbox/constants.uc:46 RESERVED_TAGS). Unused: core/constants.uc:46 RESOLV_CONF, :81 SB_TPROXY_INBOUND_ADDRESS, :87 SB_DNS_INBOUND_PORT (grep -rnw over forkop/files, install.sh, frontend -> only constants.uc).


**Reproduction:** grep -rn '127.0.0.42' forkop/files/usr/lib


**Expected:** One source of truth per runtime constant.


**Actual:** Same constant declared 7+ times; one declaration ignores overrides honoured by the others.


**Impact:** No production code sets SB_DNS_INBOUND_ADDRESS today, so no live bug; but any override (tests already set it for dns_apply.sh) makes dnsmasq forward to an address sing-box does not listen on (DNS outage), and changing the literal in one module desyncs the rest.


**Root cause:** Standalone-script heritage; constants.uc introduced later without migrating consumers.


**Affected files:** `forkop/files/usr/lib/core/constants.uc`, `forkop/files/usr/lib/singbox/constants.uc`, `forkop/files/usr/lib/dns/apply.uc`, `forkop/files/usr/lib/service/state.uc`, `forkop/files/usr/lib/service/ui.uc`, `forkop/files/usr/lib/core/netstat.uc`, `forkop/files/usr/lib/core/helpers.uc`

**Dependencies:** None


**Proposed fix:** Make singbox/constants.uc read the shared core/constants values (or honour the same env), have dns/apply.uc/state.uc/ui.uc import core.constants instead of re-declaring; delete the three unused constants.


**Tests needed:** tests/constants_owner.sh extension: forbid literal 127.0.0.42 outside core/constants.uc.


**Risk:** Low; touching DNS wiring needs the dns_apply/lifecycle tests.


---

<a id="uc-184"></a>

## UC-184 · FUTURE · FUT — Возможности этапа 7 по пространству кандидатов и реалистичности измерений (A12, только фиксация)

**Severity:** FUTURE<br>
**Stage:** FUT (Будущая работа (не реализуется))<br>
**Area:** A12 Zapret/nfqws catalog<br>
**Sources:** autotune#13<br>
**Original title:** Stage 7 candidate-space and measurement-realism opportunities (A12, record only)<br>
**Confidence:** high<br>
**Hardware required:** yes<br>
**Product decision:** yes

**Evidence:** catalog.uc:18-46 (8 TCP/443 templates + disabled udp_fake); catalog.uc:92-95 (ipfrag excluded); apply.uc:159-172 (only single TCP/443 profiles are changeable); isolation.uc:516-544 (outbound-only queueing, IPv4 only); probe.uc:168-172 (router curl ClientHello)


**Expected:** n/a


**Actual:** Fixed 8-template TCP/443 catalog


**Impact:** Coverage limits documented in 'extra'. Not defects.


**Root cause:** Deliberate Stage 3-5 scope


**Affected files:** `forkop/files/usr/lib/autotune/catalog.uc`, `forkop/files/usr/lib/autotune/isolation.uc`, `forkop/files/usr/lib/autotune/apply.uc`

**Dependencies:** n/a


**Proposed fix:** See 'extra' FUTURE STAGE 7 list; no change proposed as a fix


**Tests needed:** n/a


**Risk:** n/a


---

<a id="uc-185"></a>

## UC-185 · FUTURE · FUT — Общее исключение локальных хелперов из захвата Forkop (cgroup или uid в метку outbound)

**Severity:** FUTURE<br>
**Stage:** FUT (Будущая работа (не реализуется))<br>
**Area:** architecture<br>
**Sources:** nft#14<br>
**Original title:** Generic local-helper exemption from Forkop capture (cgroup or uid to outbound mark)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:** TorrServer Direct (torrserver/direct.uc) and the ByeDPI loop finding both need 'this local process's traffic must not be captured'. There is currently a single ad-hoc cgroup rule.


**Expected:** One mechanism (for example a ForkopExempt table at -151 with cgroup-confined `meta mark set 0x08000000`) that the contract already understands.


**Actual:** Per-feature ad-hoc handling.


**Impact:** Future providers or helpers reuse it safely.


**Root cause:** n/a


**Affected files:** `forkop/files/usr/lib/torrserver/direct.uc`, `forkop/files/usr/lib/providers/byedpi/runtime.uc`

**Proposed fix:** Record only.


**Tests needed:** n/a


---

<a id="uc-186"></a>

## UC-186 · FUTURE · FUT — Нет списка сохранения sysupgrade для состояния Forkop (/etc/forkop: снимки/restore guard, история, состояние autotune, маркер восстановления opkg, кэши)

**Severity:** FUTURE<br>
**Stage:** FUT (Будущая работа (не реализуется))<br>
**Area:** packaging / sysupgrade<br>
**Sources:** packaging#13, persistence#13<br>
**Original title:** No sysupgrade keep list for Forkop state (/etc/forkop: snapshots/restore guard, history, autotune state, opkg recovery marker, caches)<br>
**Confidence:** medium<br>
**Hardware required:** no<br>
**Product decision:** D-12

**Evidence:** Only /etc/config/forkop is a conffile (build.sh:293-295, :737). No /lib/upgrade/keep.d/forkop exists in the package trees. Persistent state lives in /etc/forkop/config-snapshots (config/snapshots.uc:7), history.jsonl, autotune/state.json, opkg-package-set-recovery, subscription-cache.


**Reproduction:** sysupgrade -k with Forkop reinstalled: /etc/forkop/config-snapshots is empty.


**Expected:** A deliberate choice of state to preserve.


**Actual:** Only the UCI config survives sysupgrade.


**Impact:** A keep-settings sysupgrade (including attended sysupgrade reinstalling Forkop) keeps the config but drops snapshots/LKG, history, autotune results and a pending opkg recovery marker.


**Root cause:** Not designed yet.


**Affected files:** `build.sh`, `forkop/Makefile`

**Dependencies:** None


**Proposed fix:** Decide which state should survive firmware upgrades. If some should, ship /lib/upgrade/keep.d/forkop listing it (excluding large caches).


**Tests needed:** Package contract test for the keep.d file, if adopted.


**Risk:** Low


### Also reported as persistence#13 (FUTURE): Forkop persistent state under /etc/forkop is not preserved across sysupgrade (only /etc/config/forkop is a conffile)

**Evidence:** forkop/Makefile:60-62 conffiles lists only /etc/config/forkop. There is no /lib/upgrade/keep.d entry for /etc/forkop (config-snapshots, last-known-working, history.jsonl, autotune/state.json, autotune-apply.json, list-cache, subscription-cache).


**Proposed fix:** Decide which state should survive (at least config-snapshots, LKG, history, autotune state) and ship a keep.d file listing it. The caches can stay excluded.


---

<a id="uc-187"></a>

## UC-187 · FUTURE · FUT — Autotune не может настраивать DPI-правила, заданные только community- или remote-списками (самая частая конфигурация); резолвер мог бы оценивать локальные source rule-set

**Severity:** FUTURE<br>
**Stage:** FUT (Будущая работа (не реализуется))<br>
**Area:** routing<br>
**Sources:** routing#10<br>
**Original title:** Autotune cannot tune DPI rules defined only by community or remote lists (the most common setup); the resolver could evaluate local source rule-sets<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:** resolve.uc:220 treats every `rule_set` as unknown, which gives undecidable_matcher. Community lists are remote binary (generator.uc:2355-2361). domain_ip_lists and materialized remote lists are local 'source' JSON on the router (generator.uc:2408-2413, 2498-2505).


**Expected:** Decidable when the list contents are available locally.


**Actual:** List-based rules are always undecidable.


**Impact:** A zapret rule with only community_lists 'youtube' makes every target 'rule_owner_undecidable:undecidable_matcher'. Autotune never applies to it, and the site check shows 'not calculated'.


**Root cause:** Stage 5 deliberately limited the resolver to static inline matchers.


**Affected files:** `forkop/files/usr/lib/routing/resolve.uc`

**Proposed fix:** Evaluate local source rule-sets (plain domain_suffix and ip_cidr rules) in the resolver. Optionally keep a decoded domain index for community .srs lists. Fail closed for anything else.


**Tests needed:** Resolver cases using local source rule-sets.


---

<a id="uc-188"></a>

## UC-188 · FUTURE · FUT — Правила Bypass и Block анонимны в Diagnostics и Monitoring (владелец определяется по тегу outbound, а не по правилу)

**Severity:** FUTURE<br>
**Stage:** FUT (Будущая работа (не реализуется))<br>
**Area:** routing<br>
**Sources:** routing#11<br>
**Original title:** Bypass and block rules are anonymous in Diagnostics and Monitoring (the owner is inferred from the outbound tag, not the rule)<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:** resolve.uc:319-323: reject gives kind 'block' and bypass-out gives kind 'bypass', both with section null. route_trace.uc:84-89 then has rule value null. connectionView.ts:101-110 behaves the same.


**Expected:** The rule label.


**Actual:** 'Bypass' or 'Block' with no rule name.


**Impact:** With several bypass or block rules, the user cannot see which one matched.


**Root cause:** The shared bypass-out and reject targets carry no section identity.


**Affected files:** `forkop/files/usr/lib/singbox/generator.uc`, `forkop/files/usr/lib/routing/resolve.uc`

**Proposed fix:** Have the generator emit a side map from route rule index to section name. The resolver and route_trace can then use route_rule, and Monitoring can use rulePayload or rule to name the section.


**Tests needed:** route_trace_owner.sh: a bypass case names the rule.


---

<a id="uc-189"></a>

## UC-189 · FUTURE · FUT — Прерванный restore (сбой или потеря питания посреди транзакции) не оставляет устойчивого следа; при загрузке запускается непроверенный файл без пометки

**Severity:** FUTURE<br>
**Stage:** FUT (Будущая работа (не реализуется))<br>
**Area:** recovery journal<br>
**Sources:** snapshots#16<br>
**Original title:** An interrupted restore (crash or power loss mid-transaction) leaves no durable trace; boot starts the unverified file without flagging it<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** yes

**Evidence:** The guard lives only in nft (lost on reboot). The restore event is written only at the end (snapshots.uc:429). There is no intent file under /etc/forkop, and lifecycle start never compares the config to LKG (confirm-working only on reload, lifecycle.uc:400-404).


**Expected:** Interrupted transactions are visible after reboot.


**Actual:** No record of the interrupted transaction.


**Impact:** After a reboot during a restore, /etc/config/forkop may be the target (atomic, never partial) while LKG is the old one. Health shows no guard and no event, so the discrepancy is invisible unless start fails. Recovery is still possible manually through LKG.


**Root cause:** The transaction state is kept only in volatile nft/tmpfs.


**Affected files:** `forkop/files/usr/lib/config/snapshots.uc`, `forkop/files/usr/lib/diagnostics/health.uc`

**Proposed fix:** Write a small durable intent record (snapshot ids plus phase) before the config write and clear it at the end. At boot or on the History page, surface 'Restore was interrupted: config differs from LKG', with one-click restore of LKG.


**Tests needed:** Crash tests like autotune_apply.sh '3 (crash list)' for restore.


---

<a id="uc-190"></a>

## UC-190 · FUTURE · FUT — Сборка пакетов не побитово воспроизводима: три сборки одного коммита дали разные sha256

**Severity:** FUTURE<br>
**Stage:** FUT (Будущая работа (не реализуется))<br>
**Area:** packaging<br>
**Sources:** manual#0<br>
**Original title:** Package build is not bit-reproducible: three build.sh runs of the same commit produced three different sha256 for every package<br>
**Confidence:** high<br>
**Hardware required:** no<br>
**Product decision:** no

**Evidence:** LuCI container harness baseline: build.sh 1.0.26-90 from 078720844608 run three times with the same SDK cache and builder image; build-manifest.json records a different sha256 for each of the six packages on every run.


**Reproduction:** Build the same commit twice with build.sh and compare sha256 of the resulting .ipk/.apk files.


**Expected:** Identical inputs produce identical packages, so a published release can be independently rebuilt and compared with its catalog sha256.


**Actual:** Every build of the same source produces different package hashes.


**Impact:** The sha256 in the release catalog proves the integrity of the published file but not its provenance from the source tree; nobody can independently re-derive a release.


**Root cause:** Not investigated in this audit (likely archive mtimes, file ordering and owners in the package tarballs, plus package metadata timestamps).


**Affected files:** `build.sh`

**Dependencies:** None.


**Proposed fix:** Future work: derive SOURCE_DATE_EPOCH from the commit date and normalise tar mtimes, owners and entry order in build.sh; compare two builds in a test.


**Tests needed:** Build twice from the same commit and assert identical sha256 (container harness).


**Risk:** Low.


---
