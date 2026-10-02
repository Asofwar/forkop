# ULTRACODE — находки delta-аудита после паузы

Дополнение к [ULTRACODE_FINDINGS.md](ULTRACODE_FINDINGS.md) (тот файл — неизменное свидетельство состояния на `07872084`). Здесь — находки по коду, пришедшему после паузы Phase B: 27 коммитов владельца на `feature/observability-safety-ux` (`8b5082b8..a99e21d0`) и 11 коммитов `main` (1.0.29–1.0.31, kill-switch VPN `0ff8e687`/`c8d0d773`), проверено на `9e795b1e` (= `origin/main` `c8d0d773` + docs).

**Метод:** 5 независимых read-only направлений (autotune, lifecycle/stop/пакеты, маршрутизация/кэш rule-set, UI-страницы, kill-switch VPN); каждая исходная P1/P2 перепроверена двумя агентами, пытавшимися её опровергнуть. Severity P1/P2 — по подтверждённому вердикту проверки (наиболее строгий из подтверждённых).

**Итог:** P1 — 1, P2 — 8, P3 — 27, CLEANUP — 5. Этап SD — аварийный этап закрытия P1/P2 delta-аудита перед продолжением S4.

| ID | Sev | Этап | Исходный id | Находка |
|---|---|---|---|---|
| [UC-191](#uc-191) | P1 | SD | KILLSWITCH-1 | Kill-switch state outlives its owner: a downgrade through the supported version picker (or a sysupgrade without the package) leaves an active DNS block list and the fw4 nft include that nothing on the system can lift |
| [UC-192](#uc-192) | P2 | SD | KILLSWITCH-2 | A start with deferred subscription sections replaces the saved kill-switch policy with one that has no destinations for those sections, and their traffic leaks directly while deferred |
| [UC-193](#uc-193) | P2 | SD | KILLSWITCH-3 | The DNS block list silently drops rule-set and community-list domains of protected sections that have excluded devices, and blocks device-scoped sections for every client |
| [UC-194](#uc-194) | P2 | SD | LIFECYCLE-STOP-2 | Explicit stop fails when no 'sing-box' procd service is registered; with init.d now exiting on a failed stop, Restart from a stopped state, Full uninstall of a stopped Forkop and the sing-box extended-compressed install all break |
| [UC-195](#uc-195) | P2 | SD | LIFECYCLE-STOP-3 | apk staged rollback can never find its archives: the previous release is staged as *.ipk, but recovery looks for *.apk |
| [UC-196](#uc-196) | P2 | SD | LIFECYCLE-STOP-4 | On apk, 1.0.27 adds upgrade refusals that run after Forkop was already stopped; nothing restarts it, the stop is recorded as the user's, and the next Start may be refused |
| [UC-197](#uc-197) | P2 | SD | LIFECYCLE-STOP-5 | A refused package stop during opkg/apk upgrade leaves ForkopTable and ip rule 105 with no listener (pre-existing; upgrade variant of UC-028) |
| [UC-198](#uc-198) | P2 | SD | ROUTING-CACHE-1 | The resolver reads stdout, but sing-box `rule-set match` prints matches to stderr, so every local list answers "no" and list-owned connections get a confident wrong owner |
| [UC-199](#uc-199) | P2 | SD | UI-PAGES-2 | The Rules page saves deleting or disabling the rule that Settings uses for DNS or proxied downloads, because the Phase B S2 refusal stayed on the Settings page |
| [UC-200](#uc-200) | P3 | S9 | AUTOTUNE-1 | Probe clamp lowers the requested probe count without telling the user, which contradicts approved D-4(a) and makes the stability rule stricter |
| [UC-201](#uc-201) | P3 | S9 | AUTOTUNE-2 | Read-only autotune_status and autotune_groups now run sing-box, DNS lookups and tmpfs writes for rule-list targets, with no single-flight |
| [UC-202](#uc-202) | P3 | S9 | AUTOTUNE-3 | Rule on the default strategy gets a 'confirmed' fake_multidisorder recommendation that can never be applied |
| [UC-203](#uc-203) | P3 | S9 | AUTOTUNE-4 | Legacy default strategy counts as non-custom 'default', so autotune splices its hostlist profile into a strategy the runtime validator rejects |
| [UC-204](#uc-204) | P3 | S9 | AUTOTUNE-5 | tcp443_scope treats a profile that filters both TCP/443 and UDP/443 as 'exact', so the splice drops its UDP/QUIC strategy (latent) |
| [UC-205](#uc-205) | P3 | S9 | AUTOTUNE-6 | An apply turns 'follow the Forkop default' into a frozen explicit copy that a later default change will neither migrate nor recognise |
| [UC-206](#uc-206) | P3 | S9 | AUTOTUNE-7 | List members are not counted against MAX_TARGETS, so one run can hold the worker lock for hours and block operator rollback and manual apply |
| [UC-207](#uc-207) | P3 | S9 | AUTOTUNE-8 | List member ids (<id>__<n>) can collide with ordinary target ids, so results go to the wrong host and are lost |
| [UC-208](#uc-208) | P3 | SD/S8 | KILLSWITCH-4 | While Forkop is stopped by the user or not started (D-15), turning off or deleting a protected section, or restoring a snapshot without it, never lifts the block, but the UI says it lasts only until the next reload |
| [UC-209](#uc-209) | P3 | SD/S8 | KILLSWITCH-5 | A reload whose list source changed refreshes the kill-switch from the new UCI order on top of the old, not rebuilt runtime, and can reject traffic that the running Forkop deliberately sends direct |
| [UC-210](#uc-210) | P3 | SD/S8 | KILLSWITCH-6 | The new killswitch.lock is a PID-only directory lock with racy stale cleanup, outside core/runtime_lock, and manual sync is not serialized with reload.lock |
| [UC-211](#uc-211) | P3 | SD/S8 | KILLSWITCH-7 | Enabling the kill-switch on one section turns other, unprotected VPN sections from failing closed to leaking direct when sing-box dies |
| [UC-212](#uc-212) | P3 | SD/S8 | KILLSWITCH-8 | The persistent include and DNS files are written without sync on flash, and state.json in /etc is rewritten on every start and reload |
| [UC-213](#uc-213) | P3 | SD/S6 | LIFECYCLE-STOP-1 | An explicit Stop or Restart, and the in-app upgrade when another sing-box runs, kill every process whose executable is named sing-box, including ones Forkop does not own |
| [UC-214](#uc-214) | P3 | SD | LIFECYCLE-STOP-10 | tests/urltest_override_validation.sh fails about half the time since e6c31a4d (provider URLTest rotation uses a random seed per config generation) |
| [UC-215](#uc-215) | P3 | SD/S6 | LIFECYCLE-STOP-6 | The 'exit 2 leaves DNS with the running runtime' contract is false: stop_impl restores dnsmasq before the ownership check |
| [UC-216](#uc-216) | P3 | SD/S6 | LIFECYCLE-STOP-7 | The start-time 're-check' before each signal is a no-op and does not protect against PID reuse |
| [UC-217](#uc-217) | P3 | SD/S6 | LIFECYCLE-STOP-8 | A leftover upgrade marker turns a user Stop into a guarded stop that refuses, keeps interception running and still records a user stop |
| [UC-218](#uc-218) | P3 | S8 | ROUTING-CACHE-2 | Even if read correctly, `rule-set match` checks a list with port 0, no network and no source, so list rules with port, network or invert constraints get decided wrongly |
| [UC-219](#uc-219) | P3 | S8 | ROUTING-CACHE-3 | The resolver's shell_quote is broken ("'\''" in ucode yields `'''`), so a list path containing a quote runs shell commands as root whenever route_trace or autotune_groups runs |
| [UC-220](#uc-220) | P3 | S8 | ROUTING-CACHE-4 | The resolver starts one sing-box process per list, per value, per rule above the owner, with no timeout; RO polls can pile up multi-second parses |
| [UC-221](#uc-221) | P3 | S8 | ROUTING-CACHE-5 | nft_apply.sh and nft_real.sh share the host's /var/run/forkop/nft-subnet-cache, so a stale entry from another checkout makes an extraction bug pass |
| [UC-222](#uc-222) | P3 | S8 | ROUTING-CACHE-6 | The prepared-subnet cache in RAM-backed tmpfs is capped by entry count, not size; stale content-keyed entries stay until reboot, and hits do not count as use |
| [UC-223](#uc-223) | P3 | S8 | ROUTING-CACHE-7 | When tmpfs is full, nft batch appends are dropped silently and apply.uc still exits 0; a candidate cut at a line boundary passes `nft -c` and replaces the live table (pre-existing, not a regression of e9e95bc2) |
| [UC-224](#uc-224) | P3 | S4/S11 | UI-PAGES-1 | configform.js's snapshot-first Save & Apply never runs on Rules or Settings: UC-064 is still present, now on two pages, and the tests stub a Map API that LuCI lacks |
| [UC-225](#uc-225) | P3 | S4/S11 | UI-PAGES-3 | configform.js's snapshot gate refuses with a message that gives no reason and has no D-14 headroom; once wired, 10 manual snapshots would block every Save & Apply |
| [UC-226](#uc-226) | P3 | S4/S11 | UI-PAGES-4 | Since 601ce4b0 the Built-in rule sets widget shows raw, untranslated list names, bypassing the Stage 6.10 localization |
| [UC-227](#uc-227) | CLEANUP | S9 | AUTOTUNE-9 | apply.uc exports a tcp443_profile that no longer exists, and part of the new refusal texts can never show |
| [UC-228](#uc-228) | CLEANUP | SD/S8 | KILLSWITCH-9 | The kill-switch tests do not catch broken logic: fake nft accepts anything, the lifecycle test is source grep, and key paths are untested |
| [UC-229](#uc-229) | CLEANUP | SD/S6 | LIFECYCLE-STOP-9 | The new stop paths have no behavioural tests, and the modelled state.uc fakes silently succeed for them |
| [UC-230](#uc-230) | CLEANUP | S8 | ROUTING-CACHE-8 | Subnet cache identity is a hand-bumped version string plus md5, and cached element strings go into the nft batch without re-validation |
| [UC-231](#uc-231) | CLEANUP | S4/S11 | UI-PAGES-5 | The new read-group grant killswitch_status is used only by admin-only pages |

---

## UC-191

- **Severity:** P1
- **Источник:** delta-аудит после паузы, направление «VPN kill-switch», исходный id `KILLSWITCH-1`
- **Проверка:** подтверждено (P1); подтверждено (P1)
- **Этап:** SD
- **Связь:** Related to D-12 (sysupgrade keep-list, FUTURE); this partial keep.d is a de-facto implementation, not a breach of an approved decision. Same class as the A5 inventory finding 'package removal ignores a refused stop and leaves TPROXY capture'. New code, not a Phase B regression.
- **Файлы:** forkop/files/usr/lib/service/package.uc:219-228; forkop/files/usr/lib/dns/apply.uc:118-156,345-351; forkop/files/lib/upgrade/keep.d/forkop-killswitch; forkop/files/usr/lib/killswitch/runtime.uc:236-274; build.sh:458-461 (and 1.0.31 build.sh:454-458); luci-app-forkop/.../main.js:16080-16099; forkop/files/usr/lib/components/action.uc:428-445

**Kill-switch state outlives its owner: a downgrade through the supported version picker (or a sysupgrade without the package) leaves an active DNS block list and the fw4 nft include that nothing on the system can lift**

**Evidence.** Package removal is the only package path that lifts the policy: package.uc:225-226 runs `disable` only when action == "remove". On apk, an upgrade or downgrade runs the incoming package's pre-upgrade script. In every release, including 1.0.31 (f19e4163 build.sh:454-458), that script calls `/usr/bin/forkop package_prerm upgrade`. At that moment /usr/bin/forkop is still the installed kill-switch build. Its stop path, dns/apply.uc dnsmasq_restore:345-351, calls killswitch_dns_apply(true). That copies the block list into /etc/forkop/killswitch/dnsmasq.servers and keeps dhcp.@dnsmasq[0].serversfile pointing at it. The kill-switch itself is kept because the action is not "remove". Older releases contain no serversfile handling at all (f19e4163 dns/apply.uc: 0 matches), so they never empty or detach the file. The fw4 include /usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft is created at runtime and is not owned by the package. fw4 reloads it on every boot and every firewall reload. Older LuCI and CLI have no kill-switch commands, and the older full-uninstall.sh deletes neither the include nor serversfile. LuCI offers older versions directly (confirmVersionChange; action.uc installs with --force-downgrade). keep.d/forkop-killswitch also carries the include and state through a sysupgrade to an image without Forkop.

**Reproduction.** Scratch /tmp/claude-0/delta-killswitch/downgrade: extracted the f19e4163 lib. Wrote the UCI state that the new code's stop leaves behind: dhcp server=1.1.1.1, serversfile=<ks>/dnsmasq.servers containing `server=/claude.ai/`. Ran the OLD `dns/apply.uc configure force`. Result: dhcp server=127.0.0.42 (Forkop running), serversfile unchanged, `server=/claude.ai/` still present. dnsmasq prefers the domain-specific local-only entry, so claude.ai is NXDOMAIN while the downgraded Forkop runs. The stop step writing the block list is what tests/killswitch_sync.sh case 3 asserts (`cmp BLOCKED SERVERS`).

**Impact.** After a downgrade to any pre-kill-switch release (deterministic on apk / OpenWrt 25.12; on opkg whenever the installed prerm runs): every protected domain returns NXDOMAIN for all LAN clients even though Forkop is running. The ForkopKillswitch table is re-installed by fw4 at every boot and rejects protected IP destinations and all FakeIP traffic whenever Forkop is stopped, including after the old full uninstall. No installed UI or CLI shows or removes it. After a sysupgrade to an image without Forkop, the same nft policy persists with no owner. Matches the P1 class 'traffic black-holing with no owner'.

**Proposed fix.** (1) A package-initiated stop (FORKOP_STOP_SOURCE=package or component) must not activate DNS blocking. Detach serversfile and leave the servers file empty; the new version's postinst start/sync re-arms it. (2) Make the persisted nft policy conditional on its owner. For example, load it through a firewall include of type script that first checks that /usr/lib/forkop/killswitch/runtime.uc exists, instead of an unconditional ruleset-post file. Alternatively, the pre-upgrade path of this and later versions lifts the policy when the target version is older. (3) Remove the keep.d entry until D-12 is decided, or have the boot loader verify the owner. (4) In LuCI's version picker, warn about the kill-switch and run killswitch_disable before installing an older version.

---

## UC-192

- **Severity:** P2
- **Источник:** delta-аудит после паузы, направление «VPN kill-switch», исходный id `KILLSWITCH-2`
- **Проверка:** подтверждено (P2); подтверждено (P2)
- **Этап:** SD
- **Связь:** Same intent as the start_lists_complete guard (lifecycle.uc:1234-1240), which misses this case. Subscription bootstrap deferral is S3/UC-057 territory. No existing UC card.
- **Файлы:** forkop/files/usr/lib/service/lifecycle.uc:1234-1240,1151; forkop/files/usr/lib/nft/apply.uc:2153,1882-2009; forkop/files/usr/lib/singbox/generator.uc:3226-3234; forkop/files/usr/lib/killswitch/runtime.uc:523-528,932-1003; forkop/files/usr/lib/subscription/cache.uc:2653,2665

**A start with deferred subscription sections replaces the saved kill-switch policy with one that has no destinations for those sections, and their traffic leaks directly while deferred**

**Evidence.** start_impl calls killswitch_sync("start") whenever start_lists_complete is true. That guard covers list generations only, not subscription-deferred sections. A deferred section still gets its priority rules and sets in ForkopTable (nft_add_section_priority_rules_from_sections ignores deferral). nft_populate_runtime_set_for_section returns before adding destinations (apply.uc:2153), so the sets stay empty. The generator drops the section from the sing-box config (enabled_sections:3230), and cache.uc:2653/2665 says it 'will remain disabled until the next successful subscription update'. The kill-switch render copies the empty live sets (ok:true, set_elements:0). The DNS render finds no route rule for the section's outbound and silently produces 0 domains for it (runtime.uc:523-528; no error). sync_locked then overwrites the include, the live table and dns-blocked.servers.

**Reproduction.** Scratch harness /tmp/claude-0/delta-killswitch/real_render.sh in `unshare -rn` with real nft 1.0.9. A protected connection section `main` with ip_cidr 93.184.216.0/24 was built live with deferred="main" (as start_main does). `killswitch-render` returned {ok:true, set_elements:0}. The rendered policy has `... ip daddr @forkop_rule_main_subnets counter name ks_main jump ks_reject` and no `add element` for that set. nft -c/-f accepted it, so a sync would install it.

**Impact.** While the section is deferred, Forkop is running but the protected section is not routed. Its domains resolve to real IPs through sing-box's default DNS (no FakeIP), its IP sets are empty, and its traffic goes straight out through WAN. The kill-switch does not reject it, although the feature promises rejection whenever traffic 'does not go through Forkop'. The previously complete persistent policy (IPs and DNS names) is also replaced. If the bootstrap never recovers (subscription unreachable, often the very outage case) and Forkop is later stopped or crashes, the section has no nft or DNS protection at all. LuCI keeps showing 'Protection active'.

**Proposed fix.** Pass subscription_deferred_sections to the kill-switch sync. Skip the refresh while a protected section is deferred (as start_lists_complete does for lists), or keep that section's previous elements and DNS names. In addition, reject a deferred protected section's destinations in the live runtime (its traffic must not go direct), and show a 'deferred, not protected' state in status/LuCI.

---

## UC-193

- **Severity:** P2
- **Источник:** delta-аудит после паузы, направление «VPN kill-switch», исходный id `KILLSWITCH-3`
- **Проверка:** подтверждено (P2); подтверждено (P2)
- **Этап:** SD
- **Связь:** No UC card (new code). The UI status figures in killswitch.js renderSectionStatus are wrong as a result.
- **Файлы:** forkop/files/usr/lib/killswitch/runtime.uc:357-377,474-480,556-564; forkop/files/usr/lib/singbox/generator.uc:2576-2605

**The DNS block list silently drops rule-set and community-list domains of protected sections that have excluded devices, and blocks device-scoped sections for every client**

**Evidence.** With excluded_source_ip_cidr set, the generator wraps every route rule of the section as {type:logical, mode:and, rules:[<conditions incl. rule_set/domain/source_ip_cidr>, {source_ip_cidr, invert:true}], action, outbound} (exclude_sources_from_matchers). route_rule_matchers reads rule.rule_set only at the top level (runtime.uc:477), and collect_rule_matchers never resolves rule_set inside children, so every rule-set and community list of such a section is skipped. The client-limited check `rule.source_ip_cidr != null` (runtime.uc:559) is also top-level only. A device-scoped section that also has exclusions is therefore treated as unscoped.

**Reproduction.** /tmp/claude-0/delta-killswitch/dns1. Generated a real config with singbox/generator.uc generate-config-fixture for three protected sections: main (domain_suffix + local rule_set), excl (same + excluded_source_ip_cidr) and devlim (domain_suffix + source_ip_cidr + excluded_source_ip_cidr). Ran `killswitch/runtime.uc render-dns-fixture`. Output: main blocks inline.example, blocked-by-list.example and chatgpt.com. excl blocks only inline2.example; second-list.example from its rule_set is missing, with sections.excl.domains=1 and uncovered=0, so nothing is reported. devlim's devonly.example is blocked for all clients (client_limited=0); without the exclusion it would be counted as client_limited and not blocked.

**Impact.** Once Forkop is stopped, crashed, or sing-box is down with the standby active, the list domains of a protected section with any excluded device resolve through the normal upstream and connect directly. The IP sets do not cover domain-only lists, so the kill-switch fails open for a common setup (community lists plus 'exclude this device'), while the UI shows a domain count that looks complete. The opposite error also occurs: device-scoped protected sections with exclusions make their domains NXDOMAIN for every LAN device, including devices outside the section's scope and the excluded devices themselves.

**Proposed fix.** In render_dns_from_config, walk logical route rules. Collect rule_set (and resolve the tags) from children in `and` mode. Treat a non-inverted child with source_ip_cidr/source_port as client-limited. Treat an inverted source child as a restriction (an exception set) rather than ignoring it. Add a generator-produced fixture with exclusions to tests/killswitch_dns_render.sh.

---

## UC-194

- **Severity:** P2
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-2`
- **Проверка:** подтверждено (P2); подтверждено (P2)
- **Этап:** SD
- **Связь:** Regresses Phase B: the start-and-wait restart path (UC-013) and D-15, since a user stop is recorded on a restart that never starts. UC-019 recovery UX. UC-028: full-uninstall now sees stop failures, which is good, but it fails on the benign case.
- **Файлы:** forkop/files/usr/lib/service/state.uc:771-797; forkop/files/etc/init.d/forkop:64-72; forkop/files/usr/lib/service/lifecycle.uc:1311-1316; forkop/files/usr/lib/full-uninstall.sh:77-82; forkop/files/usr/lib/components/action.uc:333-352,955-965,1832-1911

**Explicit stop fails when no 'sing-box' procd service is registered; with init.d now exiting on a failed stop, Restart from a stopped state, Full uninstall of a stopped Forkop and the sing-box extended-compressed install all break**

**Evidence.** state.uc:776 runs `if (!command_success_from_args([ "ubus", "call", "service", "delete", "{\"name\":\"sing-box\"}" ])) return false;` before the 'nothing left to stop' check.

For an unknown service, procd returns UBUS_STATUS_NOT_FOUND (procd service/service.c service_handle_delete: `if (!s) return UBUS_STATUS_NOT_FOUND;`), and the ubus CLI exits non-zero (ubus cli.c main returns ret).

The 'sing-box' service is unregistered after every procd stop of it, because rc.common stop calls procd_kill, which deletes the service. That covers:
- every user Stop;
- stop-managed in lifecycle stop and cleanup_failed_runtime;
- the component stop and prepare_sing_box_service_disabled;
- boot when Forkop did not start.

stop_main then returns 1 (lifecycle.uc:1311-1316). init.d now aborts on that (`[ "$status" -eq 0 ] || exit "$status"`, init.d/forkop:79), so rc.common's restart (stop; start) never reaches start.

**Reproduction.** All runs inside `unshare -r -p -f --mount-proc` with a ubus stub that has procd's semantics.

/tmp/claude-0/delta-lifecycle/r1/repro.sh:
- Case B: a stray sing-box outside procd. stop-all exits 1 and the stray is still alive; it was never signalled.
- Case C: nothing running. stop-all exits 1, while stop-managed exits 0.

/tmp/claude-0/delta-lifecycle/r2/repro_restart.sh (real init.d stop_service, initd.uc, lifecycle.uc stop() and state.uc):
- Case 1: `/etc/init.d/forkop restart` on a stopped Forkop. rc exits 1, 'START REACHED' is never logged, stop.requested contains by=user and start.explicit is removed.
- Case 3: stray sing-box plus ForkopTable. Stop exits 1, the stray is STILL RUNNING and nft is removed.

/tmp/claude-0/delta-lifecycle/r4/repro_uninstall.sh: full-uninstall.sh worker on a Forkop that is not running ends with status `{"state":"failed","phase":"stop"}`.

The same scripts on the pre-merge tree ac39174d (/tmp/claude-0/delta-lifecycle/pre/) reach start, and the uninstall passes the stop phase.

**Impact.** (a) Full uninstall (full-uninstall.sh:80 runs under set -e) fails at phase 'stop' whenever Forkop is not running, for example after the user pressed Stop. Nothing is removed.
(b) `/etc/init.d/forkop restart` never starts a stopped Forkop and records a sticky user stop (D-15). This affects the UI Restart, including the UC-019 'Restart Forkop X' button shown for a stopped runtime (overviewCards.ts:132-143), LuCI Startup, the CLI, and action.uc's fallback restarts after a failed start (action.uc:351, 962).
(c) Installing or updating the sing-box extended-compressed binary variant while Forkop runs always fails and is rolled back. stop_forkop_before_sing_box_change and install_managed_sing_box_service_script leave the service unregistered, with no start in between. restart_forkop_after_successful_change then hits the failing stop, giving 'did not start cleanly; previous sing-box variant was restored' (action.uc:1832-1911).
(d) Stopping an already stopped Forkop reports failure and applies the DNS failsafe.
(e) The stray-runtime case that 1.0.28 targeted is not handled.

All of these worked before the merge. This is a regression.

**Proposed fix.** Treat 'service not registered' as already stopped:
- query `ubus call service list '{"name":"sing-box"}'` and delete only when the service is present, or accept NOT_FOUND;
- run the 'no process and no procd pid' check before the delete;
- keep init.d's exit for real failures.

Add tests for: stop with nothing running, restart from stopped through an rc.common stand-in, Full uninstall of a stopped Forkop, and a stray sing-box outside procd.

---

## UC-195

- **Severity:** P2
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-3`
- **Проверка:** подтверждено (P2); подтверждено (P2)
- **Этап:** SD
- **Связь:** UC-027 (S6). Section 13.2 notes '321268d0/c063f92f учесть в S6'. Not a regression of an S3 fix.
- **Файлы:** forkop/files/usr/lib/components/action.uc:2090-2125,2158-2179,2238-2246,2697-2701; tests/forkop_package_set_rollback.sh:33-38

**apk staged rollback can never find its archives: the previous release is staged as *.ipk, but recovery looks for *.apk**

**Evidence.** install_forkop_package_set always stages the previous release as backend.ipk, app.ipk and i18n.ipk (action.uc:2240-2242; 321268d0 did not change these lines).

Recovery builds names with forkop_recovery_files(), whose extension comes from pkg_set_extension() and is 'apk' on apk systems (action.uc:2090-2092, 2118-2125). It returns 'Forkop package-set recovery archive is missing; manual recovery required' (action.uc:2169-2172) before restoring packages or the service.

The pending marker stays in /etc/forkop/opkg-package-set-recovery. component_action runs recovery first on every later Forkop install (action.uc:2697-2701), so every attempt returns the same error.

tests/forkop_package_set_rollback.sh:33-38 checks '.apk rollback packages' only through pkg_set_extension(), never through the staged files.

apk-tools 3.0.3 src/app_add.c:149 treats any existing path containing '.' as a local package, so the preflight on .ipk names passes and hides the mismatch.

**Reproduction.** /tmp/claude-0/delta-lifecycle/r3/repro_apk_recovery.sh uses a scratch copy of action.uc with one fixture branch calling recover_forkop_opkg_set(), an apk stub, and packages.uc reporting a half-installed set. The staged files are backend.ipk, app.ipk and i18n.ipk. It prints 'recovery files: .../backend.apk .../app.apk .../i18n.apk' and 'result: Forkop package-set recovery archive is missing; manual recovery required'.

**Impact.** The 1.0.27 rollback of a half-installed set on apk (OpenWrt 25.12) never works. In exactly the case it exists for:
- Forkop is left half-installed and stopped, because finish_forkop_opkg_recovery never runs;
- in-app upgrades stay blocked until someone deletes the recovery directory by hand;
- the message says the archives are missing although they are on disk.

**Proposed fix.** Derive the staged paths from forkop_recovery_files(), so names come from one place. Let recovery also accept the legacy .ipk names. Add a test that stages through install_forkop_package_set with apk stubbed, then recovers.

---

## UC-196

- **Severity:** P2
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-4`
- **Проверка:** подтверждено (P2); подтверждено (P2)
- **Этап:** SD
- **Связь:** Extends UC-027 (STILL_PRESENT, S6) to apk. Also a D-15 attribution gap: S3 added stop sources for component and package stops but missed this call site, so S3 coverage is incomplete. It does not regress an S3 fix.
- **Файлы:** forkop/files/usr/lib/components/action.uc:347-368,2073-2081,2219-2266,2371-2388,2456-2502; forkop/files/usr/lib/service/initd.uc:306-333; forkop/files/usr/lib/service/lifecycle.uc:1600-1613

**On apk, 1.0.27 adds upgrade refusals that run after Forkop was already stopped; nothing restarts it, the stop is recorded as the user's, and the next Start may be refused**

**Evidence.** install_forkop runs in this order:
1. Capture the upgrade marker (action.uc:2495).
2. stop_old_sing_box_before_forkop_upgrade() stops Forkop with upgrade_bounded_stop(SERVICE_INIT) (action.uc:2388, 2497).
3. install_forkop_package_set (action.uc:2500).

On apk, step 3 now refuses before touching any package if:
- recovery is pending;
- installed versions are inconsistent;
- previous_forkop_release cannot fetch metadata from api.github.com (action.uc:2073-2081), although the new release itself is resolved from fold8.ru (action.uc:700-705);
- the staging download fails;
- the `apk add --simulate` preflight fails;
- the new free-space heuristic (3×new + staged + 2 MiB) refuses (action.uc:2262-2266).

action_fail (action.uc:361-368) restarts Forkop only after a sing-box change (restart_forkop_after_failed_sing_box_change, action.uc:347-352), so Forkop stays down.

upgrade_bounded_stop passes no FORKOP_STOP_SOURCE (action.uc:2371-2380). initd.uc stop_request_source and mark_stop_requested (initd.uc:306-333) therefore record by=user and delete start.explicit. The UI shows 'stopped by user', and reloads and WAN-up retries skip it (D-15).

Only start_inner consumes the marker; once it is older than 120 s the next Start is refused once (lifecycle.uc:1603-1613; state.uc:900 wait_managed_upgrade_sing_box_exit).

Before 1.0.27, the only failure after the stop on apk was `apk add` itself.

**Reproduction.** Code trace. The D-15 attribution matches r2/repro_restart.sh case 1: a stop without FORKOP_STOP_SOURCE writes stop.requested by=user and removes start.explicit.

**Impact.** A routine in-app upgrade on OpenWrt 25.12 that is refused leaves the router without Forkop, shown as a deliberate user stop, with no automatic repair. Likely triggers are a rate-limited or unreachable GitHub API and a small overlay. The user's first Start can then fail ('managed upgrade sing-box provenance did not resolve safely').

**Proposed fix.** Run every refusal check (previous release, staging, preflight, free space) before stop_old_sing_box_before_forkop_upgrade. On any failure, restart Forkop with start-and-wait if it was running, and remove the marker. Have upgrade_bounded_stop pass FORKOP_STOP_SOURCE=component, so the stop is internal under D-15 and keeps the ownership guard.

---

## UC-197

- **Severity:** P2
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-5`
- **Проверка:** подтверждено (P3); подтверждено (P2)
- **Этап:** SD
- **Связь:** UC-028 covers the removal and Full uninstall variants; this is the upgrade variant. Related to UC-026. Pre-existing; 1.0.28 only changed the exit code from 1 to 2.
- **Файлы:** forkop/files/usr/lib/service/package.uc:101-118,207-230; forkop/files/usr/lib/service/lifecycle.uc:1259-1277

**A refused package stop during opkg/apk upgrade leaves ForkopTable and ip rule 105 with no listener (pre-existing; upgrade variant of UC-028)**

**Evidence.** package.uc:207-230 prerm_cleanup ignores the result of `env FORKOP_STOP_SOURCE=package /etc/init.d/forkop stop`. For any action, including upgrade, it then runs:
- restore_dnsmasq_if_needed();
- remove_managed_sing_box(), which stops and disables the sing-box init script and unlinks it, the binary and cronet;
- remove_rt_tables_entry().

With a second sing-box present, the internal stop is refused by stop_main (lifecycle.uc:1273-1277, now exit 2) before the nft and ip rule teardown.

postinst wait_for_upgrade_sing_box_exit (package.uc:101-118) counts the foreign process too, times out and does not start Forkop.

**Reproduction.** /tmp/claude-0/delta-lifecycle/r7/repro_prerm_refusal.sh runs real package.uc `prerm upgrade` with real init.d, initd.uc, lifecycle.uc and state.uc, plus a stub managed sing-box init. Output: 'forkop stop exit=2', 'sing-box init stop/disable', Forkop's sing-box gone, the other sing-box running, ForkopTable PRESENT, rt_tables entry removed.

The pre-merge tree gives the same result with exit 1 (/tmp/claude-0/delta-lifecycle/pre/repro_prerm_refusal.sh).

**Impact.** After `opkg upgrade` or `apk upgrade` with a managed sing-box variant while another sing-box runs, three things remain with nothing listening: ForkopTable, the fwmark rule at priority 105, and the table-105 routes. TPROXY'd traffic (IP and subnet rules) is black-holed with no owner until manual cleanup.

The consequence is P1-class, but the trigger is narrow, so this is rated the same as UC-028. The delta did not introduce it.

**Proposed fix.** prerm should fail closed: on any non-zero stop status, skip remove_managed_sing_box and remove_rt_tables_entry and return non-zero. Alternatively, tear down Forkop's own nft table and ip rules, which need no ownership proof, before refusing.

---

## UC-198

- **Severity:** P2
- **Источник:** delta-аудит после паузы, направление «routing/rule-set cache changes after the pause», исходный id `ROUTING-CACHE-1`
- **Проверка:** подтверждено (P2); подтверждено (P2)
- **Этап:** SD
- **Связь:** UC-096 and UC-103 (decided-but-wrong resolver answers in Diagnostics; here autotune is affected too, unlike UC-096), UC-187 (FUTURE item that requires failing closed), UC-052 (stub divergence), section 7 do-not-touch for routing/resolve.uc, section 13 row cbb2daf9 ("new code, not audited"). Not a section-11 regression, but it undoes the verified fail-closed property of the resolver (INVENTORIES, resolver section).
- **Файлы:** forkop/files/usr/lib/routing/resolve.uc:209-217 (rule_set_holds), :270-281; tests/routing_resolve_rule_set.sh:18-26 (stub)

**The resolver reads stdout, but sing-box `rule-set match` prints matches to stderr, so every local list answers "no" and list-owned connections get a confident wrong owner**

**Evidence.** resolve.uc:211-216 runs `sing-box rule-set match ... 2>/dev/null` and returns "match" only when `index(output, "match") >= 0` on stdout. Otherwise, on exit 0, it returns "no". Upstream cmd/sing-box/cmd_rule_set_match.go (v1.9.0, v1.10.0, v1.11.0, v1.12.0 and stable) reports a hit with Go's builtin `println(F.ToString("match rules.[", i, "]: ", currentRule))`, and the builtin println writes to stderr; a Go one-liner confirms 0 bytes on stdout. I ran a real sing-box v1.12.0 built from source (`go install github.com/sagernet/sing-box/cmd/sing-box@v1.12.0`) against `youtube.srs` with `www.youtube.com`: stdout=[] and stderr=[match rules.[0]: domain/domain_suffix=<binary>], rc=0. The rc is 0 whether or not anything matches. The commit's test stub prints the hit to stdout (`echo "match rules.[0]: ..."`), which real sing-box never does, so routing_resolve_rule_set.sh passes while production behaves differently (the same class of stub divergence as UC-052). ruleset_cache.uc:570-605 rewrites every remote rule set, community lists included, to `type: local`, so on a router this covers practically every list rule.

**Reproduction.** sh /tmp/claude-0/delta-routing-cache/resolver/repro.sh. It uses the real sing-box at /tmp/claude-0/delta-routing-cache/bin/sing-box.
Scenario A, a zapret rule `rule_set: yt` with target www.youtube.com: the resolver returns {decided, rule:null, kind:"direct"}, while sing-box routes it to youtube-out.
Scenario B, rule 0 `rule_set: yt -> vpnlist-out` above rule 1 `domain_suffix youtube.com -> youtube-out`: the resolver returns {decided, rule:1, section:"youtube"}, while sing-box uses rule 0. At cbb2daf9^ the same input gives {undecidable, undecidable_matcher, rule:0}.

**Impact.** Every rule_set matcher on a local list is decided "no". Before cbb2daf9 these were undecidable (fail closed), and the inventories record "0 guesses" for the resolver. Now the answers are decided and wrong, which breaks the "never guessed" invariant (18) that UC-096 cites.
(a) Diagnostics "Check site" and route_trace, which RO users can reach, show "Direct · No rule matched" (simulated) for every domain held in a community or remote list.
(b) autotune groups/plan/verify/apply (manager.uc:308, apply.uc:184): a list-only DPI rule never owns its targets, so the list-target feature (9a728294 together with this commit) does nothing on real hardware. Worse, when a list rule sits above a rule with a static matcher for the same domain, the lower rule is decided as the owner, and autotune can tune and apply nfqws_opt to a zapret rule that does not carry that traffic.
This contradicts section 7 do-not-touch: resolve.uc may change only in undecidable edge cases, and this commit turns a whole matcher class from undecidable into decided.

**Proposed fix.** Read the answer from stderr (`2>&1`, or stderr to a temp file with stdout discarded) and require a line that starts with `match rules.[`. Treat any other non-empty output as "unknown". Replace the stub in routing_resolve_rule_set.sh so it prints to stderr the way real sing-box does. Add a test against a real `sing-box rule-set match` when the binary is available, with a loud SKIP otherwise. Until this is fixed, revert to undecidable (fail closed) rather than ship decided answers.

---

## UC-199

- **Severity:** P2
- **Источник:** delta-аудит после паузы, направление «LuCI/UI changes after the pause: e1d74bbc», исходный id `UI-PAGES-2`
- **Проверка:** подтверждено (P2); подтверждено (P2)
- **Этап:** SD
- **Связь:** UC-008 (part b) and the Phase B S2 follow-ups. REGRESSION of section 11 S2 DONE, introduced by e1d74bbc. UI-PAGES-1 makes it worse: no reload-failure notice.
- **Файлы:** /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/page/rules.js; /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/configform.js; /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js; /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js; /home/user/forkop/tests/helpers/luci_form_harness.js; /home/user/forkop/tests/luci_settings_section_references.sh

**The Rules page saves deleting or disabling the rule that Settings uses for DNS or proxied downloads, because the Phase B S2 refusal stayed on the Settings page**

**Evidence.** The refusal is implemented only in Settings options. settings.js:61-140 holds keepUnavailableSectionChoice and currentSection; currentSection reads `option.map.lookupOption("enabled", name)` and uci.get. The validators are at settings.js:167, :214 and :246. section.js:9837-9868 (handleRemove wrapper) only UNDOES a removal when *another field* refuses the page save; its comment says so: 'e.g. a Settings select on this rule'. Before e1d74bbc the grid and the Settings tabs shared one form.Map. Now page/rules.js:14-35 builds a map that holds only the GridSection, and settings.createSettingsContent is called only from page/settings.js. LuCI's GridSection.handleRemove removes the section and then calls map.save(null, true) silently. The backend rejects the result: validator.uc:983-986 says "DNS through a section references missing rule ... / disabled rule ... Aborted." (pinned by tests/config_validator_detour.sh:40-43). validate_start_config runs first in reload (lifecycle.uc:2092) and in start (lifecycle.uc:1046). The tests stay green because tests/helpers/luci_form_harness.js:1094 ('The rules grid as page/settings.js declares it') and openSettings (:1149-1196) still build the old combined map. tests/luci_settings_section_references.sh:97-113 and :140-185 exercise only that layout, which no longer ships. The protections came from Phase B S2 commits 85e10047, d4f844fb, 9dceb57c and f5125a1c, all ancestors of 8b5082b8.

**Reproduction.** Run `node /tmp/claude-0/delta-ui-pages/repro/rules_page_refs.js`. It loads the real page/rules.js, configform.js and section.js on the harness LuCI form model (24.10 and 25.12) with settings.dns_detour_enabled=1 and dns_detour_section=vpn. Output: '24.10 Rules page remove: vpn in staged uci = null, saved data.vpn = undefined, settings.dns_detour_section = vpn, notifications = []'; '24.10 Rules page disable: save error = null, data.vpn.enabled = 0'. For the same action the old combined layout reports 'The rule was not removed because the page could not be saved: ... The selected section no longer exists' and keeps vpn. 25.12 gives the same results.

**Impact.** This is a normal admin action: deleting, or unticking Enable on, the VPN/connection rule used for 'DNS through a section' or 'download lists/components via proxy'. It is staged without a warning and goes out with Save & Apply. The committed /etc/config/forkop then fails backend validation. The triggered reload aborts: the old runtime keeps running, config and runtime diverge, and health shows an error. LuCI shows its generic success, because the Forkop notice is dead (UI-PAGES-1). The next start or reboot refuses to start Forkop at all, so every Forkop route (VPN/DPI rules, DNS) is gone. The Settings page then refuses every Settings save until the section is re-pointed. This undoes the Phase B S2 extension of UC-008: 'Every selected section is checked as the save leaves it: ... the Enable checkbox of its rules grid row, its removal'.

**Proposed fix.** Do the reference check where rules change. In section.js configureSectionSection: (1) in the handleRemove wrapper, before calling the base, check whether settings.dns_detour_section, download_lists_via_proxy_section or download_components_via_proxy_section (with its enable flag) names this rule; if so, refuse and undo with the existing message; (2) give the grid 'enabled' Flag a validate that refuses '0' for such a rule. Share describeUnavailableSection/currentSection between settings.js and section.js through a helper. Make the harness build pages from the shipped files: the Rules page from page/rules.js + configform.js, the Settings page from page/settings.js with no grid. Port the luci_settings_section_references.sh removal/Enable cases to the Rules page on 24.10 and 25.12.

---

## UC-200

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Autotune changes after the pause», исходный id `AUTOTUNE-1`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S9
- **Связь:** UC-031; contradicts approved D-4(a) ('без молчаливого снижения probes'); plan 13.2 already marks d2afaa32 as CONFLICTING_FIX — this adds the stability-semantics and UI evidence. Not a regression of a Phase B fix (S9 not started).
- **Файлы:** forkop/files/usr/lib/autotune/isolation.uc, forkop/files/usr/lib/autotune/manager.uc, forkop/files/usr/lib/autotune/state.uc, forkop/files/usr/lib/autotune/select.uc, fe-app-forkop/src/forkop/tabs/autotune/initController.ts

**Probe clamp lowers the requested probe count without telling the user, which contradicts approved D-4(a) and makes the stability rule stricter**

**Evidence.** isolation.uc:921-937: with 'max:<n>' the count becomes int(32/len(supported)), and the run is refused below 3. manager.uc tune_target always passes 'max:'+policy.probes. The source-port budget did not change: isolation.uc:56-57 is still 61000-61031, apply.uc:90 has VERIFY_PORT_FIRST/LAST 61000/61031, and contract.uc:406,553 default to [61000,61031]. probes_requested and probes_per_candidate exist only in the full tune output. state.uc summarize (lines 98-113) drops them, and the UI never reads the full output (no autotuneTarget call in fe-app-forkop/src). The policy dialog still says 3–7: initController.ts:479 numberInput('probes',…,3,7) and :530 '3–7 attempts per strategy and target in each check.' select.uc:21 sets STABLE_RATIO 0.8. Repro stab.uc gives 3/4 -> unstable, 4/4 -> stable, 4/5 -> stable.

**Reproduction.** ucode -L forkop/files/usr/lib /tmp/claude-0/delta-autotune/stab.uc; tests/autotune_select.sh 'max:5' case shows probes_per_candidate=floor(32/n)=4

**Impact.** The default policy is 5 probes. With policy 5, 6 or 7 and the 8 supported TCP candidates, every run actually uses 4 probes per candidate. One failed probe out of 4 is 0.75 < 0.8, so the candidate becomes 'unstable'. With 5 probes the same single failure (4/5) is still 'stable'. Groups therefore fall into no_stable_candidate or candidate_not_stable_for_all more often. Meanwhile the policy and UI keep showing 5 and promise 3–7 attempts; the only hint is the per-candidate 'success / attempted' text. There is no headroom either: an 11th supported candidate gives int(32/11)=2 < 3, which is a hard too_many_probes refusal again, the UC-031 situation.

**Proposed fix.** Implement D-4(a): ports 61000-61063 and MAX_TUNE_PROBES_TOTAL=64. Change all three copies of the range together (isolation.uc PORT_LAST, contract.uc sport_range defaults, apply.uc VERIFY_PORT_LAST) and keep the ip_local_port_range check. Keep the clamp only as a fail-closed guard. When it does fire, store probes_per_candidate and probes_requested in the summary and show 'N of requested M' in the UI. Add a test that LIMITS.probes[1] × supported TCP candidates fits the budget.

---

## UC-201

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Autotune changes after the pause», исходный id `AUTOTUNE-2`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S9
- **Связь:** Invariant 1 (inventory A11: RO commands read-only), UC-187 (feature now RESOLVED_EXTERNALLY). No RO->admin bypass: no new RO ACL grants, forkop-ro env -i is used. Not a regression of S1 fixes.
- **Файлы:** forkop/files/usr/lib/autotune/manager.uc, forkop/files/usr/lib/autotune/lists.uc, fe-app-forkop/src/forkop/tabs/autotune/initController.ts

**Read-only autotune_status and autotune_groups now run sing-box, DNS lookups and tmpfs writes for rule-list targets, with no single-flight**

**Evidence.** Both autotune_status and autotune_groups are in the read ACL (acl.d json:17-18, via forkop-ro). status() (manager.uc:245-250) and groups() (manager.uc:326-330) call expand_targets (manager.uc:187-201), which calls lists.expand (lists.uc:118-150). On a cache miss that does three things: (1) source_of runs mktemp -d in /tmp and then `sing-box rule-set decompile` (lists.uc:63-70); (2) sample() runs dig +time=2 for up to 4×sample hosts (lists.uc:100-118); (3) it runs `mkdir -p` and writes the cache (lists.uc:147-148). groups() also runs production_dns once per member. The cache key includes the list mtime, so every daily list update causes a miss; the retry TTL is 600 s; the cache is written only when expansion ends. In the UI, loadStatus (initController.ts:113-115) sets statusLoadedAt at the start of the call and has no in-flight guard, and the timer fires every 3 s while a run is going (:1510-1522). target_set (manager.uc:451ff) checks only valid_tag, so any local rule set is accepted; tests/autotune_rule_lists.sh itself adds 'gone-list' (direct-out) and 'dead-list' (no rule). Repro ro_status_side_effects.sh: one concurrent status+groups pair with a cold cache ran sing-box decompile twice and dig 13 times, created STATE_DIR as 0755 (ensure_state_dir at manager.uc:367 would use 0700) and wrote the cache 0644. Repro status_latency.sh: with the target resolver unreachable, a single status call takes 25 s with sample 3 and 64 s with sample 8, per list target. Repro dom.uc: parsing a 100k-domain list peaks at 37 MB and takes 7.5 s on x86; 300k peaks at 94 MB and takes 23 s.

**Reproduction.** bash /tmp/claude-0/delta-autotune/ro_status_side_effects.sh; bash /tmp/claude-0/delta-autotune/status_latency.sh; ucode -L forkop/files/usr/lib /tmp/claude-0/delta-autotune/dom.uc <list>.json

**Impact.** The A11 inventory says status and groups 'write nothing'; that is no longer true. A read-only session now starts root processes (sing-box, dig), creates directories and writes files. After any cache miss (daily list update, reboot, retry TTL), the autotune page for read-only users and admins repeats the same decompile and DNS work on every poll. With a dead resolver each poll lasts tens of seconds, and with no in-flight guard the polls pile up as ucode, sing-box and dig processes on a small router. A killed call leaks /tmp/forkop-autotune-list.* (tmpfs). merge() also re-expands while holding STATE_LOCK. A read-only user can also see up to 8 domains and the total size of any local list an admin targets, including lists of non-DPI rules. No secrets are exposed: only tag, counts, domains and rule label.

**Proposed fix.** Make status and groups read only the tmpfs sample cache, and show 'sample pending' when it is absent. Expand only in admin or worker paths (run, target-set) behind a lock, so concurrent calls do not repeat the work. Create the cache directory with ensure_state_dir (0700) and write files 0600. Put a timeout and a size limit on decompile and clean up leftover temp dirs. Accept in target_set only lists from rule_lists(), as list_domains already does. Add an in-flight guard to loadStatus.

---

## UC-202

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Autotune changes after the pause», исходный id `AUTOTUNE-3`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S9
- **Связь:** UC-032 / D-7: applicability is still decided only inside the apply.uc plan; this is a remaining case for D-7(a) 'not_applicable/no_change with explanation'.
- **Файлы:** forkop/files/usr/lib/autotune/groups.uc, forkop/files/usr/lib/core/dpi_strategy.uc, forkop/files/usr/lib/autotune/manager.uc, forkop/files/usr/lib/autotune/apply.uc

**Rule on the default strategy gets a 'confirmed' fake_multidisorder recommendation that can never be applied**

**Evidence.** catalog.uc:39 fake_multidisorder is word for word the TCP/443 profile of ZAPRET_DEFAULT_NFQWS_OPT (constants.uc:145). dpi_strategy.view returns 'default' for an empty or default option (dpi_strategy.uc:96-107) and never a catalog id. groups.uc aggregate reports no_change only when candidate == current, so it reports 'recommendation'. apply.uc:650 plan then returns no_change_required, because splice.opt == effective(current). In manager.uc:607 the no_change_required branch sets no record.outcome. Readiness is reset only when outcome.reset is set (manager.uc:764 for auto, :916 for manual), so the group stays ready. Repro equiv.uc: 'splice==default: true'; aggregate(...,'default') returns status 'recommendation', candidate 'fake_multidisorder'.

**Reproduction.** ucode -L forkop/files/usr/lib /tmp/claude-0/delta-autotune/equiv.uc

**Impact.** This happens when a rule runs the default strategy (empty option) and measurement picks fake_multidisorder, i.e. what is already running for TCP/443. The card shows 'Recommendation confirmed' with an Apply button. Every Apply ends with 'No change was needed' and the button stays, permanently. In auto mode, each time the group's turn comes it re-plans and adds another no-change apply record (state.applies is capped at 20), and history records the recommendation event. The result never converges and misstates the situation.

**Proposed fix.** In the group layer, treat 'default' as equal to the catalog candidate whose splice equals the effective default (for example, compare effective strategies through tcp443_splice in groups.aggregate or compute_groups) so the result is no_change. Also let a no_change_required apply reset pending and ready.

---

## UC-203

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Autotune changes after the pause», исходный id `AUTOTUNE-4`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S9
- **Связь:** UC-032 / D-7 (remaining not_applicable cases).
- **Файлы:** forkop/files/usr/lib/core/dpi_strategy.uc, forkop/files/usr/lib/autotune/apply.uc, forkop/files/usr/lib/config/migration.uc

**Legacy default strategy counts as non-custom 'default', so autotune splices its hostlist profile into a strategy the runtime validator rejects**

**Evidence.** dpi_strategy.uc:97 lists ZAPRET_LEGACY_DEFAULT_NFQWS_OPT among the defaults and compares normalized text, so the rule is custom=false and autoapply and manual apply proceed. migration.uc:686-694 converts the legacy default only on an exact string match. On the legacy default, tcp443_splice picks profile 1 ('--filter-tcp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt …'); the later '--filter-tcp=443 <HOSTLIST>' profile is untouched. providers/nfqueue/validator.uc:225 accepts the legacy default only verbatim. Repro legacy.uc: the spliced result is rejected with "Unsupported NFQWS token '<HOSTLIST>'", and view() of the spliced string reports it as custom. snapshots.uc:632-633: validate-runtime fails, the old file is written back and the service reloads, giving 'recovered'. apply.uc then reports reload_failed_recovered, and autoapply.outcome counts it as a failure with cooldown and a history failure entry.

**Reproduction.** ucode -L forkop/files/usr/lib /tmp/claude-0/delta-autotune/legacy.uc

**Impact.** A rule that still holds the legacy default (for example a whitespace variant that the exact-match migration missed) is treated as applicable. Every apply, automatic after each cooldown or manual, costs a guarded service reload and is recorded as a failed autotune apply. Even if the validator accepted it, only the google-hostlist profile would change, so targets outside that list would keep the old strategy while the apply reports verified. Narrow reachability.

**Proposed fix.** Classify the legacy default as custom in view(), or migrate the normalized legacy default. In plan, run the providers/zapret validator on splice.opt before build_candidate. Refuse to splice a profile that carries --hostlist*, --ipset* or <HOSTLIST>.

---

## UC-204

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Autotune changes after the pause», исходный id `AUTOTUNE-5`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S9
- **Связь:** UC-032 / D-7(b) (FUTURE); invariant 8 (exactly one semantic change: the diff proves one option changed, not that the other traffic classes are equivalent).
- **Файлы:** forkop/files/usr/lib/core/dpi_strategy.uc, tests/dpi_strategy_splice.sh

**tcp443_scope treats a profile that filters both TCP/443 and UDP/443 as 'exact', so the splice drops its UDP/QUIC strategy (latent)**

**Evidence.** dpi_strategy.uc:39-50: once --filter-tcp=443 is seen, the udp flag is ignored ('return tcp == "443" && !other ? "exact"'). Repro tcpudp.uc: '--filter-tcp=443 --filter-udp=443 --dpi-desync=fake --dpi-desync-fake-quic=…' is classified exact, and the splice yields '--filter-tcp=443 --filter-udp=443 --dpi-desync=multisplit …'. tests/dpi_strategy_splice.sh has no such case. The commit message and the test header promise that a profile taking TCP/443 together with other traffic is never split.

**Reproduction.** ucode -L forkop/files/usr/lib /tmp/claude-0/delta-autotune/tcpudp.uc

**Impact.** Not reachable today. Such strategies are custom in view(), and the manager refuses custom before any plan (autoapply.decide and manual_fresh both return custom_strategy_kept). However, apply.uc plan and stale_reason rely only on tcp443_splice to prove that the other traffic of the rule is unchanged. Production verification checks TCP only. If applicability is widened (the D-7(b) direction), the rule's QUIC handling would change silently under a 'verified' apply.

**Proposed fix.** Return 'shared' when --filter-udp, --filter-l3 or --filter-l7 appears in the same profile as --filter-tcp, and add the case to dpi_strategy_splice.sh.

---

## UC-205

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Autotune changes after the pause», исходный id `AUTOTUNE-6`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S9
- **Связь:** UC-032 / D-7 (applicability extension by owner in 55f329e3).
- **Файлы:** forkop/files/usr/lib/autotune/apply.uc, forkop/files/usr/lib/core/dpi_strategy.uc, forkop/files/usr/lib/config/migration.uc

**An apply turns 'follow the Forkop default' into a frozen explicit copy that a later default change will neither migrate nor recognise**

**Evidence.** apply.uc:194 effective() plus plan :643-656 write the whole current default, with only its TCP/443 profile replaced, into nfqws_opt ('Пустая стратегия делается явной'). dpi_strategy.view recognises a spliced default only against the current constants.ZAPRET_DEFAULT_NFQWS_OPT (dpi_strategy.uc:110-116). The default has changed before: ZAPRET_LEGACY_DEFAULT_NFQWS_OPT (constants.uc:144) needed migrate_zapret_nfqws_default, which matches the exact old string only (migration.uc:686-694).

**Reproduction.** —

**Impact.** Before the apply, an empty option tracks the shipped default; after it, the rule holds a pinned copy of today's HTTP and QUIC profiles, including file paths such as /opt/zapret/files/fake/quic_initial_www_google_com.bin. When the default next changes, three things follow for every rule autotune touched: the HTTP/QUIC profiles stay stale; the exact-match migration does not recognise them; and view() classifies the rule as custom, so autotune refuses it (custom_strategy_kept) and the UI shows 'custom strategy'. Rollback still restores the empty option.

**Proposed fix.** Record the provenance of the materialised default in the autotune apply record (or a UCI flag), and recognise or migrate spliced copies of any known historical default. Alternatively, keep the non-TCP/443 profiles referenced to the default rather than copied.

---

## UC-206

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Autotune changes after the pause», исходный id `AUTOTUNE-7`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S9
- **Связь:** S4 Commit E (operator rollback availability); inventory A11 'UI poll timeout' note; UC-187 feature.
- **Файлы:** forkop/files/usr/lib/autotune/policy.uc, forkop/files/usr/lib/autotune/lists.uc, forkop/files/usr/lib/autotune/manager.uc, forkop/files/usr/lib/autotune/isolation.uc

**List members are not counted against MAX_TARGETS, so one run can hold the worker lock for hours and block operator rollback and manual apply**

**Evidence.** policy.uc:43 MAX_TARGETS=16 counts configured sections, and lists.uc:27 MAX_SAMPLE=8, so up to 128 targets are measured. A scheduled run measures every member of the chosen group (manager.uc:551 choose plus the run_locked loop). Per target that is up to 32 probes × 10 s (probe.uc:12 MAX_TIME) plus a hold of up to 300 s (isolation.uc:87, raised from 65 s by 211b6598; about 150 s for blocked targets on GL-MT6000 per that commit). The worker flock is held for the whole run. operator_rollback (manager.uc:949-952) and manual_apply refuse with autotune_worker_running. There is no stop command in the CLI or UI, and the UI stops following the job after 20 min (initController.ts:61).

**Reproduction.** —

**Impact.** Lists of a blocked service are exactly the intended use. With them a run lasts hours (e.g. 24 members × about 5 min ≈ 2 h; worst case 128 members, 10 h or more). For that whole time the autotune Rollback and Apply actions are refused and the page stops tracking the job. Recovery is still possible through a snapshot restore, so this is not P2.

**Proposed fix.** Count expanded members against a measured-target budget per run, or rotate members across runs. Bound the run duration. Add an admin 'autotune_stop' command, using the existing SIGTERM 'interrupted after current target' handling, or let operator_rollback preempt a measuring run.

---

## UC-207

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Autotune changes after the pause», исходный id `AUTOTUNE-8`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S9
- **Связь:** UC-187 feature (9a728294).
- **Файлы:** forkop/files/usr/lib/autotune/policy.uc, forkop/files/usr/lib/autotune/lists.uc, forkop/files/usr/lib/autotune/manager.uc

**List member ids (<id>__<n>) can collide with ordinary target ids, so results go to the wrong host and are lost**

**Evidence.** policy.uc:88-89 valid_target_id allows '_' ([A-Za-z0-9_]{1,32}). lists.uc:153 builds member ids as id+'__'+n. target_set (manager.uc:451ff) does not check either direction. summary_of (manager.uc:206) checks the host only for list members. forget_target (manager.uc:446) deletes every key starting with id+'__'. Repro id_collision.sh: host target 'ytl__1' is accepted next to list target 'ytl'; status shows two 'ytl__1' entries; the group targets are [...,'ytl__1','ytl__2','ytl__3','ytl__1']; the run measures m.youtube.com twice and never the host target www.youtube.com; target-remove ytl deletes the host target's results.

**Reproduction.** bash /tmp/claude-0/delta-autotune/id_collision.sh

**Impact.** The group is measured and confirmed from duplicated and mismatched results, the host target is never measured, and it shows another host's result. Removing the list target erases the host target's state. No unsafe production change: apply re-derives the plan from the measured host.

**Proposed fix.** Reject target ids containing '__', or validate both directions in target_set and policy.read (a host id must not match /^<list id>__[0-9]+$/). Alternatively, use a member separator that a UCI section name cannot contain.

---

## UC-208

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «VPN kill-switch», исходный id `KILLSWITCH-4`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S8
- **Связь:** D-15 (approved (a)): consistent with D-15's 'reload does not start a stopped service', but the kill-switch relies on reload for teardown, which D-15 suppresses. UC-056.
- **Файлы:** forkop/files/usr/lib/service/initd.uc:1121-1147; forkop/files/usr/lib/service/lifecycle.uc:2044-2053,2459-2465,2193,2421; luci-app-forkop/.../killswitch.js:164-168,256-260; tests/killswitch_sync.sh:182-194

**While Forkop is stopped by the user or not started (D-15), turning off or deleting a protected section, or restoring a snapshot without it, never lifts the block, but the UI says it lasts only until the next reload**

**Evidence.** The policy is refreshed only from lifecycle start_impl and reload (lifecycle.uc:1238,2193,2421). Under D-15(a), every reload of a user-stopped or not-started runtime is skipped before reaching that code (initd.uc reload_begin_value:1146, lifecycle reload_tracked:2464). A snapshot restore while stopped ends as restored_not_started, with no reload. The section badge reads 'Still enforced until the next successful reload' (killswitch.js:167), but D-15 guarantees no such reload happens while stopped. sync_killswitch test case 7, 'Unchecking the option lifts everything, even while Forkop is stopped', calls `ks sync reload` directly, which production never does in that state. The Overview Stop action and the 'stopped by user' health state say nothing about the kill-switch. Only Settings > Network shows 'stopped: protected traffic is blocked'.

**Reproduction.** Code path: with Forkop user-stopped, untick kill_switch and Save & Apply. procd's config trigger leads to initd reload_begin_value, then reload_skipped_after_stop, which returns {action:skip}. killswitch_sync is never reached, so the include, table and DNS block list stay. Only an explicit Start or 'Remove protection now' clears them.

**Impact.** A user who stops Forkop to get a direct connection and then turns the kill-switch off, or deletes the section, or restores an older snapshot, still has protected destinations rejected and protected names NXDOMAIN, with UI text pointing to a reload that will never run. A workaround exists (the Remove button), so this is P3 rather than a black-hole with no owner.

**Proposed fix.** Run killswitch sync, or teardown when no section is protected, on the D-15 skip path. It needs no runtime when names are empty, and the live table is not needed for teardown. Alternatively, call killswitch_sync from the config-change trigger independently of the runtime. Fix the badge text and mention the kill-switch in the Stop confirmation and the 'stopped by user' status. Make test case 7 drive the real reload entry point.

---

## UC-209

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «VPN kill-switch», исходный id `KILLSWITCH-5`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S8
- **Связь:** Same root cause as KILLSWITCH-2 (the render trusts that live state matches UCI). No UC card.
- **Файлы:** forkop/files/usr/lib/service/lifecycle.uc:2241,2296-2308,2421; forkop/files/usr/lib/nft/apply.uc:1882-2009; forkop/files/usr/lib/killswitch/runtime.uc:943-953

**A reload whose list source changed refreshes the kill-switch from the new UCI order on top of the old, not rebuilt runtime, and can reject traffic that the running Forkop deliberately sends direct**

**Evidence.** When plan.needs_list_update==1 && changed_list==1, reload skips the nft rebuild and the sing-box transition (lifecycle.uc:2241, 2213-2214) and leaves them to the list worker's later list-content reload (LIST_UPDATE_RELOAD_FILE, :2307). It still reaches killswitch_sync at :2421. The renderer builds rules and order from the current UCI (uci_sections) but copies set elements from the old live ForkopTable. The same mismatch happens with a manual `forkop killswitch_sync` / LuCI 'Re-apply now' while committed changes wait for a reload.

**Reproduction.** /tmp/claude-0/delta-killswitch/real_render.sh in `unshare -rn` with real nft. The live table was built from orderA.uci: bypass `byp` 93.184.216.0/24 first, then protected `vpn` 93.184.216.0/24 + 1.2.3.0/24. The live priority_rules return/accept byp first. The kill-switch was then rendered from orderB.uci: vpn moved above byp and a remote_subnet_list added, which is a changed list source. Output: `priority_rules ... ip daddr @forkop_rule_vpn_subnets counter name ks_vpn jump ks_reject` with elements { 1.2.3.0/24, 93.184.216.0/24 }, and no earlier byp return.

**Impact.** From that reload until the list worker finishes its list-content reload, which may be much later if the download fails, the running Forkop sends 93.184.216.0/24 direct (old bypass first) and the forward-hook kill-switch rejects it. The user gets a black-hole while Forkop is running after an ordinary edit: reorder plus list change, or action bypass→connection plus list change, in one apply.

**Proposed fix.** Do not sync at the end of a reload that deferred the nft rebuild (changed_list && needs_list_update); the list-content reload syncs. More generally, render from the configuration the live table was built from, using a fingerprint check, or refuse the sync when the external config fingerprint differs from the committed reload state. Serialize manual killswitch_sync with reload.lock.

---

## UC-210

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «VPN kill-switch», исходный id `KILLSWITCH-6`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S8
- **Связь:** Repeats the UC-011 defect class in new code (Phase B section 11: UC-011 FIXED, core/runtime_lock). Lock order in service/state.uc (S3).
- **Файлы:** forkop/files/usr/lib/killswitch/runtime.uc:53,134-146,179-205,1005-1028,121-132,884-910; forkop/files/usr/lib/dns/apply.uc:158-165; forkop/files/usr/lib/service/package.uc:225-226; forkop/files/usr/bin/forkop:244-246

**The new killswitch.lock is a PID-only directory lock with racy stale cleanup, outside core/runtime_lock, and manual sync is not serialized with reload.lock**

**Evidence.** acquire_lock (runtime.uc:184-200) treats the lock as stale only when /proc/<pid> is missing, so a live, reused PID blocks it for 60 s. Two waiters can both unlink and rmdir the 'stale' lock, and the second can remove the first's fresh lock, which is the race UC-011 fixed with core/runtime_lock (pid plus start ticks plus exe, owner record published with the directory). core/runtime_lock.uc exists and is not used. write_atomic writes to a fixed `<path>.tmp`, so two holders can interleave writes to the include and state. killswitch_sync and killswitch_disable from the CLI or LuCI take only killswitch.lock, not reload.lock. Their dns_refresh computes 'blocking' from the dhcp UCI at that moment and commits dhcp concurrently with lifecycle's dnsmasq_configure/restore.

**Reproduction.** /tmp/claude-0/delta-killswitch/lock: wrote <run>/killswitch.lock/pid holding the PID of a live unrelated `sleep 300`, then ran `runtime.uc disable "package removal"`. It returned rc=1 after 60 s and removed nothing. prerm (package.uc:226) ignores that failure and removal continues, leaving the include, table and DNS block list behind.

**Impact.** A crashed sync combined with PID reuse within one boot makes package removal leave an ownerless policy (the KILLSWITCH-1 consequence) or makes reload syncs fail. Concurrent manual Re-apply during start/stop can leave the block list active while dnsmasq forwards to sing-box (protected names NXDOMAIN with Forkop running) or empty while stopped (DNS fail-open). A watcher that sees a stale /var/run/forkop.reload.lock never fails over to the standby (runtime.uc:823).

**Proposed fix.** Use core/runtime_lock (process_identity) for killswitch.lock. Use unique tmp names in write_atomic. Make the CLI/LuCI sync and disable take reload.lock in the documented order (reload.lock → killswitch.lock), or refuse while it is held. On prerm remove, fall back to unconditional removal of the include, table and serversfile when the lock cannot be taken. Use the lock-owner check for the watcher's reload.lock test.

---

## UC-211

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «VPN kill-switch», исходный id `KILLSWITCH-7`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S8
- **Связь:** Design consequence of c8d0d773; no UC card.
- **Файлы:** forkop/files/usr/lib/killswitch/runtime.uc:674-680,714-754,803-854; forkop/files/etc/init.d/forkop-killswitch; luci-app-forkop/.../settings.js (help text 'other traffic is not affected')

**Enabling the kill-switch on one section turns other, unprotected VPN sections from failing closed to leaking direct when sing-box dies**

**Evidence.** The watcher starts as soon as any section is protected. When sing-box stops answering while dnsmasq still forwards to it, the watcher redirects all LAN DNS to a standby dnsmasq that resolves every non-protected name through the original upstream (standby_config_text). ForkopTable stays in place after a sing-box crash, but domain-routed sections depend on FakeIP answers. With real IPs from the standby, their traffic matches no set and leaves through WAN.

**Reproduction.** Code path: with section A protected and section B unprotected (connection action, domains only), kill sing-box. After 3 failed probes, ks_dns redirects to :18054, B's domains resolve to real IPs, and mangle only marks FakeIP or IP-set destinations, so B goes direct. Without the kill-switch on A, DNS forwarding stays at the dead 127.0.0.42 and B's traffic does not leave.

**Impact.** The kill-switch on A quietly weakens B's failure behavior, which contradicts 'other traffic is not affected'. Users who rely on VPN sections without the option, expecting a dead sing-box to break rather than leak, get direct connections.

**Proposed fix.** Have the standby block every name routed to any Forkop connection outbound (or every FakeIP-routed name), not only kill-switch names, or make the standby fail-over an explicit option. At minimum, document the behavior in the option help and the status widget.

---

## UC-212

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «VPN kill-switch», исходный id `KILLSWITCH-8`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S8
- **Связь:** UC-025 (P2, S5 durable writes), UC-072 (flash wear), A8/A9 inventory.
- **Файлы:** forkop/files/usr/lib/killswitch/runtime.uc:121-132,213-216,269,901-903,998; forkop/files/usr/lib/dns/apply.uc:139-148

**The persistent include and DNS files are written without sync on flash, and state.json in /etc is rewritten on every start and reload**

**Evidence.** write_atomic and the dns/apply.uc servers-file writer do writefile+rename with no sync. The include under /usr/share/nftables.d (overlay, flash) holds the full copied set data: about 500 KB for a 30 000-prefix list (measured). It is rewritten whenever list content changes. state.json under /etc/forkop/killswitch is rewritten on every sync because updated_at changes, and on every failure (record_error). `armed` and `persistent` check only that the include exists.

**Reproduction.** Size measured in scratch: 30k random /24 list, real nft live table, then killswitch-render produced a 502 952-byte include whose set is identical to the live one. A power cut that empties the include could not be reproduced without hardware.

**Impact.** UC-025 class: after a power cut on UBIFS, a zero-length include or dnsmasq.servers silently removes protection for the boot window before Forkop starts, which is the window the feature exists for, while status still reports persistent. A partially written include (not reproduced) would make fw4 reject the whole ruleset at boot. There is also extra flash wear on every reload (UC-072 class).

**Proposed fix.** Write through a helper that fsyncs (as UC-025 proposes; for example `sync` after rename, or libuci-style write). Validate the persisted include with `nft -c -f` at watcher start and log or repair it. Write state.json only when content other than timestamps changes; move timestamps to /var/run.

---

## UC-213

- **Severity:** P3 (аудитор: P2)
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-1`
- **Проверка:** подтверждено (P3); подтверждено (P3)
- **Этап:** SD/S6
- **Связь:** Same class as UC-014, UC-053 and UC-058. Breaks invariants 13 and 14 and the S3 goal. Invalidates the UC-015 verification note. Contradicts the comment at action.uc:2382-2385. Introduces a new foreign-kill path after S3 removed the earlier ones.
- **Файлы:** forkop/files/usr/lib/service/state.uc:757-797; forkop/files/usr/lib/service/lifecycle.uc:1259-1316,1803-1823; forkop/files/usr/lib/components/action.uc:2371-2422,2495-2497; forkop/files/usr/lib/service/ui.uc:1159-1166; fe-app-forkop/src/forkop/tabs/dashboard/overviewCards.ts:103-128

**An explicit Stop or Restart, and the in-app upgrade when another sing-box runs, kill every process whose executable is named sing-box, including ones Forkop does not own**

**Evidence.** state.uc:757-769 signal_all_sing_box_processes walks /proc/*/exe and sends TERM, then KILL (state.uc:771-797), to every pid where pid_is_sing_box() matches (state.uc:474-480). That check only compares the basename to 'sing-box' or 'sing-box (deleted)'. It does not check procd ownership, argv or Forkop's config path.

lifecycle.uc:1311-1314 takes this path whenever stop() decides the stop is not internal (lifecycle.uc:1816-1820). A stop is internal only with FORKOP_STOP_SOURCE=package|component, FORKOP_INTERNAL_SERVICE_STOP=1 or the upgrade marker present. Callers that take the kill-all path:
- UI Stop and UI Restart (ui.uc:1480-1506 runs /etc/init.d/forkop stop|restart; rc.common restart is stop followed by start).
- LuCI Startup restart and `service forkop restart`.
- The Direct Proxy toggle (action.uc:2624) and component restarts (action.uc:962).
- The in-app Forkop upgrade's upgrade_bounded_stop(SERVICE_INIT) (action.uc:2388), which passes no FORKOP_STOP_SOURCE, whenever capture_managed_upgrade_sing_box_marker wrote no marker. write_managed_upgrade_sing_box_marker (state.uc:859-862) requires sing_box_runtime_provenance, i.e. exactly one sing-box process. So the marker is missing precisely when a second sing-box exists.

This contradicts action.uc:2382-2385 ('an unrelated sing-box must never be signalled from here') and the e7c4c9cf merge message, which says package and component stops keep the ownership guard.

The UI pushes users toward this. ui.uc:1163-1166 stop_available counts every sing-box process. overviewCards.ts:116-128 shows 'Stop Forkop X…' instead of Start when Forkop is down but any sing-box exists. The restart_blocked hint (overviewCards.ts:105-113) tells the user to use Stop to stop all sing-box processes.

Phase B code refused here: state.uc:600-603 says 'Do not kill by executable name here: ownership of a non-procd process is unknown'.

**Reproduction.** /tmp/claude-0/delta-lifecycle/r1/repro.sh, run under `unshare -r -p -f --mount-proc`, with a ubus stub that emulates procd's 'sing-box' service. Case A: Forkop's procd-owned sing-box plus a foreign process whose exe is .../sing-box (a copy of sleep). `ucode state.uc stop-all-sing-box-runtime 2` exits 0 and reports 'managed: gone; foreign: gone'.

**Impact.** A user's own sing-box is sent TERM and then KILL for up to about 21 s. Examples: HomeProxy's instances, a sing-box in a docker container, a manual `sing-box run`, another proxy manager. A foreign instance that procd respawns is killed repeatedly and can exhaust its respawn budget, which leaves that service down after Forkop's stop.

An in-app Forkop upgrade with a second sing-box present now kills it and continues. Phase B refused in that case ('Old sing-box processes have ambiguous ownership').

This breaks invariant 13, no signal to a process whose ownership is not proven, and the S3 goal 'никакой сигнал не уходит чужому PID'. It also invalidates the verification note on UC-015 ('Посторонний sing-box не убивается ... инварианты 13 и 14 не нарушаются').

**Proposed fix.** Never signal a process by executable name.
- An explicit Stop always tears down Forkop's own nft table, ip rules and DNS.
- It signals only processes proven to be Forkop's: the procd 'sing-box' instance by pid and start ticks, or `/usr/bin/sing-box run -c <forkop config_path>` checked through core/process_identity.
- Remaining foreign processes are reported to the user (pid, exe, argv), not killed.
- upgrade_bounded_stop must pass FORKOP_STOP_SOURCE=component.
- ui.uc stop_available and the hint should count only processes attributable to Forkop.
- Add a behavioural test with a foreign sing-box-named process inside a PID namespace.

---

## UC-214

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-10`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD
- **Связь:** S0 (UC-051 class); invariant 17 / D-20 as quoted in the test. Outside the lifecycle area, but introduced by e6c31a4d.
- **Файлы:** forkop/files/usr/lib/singbox/generator.uc (urltest_start_seed); tests/urltest_override_validation.sh

**tests/urltest_override_validation.sh fails about half the time since e6c31a4d (provider URLTest rotation uses a random seed per config generation)**

**Evidence.** Full backend run at HEAD: 249/250 pass. The one failure is urltest_override_validation: 'the URLTest groups must be generated as by 5eaa9349...'. Current outbounds are ["Native B","Native A"]; the baseline has ["Native A","Native B"].

Six reruns gave exit codes 0 1 1 0 0 1.

generator.uc urltest_start_seed() reads /proc/sys/kernel/random/uuid for every generation unless FORKOP_URLTEST_START_SEED is set, and no test sets it.

**Reproduction.** `for i in 1 2 3 4 5 6; do bash tests/urltest_override_validation.sh >/dev/null 2>&1; echo $?; done`

**Impact.** Breaks the S0 exit criterion of a deterministic suite and adds CI noise. A note for the generator area: the order of provider URLTest groups now changes on every regeneration, which conflicts with the test's invariant 17 / D-20 wording.

**Proposed fix.** Pin FORKOP_URLTEST_START_SEED in tests that compare generated configs, or derive the seed deterministically so unchanged input regenerates byte-identical output.

---

## UC-215

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-6`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S6
- **Связь:** UC-028 class. S3 stop serialization is unaffected.
- **Файлы:** forkop/files/usr/lib/service/lifecycle.uc:1743-1780; forkop/files/usr/lib/service/initd.uc:1077-1085

**The 'exit 2 leaves DNS with the running runtime' contract is false: stop_impl restores dnsmasq before the ownership check**

**Evidence.** stop_impl calls dnsmasq_restore(false) (lifecycle.uc:1745-1753) before stop_main's ownership gate (lifecycle.uc:1273-1277). On status 2 it returns early (lifecycle.uc:1758-1761) and skips shutdown_correctly, clear-reload-state and the failsafe.

initd.uc stop_finish (initd.uc:1077-1085) also skips restore_dnsmasq_failsafe for 2, with the comment 'DNS still belongs to the runtime that is serving it'. That premise does not hold.

**Reproduction.** /tmp/claude-0/delta-lifecycle/r5/repro_refusal_dns.sh: FORKOP_STOP_SOURCE=package with two sing-box processes. Event order: 'dns/apply restore' first, then 'state sing-box-process-conflict -> 0', then 'forkop stop exit=2'. Both sing-box processes keep running and ForkopTable stays.

**Impact.** After a refused package or component stop, sing-box and the nft table keep intercepting while client DNS no longer goes to sing-box. Fakeip and domain rules stop matching, so listed domains silently go direct.

A dnsmasq_restore failure is hidden behind the 2, and no failsafe runs.

The pre-merge order was the same, then followed by the failsafe. The new comments describe a property the code does not have.

**Proposed fix.** Run the ownership refusal before dnsmasq_restore in stop_impl, or keep the failsafe semantics for 2. Fix the comments at lifecycle.uc:1756-1759 and initd.uc:1079-1081.

---

## UC-216

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-7`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S6
- **Связь:** UC-014; invariant 14
- **Файлы:** forkop/files/usr/lib/service/state.uc:757-769

**The start-time 're-check' before each signal is a no-op and does not protect against PID reuse**

**Evidence.** state.uc:765: `if (ticks != null && ticks == process_start_ticks_for_pid(pid) && pid_is_sing_box(pid)) command_success_from_args([ "kill", signal, pid ]);`

Both start-tick reads happen back to back, before the identity check (a forked `readlink`) and before the forked `kill`. Nothing is read after the identity check, and nothing is compared with the enumeration.

The commit message claims it re-reads 'each process start time immediately before it signals so a reused PID is never hit'. The loop runs up to 21 iterations, each forking one readlink per /proc entry, which speeds up PID turnover (pid_max 32768 on OpenWrt).

**Reproduction.** Static. The race window is fork/exec of readlink and kill.

**Impact.** Narrow race. If a sing-box exits between readlink and kill and its PID is reused, TERM or KILL reaches an unrelated process (UC-014 class).

**Proposed fix.** Record pid, start ticks, exe and argv once with core/process_identity and re-verify immediately before each signal (signal_record), or use a pidfd. Restrict it to Forkop-owned processes (see LIFECYCLE-STOP-1).

---

## UC-217

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-8`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S6
- **Связь:** D-15: stop recorded while the runtime keeps running. UC-027.
- **Файлы:** forkop/files/usr/lib/service/lifecycle.uc:1600-1613,1803-1823; forkop/files/usr/lib/service/state.uc:859-925; forkop/files/usr/lib/components/action.uc:943-950,2495

**A leftover upgrade marker turns a user Stop into a guarded stop that refuses, keeps interception running and still records a user stop**

**Evidence.** lifecycle.uc:1816-1820 treats `fs.stat(MANAGED_UPGRADE_SING_BOX_MARKER) != null` as an internal stop, with no age or validity check. start_inner, by contrast, applies a 120 s maximum age (lifecycle.uc:1603-1609).

Only start_inner consumes the marker (state.uc:900-925). A failed or refused in-app upgrade (action_fail after action.uc:2495) leaves it in /tmp.

The refusal path still writes stop.requested by=user (lifecycle.uc:1803-1808).

**Reproduction.** /tmp/claude-0/delta-lifecycle/r6/repro_stale_marker.sh: marker with created_at=1 and two sing-box processes; a user Stop without FORKOP_STOP_SOURCE gives:
- syslog 'Refusing Forkop stop: sing-box process ownership is ambiguous', exit 2;
- both sing-box processes running and ForkopTable present;
- stop.requested 'by=user', marker still present.

**Impact.** The user's Stop does not end interception and is reported as a failure. stop.requested makes runtime_apply_allowed() false, so subscription updates and DNS failover stop applying to a runtime that is still running. The 1.0.28 explicit-stop behaviour stays disabled until a Start consumes the marker.

**Proposed fix.** In stop(), honour the marker only when it is valid and fresh (the same check as start_inner). Delete it in action_fail and cleanup_action.

---

## UC-218

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «routing/rule-set cache changes after the pause», исходный id `ROUTING-CACHE-2`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S8
- **Связь:** UC-187 (requires failing closed beyond plain domain_suffix/ip_cidr), UC-096, invariant 18 (never guessed), section 7 do-not-touch for resolve.uc.
- **Файлы:** forkop/files/usr/lib/routing/resolve.uc:222-235 (rule_set_values), :270-281

**Even if read correctly, `rule-set match` checks a list with port 0, no network and no source, so list rules with port, network or invert constraints get decided wrongly**

**Evidence.** Upstream ruleSetMatch builds `metadata.Destination = M.SocksaddrFrom(ip, 0)` or `metadata.Domain = domain`, and nothing else: no Network, no destination port, no Source, no process. The resolver passes only the host and address, even though its target carries network and port (resolve.uc:163-164). I ran real sing-box v1.12.0 through a wrapper that forwards stderr, which emulates the obvious fix for ROUTING-CACHE-1:
- List {domain_suffix youtube.com, network tcp, port 443}, target www.youtube.com TCP/443: resolver gives {decided, kind:"direct"}. sing-box would route it through the list rule.
- List {port [443], invert:true} as rule 0 above rule 1 {domain_suffix example.org}, target www.example.org TCP/443: resolver gives {decided, rule:0}. sing-box skips rule 0 (443 matches, so the inverted rule fails) and uses rule 1.
Rule sets that carry port filters are an explicit concept in this product (rulesets.uc extract_port_filter, and tests/nft_subnet_cache.sh uses `{"ip_cidr":[...],"port":[8443]}`). Users can point rule_set at any local or remote .srs/.json.

**Reproduction.** /tmp/claude-0/delta-routing-cache/resolver/repro.sh, cases C and D (c.json/d.json with yt443.srs and not443.srs, run through the sb-stderr wrapper).

**Impact.** Decided-but-wrong owners (the never-guessed invariant again) for user lists whose rules use port, port_range, network, source_*, process_* or invert. This affects Diagnostics and autotune ownership in the same way as ROUTING-CACHE-1, but only for these list shapes.

**Proposed fix.** Only decide lists whose rules use destination-address matchers alone (domain*, ip_cidr). Read the source JSON, or decompile binary lists once (they are already validated by decompile in ruleset_cache.uc), and return "unknown" if any rule contains another field or invert. This matches UC-187's "fail closed for anything else".

---

## UC-219

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «routing/rule-set cache changes after the pause», исходный id `ROUTING-CACHE-3`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S8
- **Связь:** Section 7 do-not-touch for resolve.uc. RO-reachable trigger (invariant 1 context), but the payload needs admin, so no boundary break. UC-001 class (hostile inputs reaching commands).
- **Файлы:** forkop/files/usr/lib/routing/resolve.uc:191, :211-212; forkop/files/usr/lib/config/validator.uc:397-413

**The resolver's shell_quote is broken ("'\''" in ucode yields `'''`), so a list path containing a quote runs shell commands as root whenever route_trace or autotune_groups runs**

**Evidence.** resolve.uc:191 is `replace(v, /'/g, "'\''")`. In a ucode string literal, `\'` is just `'`, so each quote becomes `'''`. Running `shell_quote("a'b")` prints `'a'''b'`, which sh rejects with an unterminated quote. Compare nft/apply.uc, which uses `"'\\''"`. Host and IP values are regex-checked (rule_set_values), but entry.path, taken from route.rule_set[].path in the generated config, is not. The validator accepts any characters in a local rule_set reference as long as it starts with / and ends with .srs or .json (validator.uc:397-413), and the generator copies the reference into config.json verbatim (generator.uc:381-387).

**Reproduction.** /tmp/claude-0/delta-routing-cache/inject/r.uc. Create the empty file `<dir>/a';touch${IFS}PWNED;'.srs`, declare it as a local rule_set in the config, and resolve any FakeIP host. PWNED is created in the cwd; the observed output is cobra usage from the split command, then PWNED present.

**Impact.** If a configured local rule-set path contains `'` and the file exists, every resolve of a rule above or at that list executes the embedded commands as root. RO sessions trigger resolves through `/usr/libexec/forkop-ro route_trace *` and `autotune_groups` (acl.d lines 18 and 20), and so does the autotune worker. Planting the path requires admin config write access, so this is not by itself an RO-to-admin break. It is a latent injection in a do-not-touch module whose header promises that unsafe input never reaches a shell.

**Proposed fix.** Use the same quoting as nft/apply.uc (`"'\\''"`), or better, avoid the shell entirely (an argv-safe spawn, or pass the value through a temp file). Also accept only paths matching `^/[A-Za-z0-9._/-]+$` in local_rule_sets(), and reject quote and whitespace characters in local rule_set references in validator.uc.

---

## UC-220

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «routing/rule-set cache changes after the pause», исходный id `ROUTING-CACHE-4`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S8
- **Связь:** UC-016 (unbounded subprocess on RO and UI paths, FIXED in S3 for curl; this adds a new unbounded path), UC-146 and UC-147 (poll cost).
- **Файлы:** forkop/files/usr/lib/routing/resolve.uc:209-217, :270-281; fe-app-forkop/src/forkop/tabs/autotune/initController.ts:58,1520; fe-app-forkop/src/forkop/methods/shell/index.ts:23

**The resolver starts one sing-box process per list, per value, per rule above the owner, with no timeout; RO polls can pile up multi-second parses**

**Evidence.** rule_set_holds uses an unbounded fs.popen; there is no time limit and no cache of answers. The number of spawns per resolve is Σ(rules above the owner with rule_set) × lists × (1 for FakeIP, 2 for a real address). Because of ROUTING-CACHE-1 no list ever answers "match", so the stop-at-first-hit shortcut never triggers. Materialized remote lists and domain_ip_lists are `format: source` JSON (generator.uc:2429-2433, 2520-2524), which sing-box parses in full on every query. Measured on x86 with a 4 cores: a 1.27 MB source list of 50k domains in 5000-entry rules takes 284-297 ms per query; a 4.4 MB source list takes 1.06 s. Bare sing-box startup is 16 ms. autotune_groups resolves every target (manager.uc:300-317). It is RO-callable, refreshed every 120 s while the page is open, and has a 45 s RPC timeout.

**Reproduction.** Run `sing-box rule-set match -f source mat50k.json nothing.test` three times on x86 (≈290 ms each). For spawn counts, take a config with 5 list rules of 2 lists each above the owner and one real-address target: 20 sing-box processes per resolve.

**Impact.** On an A53 or MIPS router, a single autotune_groups call with tens of targets and one or two large source lists above the owner can run for minutes. The UI gives up after 45 s and asks again 120 s later, so backend chains overlap, the same pattern UC-016 fixed for curl. route_trace from Diagnostics, which RO can reach, becomes slow in the same way. CPU load runs alongside reloads.

**Proposed fix.** Bound each query (deadline or kill) and give each resolve a total budget that degrades to "unknown". Memoise answers per (path, mtime, size, value) within one process (groups resolves many targets). Prefer reading source lists in-process, or decompile binary lists once, over one process per question.

---

## UC-221

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «routing/rule-set cache changes after the pause», исходный id `ROUTING-CACHE-5`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S8
- **Связь:** Regresses section 11 S0 (UC-049/UC-050 hermeticity, no writes outside temp dirs); weakens UC-052.
- **Файлы:** forkop/files/usr/lib/nft/apply.uc:20; tests/nft_apply.sh:548-561; tests/nft_real.sh:328-330

**nft_apply.sh and nft_real.sh share the host's /var/run/forkop/nft-subnet-cache, so a stale entry from another checkout makes an extraction bug pass**

**Evidence.** SUBNET_CACHE_DIR defaults to /var/run/forkop/nft-subnet-cache, and only tests/nft_subnet_cache.sh overrides FORKOP_NFT_SUBNET_CACHE_DIR. This host already holds v1-277d3d62…-5000-all.json, v1-277d3d62…-4-53,853,5353.json (nft_apply.sh fixtures) and v1-824d9be1…-5000-443,8443-8444.json (nft_real.sh), written at 10:20-10:21 by an earlier suite run. To demonstrate, I ran in `unshare -rm` with /run/forkop bind-mounted to scratch, using a copy of the repo with a bug injected into rulesets.uc that drops IPv6 unscoped CIDRs:
- Cold cache: nft_apply.sh rc=1 (FAIL: json ruleset unscoped6 import).
- After one run of the good tree: the buggy tree's nft_apply.sh rc=0, "NFT apply checks passed".

**Reproduction.** unshare -rm bash /tmp/claude-0/delta-routing-cache/pollution/run.sh (repo_good and repo_bad copies under /tmp/claude-0/delta-routing-cache/pollution).

**Impact.** These tests read from and write to host state outside TMPDIR. Results depend on what ran earlier on the machine (another branch, bisect steps, CI cache), so regressions in rule-set extraction or preparation can pass. This regresses the S0 Phase B result in section 11: tests no longer write outside temp dirs (UC-049/UC-050 hermeticity, "запись вне temp-каталогов — нет"). It also weakens UC-052's real-nft lane.

**Proposed fix.** Export FORKOP_NFT_SUBNET_CACHE_DIR="$WORK_DIR/subnet-cache" (or a per-test mktemp dir) in nft_apply.sh, nft_real.sh and any other test that reaches nft-add-json-ruleset-subnets*, or set it centrally in the test runner. Add a meta-check that fails when a test leaves files in /var/run/forkop.

---

## UC-222

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «routing/rule-set cache changes after the pause», исходный id `ROUTING-CACHE-6`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S8
- **Связь:** S5/S12 (UC-072 flash-cache size policy; UC-146..148 resource use); section 13 row for ac39174d ("учесть в S5/S12").
- **Файлы:** forkop/files/usr/lib/nft/apply.uc:16-22, :2219-2238

**The prepared-subnet cache in RAM-backed tmpfs is capped by entry count, not size; stale content-keyed entries stay until reboot, and hits do not count as use**

**Evidence.** SUBNET_CACHE_MAX = 32 entries. Eviction runs only when a new entry is written, ordered by the mtime of that write; a cache hit never refreshes mtime. The key includes the content md5, so each remote rule-set update with changed content adds a new entry, and the superseded ones are never removed. Nothing clears the directory on stop, uninstall or upgrade (grep finds no other reference). Built-in rule sets #2 (b4geoip) are stored in rule_set_with_subnets and go through this path. Measured entry sizes: 8400 IPv4 + 1050 IPv6 subnets → 138 KB; 100k + 12.5k → 1.73 MB, about 0.9 × the JSON size. On OpenWrt /var is /tmp, the same tmpfs that holds the nft candidate batch, config.json and list downloads. Persistent list caches elsewhere are capped at 8 MiB (ruleset_cache.uc:20-21), but this cache has no byte limit. Cold versus warm import: 19.0 s versus 0.18 s for 100k subnets, so the cache is useful.

**Reproduction.** /tmp/claude-0/delta-routing-cache/cache: run nft-add-json-ruleset-subnets-for-section-fixture with r8400.json and r100000.json, then `ls -la c*/`.

**Impact.** With a few large subnet rule sets that update daily, the cache grows toward 32 × entry size, for example ≈55 MB at 1.7 MB per entry, and stays there until reboot. That is permanent RAM use on 128-256 MB routers, and it raises the chance of ENOSPC for the batch, config and download files (see ROUTING-CACHE-7). Hot unchanged entries are evicted before stale ones, because eviction follows write time rather than use.

**Proposed fix.** Bound the cache by total bytes (for example 2-4 MiB, or a share of free tmpfs) as well as entry count. When a new entry is written for the same (rule-set identity, ports, chunk) slot, delete the entries it supersedes. Touch the mtime on a hit. Clear the directory on stop or full-uninstall, and on package upgrade (see the CLEANUP card).

---

## UC-223

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «routing/rule-set cache changes after the pause», исходный id `ROUTING-CACHE-7`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S8
- **Связь:** UC-052 (batch path); safety principle that a reload never reports success over a partial runtime (invariants 3-5 family); ROUTING-CACHE-6 (tmpfs pressure).
- **Файлы:** forkop/files/usr/lib/nft/apply.uc:146-153 (run_args batch append); forkop/files/usr/lib/service/lifecycle.uc:813-847

**When tmpfs is full, nft batch appends are dropped silently and apply.uc still exits 0; a candidate cut at a line boundary passes `nft -c` and replaces the live table (pre-existing, not a regression of e9e95bc2)**

**Evidence.** e9e95bc2 checks `batch.write(...) != null` but ignores close(). In ucode on a full tmpfs, write() returns the byte count and close() returns true even though the stdio flush failed. Observed in `unshare -rm` with a 64k tmpfs: 50 appends reported ok=50, the file stayed at 0 bytes, and fs.writefile returned 37 with a 0-byte file. End to end, I put a 4096-byte page-aligned candidate on a full 16k tmpfs and ran `apply.uc nft-add-subnet-file-for-section-fixture` with FORKOP_NFT_BATCH_FILE set: exit 0, batch still 4096 bytes, both `add element` lines missing. The pre-e9e95bc2 code (writefile of the whole file) behaves the same in the same run, so this is not a regression. nft_validate_candidate_batch only checks size > 0 and `nft -c`; it does not look for an end-of-batch marker. The candidate begins with `delete table inet ForkopTable` (nft_real.sh asserts this).

**Reproduction.** unshare -rm sh /tmp/claude-0/delta-routing-cache/enospc2/run.sh (HEAD and e9e95bc2^ give the same result); /tmp/claude-0/delta-routing-cache/enospc.uc for the raw ucode write/close behaviour.

**Impact.** Usually the cut lands mid-line, `nft -c` rejects it, and the reload fails closed. If it lands exactly on a line boundary (the file is page-aligned when space runs out), the shortened candidate validates and is committed: the live table is deleted and rebuilt without the missing rules or set elements, and the reload reports success. Proxied or VPN destinations then leave the router uncaptured. This is low probability, but the subnet cache from ROUTING-CACHE-6 now keeps tmpfs fuller for long periods. The `written` check gives a false impression that write errors are detected.

**Proposed fix.** Append a sentinel comment (for example `# forkop-candidate-end <count>`) once the build succeeds, and have nft-validate-candidate-batch and nft-commit-candidate-batch refuse a batch without it, or one whose line count differs. Alternatively, after each append check that the file size grew by exactly the line length, and fail otherwise.

---

## UC-224

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «LuCI/UI changes after the pause: e1d74bbc», исходный id `UI-PAGES-1`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S4/S11
- **Связь:** UC-064: STILL_PRESENT, which contradicts the plan's section 13.2 'probably RESOLVED_EXTERNALLY'. Section 11 S4 lists UC-064 under subtask 7 as not done. The Save & Apply part of UC-062/UC-063 is ineffective. Not a regression: the pattern dates from 78877c17 and e1d74bbc copied it to the Rules page.
- **Файлы:** /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/configform.js; /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/page/rules.js; /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/page/settings.js; /home/user/forkop/tests/luci_apply_diff_notice.sh; /home/user/forkop/tests/luci_readonly_view.sh

**configform.js's snapshot-first Save & Apply never runs on Rules or Settings: UC-064 is still present, now on two pages, and the tests stub a Map API that LuCI lacks**

**Evidence.** configform.js:83-85 has `const originalHandleSaveApply = map.handleSaveApply; map.handleSaveApply = async function (ev, mode) {` and :139 has `originalHandleSaveApply.call(this, ev, mode)`. The EntryPoints in page/rules.js and page/settings.js define only load/render, so both views inherit LuCI's default handleSaveApply. form.js for openwrt-24.10, openwrt-25.12 and master has 0 occurrences of handleSaveApply, so originalHandleSaveApply is undefined. In luci.js 24.10, :2040-2044 is `handleSaveApply(ev, mode) { return this.handleSave(ev).then(() => { classes.ui.changes.apply(mode == '0'); }); }` and handleSave (:1996-2001) only calls DOM.callClassMethod(map,'save'). The footer binds `classes.ui.createHandlerFn(this /*view*/, 'handleSaveApply')` (:2138). tests/luci_apply_diff_notice.sh:50 gives its Map stub `handleSaveApply() { return Promise.resolve('applied'); }` and :78 calls `maps[0].handleSaveApply` directly. tests/luci_readonly_view.sh:104-106 only regex-matches the source. The plan (section 13.2, row e1d74bbc) records 'UC-064 — вероятно RESOLVED_EXTERNALLY', which is wrong.

**Reproduction.** Run `node /tmp/claude-0/delta-ui-pages/repro/saveapply_dead.js`. It loads the real page/rules.js and configform.js with a view base that copies luci.js 24.10 handleSave/handleSaveApply and a form.Map without handleSaveApply. It prints 'map has own handleSaveApply: function | originalHandleSaveApply was: undefined', 'view handleSaveApply is LuCI default: true' and 'footer Save & Apply calls: map.save -> ui.changes.apply(true)'. snapshotCreate is never called.

**Impact.** Save & Apply on both config pages never takes the pre-apply snapshot and never refuses while a snapshot operation is busy. It never marks the service 'reloading' and never shows either 'Configuration applied successfully' with the change list or the 'reload has not been confirmed' warning. The user sees LuCI's generic message even when the Forkop reload fails (UI-PAGES-2). The Save & Apply-notice part of the S4 fixes for UC-062 (truncation) and UC-063/D-2 ('not set') is unreachable; the History-page part is live. The backend reload snapshot (lifecycle.uc:2089) runs after the UCI commit, so it holds the new config, not the pre-apply one. Anything that did call map.handleSaveApply would create a snapshot and then throw a TypeError at configform.js:139.

**Proposed fix.** Wire the hook on the view. Export from configform a handleSaveApply(ev, mode) and assign it as EntryPoint.handleSaveApply in page/rules.js and page/settings.js. It should: snapshot automatic → fail closed with a mapped reason (UI-PAGES-3) → view.prototype.handleSaveApply.call(this, ev, mode). For the outcome, poll get_health_status.last_reload until it is newer than the previous one, with a deadline. ui.changes.apply resolves before the apply completes, and LuCI reloads the page afterwards (ui.js 24.10:5079-5089: window.location = ... after apply_display). So keep the notice across the reload (e.g. sessionStorage keyed by the snapshot id, shown by shell.startPage) or point to History. Remove the Map-level override. Rewrite luci_apply_diff_notice.sh to load the page modules with a luci.js-faithful view stub and a Map stub without handleSaveApply. Assert that the snapshot is taken before the base apply and that busy or failure skips the apply. Drop the regex assertions in luci_readonly_view.sh. In plan section 13.2, mark UC-064 STILL_PRESENT (now on two pages).

---

## UC-225

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «LuCI/UI changes after the pause: e1d74bbc», исходный id `UI-PAGES-3`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S4/S11
- **Связь:** UC-022 / D-14 (approved, not implemented) and UC-064. Latent; no current regression.
- **Файлы:** /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/configform.js; /home/user/forkop/forkop/files/usr/lib/config/snapshots.uc

**configform.js's snapshot gate refuses with a message that gives no reason and has no D-14 headroom; once wired, 10 manual snapshots would block every Save & Apply**

**Evidence.** At configform.js:87-108, any status other than created/existing produces 'Could not save a pre-apply configuration snapshot. Changes were not applied.'. Only busy gets its own text (:97), and snapshot.data.reason is ignored. In the backend, snapshots.uc:188-199 trim_retention never evicts manual or LKG snapshots, so create() returns {failed, retention_full} (:220). Manual creation is still allowed up to RETENTION=10 (:31). D-14(a)+(b), S4 subtask 5, is not implemented (section 11, S4 row: 'Не сделано: подзадача 5 — UC-022/D-14').

**Reproduction.** In the scratch dir /tmp/claude-0/delta-ui-pages/snap, run 10× `ucode -L <lib> config/snapshots.uc create manual` with FORKOP_* overrides, change the config, then run `create automatic`. Result: `{ "status": "failed", "reason": "retention_full" }`, exit 1. In configform this maps to the generic refusal.

**Impact.** Today this is latent, because the hook is dead (UI-PAGES-1). Once UC-064 is fixed by wiring this code, a user with 10 manual snapshots cannot apply any Rules or Settings change, and nothing tells them to delete a manual snapshot. The Stage-6 router already held 10. UC-022 would grow from 'restore blocked' to 'all configuration blocked'. Failing closed is correct here (it is not a silent skip), but without D-14 it becomes a lockout.

**Proposed fix.** Land D-14(a)+(b) in snapshots.uc (≥2 slots reserved for automatic snapshots, manual creation stops at RETENTION-2) before or together with wiring UC-064. Map the reasons in configform: retention_full → 'Snapshot storage is full: delete a manual snapshot in History and recovery'; give busy, lock_unavailable and config_unavailable separate texts. Add a test that the gate shows the reason and never calls the base apply.

---

## UC-226

- **Severity:** P3
- **Источник:** delta-аудит после паузы, направление «LuCI/UI changes after the pause: e1d74bbc», исходный id `UI-PAGES-4`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S4/S11
- **Связь:** Regresses the Stage 6.10 localization (baseline 75fbda6d), S11 territory, UC-136-adjacent. Not a Phase B regression.
- **Файлы:** /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js; /home/user/forkop/fe-app-forkop/src/constants.ts

**Since 601ce4b0 the Built-in rule sets widget shows raw, untranslated list names, bypassing the Stage 6.10 localization**

**Evidence.** section.js:9378-9383 passes `{ value, label: _(label) }`, built from the raw main.DOMAIN_LIST_OPTIONS strings, to hideSelectedRulesetChoices (section.js:8098-8128). Its renderWidget builds a ui.DynamicList with those labels. LuCI's ui.DynamicList uses the choices labels both in the dropdown and for the selected items (ui.js 24.10 UIDynamicList.render: `let label = this.choices ? this.choices[this.values[i]] : null; this.addItem(dl, this.values[i], label)`). Before, the labels came from loadRulesetValues → main.domainListLabel(key) (section.js:8082-8089; fe-app-forkop/src/constants.ts:47-70). 'Russia inside', 'Russia outside', 'Geo Block' and 'Porn' have no ru msgid. `_(label)` with a variable argument is not extracted by extract-calls.js, so luci_localization.sh cannot catch it.

**Reproduction.** Run `node /tmp/claude-0/delta-ui-pages/repro/ruleset_labels.js` (ru catalog applied). russia_inside: before="Россия: заблокировано внутри", after="Russia inside". russia_outside: "Россия: блокируют извне" → "Russia outside". geoblock: "Сервисы с геоблокировкой" → "Geo Block". block: "Список блокировки" → "Блокировка" (an unrelated msgid). porn: "Сайты для взрослых" → "Porn".

**Impact.** RU and EN admins see raw internal names in the most-used rule condition list, for both suggestions and selected items. The 'Adult sites' label became 'Porn'. Values and config are not affected.

**Proposed fix.** Build the built-in choices with main.domainListLabel(value). Leave the SECONDARY_RULESET_OPTIONS brand names as they are. Alternatively, have renderWidget reuse this.keylist/this.vallist filled by loadRulesetValues/refreshOptionChoices. Add a harness assertion on the labels passed to ui.DynamicList.

---

## UC-227

- **Severity:** CLEANUP
- **Источник:** delta-аудит после паузы, направление «Autotune changes after the pause», исходный id `AUTOTUNE-9`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S9
- **Связь:** UC-032
- **Файлы:** forkop/files/usr/lib/autotune/apply.uc, fe-app-forkop/src/forkop/tabs/autotune/model.ts

**apply.uc exports a tcp443_profile that no longer exists, and part of the new refusal texts can never show**

**Evidence.** apply.uc:1082 'return { parse_config, route_owner, tcp443_profile, plan }': the function was removed in 55f329e3, so the export is null (repro req.uc). model.ts strategyShapeText handles strategy_empty and candidate_not_tcp443, which cannot occur: effective() is never empty and the catalog is TCP/443 only. tcp443_profile_shared, no_tcp443_profile and strategy_unparsed can only come from custom strategies, which the manager refuses before plan.

**Reproduction.** ucode -L forkop/files/usr/lib /tmp/claude-0/delta-autotune/req.uc

**Impact.** A dead export and dead UI branches. A module consumer (tests/helpers/route_owner/run_apply.js imports autotune.apply) could call null.

**Proposed fix.** Drop tcp443_profile from the export list, and prune or annotate the unreachable refusal texts.

---

## UC-228

- **Severity:** CLEANUP
- **Источник:** delta-аудит после паузы, направление «VPN kill-switch», исходный id `KILLSWITCH-9`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S8
- **Связь:** UC-154, UC-156 (S0 test credibility), UC-052 (real nft coverage).
- **Файлы:** tests/killswitch_nft_render.sh:47-64; tests/killswitch_sync.sh:30-55,182-194; tests/killswitch_lifecycle.sh:23-60; tests/killswitch_dns_render.sh; tests/nft_real.sh

**The kill-switch tests do not catch broken logic: fake nft accepts anything, the lifecycle test is source grep, and key paths are untested**

**Evidence.** The render, sync and standby tests replace nft with a stub (`-c -f` passes when the file contains `add table inet ForkopKillswitch`). The generated include is never checked by real nft; nft_real.sh does not cover killswitch-render. killswitch_lifecycle.sh asserts placement through function_body+grep. Not covered anywhere: D-15 skipped reloads (case 7 tests an unreachable path), deferred subscriptions, changed-list reload, logical route rules with exclusions, and prerm or full-uninstall behavior.

**Reproduction.** Mutation in scratch (/tmp/claude-0/delta-killswitch/mut): deleting `start_lists_complete = !has_list_sources;` (lifecycle.uc:1105), which re-enables refresh from an incomplete runtime, still gives `killswitch_lifecycle: PASS`. The generated include is valid, but only my scratch run showed it (real nft -c, -f and re-apply in unshare -rn all OK).

**Impact.** Regressions in the guards that protect the persisted policy go undetected (UC-154 class). KILLSWITCH-2 to KILLSWITCH-5 all pass the current suite.

**Proposed fix.** Add a kill-switch section to nft_real.sh: render from a real live table, `nft -c -f`, apply, re-apply. Optionally add a veth packet test for reject versus return order. Replace the source greps with behavioral lifecycle tests through stub modules. Add generator-produced DNS fixtures with exclusions, a D-15 stopped-reload case, and deferred and changed-list cases.

---

## UC-229

- **Severity:** CLEANUP
- **Источник:** delta-аудит после паузы, направление «Lifecycle, stop and package changes after the pause», исходный id `LIFECYCLE-STOP-9`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** SD/S6
- **Связь:** UC-154 (grep-only tests); S0
- **Файлы:** tests/user_stop_sticky.sh; tests/stop_runtime_serialization.sh; tests/runtime_ownership_gates.sh; tests/forkop_package_set_rollback.sh

**The new stop paths have no behavioural tests, and the modelled state.uc fakes silently succeed for them**

**Evidence.** No test references stop-all-sing-box-runtime or allow_process_conflict.

The state.uc fakes in tests/user_stop_sticky.sh and tests/stop_runtime_serialization.sh end with `ev("state " + mode); exit(0);`. Every user stop in those tests therefore 'succeeds' through a mode the fake does not model.

tests/runtime_ownership_gates.sh only checks source order with awk; 76b922c3 relaxed it to 'any non-zero'.

Not tested: init.d's new `exit "$status"`, stop_finish's handling of 2, and the apk staged-file names in tests/forkop_package_set_rollback.sh.

**Reproduction.** `grep -rn 'stop-all-sing-box' tests/` finds nothing. The 31 lifecycle and package tests pass while LIFECYCLE-STOP-2 and LIFECYCLE-STOP-3 reproduce.

**Impact.** LIFECYCLE-STOP-2 and LIFECYCLE-STOP-3 shipped with green suites, and the fakes will hide future regressions in these paths.

**Proposed fix.** Make the fakes fail on unknown modes. Turn the r1, r2, r3 and r4 scratch scripts (private PID namespace plus a procd-like ubus stub) into tests.

---

## UC-230

- **Severity:** CLEANUP
- **Источник:** delta-аудит после паузы, направление «routing/rule-set cache changes after the pause», исходный id `ROUTING-CACHE-8`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S8
- **Связь:** ROUTING-CACHE-5, ROUTING-CACHE-6; section 7 do-not-touch "кэши rule-set" (changes need explicit approval).
- **Файлы:** forkop/files/usr/lib/nft/apply.uc:21, :2191-2217, :2252-2275

**Subnet cache identity is a hand-bumped version string plus md5, and cached element strings go into the nft batch without re-validation**

**Evidence.** The key is `v1-<md5(json)>-<chunk>-<ports>`. Preparation depends on routing/rulesets.uc (extract_ip_cidr_nft_elements), core.ip, config/rule.uc normalisation and nft_build_chunks_from_values. Any change to these needs a manual SUBNET_CACHE_VERSION bump, and /var/run survives a package upgrade without reboot. ROUTING-CACHE-5 shows the mechanism: a stale entry hides changed extraction code. nft_subnet_cache_read checks only the types of the object and arrays. The chunk strings are passed verbatim to `add element` lines, so a newline or `}` in a cached string would add arbitrary batch lines. Only root can write the directory (0700 parent), so this is hardening, not a boundary issue. md5 is used where sha256sum is available.

**Reproduction.** See ROUTING-CACHE-5. No production reproduction, since the version is still "1".

**Impact.** After an upgrade that changes extraction or validation semantics, a router keeps applying the old prepared elements until reboot or eviction. The defence against a malformed cache file is structural only.

**Proposed fix.** Derive the version from the package version (or a hash of the preparing modules) and clear the cache directory in postinst. On read, check each cached element against the same nft_ip_or_cidr and port grammar (cheap compared with extraction), or at least reject strings containing newline, `{` or `}`. Use sha256sum.

---

## UC-231

- **Severity:** CLEANUP
- **Источник:** delta-аудит после паузы, направление «LuCI/UI changes after the pause: e1d74bbc», исходный id `UI-PAGES-5`
- **Проверка:** не требовалась (P3/CLEANUP)
- **Этап:** S4/S11
- **Связь:** UC-034 (Phase B S1 least privilege): a soft regression of that principle. Comes from the kill-switch commits 0ff8e687/c8d0d773.
- **Файлы:** /home/user/forkop/luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json; /home/user/forkop/fe-app-forkop/src/forkop/services/readonlyCommandGuard.ts; /home/user/forkop/luci-app-forkop/htdocs/luci-static/resources/view/forkop/killswitch.js; /home/user/forkop/tests/acl_boundary.sh

**The new read-group grant killswitch_status is used only by admin-only pages**

**Evidence.** acl.d/luci-app-forkop.json:7 has `"/usr/libexec/forkop-ro killswitch_status": ["exec"]`, mirrored at readonlyCommandGuard.ts:16 and required by acl_boundary.sh:69. The only caller is killswitch.js:22 (loadStatus via FORKOP_RO), used by settings.js:423 (createGlobalStatus) and section.js:9077 (createSectionStatus). Those run only on the Settings and Rules pages, which depend on luci-app-forkop-admin in menu.d. No RO page calls it: overview, monitoring, diagnostics, autotune and history have no reference.

**Reproduction.** `grep -rn killswitch fe-app-forkop/src luci-app-forkop/htdocs/.../view/forkop` finds only killswitch.js, settings.js and section.js, apart from the guard list.

**Impact.** The read role gains a command that no RO page renders, against the UC-034 rule fixed in S1 ('RO allow-list = commands RO pages actually call'). Low risk: the output is status only (protected section names, nft counters, dnsmasq serversfile flags, last error). I found no secrets, and the env -i wrapper applies.

**Proposed fix.** Have the admin pages call /usr/bin/forkop killswitch_status (write group). Remove it from the read group, READONLY_EXEC_PATTERNS and the required list in acl_boundary.sh. Alternatively, if an RO kill-switch view is planned, render it on an RO page.
