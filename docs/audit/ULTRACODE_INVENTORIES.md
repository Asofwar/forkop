# Ultracode audit: инвентари и проверенные свойства

Приложение к [ULTRACODE_MASTER_PLAN.md](ULTRACODE_MASTER_PLAN.md). Коммит `07872084`. Для каждого направления аудита: краткий вывод, список свойств, проверенных и признанных корректными (PASS), и инвентари (матрица UCI-опций, матрица блокировок, контракт CLI, карта меток и очередей nft, таблица записей на flash, покрытие каталога autotune и т. д.). Текст оставлен в формулировке аудиторов.

## A1 Архитектура и классификация тестов

### Вывод

Архитектура на 07872084 целостная. Бэкенд состоит из 90 ucode-модулей в /usr/lib/forkop, одного ucode-диспетчера /usr/bin/forkop с 89 командами и двух init-скриптов. require-граф без циклов. Каждая команда CLI и каждая exec-запись ACL указывают на существующий модуль или режим, у фронтенда нет модулей-сирот. Модули общаются в основном через дочерние процессы `ucode -L lib module.uc <mode>`, а не через require. Под procd работают только sing-box (через /etc/init.d/sing-box) и TorrServer Direct. Сам Forkop в procd — служба без instance: init.d -> initd.uc -> `forkop start` -> lifecycle.uc. Все DPI-супервизоры, воркеры и асинхронные задачи — это фоновые `sh -c ... &`, их отслеживают через pidfile с проверкой pid + start-ticks (core/process_identity.uc). Путь мутации DPI проходит только через autotune/apply.uc (проверено: manager.apply_group — единственный вызывающий, им пользуются и autoapply, и ручное применение). UI обращается к бэкенду только через LuCI fs.exec('/usr/bin/forkop', ...), плюс fs.read файлов задач и прямой HTTP/WS к Clash API.

Находки (9):
- **P2, известная из аппаратного отчёта, подтверждена.** Цепочка postinst `migrate && mirror-migration && package_postinst` записана в 4 местах. Если зеркало недоступно, mirror-migration.sh выходит с кодом 1 и package_postinst пропускается, поэтому Forkop после обновления остаётся остановленным.
- **P2, новая.** Команда-сирота `forkop main` вызывает start_main() в обход всех защит start_inner: проверки владения sing-box, проверки provenance при обновлении, отката при сбое, проверки стабильного запуска и сериализации через reload-lock. При этом она пересобирает рабочую таблицу nft.
- **P3.** Проверка DNS в Diagnostics использует разошедшуюся копию разбора URL (core/helpers.uc url-get-host). IPv6-адрес DNS разбирается неверно, и появляется ложная ошибка Bootstrap DNS. Воспроизведено локально.
- **P3.** Два рецепта сборки пакетов разошлись: forkop/Makefile не ставит init-скрипт forkop-torrserver-direct, а семантика скриптов пакета у Makefile и build.sh разная.
- **P3.** Ни удаление пакета, ни полное удаление не останавливают и не отключают forkop-torrserver-direct.
- **CLEANUP.** Модуль-сирота providers/rules.uc, который тесты закрепляют вместо рабочего кода.
- **CLEANUP.** Мёртвый неатомарный режим create-nft-rules в nfqueue/runtime.uc, дублирующий nft/apply.uc.
- **CLEANUP.** Три копии текста управляемого init-скрипта sing-box, которые разошлись в `procd_set_param file`.
- **CLEANUP.** Устаревший третий путь удаления `forkop uninstall`.

Классификация тестов: 154 тестов tests/*.sh + 3 в tests/router + 63 файла vitest.

### Проверено и корректно

- В require-графе нет циклов по всем 90 модулям usr/lib/**/*.uc. Проверено скриптом, который обходит require("a.b") в каждом модуле.
- Нет модулей без ссылок из рабочего кода, кроме providers/rules.uc. Учитывались require, пути-строки .uc в forkop/files, build.sh, install.sh и Makefile.
- Все 89 записей command_spec в /usr/bin/forkop указывают на существующий модуль, а строка mode в нём обрабатывается. Исключения намеренные: components/uninstall.uc игнорирует ARGV; route_trace.uc считает любой режим, кроме fixture, трассировкой.
- Каждая exec-запись `/usr/bin/forkop <cmd>` в rpcd ACL (luci-app-forkop.json) ссылается на существующую команду CLI; все значения Forkop.AvailableMethods во фронтенде (fe-app-forkop/src/forkop/types.ts:346) есть в таблице CLI.
- В фронтенде нет модулей-сирот: каждый не тестовый модуль в fe-app-forkop/src импортируется другим модулем.
- Инвариант 10, структурно: autotune/manager.uc apply_group (:410-452) — единственный вызывающий run_tool("apply", plan/apply). Им пользуются и расписание (autoapply), и ручное применение (manual_apply_locked :658-721). nfqws_opt в бэкенде больше не пишет никто, кроме config/migration.uc:666 (заполнение значения по умолчанию).
- Процессы и PID: supervisors (nfqueue/runtime.uc:450, byedpi/runtime.uc:305), воркеры dns_failover/priority и задачи autotune записывают pid и start-ticks через core/process_identity.uc и сверяют exe+argv перед сигналом (byedpi/runtime.uc:209-215, manager.uc:770-774).
- `running` в Overview и Diagnostics — один и тот же предикат: service/ui.uc:870 и diagnostics/runtime.uc:1174 оба используют service/state.uc forkop-stably-running.
- Исходники локализации синхронизированы: fe-app-forkop/locales/forkop.pot совпадает байт в байт с luci-app-forkop/po/templates/forkop.pot, forkop.ru.po — с po/ru/forkop.po (проверено cmp).
- Сгенерированный бандл main.js в CI проверяется на соответствие TS-исходникам (.github/workflows/frontend-ci.yml: yarn build + git diff --exit-code).
- Списки DEPENDS/CONFLICTS в build.sh:63-65 и forkop/Makefile совпадают.
- Три реализации выделения тегов (singbox/constants.uc tag(), core/helpers.uc allocate_runtime_tag, fe runtimeTags.ts) расходятся в списке зарезервированных тегов (нет direct-proxy-out и др.). Но расхождение недостижимо: имена UCI-секций не могут содержать '-', а у всех отсутствующих тегов есть дефис в базовой части.
- Самый длинный тест config_contract_matrix.sh требует локальный git-тег 0.7.19.9 или коммит 68d516e8. Тег в этом дереве есть, поэтому без сети он не падает.
- Ни одно из известных P3 по UI из аппаратного отчёта не является архитектурной проблемой. Отсутствие карточки Autotune в Overview подтверждено: в fe-app-forkop/src/forkop/tabs/dashboard/*.ts нет ни одной ссылки на autotune, хотя дизайн G.1 (docs/design/STAGE6_UX_DESIGN.md:420-440) требует карточку «Автоподбор DPI».

### Инвентарь

#### Forkop 07872084 — карта архитектуры (A1) и классификация тестов (A27)

##### 1. Карта модулей бэкенда (forkop/files/usr/lib → /usr/lib/forkop)
Обозначения: [lib] — модуль подключается через `require("a.b")`; [cli] — модуль вызывается как `ucode -L $LIB $LIB/x.uc <mode>`. Почти все межмодульные вызовы идут как дочерние процессы [cli], а не через require.

**Вход и жизненный цикл**
- `usr/bin/forkop` [ucode]: диспетчер с 89 командами (command_spec → модуль, режим, фиксированное число аргументов). Блокирует мутирующие команды, пока существует /tmp/forkop-full-uninstall.lock. Если модуль отсутствует, для start/stop/reload/uninstall выполняет аварийное восстановление dnsmasq. Кто вызывает: initd.uc, LuCI fs.exec, cron, скрипты пакета, install.sh, snapshots.uc, action.uc.
- `etc/init.d/forkop`: rc.common, USE_PROCD=1, START=99, **procd instance нет**. start_service → `initd.uc start-service` (отсоединяется, если работает внутри rcS/procd с fd 1000); stop/reload/status → initd.uc; service_triggers → `initd.uc trigger-plan` (config.change forkop → reload on_config_change; interface.*.up wan → handle_wan_up; для отслеживаемых интерфейсов → reload); disable отменяет запланированный повтор старта.
- `etc/init.d/forkop-torrserver-direct`: START=100, procd instance `torrserver/direct.uc worker` с respawn; stop → `direct.uc remove`.
- `service/initd.uc` [cli]: бэкенд init.d — планы start/stop, повтор старта (фоновый `sh -c 'sleep; exec init.d retry_start_on_wan_up'`, start-retry.pid), reload-service (/var/run/forkop.reload.lock, очередь / reload.pending, защита от внутренней смены конфига), status-service (через `forkop get_status`), trigger-plan. Вызывает: /usr/bin/forkop start|stop|reload|get_status, dns/apply.uc, service/ui.uc.
- `service/lifecycle.uc` [cli]: start/stop/reload/restart/main/enable/disable/uninstall/dnsmasq-restore/dns-failover-apply/refresh-rulesets-after-start. Оркеструет validator → списки и подписки → кандидат nft → sing-box → провайдеры → dnsmasq → воркеры. Вызывает snapshots (automatic перед reload, confirm-working после успешного start/reload), health record, cron (updates.uc и autotune/manager cron-sync/remove). Вызывающий: bin.
- `service/state.uc` [cli]: предикаты рантайма (forkop-running / stably-running, sing-box-process-conflict, сигнатуры), управление sing-box (start/stop/controlled-replace managed runtime через /etc/init.d/sing-box с проверкой владельца-procd, pid и start-ticks; HUP), маркер managed upgrade, блокировки runtime-dir, снимки состояния reload, pending reload. Вызывают: lifecycle, ui, updates, action, diagnostics/runtime, subscription/cache, initd (косвенно).
- `service/reload.uc` [cli]: чистая функция плана reload (какие подсистемы менять). Вызывает lifecycle.
- `service/ui.uc` [cli]: get-ui-capabilities/get-ui-state, асинхронные service_action/latency_test (воркеры, каталоги ui-state), action-ack. Вызывают bin, initd, lifecycle, diagnostics/health, diagnostics/runtime.
- `service/package.uc` [cli]: prerm (запоминает, была ли служба запущена → /tmp/forkop-package-was-running, stop, восстановление dnsmasq, удаление managed sing-box, удаление записи rt_tables), postinst (восстановление отсутствующего конфига из /usr/share/forkop/defaults, ожидание выхода sing-box, init start), luci-postinst (сброс кэша LuCI, reload rpcd). Вызывающие: bin package_prerm/package_postinst/luci_postinst, uci-defaults 50_luci-forkop.

**Конфигурация**
- `config/validator.uc` [cli]: check-requirements (пакеты, версия sing-box, наличие службы; ставит управляемый скрипт sing-box, если его нет), validate-runtime, валидаторы полей. Кто вызывает: lifecycle, updates, snapshots, singbox/runtime, diagnostics, installer (через установленный модуль).
- `config/migration.uc` [cli]: migrate (legacy podkop → forkop, переименование опций, значения по умолчанию), commit, fixture. Кто вызывает: postinst пакета, install.sh.
- `config/snapshots.uc` [cli]: create/list/diff/restore/delete/apply/confirm-working (LKG = /etc/forkop/config-snapshots/last-known-working), блокировка /var/run/forkop/config-snapshot.lock, restore через `/etc/init.d/forkop reload` с откатом и защитой DPI. Кто вызывает: bin, lifecycle, autotune/apply.
- `config/urltest_override.uc` [cli+lib]: сохранение и сброс per-group URLTest overrides. Вызывают bin (UI) и generator (require).
- `config/connections.uc`, `config/rule.uc`, `config/domain.uc` [lib]: модель правил, подключений и доменов. Используются validator, nft, generator, updates, state, subscription/cache, singbox/route, routing/*.

**Ядро (core)**
- `constants.uc` [lib+cli]: константы с переопределением через env; в плейсхолдер версии подставляет sed при сборке. Используется почти везде.
- `common.uc`, `uci.uc` (обёртка курсора), `ip.uc`, `url.uc`, `netstat.uc` [lib].
- `packages.uc` [cli]: версии и установленность пакетов opkg/apk.
- `process_identity.uc` [lib]: запись и сверка pid+ticks, безопасная отправка сигналов (инварианты 13/14).
- `pidfile_cli.uc` [cli]: записывает pid потомка изнутри sh супервизора.
- `dpi_strategy.uc` [lib]: производное RO-представление стратегии (сырой опции нет); лениво подключает autotune.catalog (нарушение слоёв core→autotune, без цикла). Используется в routing/resolve и diagnostics/runtime.
- `helpers.uc` [cli]: сборник устаревших хелперов с 40+ режимами. В рабочем коде используются только version-at-least (action.uc:520, diagnostics/runtime.uc:1509), server-inbound-tag и url-get-host (diagnostics/runtime.uc:542,1247); остальное нужно только тестам. Дублирует core/url, core/ip и выделение тегов с расхождениями (см. находку об IPv6 DNS).

**sing-box**
- `singbox/generator.uc` [cli]: UCI → JSON конфиг sing-box. Использует dns, route, urltest, rulesets, subscription, country, constants, routing/rule_conditions, routing/rulesets, config/urltest_override, subscription/share_link. Вызывающий: singbox/runtime.
- `singbox/runtime.uc` [cli]: init-config (stage, `sing-box check`, commit/restore stage), configure-service (UCI sing-box, управляемый init-скрипт для compressed-варианта), маркеры варианта и версии, patch/restore DNS. Кто вызывает: lifecycle, updates, action.
- `singbox/dns.uc` [lib] — модель DNS и failover. `singbox/dns_failover.uc` [cli] — воркер failover (pid dns-failover.pid, состояние dns-failover.json, применение через SIGHUP). `singbox/priority.uc` [cli] — воркер Priority-групп (priority.pid). `urltest.uc`, `route.uc`, `subscription.uc`, `country.uc`, `constants.uc` [lib]. `rulesets.uc` [lib+cli]. `ruleset_cache.uc` [cli] — материализация удалённых rule-set и refresh-if-due (+ `init.d reload ruleset-cache`).

**Подписки**
- `subscription/cache.uc` [cli]: загрузка, кэш и состояние, метаданные, воркер отложенного bootstrap (subscription-bootstrap-retry.pid). Кто вызывает: lifecycle, updates, diagnostics, singbox/runtime.
- `parser.uc` [lib+cli] — нормализация URI-списка, Clash YAML, gzip. `share_link.uc` [lib]. `filter_identity.uc` [lib].

**Маршрутизация и потоки данных**
- `routing/resolve.uc` [lib+cli]: единственный резолвер маршрута и владельца (first-match, FakeIP, identity zapret). Используется в autotune/apply, autotune/manager, diagnostics/route_trace.
- `routing/rule_conditions.uc` [lib]: канонические условия правил, включая legacy. `routing/rulesets.uc` [lib+cli].
- `nft/apply.uc` [cli]: **рабочий апплаер nftables**. Батч кандидата (FORKOP_NFT_BATCH_FILE) → apply/commit; пересборка рантайма (delete+create таблицы); наборы; правила вывода провайдеров; защиты DPI и переходов; ip rule tproxy и маршруты в table 105 + rt_tables; bridge netfilter. Кто вызывает: lifecycle, snapshots, state, updates, singbox/runtime.
- `dns/apply.uc` [cli]: интеграция dnsmasq (configure / restore / failsafe-restore; резервные копии в dhcp.@dnsmasq[0].forkop_*). Кто вызывает: lifecycle, initd, bin (аварийно), package, diagnostics.

**Провайдеры**
- `providers/nfqueue/runtime.uc` [lib, engine]: общий движок zapret/zapret2 — preflight, start/stop-runtime (по одному супервизору `runtime.uc supervisor <rule> <queue> <opt> <child_pidfile>` на правило, nfqws запускается в sh-цикле), snapshot/restore-runtime, status/check. Точки входа: `providers/zapret/runtime.uc`, `zapret2/runtime.uc` (по 6 строк, `runtime.run(provider, ARGV)`); настройки провайдера в `zapret(2)/common.uc`. Кто вызывает: lifecycle, updates, action, diagnostics, autotune/apply (перезапуск zapret).
- `nfqueue/validator.uc` (+ обёртки zapret(2)/validator.uc) [lib+cli]. `nfqueue/check.uc` (+ zapret(2)/check.uc) [cli].
- `byedpi/runtime.uc` [cli] — супервизоры ciadpi. `byedpi/validator.uc` [lib+cli].
- `runtime_snapshot.uc` [lib] — снимок и восстановление набора процессов провайдера. `status.uc` [cli] — хелперы для diagnostics.
- `rules.uc` — **сирота**.

**Autotune**
- `manager.uc` [cli]: точка входа (status/target/groups/policy-set/target-set/remove/run/run-async/run-status/apply/apply-async/if-due/cron-sync/remove; задачи → фоновый `manager.uc run-job|apply-job`).
- `isolation.uc` (изолированный путь проб: собственная таблица nft, очередь 4600, процессы проб nfqws).
- `apply.uc` (Stage 5: plan/apply/verify/rollback/status через транзакции snapshots.uc).
- `probe`, `select`, `catalog`, `contract` [lib+cli].
- `lock` (единая блокировка isolation и apply), `state` (/etc/forkop/autotune/state.json), `policy`, `groups`, `hysteresis`, `autoapply` [lib].

**Компоненты**
- `components/action.uc` [cli]: install/remove/update/restore для Forkop, вариантов sing-box, zapret(2), byedpi; каталог релизов Forkop; переключатель TorrServer Direct; восстановление набора пакетов opkg.
- `updates.uc` [cli]: обновление списков (воркер, кэш списков), обновление подписок (задачи), асинхронные действия с компонентами, проверки обновлений, cron.
- `updater.uc` [cli]: хелперы выбора релизов и ассетов.
- `uninstall.uc` → `usr/lib/full-uninstall.sh` (фоновый воркер копируется в /tmp/forkop-uninstall.XXXX, статус пишется в /www/<job>.json).

**Диагностика**
- `diagnostics/runtime.uc` [cli]: check_*, get_*_status, прокси clash_api, show_config/sing-box config (masked), global_check, support_report, системная информация, автоматические тесты задержки.
- `status.uc` [cli] — чистое форматирование и маскирование. `health.uc` [cli] — статус здоровья и журнал истории. `route_trace.uc` [cli]. `connectivity.uc` [cli].

**Прочее**
- `torrserver/direct.uc` [cli]: nft-таблица ForkopTorrServerDirect (cgroupv2 → mark 0x08000000), 60-секундный цикл reconcile.
- `usr/share/forkop/mirror-migration.sh`: транзакция по фидам и ключу зеркала (запускается в postinst).

###### Как запускаются и контролируются процессы
- **sing-box**: единственный крупный процесс под procd (/etc/init.d/sing-box — стоковый скрипт пакета или управляемый скрипт Forkop для compressed-варианта). Forkop никогда не полагается на reload через procd: state.uc выполняет controlled replace (stop → start) и проверяет единственный процесс-владелец procd по pid и start-ticks. Фиксацию DNS failover делает SIGHUP.
- **Forkop**: демона нет; «running» вычисляется в state.uc forkop-stably-running (таблица nft, ip rule, sing-box).
- **nfqws/nfqws2/ciadpi**: фоновые ucode-супервизоры, по одному на правило (`& echo $!`, закрыт fd 1000), pidfile + ticks потомка в /var/run/forkop/{zapret,zapret2,byedpi}/.
- **dns_failover / priority / subscription bootstrap / list update**: фоновые ucode-воркеры с pidfile.
- **Асинхронные действия UI**: service/latency (ui.uc, ui-state/), component (updates.uc, component-actions/), subscription (subscription-update-jobs/), autotune (autotune/jobs), full uninstall (/tmp/forkop-uninstall.* + /www/*.json).
- **cron** (/etc/crontabs/root): list_update_if_due, subscription_update_if_due, component_updates_if_due, autotune_if_due.
- **TorrServer Direct**: procd respawn.

##### 2. Поток данных
UCI /etc/config/forkop
→ (postinst: config/migration.uc migrate)
→ `forkop start` → lifecycle start_inner: гейты (upgrade provenance, sing-box-process-conflict, дубликат старта и transition guard)
→ start_main:
  - validator check-requirements и validate-runtime;
  - bridge netfilter;
  - subscription/cache prepare-caches (parser/share_link);
  - кэш списков (updates.uc restore/prepare-list-cache, routing/rulesets);
  - **nft candidate** (nft/apply.uc nft-rebuild-runtime-from-uci в batch: удаление и создание таблицы, наборы, правила вывода провайдеров, tproxy);
  - singbox/runtime configure-service;
  - apply-list-cache;
  - наборы runtime;
  - **commit кандидата** (атомарно);
  - singbox/runtime init-config (generator.uc → staged JSON → `sing-box check` → commit, материализация ruleset_cache);
  - cron;
  - byedpi start;
  - старт sing-box и проверка стабильности (state.uc);
  - priority;
  - отложенный bootstrap подписок;
  - zapret/zapret2 start.
→ start_impl: **dns/apply.uc configure** (dnsmasq → 127.0.0.42, резервные копии forkop_*) → settings.shutdown_correctly=0 → reload-state → воркер dns_failover → фоновые обновление списков / refresh rule-set / системная информация / тест задержки
→ start_inner: wait-forkop-stable-start, планирование теста задержки
→ режим start: health record и **snapshots confirm-working (LKG)**.

Маршрутизация: ip rule fwmark FAKEIP_MARK → table 105 (`forkop`, запись в /etc/iproute2/rt_tables) → local route dev lo → TPROXY-inbound sing-box.

Reload: config.change → init.d reload → initd.uc (reload.lock / очередь) → `forkop reload` → lifecycle reload: snapshot automatic, reload.uc plan → частичный переход (nft candidate / controlled replace sing-box / провайдеры / DNS) с откатом и отказоустойчивой защитой.

Наблюдаемость:
- diagnostics/runtime.uc (+ status.uc, providers/status.uc) — проверки;
- health.uc — здоровье и history.jsonl;
- route_trace.uc через routing/resolve.uc;
- connectivity.uc;
- UI: fs.exec plus прямой Clash API :9090 по HTTP/WS (socket.service.ts), с fallback через rpcd на `clash_api get_connections`.

##### 3. Состояние и где оно хранится (путь → модули-владельцы)
**Постоянное (flash):**
- /etc/config/forkop — UCI. Пишут: LuCI, migration, package, snapshots restore, autotune manager/apply, urltest_override, action (torrserver), lifecycle (shutdown_correctly).
- /usr/share/forkop/defaults/forkop — копия значений по умолчанию (package.uc).
- /etc/config/dhcp — forkop_* резервные копии (dns/apply.uc).
- /etc/config/sing-box — singbox/runtime configure-service.
- /etc/sing-box/config.json — singbox/runtime (stage/commit/restore).
- /etc/init.d/sing-box — управляемый скрипт от runtime.uc, action.uc, validator.uc, удаляется package.uc.
- /etc/iproute2/rt_tables (nft/apply.uc, package.uc).
- /etc/crontabs/root (updates.uc, autotune/manager.uc).
- /etc/forkop/:
  - config-snapshots/ (+ last-known-working; snapshots.uc, autotune/apply.uc);
  - history.jsonl (health.uc);
  - autotune/state.json (autotune/state.uc);
  - autotune-apply.json (autotune/apply.uc, manager.uc);
  - list-cache/ (updates.uc, ruleset_cache.uc);
  - ruleset-cache/ (ruleset_cache.uc, updates.uc);
  - subscription-cache/ (subscription/cache.uc, singbox/subscription.uc, updates, lifecycle, migration);
  - sing-box-variant, sing-box-version (singbox/runtime, validator, action/updates, ui, lifecycle, subscription/cache);
  - automatic-latency-test.pending (updates.uc, diagnostics/runtime.uc);
  - opkg-package-set-recovery (action.uc, health.uc).
- /etc/forkop-backups (action.uc).
- /etc/apk|opkg feeds, *.pre-forkop-mirror, /etc/apk/keys/forkop-mirror.pem, /etc/apk/repositories.d/forkop.list — mirror-migration.sh, full-uninstall.sh, install.sh.

**Во время работы (tmpfs):**
- /var/run/forkop/ (базовый каталог — RUNTIME_STATE_DIR):
  - reload.pending, reload-state(.snapshot.*), start.failure, start.retry, start-retry.pid, start.in-progress, service-triggers.sync — initd, lifecycle, state, ui, snapshots, autotune/apply;
  - section-cache/, outbound-metadata/, subscription-links/, subscription-metadata/, subscription-update(.lock), subscription-update-jobs/, subscription-bootstrap-retry.pid, cache-format, rule-condition-cache/ — subscription/cache, updates, lifecycle, singbox/*, migration;
  - list-update.reload, list-update-signature, list-update-last-success.timestamp, ruleset-refresh-after-list, validated-list-srs/, list-cache-restore.log-state — updates.uc;
  - ruleset-cache-runtime.json — ruleset_cache;
  - dns-failover.json/.pid — dns_failover, dns.uc, lifecycle;
  - priority.pid;
  - zapret/, zapret2/, zapret-runtime/, byedpi/ — pid, child-pid, log, hostlist (constants, провайдеры);
  - ui-state/{service-actions,latency-actions}(+.lock), component-actions/, automatic-latency-test.lock, component-update-check(s)(.timestamp/.lock), component-action.lock, system-info.json — ui.uc, updates.uc, action.uc, package.uc, diagnostics;
  - health-events.json — health.uc;
  - config-snapshot.lock, snapshot-hash/ — snapshots.uc, autotune;
  - autotune/{lock,state.lock,worker.lock,jobs/,active.json,work/,nfqws-*,last/} — autotune/*.
- /var/run/forkop.reload.lock (initd, lifecycle, updates, diagnostics, autotune/apply).
- /var/run/forkop.internal-config-change (initd, lifecycle, migration).
- /var/run/forkop_list_update.pid (updates).
- /tmp:
  - /tmp/sing-box/ (cache.db, ruleset-cache, subscriptions, rulesets);
  - /tmp/forkop-full-uninstall.lock (bin, full-uninstall.sh);
  - /tmp/forkop-package-was-running (package.uc);
  - /tmp/forkop-managed-upgrade-sing-box (action, lifecycle);
  - /tmp/forkop-torrserver-direct.nft;
  - /tmp/forkop.latest-version.cache;
  - /tmp/forkop-updates*, /tmp/forkop-autotune-* (временные файлы);
  - /tmp/.uci (сохранения uci для autotune);
  - /tmp/forkop-uninstall.XXXX/;
  - /www/forkop-uninstall.XXXX.json — статус полного удаления в webroot, без чувствительных данных, удаляется через 300 с.
- **Ядро**: таблицы nft — рабочая, ForkopConfigRestoreDpiGuard / <table>DpiGuard, ForkopAutotuneProbe, ForkopTorrServerDirect; ip rule/route table 105.

##### 4. Карта фронтенда
Меню (luci-app-forkop/root/usr/share/luci/menu.d/luci-app-forkop.json): admin/services/forkop «Forkop X» (firstchild; depends acl luci-app-forkop + uci forkop).
- **overview** → view/forkop/page/overview.js → shell.detectAccess/startPage("dashboard") → main.DashboardTab (src/forkop/tabs/dashboard/*: overview.ts, overviewCards.ts, clashTraffic.ts, partials/renderSections.ts). **Карточки Autotune нет** — известный P3.
- **monitoring** → page/monitoring.js → DashboardTab.initController (выбор узла) + MonitoringTab (tabs/monitoring/*) + local_devices.js.
- **diagnostics** → page/diagnostics.js → DiagnosticTab (tabs/diagnostic/*: checks/*, connectivityMatrix, dpiPlayground, siteCheck, serviceTransition) + local_devices.js.
- **autotune** («DPI autotune») → page/autotune.js → AutotuneTab (tabs/autotune/*).
- **history** («History and recovery») → page/history.js → HistoryTab (tabs/history/*).
- **settings** (depends acl luci-app-forkop-admin) → page/settings.js: form.Map со вкладками.
  - «Rules» — GridSection через section.js (7874 строки, написан вручную);
  - DNS / Network / Lists and updates / Service — settings.js;
  - «Components» — updates.js → main.UpdatesTab (tabs/updates/*: releaseSelector, fullUninstall, componentActionCompletion).

Общий код:
- shell.js: detectAccess (read-only, если нельзя читать UCI), loadUiCapabilities (`get_ui_capabilities` / `get_ui_state`, fallback на check_*_runtime), startPage → main.coreService (store, socket, log watcher, уведомления о действиях), renderPage.
- main.js: сгенерированный tsup-бандл из fe-app-forkop/src/main.ts, патчится в `return baseclass.extend({...})`; __COMPILED_VERSION_VARIABLE__ подставляет sed при сборке.

RPC:
- Все вызовы бэкенда — `fs.exec('/usr/bin/forkop', [method,...])` (helpers/executeShellCommand.ts, с локальным отказом через readonlyCommandGuard; methods/shell/callBaseMethod.ts разбирает JSON из stdout).
- fs.read файлов состояния задач (/var/run/forkop/component-actions/<id>.json, section-cache); uci.load('forkop').
- Прямой Clash API: fetch `${clash}/proxies` и WebSocket (socket.service.ts) с fallback через rpcd на `clash_api get_connections`.
- fetch https://<ip-check / fakeip-check>/check из браузера; fetch status_url полного удаления (/www/*.json).
- section.js вызывает fs.exec `/usr/bin/forkop validate_*_strategy_json`.

Собственных объектов rpc.declare или ubus нет, кроме luci-rpc getDHCPLeases/getHostHints, network.interface dump и service list.

Опрос: setInterval — dashboard (sections, health 10 с, clash poll), monitoring (connections, render), history, autotune; forkopLogWatcher; модальный таймер.

ACL:
- `luci-app-forkop` read: перечисленные RO-команды и файлы ui-state/component-actions.
- write: `/usr/bin/forkop` с любыми аргументами, /etc/init.d/forkop, чтение config.json, запись в ui-state, uci forkop.
- `luci-app-forkop-admin`: чтение uci forkop (разграничение по роли).

##### 5. Карта пакетов
- **forkop** (build.sh build_backend_root; Makefile Package/forkop/install):
  - файлы: /etc/init.d/forkop, /etc/init.d/forkop-torrserver-direct (**только build.sh**), /etc/config/forkop (conffile), /usr/bin/forkop, /usr/lib/forkop/** (все модули + full-uninstall.sh), /usr/share/forkop/defaults/forkop, /usr/share/forkop/mirror-migration.sh; sed подставляет версию в core/constants.uc;
  - ipk (build.sh:293-314): conffiles; postinst на sh `migrate || exit; mirror-migration || exit; forkop package_postinst`; prerm на ucode `forkop package_prerm $1`;
  - apk (build.sh:430-463): pre-install (no-op), post-install/post-upgrade (та же цепочка через ucode system()), pre-deinstall `package_prerm remove`, pre-upgrade `package_prerm upgrade`;
  - хуки пакета **не** вызывают default_postinst/default_prerm.
- **luci-app-forkop**:
  - файлы: /www/luci-static/resources/view/forkop/** (main.js, page/*.js, section/settings/shell/updates/local_devices.js, fonts/Twemoji), menu.d json, rpcd acl json, /etc/uci-defaults/50_luci-forkop (`forkop luci_postinst` → очистка кэша индекса LuCI, reload rpcd); sed подставляет версию в main.js;
  - скрипты: default_postinst/default_prerm.
- **luci-i18n-forkop-ru**: /usr/lib/lua/luci/i18n/forkop.ru.lmo (po2lmo из po/ru/forkop.po), /etc/uci-defaults/luci-i18n-forkop-ru; скрипты default_*.
- **install.sh** (98 KB): онлайн-установщик — разрешение релиза через зеркало или GitHub, транзакция фидов зеркала, выбор варианта sing-box, политика свободного места на flash, миграция legacy-podkop. Содержит **встроенный ucode-хелпер примерно на 1200 строк** (install-json.uc: собственная обёртка UCI, запасное восстановление dnsmasq, которое используется только когда /usr/bin/forkop отсутствует, очистка legacy, post-install).
- **ops/**: скрипты и systemd-юниты серверной части зеркала и хостинга, router-bootstrap.sh; на роутер не ставятся.
- **CI**: build.yml запускает build.sh; SDK Makefile никогда не собираются, только grep'аются тестами.

##### 6. Классификация тестов (154 шт. tests/*.sh + 3 tests/router + 63 vitest)
Метод: разбор заголовков и сообщений fail/assert в каждом файле, плюс вызывают ли тесты ucode/node (выполнение) или только grep исходников (статика).

**acl/security (10)**
- acl_boundary: ACL JSON + RO-исполнение через node.
- luci_readonly_command_guard, luci_readonly_view, readonly_dpi_strategy.
- log_hygiene: очистка URL.
- process_identity, foreign_pid_stop: инварианты 13/14.
- sing_box_deleted_identity, sing_box_package_identity, singbox_stale_procd_pid: идентичность и владение.

**backend-unit (≈47)** — чистые модули, выполняются с fixtures или заглушками:
- autotune_contract, autotune_groups, autotune_hysteresis, autotune_select, autotune_state;
- byedpi_validator, zapret_validator;
- config_validator_detour, config_validator_download_section, config_validator_reference, config_validator_runtime;
- connection_cascade, core_helpers, core_uci_runtime, country_detection, dashboard_server_filter, direct_proxy_device_exclusions, discord_cloudflare_split;
- dns_failover, dns_ruleset_kinds, dpi_transition_guard, dpi_restore_guard_verify;
- health_status, history_journal, connectivity, route_trace, mark_ranges, nft_apply, outbound_tags, package_versions, priority_failover, provider_rules;
- proxy_parameter_filters, remote_lists_routing, route_list_alternatives, runtime_state_predicates, selector_state, semantic_json_compare, service_reload_plan, singbox_rulesets, sing_box_dns114;
- subscription_alpn, subscription_filter_identity, subscription_hysteria2, subscription_reorder, subscription_source_entry, subscription_user_agent;
- urltest_empty_groups, urltest_groups, urltest_interrupt, urltest_override;
- build_version, ucode_forward_reference (линт).

**contract (≈20)** — в основном статические проверки владения и структуры через grep, а также контракты UI↔CLI:
- cli_entrypoint, constants_owner, config_validation_owner, helpers_owner, byedpi_runtime_owner, runtime_state_owner, zapret_runtime_owner, diagnostics_status (смешанный), shell_inventory;
- package_contract, release_workflow, installer_owner, installer_mirror_contract, openwrt24_mirror_contract, forkop_x_components, forkop_release_catalog, component_update_check_cache;
- runtime_ownership_gates: порядковые контракты на awk.

**regression (≈22)**:
- cron_preserves_foreign_jobs, route_owner_regression, routing_resolve, route_trace_owner (golden-файлы Stage 5);
- idempotent_start, start_reload_serialization, latency_reload_serialization, automatic_latency_pending;
- list_transaction_failures, list_update_final_reload, list_bootstrap, dns_reload_snapshot, dpi_reload_faults, package_upgrade_wait;
- subscription_update_reload, subscription_bootstrap_dns, remote_list_bootstrap_dns, ui_sing_box_probe;
- config_restore_guard, forkop_recovery_boundary, luci_hidden_rule_options, json_outbound_connection.

**integration (≈32)** — многомодульные потоки с заглушками инструментов OpenWrt или фейковым корнем ФС:
- autotune_apply, autotune_isolation, autotune_autoapply, autotune_manual_apply, autotune_recovery, autotune_scheduler;
- config_snapshots, dpi_runtime_snapshot, sing_box_runtime (1585 строк), service_start_trap, initd_state, ui_runtime_job, components_updater_job, subscription_cache_state, subscription_update_job, updates_due;
- list_cache, list_update_reload_policy, ruleset_cache, nft_atomic_apply, dns_apply;
- full_uninstall, full_uninstall_cleanup, forkop_opkg_set;
- mirror_migration, mirror_multi_platform, package_lifecycle, hosting_release_bundle, installer_feed_transaction, installer_space_policy;
- zapret_mirror_cache (python, ops), forkop_release_sync (python, ops).

**compatibility (≈8)**:
- config_migration (legacy podkop → forkop), config_contract_matrix (сравнение с конфигом стабильного тега 0.7.19.9);
- installer_compatibility_matrix (target / arch / release / format), legacy_domain_list, own_mirror_migration;
- mark_ranges (пересечение legacy-меток), sing_box_dns114 и dns_ruleset_kinds (семантика sing-box 1.12–1.14), package_versions (форматы apk v3 и opkg).

**luci (≈15)** — node поверх исходников написанных вручную view или бандла:
- luci_builtin_rulesets, luci_clash_transport_fallback, luci_destructive_confirmations, luci_duration_validation, luci_dynamiclist_layout, luci_interface_settings, luci_localization, luci_mixed_proxy, luci_monitoring_nodes, luci_section_cascade, luci_settings_tabs, luci_stacked_settings_validation, luci_updates_theme;
- dns_action_ui.

**stress**: нет. Стресса нет, кроме режима раннера `--repeat N` (tests/runner — не отслеживается в git в этом коммите, добавлен локально).

**hardware-oriented (3)**:
- tests/router/list_cache_space.sh, list_download_space.sh (ограниченные монтирования, нужен root);
- singbox_single_process.sh (установленный работающий Forkop).

**frontend-unit (63 vitest)**:
- валидаторы (13 .test.js);
- helpers (getClashApiUrl, isCopyableProxyLink, isTransientRpcError, navigation, restoredActionLoading, serviceAvailability);
- services (store, socket, tab, uiState, runtimeUiState, uiActionNotification, forkopLogWatcher, logNotificationDeduper);
- tabs (модели dashboard / monitoring / diagnostic / history / autotune / updates, renderSections(+Readonly), priorityMembers, renderFlagEmojis, clashTraffic, overview, startService, serviceTransition, diagnosticRunPersistence, maskDiagnostics, localization);
- ui (asyncState, states, status); fetchers/fetchServicesInfo; methods/custom (getConfigSections, getDashboardSections).

**Frontend contract**: methods/shell/tests (callBaseMethod, componentAction, latencyAction, observabilityMethods, serviceAction, subscriptionUpdate), tests/runtimeTags.test.ts.

**Frontend acl/security**: services/tests/readonlyCommandGuard.test.ts, diagnostic/tests/maskDiagnostics.test.ts.

**Замечено дублирование или избыточность:**
- 9 файлов повторяют «forkop entrypoint must be a direct ucode executable», 12 — «X.sh shell owner must be removed» (охранные проверки эпохи миграции shell → ucode): byedpi_runtime_owner, cli_entrypoint, config_validation_owner, constants_owner, helpers_owner, service_start_trap, runtime_state_owner, sing_box_runtime, zapret_runtime_owner, diagnostics_status, ui_runtime_job, subscription_update_job, components_updater_job, subscription_cache_state. Их можно свести в shell_inventory.sh.
- full_uninstall.sh (отказ на preflight) почти полностью перекрывается fixture `missing_backup` в full_uninstall_cleanup.sh.
- route_owner_regression.sh и routing_resolve.sh прогоняют один и тот же golden (tests/helpers/route_owner) через apply.uc и через resolve.uc. Намеренно, но перекрываются.
- provider_rules.sh, helpers_owner.sh и core_helpers.sh проверяют код, который в рабочем пути не используется (providers/rules.uc — сирота; core/helpers.uc — в основном только для тестов).
- Тесты зеркала и установщика пересекаются: mirror_migration, own_mirror_migration, mirror_multi_platform, openwrt24_mirror_contract, installer_mirror_contract, installer_feed_transaction.
- SDK Makefile только grep'ается (package_contract, package_lifecycle, constants_owner), но ни один тест его не собирает.

##### 7. Проверка известных пунктов аппаратного отчёта (моя зона)
- **P2 «обновление оставляет Forkop остановленным»**: подтверждено. Корень — цепочка postinst в build.sh:300-302, 438, 461 и в forkop/Makefile postinst; сбой в mirror-migration.sh check_platform_index или загрузке ключа. См. находку 1.
- **P3 «в Overview нет карточки Autotune DPI»**: подтверждено статически — в tabs/dashboard нет ссылок на autotune. Остальные пункты P3 про UI и локализацию относятся к зонам фронтенда и i18n.

##### 8. Скретч-скрипты (только чтение; все в scratch/audit-archmap/)
- paths.sh — извлечение путей.
- tests_inventory.sh, tests_heads.sh — инвентаризация тестов.
- orphans.cjs — сироты во фронтенде.
- cycles.cjs — циклы require и модули без ссылок.
- cli_contract.cjs — сверка bin, ACL и режимов.
- urlhost.sh — воспроизведение IPv6-ошибки.

## A3 UCI: правила и outbound

### Вывод

I audited the rule-section and outbound-source config chain in worktree 07872084. The chain runs LuCI section.js, then connections.uc / rule_conditions.uc, validator.uc, migration.uc, and finally generator.uc / nft/apply.uc / state.uc. I proved round trips with a Node harness that runs the real section.js against LuCI form.js semantics copied from luci-base master (AbstractValue.parse, Flag.parse, isDependencySatisfied, isEqual, ui.Select). I also fed fixtures through the real ucode validator, generator, status masking and snapshot diff in WSL.

Three P1 issues are confirmed.
(1) Device filter wiped: the rule editor erases the Device filter (source_ip_cidr) on save when a rule's only conditions are Built-in rule sets #2 (b4geoip) or legacy remote lists. The dependency list omits "secondary_rule_sets" and the option has no retain, so the rule silently widens from one device to all LAN devices. The generator output proves it: the reject rule loses source_ip_cidr.
(2) Built-in rule sets #2 deleted: the rule-set item modal ("Include IP addresses and subnets") rewrites rule_set_with_subnets from custom refs only, which deletes every Built-in rule set #2. The main modal save does not restore them, and Dismiss does not revert them.
(3) Credentials visible to read-only role: `list outbound_jsons` (socks/http passwords, WireGuard private_key, vless UUIDs) is not masked by the backend `forkop-config-masked` or by the frontend mask. The output is reachable by the read-only role through `global_check masked`. The ≤1.0.4 HTTP migration also moves proxy credentials out of masked selector_proxy_links into these unmasked outbound_jsons.

One P2: editing a zapret/zapret2/byedpi rule while its provider is not detected. The action select lacks the stored value, so the rule is saved as Connection and its DPI strategy is deleted. The resulting config passes the validator but fails generation.

The P3 findings cover several gaps:
- Stale references in ListValues are silently re-pointed.
- Hidden cascade options cannot be cleared from the UI.
- Legacy remote/local list options are invisible.
- The validator misses empty connection rules.
- Legacy *_text / ports_text handling diverges between UI and backend, and a legacy `list interfaces` is erased on save.
- The snapshot diff is blind to anonymous child sections.
- URLTest tags depend on position-based anonymous ids.
- Nested modals write UCI immediately.
- The Built-in #2 widget is ignored for DNS rules.
- The retired-b4geoip migration drops IP sets without mapping them to equivalents.
- Legacy regex values are dropped silently.

The legacy `list domain` fix (4b9ca26e) is complete across readers. The b8d3f1c8 retain fix is complete for the four permanently hidden options. It does not cover conditionally hidden options (source_ip_cidr) or the provider-dependent action/strategy fields. None of the known hardware-report items fall in this area.

### Проверено и корректно

- b8d3f1c8 retain fix is complete for all permanently hidden rule options: outbound_detour_enabled, outbound_detour_section, sort_by_latency and resolve_real_ip_for_routing all have o.retain = true (section.js:7316-7330, 7356-7366, 7383-7394, 7564-7576). Pinned by tests/luci_hidden_rule_options.sh.
- Legacy `list domain` (exact) is read consistently everywhere. Generator and autotune read it through routing/rule_conditions.uc:21-80. nft/apply.uc:531-566, service/state.uc:1213-1231 and connections.uc:422-455 treat it as non-empty. validator.uc:1494 validates it as joined text. UI loadCombinedDomainText (section.js:4950-4966) turns it into full: entries. Scratch gen_check shows domain_list_legacy producing domain:[a.example,b.example]. The harness shows an unchanged save leaves it untouched.
- Shared-storage dual widgets never erase each other: ruleSetOption/dnsRuleSetOption (rule_set) and domainIpListsOption/dnsDomainListsOption (domain_ip_lists) are all retain=true (section.js:7683, 7720, 7743, 7765). Pinned by tests/dns_action_ui.sh:58-66.
- Child item settings modal writes only changed keys (changedSettings/applyChildItemSettings, section.js:3060-3070, 3262-3272), so unknown or hidden child options (show_dashboard_metadata, legacy alias keys) survive.
- UI child defaults match backend defaults: subscription_url 4h/enabled/include_urltest_groups=1, section_interface 0/udp/8.8.8.8, urltest 3m/50/generate_204/filter disabled/flag_emoji, priority_group 5s/2s/15s/3m, priority_level include (section.js:2044-2230 vs connections.uc:505-930).
- enabled defaults to true in every reader: validator.uc:829, generator.uc:171, nft/apply.uc:847/1483/1894, service/state.uc, components/updates.uc, and the UI Flag default "1".
- Community list catalog is identical in UI and backend: DOMAIN_LIST_OPTIONS (fe-app-forkop/src/constants.ts:15-43) and COMMUNITY_SERVICES (core/constants.uc:118) both have the same 27 ids. getBuiltInRulesetReferences' builtin filter therefore drops nothing the validator would accept.
- Read-only config API is an explicit allowlist (diagnostics/runtime.uc:810-830: action/enabled/interface(s)/label/section/sort_by_latency/urltests/priority_groups plus the DPI strategy view). No links, JSON or subscription URLs.
- Snapshot diff redaction is an allowlist (config/snapshots.uc:206-212), so no secrets in the History diff.
- Subscription logging never prints source URLs or tokens, only the rule name and index (subscription/cache.uc log_message calls 1061-2111).
- mixed_proxy_password is a password widget (section.js:7516 o.password=true). mixed_proxy_username/password are masked in diagnostics (status.uc:395-396).
- Rule deletion from the grid cleans subscription_url, section_interface, urltest and priority_group children plus their priority levels (section.js:7852-7859, cleanupPriorityLevelsForGroup).
- UI removal of mixed_proxy_* on bypass/block/dns matches the generator, which rejects mixed proxy for those actions (generator.uc:1488-1499). Removal of ports/ip_cidr on DNS rules is harmless because the DNS path ignores them.
- zapret nfqws_opt legacy default: UI load maps the legacy default to the current one and writes only on change (section.js:6958-6990). Validator strategy_or_default treats the legacy default consistently.
- Rule order equals UCI order (GridSection sortable) for both generator and nft. Rules have no per-rule priority or network (tcp/udp) option, so there is nothing to diverge.
- Unchanged save of legacy action proxy/vpn/outbound rewrites the action to connection, which is semantically equal (connections.is_connections_action). Legacy outbound_json is retained because it is undeclared, and connections.outbound_jsons falls back to it.

### Инвентарь

OPTION CHAIN MATRIX (option -> LuCI writer [retain/rmempty/deps] -> parser/reader -> validator -> migration -> generator/runtime). Worktree 07872084.

A. `config section` (rule)
- enabled: Flag basic, editable in grid, default 1, rmempty=false. Readers default true everywhere (validator 829, generator 171, nft 847/1483, state, updates). OK.
- label: Value, load label||id, rmempty=false. Display only; read-only allowlist. OK.
- action: ListValue [connection,bypass,block,dns,+zapret/zapret2/byedpi if detected]; the cfgvalue is the raw stored action. connections.normalize_action (proxy/vpn/outbound->connection), validator rule_action. Podkop migration uses migrated_rule_action. Consumers: route.target, nft action_captures_traffic, providers/rules.uc counts. Problem: action missing from choices is saved as connection (P2 finding).
- dns_type/dns_server/dns_detour_enabled/dns_detour_section: depend action=dns, no retain. validate_dns_action. Consumer: generator add_dns_action_rules_for_section. Stale-reference re-point: P3 finding.
- nfqws_opt/nfqws2_opt/byedpi_cmd_opts: TextValue per action with remote validation; written only on change; no retain. validate_provider_strategy (strategy_or_default). Podkop migration: migrate_zapret_nfqws_default/byedpi. Writers also include autotune/apply.uc (uci on a private copy). Consumer: provider runtime. Lost when the provider is not detected (P2).
- selector_proxy_links: DynamicList, deps connection, UI validateProxyUrl. connections.connection_urls. Validator: none; the generator parses. Migration: http_connection_urls moves http(s) links to outbound_jsons (≤1.0.4). Consumer: generator add_connection_manual_links. Masked in diagnostics.
- subscription_url (widget) <-> child `subscription_url` {section,url,subscription_update_enabled=1,subscription_update_interval=4h,download_via_proxy_enabled/section,prefix_nodes/node_prefix,include_urltest_groups=1 (flintnet 0), show_dashboard_metadata (no UI, default 1)}. Dead: auto_user_agent/user_agent/auto_hwid/hwid/hide_* (runtime forces auto). Legacy parent list subscription_urls: read if there are no children; not shown in UI; retained on save. Consumer: subscription/cache.uc + generator.
- interfaces (widget) <-> child `section_interface` {name,domain_resolver_enabled=0,dns_type=udp,dns_server=8.8.8.8}. Legacy: list interfaces / option interface (migration interface_sections ≤1.0.1). UI remove() erases the legacy `interfaces` list (P3). Consumer: add_connection_interfaces.
- outbound_jsons: ButtonAddSettingsDynamicList (connection), UI validateOutboundJson + tag uniqueness. validate_outbound_json_values (falls back to outbound_json). Consumer: generator. NOT MASKED in diagnostics (P1). Legacy option outbound_json: no UI, retained, masked.
- urltest (widget) <-> child `urltest` (anonymous) {name,check_interval,tolerance,testing_url,idle_timeout,interrupt_exist_connections,pin_dashboard,filter_mode,detect_server_country,include_/exclude_ countries/outbounds/regex/proxy_parameters/protocols/transports/securities}. Backend aliases: urltest_check_interval/urltest_tolerance/urltest_testing_url/urltest_filter_mode/display_name. Legacy parent urltest_enabled + urltest_* is read when there are no children (invisible in UI). Dashboard writer: urltest_override.uc save_source (commits directly). Tag uses the anonymous id (P3).
- priority_group (widget) <-> child `priority_group` (named pg_*) {name,health_url,active_check_interval,check_timeout,recovery_check_interval,pick_fastest,switch_to_faster_same_priority,fastest_check_interval,interrupt_exist_connections,pin_dashboard} + `priority_level` {group,name,order,direct,filter_mode=include,detect_server_country,country|server_name|regex (UI) ≈ include_countries|include_outbounds|include_regex (backend-preferred alias, never written),exclude_*,*_proxy_parameters}. validate_priority_group. Consumer: singbox/priority.uc.
- outbound_detour_enabled/section: hidden, retain (b8d3f1c8). validate_outbound_detours_rows. Consumer: generator cascade (manual+subscription only). Cannot be cleared in the UI (P3).
- sort_by_latency: hidden, retain; dashboard only.
- resolve_real_ip_for_routing: hidden, retain; UI cfgvalue shows 1 for byedpi. route.uc resolve_rule_for_section (byedpi always resolves).
- mixed_proxy_enabled/port/auth_enabled/username/password: Advanced, deps connection/legacy/DPI actions, password widget. Validator: none; the generator validates port/auth and rejects for bypass/block/dns. Masked.
- domain: TextValue 'Domains' (optionName domain, key domain_suffix, legacy domain_suffix_text). loadCombinedDomainText merges list domain (as full:), domain_suffix, domain_keyword, domain_regex and every *_text. write sets option domain and unsets domain_suffix*, domain_keyword*, domain_regex*, domain_text*. validator: option domain + list domain_suffix + domain_suffix_text (not legacy keyword/regex lists: P3). Readers: rule_conditions.domain_conditions (generator), rule_condition_csv (nft/state/has_dns_matchers, non-empty only). Podkop migration: migrate_combined_domain_conditions. list domain = exact (4b9ca26e) is handled by every reader. OK.
- ip_cidr (+ip_cidr_text, _text_mode): TextValue, routing actions, written as option text. Generator legacy_condition_values (raw, unvalidated), nft filtered. Validator: none. Podkop migration: migrate_text_condition. Text-mode precedence differs in UI (P3).
- community_lists: DynamicList (no deps), builtin filter = COMMUNITY_SERVICES (identical sets). validator community_service_valid. Consumer: ensure_community_ruleset.
- secondary_rule_sets (virtual) -> rule_set_with_subnets b4geoip URLs (mirror/legacy mirror/raw/cdn recognized). Migrations retired_secondary_rulesets(_v2), secondary_rulesets_mirror_v1, own_dependency_mirror_v1. Problems: dropped by the rule-set item modal (P1), missing from the device-filter dependency (P1), no action deps (P3).
- rule_set / rule_set_with_subnets: 'Rule sets' (routing, retain) + '_dns_rule_set' (dns, retain), include_subnets per item. validator ruleset_reference_valid; DNS forbids with_subnets. Consumers: generator ensure_custom_ruleset; nft subnet extraction; updates. rule_set_settings (legacy JSON): UI read/unset, backend ignores.
- domain_ip_lists: routing + dns widgets (retain). Validator plain list ref. Consumers: generator add_domain_ip_list_ruleset, nft, updates.
- remote_domain_lists/remote_subnet_lists: NO UI. Generator/nft/updates/state read them; validator ignores; mirror migration rewrites the host (P3).
- local_domain_lists/local_subnet_lists/subnet/subnet_text: NO UI. Generator 'unsupported matcher' makes generation fail; validator silent (P3).
- source_ip_cidr (+_text,_text_mode): 'Device filter' via dependsOnRuleConditions, NO retain (P1). Generator legacy_condition_values → source_ip_cidr; nft sources sets; DNS source-aware.
- fully_routed_ips: 'Forced device routing' (routing+dns), list. Generator add_fully_routed_ips_rules, nft fully_sources.
- excluded_source_ip_cidr (+_text...): 'Exclude devices' (routing+dns). Generator exclude_sources_from_route_rule; nft excluded sets.
- ports (+ports_text,_text_mode): DynamicList (routing), loads list else ports_text; write unsets ports_text/_text_mode. Validator: list only. Generator and nft MERGE list+text (P3).
- network tcp/udp, per-rule priority: no such options (N/A). Priority = UCI order.
- Other legacy (podkop) options, handled only by migrate-podkop: proxy_string, urltest_proxy_links, subscription_url(single), subscription_user_agent, connection_type, proxy_config_type, *_interval_disabled, user_domains*, enable_udp_over_tcp, subscription_*_settings/urltest_settings/interface_settings JSON maps (connections.uc still has item_settings fallbacks).

B. `config urltest_override` {rule,tag,testing_url,check_interval,tolerance,idle_timeout,interrupt_exist_connections}: written by the Dashboard via CLI urltest_override_save (direct commit). Consumer: generator urltest_override.apply. Not validated, not cleaned on rule delete (CLEANUP).

SAVE PATHS checked: the rule modal (GridSection clone map sharing uci data), table-level 'enabled' flag, nested item modals (subscription/interface/urltest/priority/JSON outbound/rule-set), the dashboard URLTest override, autotune (nfqws_opt only, other area), migration. The frontend TS has no other UCI writer for rules. No bulk/import path exists in the LuCI UI.

SCRATCH (read-only audit, all under scratch/audit-a3\):
- luci_env.js + load_section.js: LuCI form.js semantics harness loading the real main.js and section.js.
- rt_rule.js: modal round trips, 30 cases.
- rt_ruleset_modal.js: rule-set subnets modal.
- gen_check.sh: validator + generator fixtures (WSL).
- masked_config.uci: diagnostics masking.
- snap_diff.sh: snapshot diff.
- anon_id2.sh: libuci anonymous ids.
- regex_check2.sh: regex normalization.
Run with: `WT=<tree> node rt_rule.js` and `wsl.exe -e bash <script>.sh`.

KNOWN HARDWARE-REPORT ITEMS: none fall in this area. The snapshot '***' item belongs to snapshots; the anonymous-section diff blindness reported here is a separate defect.

## A3 UCI: глобальные настройки, DNS, DPI, autotune

### Вывод

I traced every settings-level option (plus subscription_url child options, per-rule DPI strategy options and the autotune policy/targets) from the default UCI file through settings.js, page/settings.js, the TS UI and the autotune page, then validator.uc, migration.uc and the runtime consumers and reload signatures. I found one P1: `forkop global_check masked` is granted to the read-only role and prints /etc/config/forkop through a denylist mask. That mask misses `list outbound_jsons`, the live storage for JSON outbounds, so proxy passwords, UUIDs and keys reach read-only users and "masked" diagnostics. Token-bearing list URLs and DoH resolver paths also pass through. Reproduced in scratch.

I found two P2s. First, the known hardware P2 is confirmed with its root cause (the postinst `&&` chain plus `set -eu` in mirror-migration.sh), and it is wider than reported: an upgrade also leaves Forkop stopped when the mirror is reachable but the router's platform is not listed. Reproduced. Second, restoring a History snapshot saved by an older release bypasses migration.uc completely. It re-installs the retired mirror, retired b4geoip rulesets and the old applied_migrations list; the validator passes and downloads break until the next package upgrade. Reproduced with migrate-fixture.

There are 11 P3s, all with concrete scenarios: snapshot diff misattributes and hides options of anonymous sections (reproduced); settings dropdowns silently swap a referenced rule; the reload signature's dns_type default of doh differs from the runtime's udp (reproduced); core/uci.uc reports failed set/commit as success, so migration commit failures are not surfaced; badwan_reload_delay has no validation; the YACD secret is put unencoded into WebSocket URLs and logged; subscription UA/HWID options are written by migration but ignored; the autotune cron is not re-synced after restore or CLI changes; the torrserver worker reads a cached flag; list-update intervals have no lower bound; and the validator allows WAN Clash API with no secret. Also 1 FUTURE item (the Clash API has no secret on the LAN by default) and 2 CLEANUP items. Migration idempotency, hidden-option preservation on LuCI save, the read-only config allowlist, snapshot value masking and the autotune policy chain all PASS.

### Проверено и корректно

- LuCI Settings save writes only its own options: the four tabs are TypedSections all pointing at 'settings' (page/settings.js:183-205). Hidden options are preserved on save: mirror_base_url, config_version, applied_migrations, direct_proxy_*, torrserver_direct_enabled, service_listen_address, dns_failover_failure_threshold, shutdown_correctly.
- The DNS failover fields (dns_check_interval, dns_recovery_check_interval, dns_check_timeout) use retain=true with a custom checkDepends (settings.js:132-160), so they are not erased while hidden with a single DNS server. The validator requires them only when there is more than one server (validator.uc:960-966).
- Options hidden by depends are removed on save, and the runtime falls back to matching defaults: update_interval and component_update_check_interval default to 1d, dns_detour_section and download_*_section are cleared, and the validator rejects enabled-without-section (validator.uc:971-972, 603-604).
- The read-only config view is an explicit allowlist that excludes yacd_secret_key, URLs, JSON and raw DPI options (diagnostics/runtime.uc:810-830). The DPI view exposes only provider and strategy id (core/dpi_strategy.uc).
- Snapshot diff masks every value except enabled/action/dns_type/dns_strategy/disable_quic and plain DNS IPs (snapshots.uc:206-213).
- yacd_secret_key is masked in global_check (status.uc:401) and in the masked sing-box config ('secret' key, status.uc:1513). The UI field is a password input (settings.js:484-494).
- migration.uc named migrations are idempotent and recorded in applied_migrations (migration.uc:1418-1447; pinned by tests/config_migration.sh:679). Unknown IDs, such as mirror_infotechtg_ru_v1 or IDs from a newer release after a downgrade, are preserved.
- migrate_own_dependency_mirror keeps a custom mirror and rewrites only the former built-in mirror paths (migration.uc:1380-1405). mirror-migration.sh has a transactional rollback of feeds and keys.
- The default config ships config_version 1.0.5 and the full applied_migrations list, so a fresh install is a migration no-op.
- Autotune policy: invalid or out-of-range values fall back to the defaults and are reported, never more aggressive (autotune/policy.uc:86-101). apply_min_confidence is fixed at 'high', and max_applies_per_day=0 disables auto-apply (autoapply.uc:48-50). The UI ranges (initController.ts:406-429) match LIMITS.
- Autotune UCI writes go through a private uci savedir and are refused while /tmp/.uci/forkop has uncommitted changes (manager.uc:240-263). target_set rejects an id already used by another section (manager.uc:295-296), and LuCI section-add rejects existing names.
- Autotune state lives in /etc/forkop/autotune/state.json (atomic writes, only catalog ids, no raw strategies). The policy is not duplicated there.
- DNS server validation: the UI validators (validators/validateDns.ts) are as strict as or stricter than the backend dns_server_value_valid. Bare IPv6 is accepted by both (core/url.uc host/port handle multi-colon).
- The download-through-section action set is the same in the UI (settings.js:25-41) and the validator (validator.uc:586-598).
- Subscription update interval defaults to 4h in the UI (section.js:2047, 2280), connections.uc:537 and the validator. The podkop migration keeps the podkop 1h default explicitly.
- FakeIP has no UCI options. Ranges are consistent (198.18.0.0/15, fc00::/18) across singbox/constants.uc:32-33, lifecycle.uc:83-84, nft/apply.uc:789-790 and routing/resolve.uc:21.
- The direct proxy port is validated at generation time (generator.uc:1615-1620). The toggle checks port availability and rolls back on restart failure (components/action.uc:2487-2530).
- The subscription URL child 'url' is masked in global_check ('option url'), and selector_proxy_links / subscription_urls are masked.

### Инвентарь

##### Scratch reproductions (read-only, private TMPDIR)
All scripts are in scratch/audit-a3\
- masked_config.sh: global_check masked leak (P1)
- mirror_unlisted_platform.sh: postinst chain stop (P2 known, plus the unlisted-platform trigger)
- migrate_old_snapshot.sh: old snapshot content still needs migration (P2)
- snapdiff_anon.sh: anonymous sections in the snapshot diff (P3)
- dns_type_signature.sh: signature default mismatch (P3)
- null_ne_false.uc: ucode `null != false` is true (P3 core/uci)
- form.js, ui.js, ucode_uci.c: upstream sources for LuCI 24.10 and ucode, used to verify ListValue behaviour and uci error semantics.

##### Option chain matrix
Columns: default in etc/config | UI (field, default, validation) | validator.uc | migration.uc | runtime consumer | reload signature (state.uc) | notes.

###### settings section
- config_version | 1.0.5 | none | none | set to 1.0.5 only if the source is <=1.0.4 (never advanced) | none | n/a | Frozen value (CLEANUP). applied_migrations is the real tracker.
- applied_migrations (list) | full list | none (preserved on save) | none | appended by apply_migrations; mirror-migration.sh adds mirror_infotechtg_ru_v1 | n/a | n/a | Snapshot restore reverts it (P2).
- dns_type | udp | ListValue, udp | udp/dot/doh, default udp | none | dns.uc:50 udp | state.uc:1645 defaults to **doh** | P3 mismatch.
- dns_server (list) | 77.88.8.8 | DynamicList, validateDNS | dns_server_value_valid, >=1 required | podkop option->list | dns.uc server_list, fallback 77.88.8.8; autotune resolver_for | yes | Masked in diagnostics.
- bootstrap_dns_server (list) | 77.88.8.8 | DynamicList, validateBootstrapDNS (IP only) | valid; non-IP gives a warning only | podkop option->list | dns.uc, subscription/cache, ruleset_cache, components/updates, autotune resolver_for (used first) | yes | UI is stricter than the backend (OK).
- dns_check_interval / dns_recovery_check_interval / dns_check_timeout | 10s/60s/2s | Value, retain, shown only with >1 server | required only with >1 server | none | dns_failover worker | yes | OK.
- dns_failover_failure_threshold | 3 | none (hidden, preserved) | positive int with >1 server | none | dns_failover.uc:264 | **no** | CLEANUP.
- dns_rewrite_ttl | 60 | parseInt>=0 (accepts '60abc') | none | none | generator int_option, fallback 60 | yes | Minor.
- dns_strategy | prefer_ipv4 | ListValue | enum | none | generator | yes | OK.
- dns_detour_enabled / dns_detour_section | 0 / - | Flag + dynamic ListValue | section exists, enabled, eligible action | none | dns.uc detour_tag | yes | Silent swap (P3).
- source_network_interfaces (list) | br-lan | DeviceSelect multiple | none | none | nft/apply, dns/apply, singbox/runtime listen fallback | nft signature | OK.
- enable_output_network_interface | 0 | Flag | none | none | **ignored** | no | CLEANUP.
- output_network_interface | (commented) | DeviceSelect, depends on the flag (removed when off) | none | none | route.uc:19, runtime.uc:843 | yes | OK via UI only.
- enable_badwan_interface_monitoring / badwan_monitored_interfaces / badwan_reload_delay | 0/-/2000 | Flag, NetworkSelect multiple, Value (non-empty only) | none | none | initd trigger_plan; delay = PROCD_RELOAD_DELAY for all triggers | service_trigger signature | P3 validation.
- enable_yacd / enable_yacd_wan_access / yacd_secret_key | 0/-/- | Flag / Flag (depends yacd) / password (depends wan) | **none** | none | generator clash_api_config (secret applied on LAN too) | yes | P3 validator, FUTURE (LAN without auth); unencoded secret in WS URL (P3).
- disable_quic | 1 | Flag 1 | none | none | route.uc:44 true | yes | OK.
- list_update_enabled / update_interval | 1/1d | Flag / Value, sing-box duration | duration when enabled (no lower bound) | podkop migrate_list_update_enabled | generator rule_set update_interval, updates.uc cron | cron + sing-box | P3 lower bound.
- component_update_check_enabled / component_update_check_interval | 1/1d | Flag **default 0** / Value | **none** | enable_component_checks forces 1 for <=1.0.1 | updates.uc cron (default false/1d) | cron | CLEANUP default mismatch.
- direct_proxy_enabled / direct_proxy_port | 0/2080 | Updates tab component action (not LuCI form) | none | none | generator add_direct_proxy (validates port) | yes | OK.
- torrserver_direct_enabled | 0 | Updates tab action | none | none | forkop-torrserver-direct init + worker (cached flag) | not in forkop reload | P3.
- mirror_base_url | https://mirror.infotechtg.ru | none (hidden, preserved) | none | own_dependency_mirror_v1 plus mirror-migration.sh | core/constants.uc (no runtime normalisation), components/action/updates, full-uninstall | n/a | Restore revert (P2).
- latency_test_url | gstatic 204 | Value + validateUrl | http url | none | diagnostics latency | n/a | OK.
- download_lists_via_proxy (+_section), download_components_via_proxy (+_section) | 0 | Flag + dynamic ListValue | section rows validated; components falls back to the lists section | podkop migrate_download_via_proxy_flags | generator/runtime/updates | yes | Silent swap (P3).
- dont_touch_dhcp | 0 | Flag | none | none | dns/apply, lifecycle, package | dnsmasq signature | OK.
- config_path | /etc/sing-box/config.json | ListValue (2 paths) | none | none | many; ACL reads only those 2 paths | yes | A CLI custom value would be swapped to the first choice on save (LuCI ListValue).
- cache_path | /tmp/sing-box/cache.db | Value validated (abs, *cache.db) | none | none | generator | yes | OK.
- log_level | warn | ListValue | none | none | generator | yes | OK.
- exclude_ntp | 0 | Flag | none | none | nft/apply | nft | OK.
- shutdown_correctly | 0 | none | none | none | lifecycle writes each start/stop; dns/apply, initd read it | excluded from fingerprints | CLEANUP (runtime state in UCI).
- service_listen_address | (absent) | none | none | none | singbox/runtime | yes | Hidden, preserved.
- routing_excluded_ips (podkop legacy) | - | - | - | deleted by migrate-podkop (pinned by tests/config_migration.sh:217/629) | - | - | Devices previously excluded in Podkop Plus get routed after migration. Product decision already pinned by tests; not re-reported.
- download_subscriptions_via_proxy (podkop legacy) | - | - | - | converted to per-source download_via_proxy_* | - | - | OK.

###### subscription_url child (anonymous)
- url: live; masked in diagnostics.
- subscription_update_enabled / subscription_update_interval: live; default 4h in UI, runtime and validator; the podkop migration writes 1h explicitly (keeps Podkop semantics).
- download_via_proxy_enabled / download_via_proxy_section: live; validated.
- show_dashboard_metadata, prefix_nodes, node_prefix, include_urltest_groups: live.
- auto_user_agent, user_agent, auto_hwid, hwid, hide_urltest_group_outbounds, hide_detour_outbounds: DEAD in the runtime (connections.uc hard-codes them), still written by migration, documented in the default example and passed through in types and getDashboardSections (P3, product decision).

###### Per-rule DPI provider options (zapret / zapret2 / byedpi)
- nfqws_opt / nfqws2_opt / byedpi_cmd_opts: section.js textareas with backend remote validation; an empty or legacy value is shown as the default and not written unless edited. validator.uc validate_provider_strategy (the legacy zapret default is allowed). Migration (podkop only): cmd_opts -> byedpi_cmd_opts, legacy zapret default -> new default. Runtime: providers/*/runtime.uc. The RO view is dpi_strategy.view (provider plus catalog id). The raw text still reaches RO through global_check masked (part of the P1). Providers read only settings.config_path globally.
- nfqueue: no UCI options of its own (runtime/check only).

###### Autotune (config autotune 'autotune' / config autotune_target '<id>')
- mode, interval, confirmations, min_confidence, max_applies_per_day, cooldown, probes: defaults in policy.uc DEFAULTS (off, 6h, 3, high, 1, 24h, 5); LIMITS match the UI numberInput and select ranges. Written only by manager.uc policy_set (uci -c/-t private savedir, refused when /tmp/.uci/forkop has changes). No validator.uc involvement; invalid values fall back to the defaults and are reported. No migration: a missing section means off. Consumers: manager, hysteresis, autoapply (apply_min_confidence fixed high). The cron line follows mode on policy_set and start but not on reload or restore (P3).
- autotune_target: host (probe.valid_host), enabled, resolver (IPv4). Id is [A-Za-z0-9_]{1,32}, max 16 targets, and must not collide with other section names. Results live in /etc/forkop/autotune/state.json keyed by id and are pruned on removal or host change. There is no duplicated storage of policy in state.
- Autotune apply state is in /etc/forkop/autotune-apply.json (outside UCI).

###### DNS / FakeIP
- FakeIP has no UCI options. Constants 198.18.0.0/15 and fc00::/18 are duplicated but consistent across singbox/constants.uc, lifecycle.uc, nft/apply.uc and routing/resolve.uc.

##### migration.uc review notes
- Ordering: podkop conversions run first (dns lists -> list_update -> rules -> sections -> subscription download -> download flags), then the named MIGRATIONS. forkop mode runs only the named MIGRATIONS.
- Idempotency: named IDs are recorded (tested at tests/config_migration.sh:679). migrate_interface_item_settings is itself idempotent (seen_values). Unknown IDs are preserved (downgrade and mirror-migration id).
- Gating: release_at_most uses config_version; missing means 0.0.0, so every gated migration runs (podkop and legacy). config_version is never advanced past 1.0.5.
- Silent drops: podkop routing_excluded_ips (pinned by tests), retired b4geoip rulesets (documented), rule_set_settings/subscription_url_settings/interface* legacy options (converted to children).
- Secret movement: outbound_json and http:// proxy URLs are moved into 'list outbound_jsons', which is unmasked in diagnostics (P1).
- Failure surfacing: apply_operations ignores results, and core/uci.uc turns set/commit failures into success (P3). Migration runs only in postinst, not on snapshot restore (P2) and not at service start.
- Downgrade: old releases contain migration 'mirror_51343_ru_v1', which is absent from current configs. A downgrade to such a release would re-run the old mirror migration (old code; cross-version downgrade is inherently unsupported, recorded only).

##### Known hardware-report items: root causes in this area
- P2, upgrade leaves Forkop stopped: build.sh:300-301 (ipk postinst), build.sh:438 (apk post-install), build.sh:461 (apk post-upgrade), forkop/Makefile:55-56. mirror-migration.sh check_platform_index returns 1 under `set -eu`. Reported above with the new unlisted-platform trigger.
- P3, plural agreement 'до 1 автоизменений в сутки' / 'Не больше 1 изменений в сутки': fe-app-forkop/src/forkop/tabs/autotune/initController.ts:182 and 620 use singular msgids with `.replace('%d', ...)` and no plural (N_) forms; po/ru/forkop.po:324 and 3459.
- P3, snapshot diff shows *** for a value absent in the snapshot: config/snapshots.uc diff() passes '' for an absent side into safe_value(), which returns '***' for anything not whitelisted (snapshots.uc:206-213, 283-287). Pinned by tests/config_snapshots.sh (`diff('', lines("option action 'x'"))` gives before '***'). Needs a decision, e.g. emit null or '(not set)' for absent.
- The other hardware items (Components overflow, Rules at 768 px, Overview Autotune card, traffic units, Monitoring sort label, 'Direct' raw type, RO outbound tags, uninstall modal focus) are outside A3.

##### Not verified / limits
- The ucode uci module is not available in WSL. The libuci cursor caching (torrserver finding) and set/commit null returns are established from the ucode lib/uci.c source and language semantics, not executed.
- The sing-box remote rule_set behaviour at very small update_interval is inferred from its update loop, not executed (medium confidence).

## A4 Маршрутизация

### Вывод

For IPv4 targets on ordinary ports, the resolver agrees exactly with sing-box. I checked the canonical resolver (routing/resolve.uc) against a separate model of sing-box first-match, run over configs built by singbox/generator.uc: 241 section orderings × 360 IPv4 targets (FakeIP and real addresses, ports 443/80/8443, TCP and UDP, with and without a source). All 37,964 decided answers matched sing-box. 48,796 were undecidable, which is the conservative outcome. There were 0 guesses. Autotune (IPv4, FakeIP only, TCP/443, zapret identity cross-checked against the route mark and queue) is sound.

The problems are outside that model, plus one nft ordering defect:
- P2: nft bypass priority rules for port-only bypass sections accept IPv4 FakeIP destinations without the tproxy mark. That traffic never reaches sing-box and is black-holed.
- P3: the resolver still returns a "decided" owner for inputs it does not model: IPv6 addresses (CIDR check is IPv4-only, and there is no sniffing on tproxy6-in), DNS port 53 (hijack-dns), and a FakeIP literal with no domain. It also treats a real-address domain match as proof that sing-box sees the connection.
- P3 generator issues: sniff and the QUIC reject only apply to the IPv4 tproxy inbound; a single-port range "N-N" produces an invalid sing-box port_range; mixed-case keywords are kept as typed.
- P3: extracting IPs from rule-sets for nft ignores invert, AND logic and source constraints, so bypass rules can bypass the wrong addresses.
- UX gaps: rules whose only condition is a device filter do nothing, and the site-check reasons are misleading.

There is no separate rule-priority module. Rule order is the UCI section order in both the generator and nft; singbox/priority.uc is the priority-group failover worker.

### Проверено и корректно

- routing/resolve.uc:234-255 walks config.route.rules in generated order (first match). It skips rules from other inbounds and non-final actions (sniff, route-options), treats route/reject as final, and returns final when nothing matches. The resolver reads the same file the lifecycle writes (settings.config_path; resolve.uc:105-107, runtime.uc:488-494).
- Fail-closed cases confirmed by code and by the permutation harness. Logical/invert rules (the exclude_sources wrapper, generator.uc:2556-2585) give unsupported. Unknown fields and non-QUIC protocol matchers give unsupported. rule_set and domain_regex give undecidable. Source-scoped rules without a source (including fully_routed_ips rules, generator.uc:2942-2970) give undecidable. A resolve rule above the owner of a FakeIP connection gives undecidable (resolve.uc:241-245). A missing config gives unavailable.
- Domain semantics match sing's domain matcher (sagernet/sing v0.5.1 common/domain/matcher.go): a leading dot means subdomains only, a plain suffix means the apex plus subdomains (resolve.uc:208-216). The generator lower-cases domain and suffix values through domain_to_ascii, so the resolver's lc() matches runtime for those keys.
- FakeIP semantics: ip_cidr does not match a FakeIP connection unless it was resolved; a real-address connection matches ip_cidr (resolve.uc:219), consistent with sing-box IPCIDRItem behaviour.
- Zapret identity: resolve.uc:260-273 proves section, index, mark and queue from the direct outbound's routing_mark plus the tag convention. This uses the same index formula as generator.uc:2302-2323 (enabled_action_index) and nft/apply.uc:1013-1044 (queue = base + index - 1). Disabled zapret rules do not shift the queue (routing_resolve.sh). Deferred sections are subscription-only connection rules, so zapret indices stay aligned between the generator (non-deferred) and nft (all enabled).
- Autotune apply only mutates when production DNS gives FakeIP answers, the owner is decided as zapret, and the section and queue are unchanged. This is checked at plan, at the stale check and at verification (apply.uc:462-484, 579-581, 367-369). The 'direct' candidate never mutates (apply.uc:467-476). groups.classify uses the same resolver with a TCP/443 target and the FakeIP requirement (manager.uc:147-163, groups.uc:17-37). Conflicts are never auto-resolved (groups.uc:65-84).
- The generator keeps inline domains and rule-set lists as separate alternative rules that share port and source filters (generator.uc:3059-3083; route_list_alternatives.sh). Disabled sections are not emitted (generator.uc:3206-3214). A missing materialized remote list fails generation instead of falling through to direct (generator.uc:2404-2405). The resolve_real_ip rule copies only non-IP matchers and sits directly before the section's route rule (route.uc:67-91, generator.uc:2972-2979).
- nft and generator ordering: priority rules are added per section in UCI order (nft/apply.uc:843-853), matching sing-box first-match order for real-address IP rules. Fully-routed bypass rules explicitly exclude the FakeIP range (nft/apply.uc:762-763).
- route_trace (diagnostics/route_trace.uc:57-91) labels the route 'simulated' and the DPI strategy 'configured', reports the undecidable, unsupported or unavailable reason, validates inputs (no injection), and returns no secrets or raw nfqws options (route_trace_owner.sh, route_trace.sh). The site check shows 'Rule not calculated' for undecided results (siteCheck.ts:57-66).
- Monitoring (connectionView.ts:78-112, initController.ts:206-300) derives the owner from the observed sing-box chain, where the route's outbound is last, using the same tag convention as the resolver (<name>-out, the -out-1 reserved-tag suffix, urltest tags). The route is marked observed and the DPI strategy configured (initController.ts:1102-1121). UCI section names are limited to [A-Za-z0-9_] (generator.uc:166-168), so mapping a tag prefix to a section is unambiguous.
- The only places that compute a connection's owner are routing/resolve.uc (used by route_trace, autotune apply, manager and groups) and the observed-chain mapping in Monitoring. diagnostics/status.uc check_proxy_outbound_tag only resolves the fixed ip.podkop.fyi service rule. No other copy of the domain or CIDR match logic was found in the backend or the TypeScript.
- The existing test routing_resolve passes on this tree (backend runner, isolated).

### Инвентарь

##### Where a connection's owning rule is computed
1. routing/resolve.uc route_owner/resolve. This is the canonical resolver. It works statically on the generated /etc/sing-box/config.json plus the UCI sections.
   - Callers: diagnostics/route_trace.uc:57-91 (the site check; CLI `forkop route_trace`), autotune/apply.uc:131-157 (plan, stale and verify), autotune/manager.uc:147-163 together with autotune/groups.uc classify.
2. Monitoring (TS) connectionView.ts:78-112 and initController.ts:206-300. This works from observed data: the sing-box chain, with the route outbound last, mapped to a section by the tag convention. There is no separate matcher logic.
3. diagnostics/status.uc:1567 check_proxy_outbound_tag. This only covers the fixed service rule ip.podkop.fyi, which goes to the first connection or DPI section (generator.uc:3171-3194).
   - With a DPI rule first, the FakeIP check always gives 'public IP comparison inconclusive' (runFakeIPCheck.ts), which is correctly shown as a warning.
4. autotune/contract.uc in_prefix. This belongs to probe-isolation nft contracts, not route ownership (another auditor's area).

No other domain-suffix or CIDR ownership logic exists in the backend or the TypeScript.

##### Semantics matrix: generator (config) vs resolver vs sing-box
| Aspect | Generator / config | Resolver | sing-box |
|---|---|---|---|
| Rule order | UCI section order. Per section: fully_routed source rule, then resolve rule, then inline rule, then list rule. Service rules first. | Walks the generated rules in order | first match |
| Exact domain | `list domain` or `full:` → domain, lower-cased | exact, lc | exact (on lowercased host) |
| Suffix | default or legacy suffix → domain_suffix; a leading dot means subdomains only | same | sing matcher: same |
| Keyword | kept as typed | lc on both sides | host lowercased, keyword as-is (mismatch; P3 finding) |
| Regex | kept | undecidable | regex |
| IP/CIDR | IPv4 and IPv6 | IPv4 only; IPv6 gives 'no' (P3 finding) | both |
| rule_set (community, remote, local lists, domain_ip_lists) | separate alternative rule | undecidable | matches |
| Source (source_ip_cidr) | in the rule. excluded_source_ip_cidr becomes a logical wrapper. | undecidable without a source; logical → unsupported | matches |
| TCP/UDP | QUIC reject on tproxy-in only | UDP → protocol_matcher unsupported | — |
| Ports | port and port_range. 'N-N' gives an invalid range (P3 finding). | port_matches | — |
| FakeIP | FakeIP answers for rule domains (v4 and v6) | ip_cidr skipped; host used | FQDN from the FakeIP store |
| Sniffing | tproxy-in only (P3 finding) | assumes a sniffed host for any real address | — |
| DNS hijack | hijack-dns for port 53 or protocol dns, no inbound restriction | ignored (P3 finding) | final |
| resolve_real_ip | resolve rule before the route rule | FakeIP → undecidable | fills addresses |
| Disabled rules | not emitted | section_for_outbound only enabled | — |
| Empty lists | skipped, no rule | — | — |
| Source-only rule | no rule (P3 finding) | — | — |
| DPI vs proxy detour | the detour must target a Connection rule (validator) | owner = route outbound | chain starts from the route outbound |
| Ambiguous owner | first section wins in both | — | — |

##### nft interaction
- The FakeIP range is always tproxied, except where the port-only bypass priority rule accepts it first (P2 finding).
- Real-address interception comes from per-section priority sets in UCI order, the common, port and ip_port sets, and fully-routed sources. The resolver does not model any of this (P3 finding on real-address domain matches).
- IPv6 FakeIP (fc00::/18) is inside localv6 (fc00::/7), so priority rules never catch it.

##### Permutation check (scratch)
Files: <scratch>/audit-routing/perm*.uc and run_perm*.sh. The model is an independent re-implementation of sing-box first-match: inbound per address family, sniffing only on the inbounds listed in the generated sniff rule, hijack-dns, logical rules, IPv4 and IPv6 CIDR, host-lowercased keyword.
- Run 1: 289 scenarios × 486 targets = 140,454 comparisons. 35,332 agree, 78,767 undecidable, 25,932 wrong. All wrong answers are IPv6, port 53, uppercase keyword or the '443-443' range.
- Run 2 (IPv4, ports 443/80/8443, normalized input): 86,760 comparisons. 37,964 agree, 48,796 undecidable, **0 wrong**.

##### Test coverage and gaps
- routing_resolve.sh and route_owner_regression.sh use 29 hand-written rule lists (no generated configs).
- route_trace_owner.sh uses a hand-written config covering source-scoped, bypass, block, rule_set and missing-config cases.
- route_trace.sh covers input validation and provenance only.
- route_list_alternatives.sh checks generator shape only.

Gaps:
- No end-to-end test from UCI through the generator to the resolver (the scratch harness could become one).
- No IPv6, hijack-dns, or FakeIP-literal-without-host cases.
- No generated logical exclude_sources rule, fully_routed rule or resolve pair.
- No sniff or QUIC inbound assertion for tproxy6-in.
- No port_range format assertion.
- nft_apply.sh pins the unsafe port-only bypass rule.

##### Other notes
- singbox/priority.uc is the priority-group failover worker. Levels are sorted by `order` (connections.uc:394-398), and there is no rule-order logic in it. Rule order is UCI order everywhere.
- route_trace's site check uses the router's DNS answer. For source-aware DNS devices the device's answer may differ; this is labelled 'Answer of the router DNS'.
- Devices on interfaces not in source_network_interfaces are never intercepted, and the resolver does not know this.

Scratch directory: scratch/audit-routing\ (perm.uc, perm2.uc, perm3.uc, run_perm.sh, run_perm3.sh, trace_v6.sh, port_range.sh, src_only.sh, dns_before.sh, ruleset_invert.sh). No files in the audit tree were modified.

## A5 nftables, метки, очереди

### Вывод

The core nft design holds up. The production table is built as one validated `nft -f` candidate. The transition guard, the DPI guard and the rollback are each a single transaction. Forkop's marks never overlap in a way that lets one subsystem's mark satisfy another's match. Autotune isolation meets invariants 11 and 12. I checked this against real nft 1.0.9 in a private user+net namespace (scratch scripts), not only the test stubs: candidate, rollback round trip, probe batch, atomic rule switch and the bypass contract all pass.

One significant new defect (P2): a ByeDPI rule with IP, subnet-list or port-only matchers loops. ciadpi's own upstream connections leave the router with mark 0. `priority_output_rules` captures them, TPROXY hands them back to sing-box, and sing-box routes them to the same ByeDPI outbound. The loop continues until file descriptors run out.

Lower-severity findings:
- Exact-mark matches for the outbound bypass and the zapret queues depend on hook registration order at priority -150 (fw4 mangle_output/pbr, mwan3).
- The rule "enabled" flag is parsed case-sensitively in some modules and case-insensitively in others, so queue and strategy numbering can drift apart.
- The DPI-guard JSON validator accepts only the nft ≥1.1.0 rendering. On older nft, `ensure` fails and leaves an unverifiable guard behind; I reproduced this with nft 1.0.9. Supported OpenWrt 24.10 and 25.12 are unaffected.
- A duplicate start reports success while a DPI guard is still retained.
- Package removal ignores a refused stop and leaves the TPROXY capture and ip rule 105 in place.
- The NFT diagnostic misreports Forkop's own tables and counters.
- The TorrServer Direct re-apply is not atomic.
- The br_netfilter sysctl is changed globally and never restored.

Cleanups: the global nft sets are never populated, so their rules are dead. There is dead duplicate mark/queue code, with mark constants defined in four places. The start path re-populates the sets live after the atomic commit. The ip-rule presence check is not scoped to one line.

The 7 targeted tests I ran pass. The rest of the backend suite was not run here.

### Проверено и корректно

- Production ruleset is built as ONE candidate batch (FORKOP_NFT_BATCH_FILE, nft/apply.uc:106-123) validated with `nft -c -f` and committed with `nft -f` (nft/apply.uc:1592-1618; lifecycle.uc:914-948, 1840-1872). A real nft 1.0.9 run in a private user+net namespace accepted a rendered candidate (base + priority + provider + output + populate, 149 lines): scratch/audit-a5/real_nft.sh.
- DPI rollback (snapshot_dpi_runtime, lifecycle.uc:1162-1175) is `delete table` + `nft list table` in one transaction, pre-validated with `nft -c`. The round trip re-parses and applies with real nft.
- Transition guard (filter/prerouting/-101, fakeip-mark drop) and DPI guard (filter/output/-149, provider-mark drop) are installed and removed as single checked `nft -f` transactions (nft/apply.uc:1620-1678). Committing the candidate atomically drops the in-table guard together with the old table (lifecycle.uc:1949-1956).
- Mark bit layout proven non-overlapping for every Forkop match (proof in extra). The validator (validator.uc:1602-1640) and tests/mark_ranges.sh enforce the Tailscale mask 0x00ff0000 and keep route-mark ranges clear of the fakeip and outbound marks.
- Invariant 12: probe traffic never reaches a production NFQUEUE. The probe mark 0x08000000 hits the production bypass (mangle_output rule #3) before any queue rule. Production queue rules match exact provider marks only. nfqws-injected probe packets are normalised at -151 (isolation.uc:519-545). Probe queues 4600-4607 are checked against 4000-4255 and 4300-4555 (queue_reserved) and against live and referenced queues (queue_check). The probe queue has no bypass flag, so it fails closed.
- Invariant 11: contract.uc proves bypass-first from the live `nft -j` listing and ip rules and never uses production handles (contract.uc:444-477). The only handle use is inside Forkop's own probe table, looked up by comment just before an atomic `replace rule` (isolation.uc:598-616). The contract returned ok against a real nft listing of the rendered production table (scratch/audit-a5/real_probe.sh).
- nfqws desync marks (0x40000000, 0x20000000) return before the queue rules (nft/apply.uc:1031-1034), so injected packets are never re-queued. No ip rule matches the desync or route marks. A queue verdict does not re-route unless nfqws changes the mark.
- Stop order: DPI processes, then DPI guard, then ForkopTable, then ip rules v4/v6 prio 105, then table-105 routes, then sing-box (lifecycle.uc:1082-1105). The restore guard intentionally survives stop (invariants 4 and 6).
- Strategy validator forbids --qnum, --dpi-desync-fwmark and --fwmark overrides (nfqueue/validator.uc:181-188), so a strategy cannot bind another rule's or autotune's queue or break loop prevention.
- With normal enabled values ('1'/'0'), the zapret index, mark and queue mapping agrees across generator.uc:2303-2334, nft/apply.uc:1013-1044, nfqueue/runtime.uc:180-190 and routing/resolve.uc:259-273.
- List-update nft work goes into a candidate file and never touches the live table (updates.uc:1221-1228, 3641-3667).
- External queue-overlap detection excludes only ForkopTable. Autotune queue range is disjoint from both provider ranges (check.uc:252-285).
- Targeted tests pass: nft_apply, nft_atomic_apply, mark_ranges, dpi_transition_guard, autotune_contract, zapret_runtime_owner, runtime_ownership_gates (runner, isolated).

### Инвентарь

##### Inventory: nft tables and chains (all family inet)

| Table | Chain | type / hook / prio / policy | Lifetime and notes |
|---|---|---|---|
| ForkopTable | dns_redirect | nat / prerouting / -101 / accept | Always. Redirects DNS (tcp and udp 53) from @forkop_dns_sources{,6} to :1603 |
| ForkopTable | forkop_transition_guard | filter / prerouting / -101 / accept | Temporary during a sing-box transition. `meta mark & 0x04000000 == 0x04000000 counter drop`. Removed by the candidate commit (the table is recreated) or explicitly |
| ForkopTable | mangle | filter / prerouting / -149 / accept | `ct status dnat return`, local returns, `jump priority_rules`, 12 dead global-set rules, fakeip-range mark rules. Optional `udp dport 123 return` inserted first |
| ForkopTable | proxy | filter / prerouting / -100 / accept | `meta mark & 0x04000000 == 0x04000000` then tproxy tcp/udp to :1602 (v4) and [::1]:1602 (v6) |
| ForkopTable | mangle_output | route / output / -150 (mangle) / accept | See the rule order below |
| ForkopTable | priority_rules, priority_output_rules | regular chains | Per section in UCI order, first match with accept. The output variant starts with `meta mark != 0 return` |
| ForkopTableDpiGuard | output | filter / output / -149 / accept | Temporary during a DPI switch. Drops `meta mark & 0xff000000 == 0x01000000` and `== 0x02000000`. Removed on success and by stop |
| ForkopConfigRestoreDpiGuard | output | filter / output / -149 / accept | Temporary during a config restore or autotune apply. Survives stop and uninstall by design (invariants 4 and 6) |
| ForkopAutotuneProbe | premark | route / output / -152 / accept | Probe tuple (daddr T, dport 443, sport 61000-61031) with mark 0: set 0x08000000, accept |
| ForkopAutotuneProbe | output | route / output / -151 / accept | Rules: reinjected (0x48000000 to 0x08000000, return), reinjected_bare (0x40000000 to 0x08000000, return), probe/direct/released (0x08000000 to queue 46xx or accept), unexpected (drop). Switched by `replace rule ... handle` from its own table |
| ForkopAutotuneProbe | replies | filter / prerouting / -300 | Only with TRACE |
| ForkopTorrServerDirect | output | route / output / -151 / accept | `socket cgroupv2 level N "<cg>" meta mark set 0x08000000` |

ForkopTable sets: localv4, localv6, forkop_subnets{,6}, forkop_ports, forkop_ip_ports, forkop_ip6_ports, forkop_dns_sources{,6}, forkop_interfaces (ifname interval), plus 13 per enabled capture section: forkop_rule_<name>_{subnets,subnets6,ports,ip_ports,ip6_ports,udp_ip_ports,udp_ip6_ports,sources,sources6,excluded_sources,excluded_sources6,fully_sources,fully_sources6}.

mangle_output rule order (verified on real nft): 1 `ip daddr @localv4 return`; 2 `ip6 daddr @localv6 ip6 daddr != fc00::/18 return`; 3 `meta mark 0x08000000 counter return` (bypass); 4 `jump priority_output_rules`; 5 per provider with sections: `meta mark & 0x40000000 == 0x40000000 return`, `meta mark & 0x20000000 == 0x20000000 return`, then `meta mark 0x0100000N l4proto tcp|udp queue num 4000+N-1 bypass` (zapret2: 0x0200000N, queue 4300+N-1); 6 global-set marks (dead); 7 fakeip range 198.18.0.0/15 and fc00::/18 set mark 0x04000000.

Policy routing: ip -4 and ip -6 rule `priority 105 fwmark 0x04000000/0x04000000 lookup forkop(105)`. Table 105: `local 0.0.0.0/0 dev lo`, `local ::/0 dev lo`. rt_tables entry `105 forkop` is added at start and removed at prerm. sing-box uses no auto_route or tun, so it adds no ip rules.

##### Marks and bits

| Mark | Value | Set by | Matched by |
|---|---|---|---|
| FakeIP / TPROXY | 0x04000000 (bit 26) | ForkopTable mangle, priority_*, mangle_output | ip rule 105 (masked), proxy chain (masked), transition guard (masked) |
| sing-box egress (route.default_mark and direct outbounds routing_mark), also autotune probe mark and TorrServer | 0x08000000 (bit 27) | sing-box, probe premark/normalise, TorrServer cgroup rule | mangle_output bypass (exact), probe rules (exact), contract |
| zapret route mark | 0x01000000 + i, i = 1..256 (bit 24 plus bits 0-8) | sing-box zapret direct outbound routing_mark | queue rules (exact), DPI guard (mask 0xff000000) |
| zapret2 route mark | 0x02000000 + i (bit 25) | sing-box | queue rules (exact), DPI guard |
| nfqws/nfqws2 desync | 0x40000000 (bit 30) | nfqws `--dpi-desync-fwmark`, nfqws2 `--fwmark` (zapret and zapret2 share it) | mangle_output return (masked), probe reinjected rules (exact 0x40000000 / 0x48000000) |
| desync postnat | 0x20000000 (bit 29) | not set by Forkop's nfqws (zapret's own convention) | mangle_output return (masked) |

Proof of no cross-satisfaction:
- The ip rule and proxy/transition-guard masks test only bit 26. Of all Forkop marks, only FakeIP has bit 26, because i ≤ 256 keeps route marks below 0x01000101.
- The DPI guard's top byte is 0x01 or 0x02 only for route marks. FakeIP (0x04), outbound (0x08), desync (0x40/0x20) and probe-injected (0x48) are never dropped.
- The desync returns test bits 30 and 29, which no route, outbound or fakeip mark carries.
- The exact bypass value 0x08000000 equals no other Forkop mark.
- The exact queue marks 0x0100000N and 0x0200000N are disjoint from all others.
- The contract re-checks probe mark vs fakeip and desync, and vs the route ranges (contract.uc:406-422).
- The Tailscale mask 0x00ff0000 is disjoint from all of the above (validator plus mark_ranges.sh). The mwan3 mask 0x3f00 is disjoint while i < 256.
- Caveat: exact matches are sensitive to foreign bits being ORed in (finding 2).

##### Queues

| Owner | Queue range | Notes |
|---|---|---|
| zapret nfqws (one per enabled zapret rule, supervised) | 4000 + i - 1 (range 4000-4255) | |
| zapret2 nfqws2 | 4300 + i - 1 (range 4300-4555) | |
| autotune temporary nfqws | 4600-4607 (FORKOP_AUTOTUNE_QUEUE, MAX_QUEUES 8) | Refused if it overlaps a provider range or is in use or referenced |
| standalone zapret (not Forkop) | 200 by default | Reported as standalone_conflict |

The validator does not cap the number of enabled zapret rules at QUEUE_RANGE_SIZE. More than 300 rules would overlap zapret2 queues; not realistic.

##### Priority ties and ordering dependencies

- ForkopTable mangle_output (route, -150) ties with fw4 mangle_output (-150) and iptables-nft `ip mangle OUTPUT` (mwan3). The kernel runs the last-registered hook first, and a `fw4 reload` re-registers fw4 (finding 2).
- proxy (filter, prerouting, -100) ties with fw4 dstnat (nat, -100). This only matters for DNAT'ed captured flows (the DNS-intercept rules I examined are harmless).
- dns_redirect (-101) ties with transition_guard (-101), both in the same table. Harmless: DNS to router IPs is never fakeip-marked.
- TorrServer (-151) ties with probe output (-151). Disjoint matches; contract.uc accepts cgroup-confined probe-mark setting.
- The two DPI guards (-149) tie with each other. Drop-only, so harmless.
- Rule order inside priority_rules follows UCI section order, first match wins, consistent with sing-box first-match. Production never depends on nft handles. The probe uses handles only in its own table, resolved by comment just in time.

##### Atomicity matrix

| Step | Atomicity |
|---|---|
| Start/reload table build | 1 transaction (candidate) |
| Transition guard add/remove | 1 transaction each |
| DPI guard add/remove | 1 transaction each |
| DPI rollback | 1 transaction (delete + recreate) |
| Probe create, switch, delete | 1 transaction each |
| Stop | `delete table` (1), then separate ip rule/route commands, safe order |
| Start re-populate | Live multiple commands, redundant (CLEANUP) |
| TorrServer | 2 transactions (finding) |
| nfqueue create-nft-rules | Dead code, multiple commands |

##### Cleanup coverage on stop, crash and uninstall

- stop removes: ForkopTableDpiGuard, ForkopTable, ip rules 105 v4/v6, table 105 routes.
- stop keeps: ForkopConfigRestoreDpiGuard (by design), ForkopAutotuneProbe (autotune's own teardown and hold manage it), ForkopTorrServerDirect (its own init, STOP=9).
- uninstall: leftovers are inert until reboot (restore guard only drops Forkop route marks; probe table only matches the probe tuple). Exception: a refused stop leaves live capture (finding 6).
- The br_netfilter sysctl is never restored (finding 9).

##### Test stubs vs real nft

- tests/nft_atomic_apply.sh, nft_apply.sh and dpi_* stub `nft` and only check argv and batch text.
- tests/helpers/autotune_nft_sim.js orders equal-priority chains by listing order (stable sort), whereas the kernel uses reverse registration order. No Forkop-vs-production tie exists in the probe path, so this is acceptable. Its "re-route on accept" model matches nf_route_table_hook4, where a base-chain return also leads to policy accept.
- dpi_restore_guard_verify.sh pins only the nft 1.1.6 JSON form.
- Real-nft checks I ran (nft 1.0.9, `unshare -rn`, nothing on the host touched) passed for:
  - the candidate
  - the rollback round trip
  - the transition guard
  - the probe batch with replace-by-handle
  - the bypass contract (ok=true, bypass at position 3)
- The same runs showed that nft 1.0.9 renders the DPI guard mask as a prefix (finding 4). nftables 1.1.0 changelog: "Remove prefix notation from mark" ([announce](https://www.mail-archive.com/netfilter-announce@lists.netfilter.org/msg00265.html)). Other changelogs checked: [1.1.2 announce](https://www.mail-archive.com/netfilter-announce@lists.netfilter.org/msg00272.html), [LWN 1.1.2](https://lwn.net/Articles/1017461/). OpenWrt 24.10 (nft 1.1.1) and 25.12 (1.1.6) therefore render the `&` form.

##### Scratch scripts (scratch/audit-a5\)

- byedpi_loop.sh, byedpi_ports.sh: output-capture rules for byedpi sections.
- common_sets.sh: global sets are never populated.
- enabled_case.sh: enabled-flag divergence.
- real_nft.sh, real_probe.sh, guard_json.sh: real-nft validation.

##### Known hardware items

None of the listed hardware-report items (upgrade chain, UI layout, i18n, snapshot diff, modal focus) fall in the nft/marks/queues area. F-009 (fw4 flush) is prior audit material and not re-reported.

##### Not reported (insufficient evidence)

- Possible start failure when IPv6 is disabled in the kernel (ensure_tproxy_route_rule treats a failing `ip -6 route add local ::/0 dev lo` as fatal). Unverified.
- autotune orphans() can signal a hand-started nfqws with exactly `--qnum=46xx --dpi-desync-fwmark=0x40000000` as argv[1..2]. Contrived.
- Route table id 105 is shared with podkop. The packages are alternatives, not co-installed.

## A6/A7 Процессы, блокировки, конкурентность

### Вывод

Process identity itself is solid. sing-box ownership, zapret/zapret2/ByeDPI supervisors and children, the DNS-failover and Priority workers, autotune probe nfqws and the snapshot and autotune locks all use PID + start ticks + exe + argv, and KILL requires ticks. The concurrency layer around the lifecycle is broken in several places.

(1) On OpenWrt, procd.sh opens fd 1000 (procd_lock) for every init.d call, so `/etc/init.d/forkop start` always takes the detached branch. That branch records the exiting rc.common shell `$$` as the reload.lock owner, so the lock is stealable for the whole start. This is reproduced, and it affects every start: boot, UI, postinst, retry and component restart. The same branch makes start/restart always exit 0, so the Direct Proxy rollback and other status-based fallbacks never fire.

(2) Snapshot restore treats a merely queued reload as a completed one. When reload.lock is held by the list update, subscription update or latency test, restore reports success, moves LKG and drops the restore guard with zero runtime reloads (reproduced). This violates invariants 3, 4 and 5.

(3) Stop takes no reload.lock and does not stop subscription updates or ruleset-refresh workers. An in-flight subscription update restarts sing-box after the stop. A straggling or pending reload restarts the whole runtime, because reload of a stopped runtime runs restart_runtime_for_reload.

(4) Three PID-only stoppers still TERM a foreign PID taken from a stale pidfile: the list update worker, the deferred subscription worker and the start retry worker (reproduced). This is the F-004 class; the earlier fix did not cover these three.

Lower items: TOCTOU in the directory-lock helpers (reproduced); a latent reload/subscription lock-order inversion that becomes live once (1) is fixed; the autotune worker flock inherited by production daemons; reload.lock held across network I/O, which blocks DNS failover; a legacy kill-by-ps-substring; incomplete full-uninstall guarding.

The known hardware P2 (Forkop stopped after upgrade when the mirror is unreachable) is confirmed in forkop/Makefile:55-57 and build.sh:300-302/438/461.

All reproductions are in the scratch directory audit-a6a7. The audit tree was not modified.

### Проверено и корректно

- core/process_identity.uc:90-127 matches_record checks pid+start ticks+exe basename (tolerates ' (deleted)' only with saved ticks)+argv and re-reads ticks after reading exe/cmdline (PID-reuse safe); signal():145-148 forces ticks for KILL
- service/state.uc:603-638,718-807 sing-box: procd PID + start ticks + exe + sole-process count; stop waits for the exact pid/ticks, refuses on reuse/extra process, never signals a stale procd PID (671-713); start detaches from fd 1000 (787)
- service/state.uc:832-901 managed-upgrade sing-box marker stores pid+start_ticks, consumed on any mismatch (fail closed)
- providers/nfqueue/runtime.uc:256-263,400-419 and providers/byedpi/runtime.uc:209-251: supervisor TERM by ucode argv prefix, child TERM/KILL require saved ticks; children recorded with ticks via core/pidfile_cli.uc inside the supervisor wrapper (nfqueue 374-384)
- providers/runtime_snapshot.uc:179-236 stop_owned/restore: pid+ticks+argv+ancestry, descendant scan, TERM->KILL->verify, refuses unowned live processes
- singbox/dns_failover.uc:318-339, singbox/priority.uc:424-445: pid+ticks recorded, stop by exact argv identity (tests/foreign_pid_stop.sh covers)
- autotune/isolation.uc:420-459,654-742: probe nfqws identified by exact exe path + qnum in run range 4600-4607 + desync mark prefix + pid/ticks; queue_reserved() refuses overlap with production zapret/zapret2 queue ranges (140-145,1158-1162); queue_check refuses a queue in use or already referenced (362-369) => invariants 11-14 hold for probes
- config/snapshots.uc:64-128 and autotune/lock.uc:32-86: owner.<pid>.<ticks> record published by atomic rename; stale detection by identity of the owning ucode command line; busy vs failure distinguished (snapshots.uc:405-410, isolation.uc:1164-1165, apply.uc:846-847)
- Lock order autotune lock -> snapshot lock -> procd flock -> reload.lock(try) is acyclic: the reload's own automatic snapshot is try-lock only (lifecycle.uc:1689) and confirm-working after start is try-lock (lifecycle.uc:2168-2173)
- config/snapshots.uc apply mode (autotune Stage 5) detects a queued reload (314-318, 324) and refuses when reload.pending exists (377); autotune/apply.uc stale_reason checks guards, snapshot op, reload.lock owner, pending reload, probe table, uncommitted uci, LKG equality before mutation (560-593)
- autotune/apply.uc:82-91,506-510 snapshot transactions run under setsid so Ctrl-C/SSH hangup cannot interrupt restore/apply/reload
- autotune/manager.uc:771-775,823-833 async job liveness uses pid+ticks+argv identity; worker flock auto-released on process exit; begin_run records a crashed run and cools down its candidate (471-495)
- autotune/manager.uc: run/if-due/apply share one non-blocking worker flock; concurrent job_start races resolve to status busy (588-592, 777-792)
- service/ui.uc:820-853 service-actions dir lock tolerates the mkdir->pid window (5 s grace for empty pid)
- Background workers close procd fd 1000 (1000>&-) so they do not hold procd's per-service flock (pinned by tests/service_start_trap.sh)
- components/updates.uc:3836-3871 list worker persists the list-content apply intent before calling init reload and recognises a 'queued' acknowledgement
- etc/init.d/forkop-torrserver-direct: procd instance with respawn; stop = procd kill + own nft table removal only
- usr/bin/forkop:259-266 full-uninstall lock refuses start/reload/restart/updates/autotune commands; full-uninstall.sh takes its own mkdir lock and the component-action lock
- Snapshot lock + autotune lock exclude restore/apply/probe correctly (isolation refuses on guard or snapshot lock; apply takes the autotune lock and then the snapshot lock via snapshots.uc apply)
- Existing tests pass in isolation: start_reload_serialization (PASS, but only uses a live $$ and direct initd.uc invocation, not the detached init.d path)

### Инвентарь

##### 1. Process inventory (A6)

| Process | How started | Identity recorded | How stopped / escalation | Stale / PID-reuse handling | Verdict |
|---|---|---|---|---|---|
| sing-box | procd instance of /etc/init.d/sing-box, started detached from fd 1000 (state.uc:787) | procd PID from ubus + /proc exe basename sing-box or 'sing-box (deleted)' + start ticks + sole-process count (state.uc:603-638) | `/etc/init.d/sing-box stop` (procd TERM->KILL); waits for the exact pid/ticks to exit; refuses on reuse or an extra process (718-769) | stale procd PID waited out, never signalled (671-713) | OK |
| zapret / zapret2 supervisor (ucode .../runtime.uc supervisor) | `sh -c "ucode ... >>log 2>&1 1000>&- & echo $!"` (nfqueue/runtime.uc:441-451), reparented to init | pid+ticks (process_identity.record) | TERM by ucode argv prefix (legacy no-ticks allowed for TERM) -> sleep 1 -> KILL (requires ticks) (400-419); runtime_snapshot.stop_owned stricter | ticks + argv + ancestry | OK |
| nfqws / nfqws2 child | supervisor wrapper `bin & child=$!; pidfile_cli record` (374-384); respawn after delay | pid+ticks | TERM/KILL require ticks + argv[0] basename | promote_legacy_child for old pidfiles | OK (tiny orphan window if the supervisor is killed exactly while the wrapper spawns a child) |
| ciadpi (ByeDPI) | same pattern (byedpi/runtime.uc:256-305) | pid+ticks | same | same | OK |
| DNS-failover worker | `sh -c ... & echo $!` (dns_failover.uc:335-338) | pid+ticks | TERM by exact argv, no wait/KILL (318-322) | identity | OK. In-flight child `forkop dns_failover_apply` is not stopped (see the stop-serialization finding) |
| Priority worker | same (priority.uc:431-445) | pid+ticks | TERM exact argv | identity | OK |
| list update worker | module_background / cron / CLI; pidfile /var/run/forkop_list_update.pid | PID only | `kill pid` after kill -0 (updates.uc:4063-4069) | none: FOREIGN KILL (reproduced) | FAIL |
| deferred subscription bootstrap worker | launch_self_worker `& echo $!` | PID only | `kill pid` after kill -0 (cache.uc:2462-2468) | none: FOREIGN KILL (reproduced) | FAIL |
| start-retry worker (`sh -c 'sleep 30; rm pidfile; exec init retry_start_on_wan_up'`) | initd.uc:299-307 | PID only | `kill pid` (276-283) | none: FOREIGN KILL (reproduced); a reused PID also suppresses rescheduling | FAIL |
| detached start worker (initd.uc start-service) | init.d background (`&`), fd 1000 closed | owner recorded = `$$` of the exited rc.common shell | not stoppable; start.in-progress holds the lifecycle PID (kill -0) | dead owner from ~0.1 s | FAIL (detached-start finding) |
| async service-action workers (ui.uc) | launch_worker `& echo $!` | PID in job json | kill only right after a failed pid write | kill -0 liveness; reuse leaves a job 'running' forever (P3 class) | OK-ish |
| latency-test workers (UI) / automatic latency test | launch_worker / module_background | PID in job json / lock pid | not stopped by stop (harmless, read-mostly) | kill -0 | OK-ish |
| subscription update jobs | launch_subscription_worker `& echo $!` | PID in job json | not stopped by stop_main | kill -0 | RACE with stop (stop-serialization finding) |
| component action jobs | launch_component_worker | PID in job json + component-action.lock pid | none | kill -0 | OK-ish |
| ruleset refresh workers (refresh-after-start, refresh-and-reload, refresh-if-due-and-reload) | module_background, untracked | none | never stopped | n/a | FAIL (reload-after-stop finding) |
| autotune manager job workers | `sh -c "... &"` (manager.uc:785-786) | job json pid+ticks, argv-checked (771-775) | none (SIGTERM sets `interrupted`) | identity | OK; worker flock inheritance (P3) |
| autotune probe nfqws | popen `& echo $!` (isolation.uc:746-752) | pidfile pid+ticks + exact argv; orphan scan by exact exe path + qnum 4600-4607 + desync mark | TERM -> 3 s -> KILL -> verify (432-440) | identity | OK (invariants 12, 13, 14) |
| autotune path_probe curl | background, self-terminating (--max-time 5) | none | none needed | n/a | OK |
| torrserver direct worker | procd instance with respawn | procd | procd + nft table delete | procd | OK |
| full-uninstall worker | `sh worker.sh &` | lock pid files (mkdir) | n/a | no stale detection (/tmp cleared at reboot) | OK-ish |
| validator/ui bounded-command watchdogs | shell `& child=$!` watchdog | own child | KILL of own child after timeout | <=1 s reuse window | OK |
| legacy nfqws cleanup | n/a | `ps w` substring | TERM | none | FAIL (P3) |

##### 2. Lock inventory (A7)

| # | Lock | Mechanism | Scope / users | Stale detection | On crash |
|---|---|---|---|---|---|
| L1 | /var/run/forkop.reload.lock | mkdir + pid file; release unconditional | initd start (wait 30 s, owner = passed `$$`), initd reload (try; busy -> reload.pending, exit 0), lifecycle dns-failover-apply (wait 2 s), list update (wait 300 s, held across downloads), subscription update (try / wait 300 s when forced, held across downloads + sing-box transition), automatic latency test (wait 300 s, per-batch release + pending handoff); read-only check in autotune apply service_action() | kill -0 on pid | dir stays; next contender steals if the PID is dead; permanent 'busy' if the PID is reused |
| L2 | /var/run/forkop/subscription-update.lock | same helper | lifecycle start (wait 300 s, held until after deferred bootstrap), subscription update, deferred worker (try) | kill -0 | same |
| L3 | /var/run/forkop/config-snapshot.lock | dir containing owner.<pid>.<ticks>, published by atomic rename | snapshots.uc create/delete/restore/apply/confirm-working; isolation refuses while the dir exists (existence only); apply.uc snapshot_operation_active (identity) | pid+ticks+argv | cleaned by the next acquirer; a stale dir blocks autotune probes until then |
| L4 | /var/run/forkop/autotune/lock | same scheme, owners isolation.uc / apply.uc | probe, tune, cleanup, apply, rollback | identity | same |
| L5 | /var/run/forkop/autotune/worker.lock | flock xn on an fs.open 'a' fd (inheritable) | manager run / if-due / apply / jobs; job_start probe | kernel releases on close | inherited by descendants -> held after manager crash (P3) |
| L6 | /var/run/forkop/autotune/state.lock | flock x (blocking) | state read-modify-write (no spawns inside) | kernel | OK |
| L7 | /var/run/forkop/component-action.lock | mkdir + pid (action.uc) | component actions; full uninstall (mkdir only) | kill -0 (none in full-uninstall) | stale -> 'Another component action is running' for full uninstall |
| L8 | /tmp/forkop-full-uninstall.lock | mkdir + pid | full uninstall; forkop CLI checks existence for a subset of commands | none | persists until reboot (/tmp) |
| L9 | /var/run/forkop/ui-state/service-actions.lock | mkdir + pid, 5 s grace for empty pid | begin_service_action_if_idle | kill -0 | brief |
| L10 | /var/run/forkop/automatic-latency-test.lock | L1 helper | manual + automatic latency tests | kill -0 | same as L1 |
| L11 | component-update-check.lock, sing-box version cache lock | helper, try | update checks / version probe | kill -0 | brief |
| L12 | /var/lock/procd_forkop.lock (fd 1000) | procd.sh procd_lock flock, taken for EVERY init.d call and inherited by children unless 1000>&- | serializes synchronous init.d stop/reload/status; the detached start releases it immediately | kernel | n/a |

Markers and guards:
- reload.pending: queued reload; survives stop.
- start.in-progress: lifecycle PID, kill -0.
- start.retry, start-retry.pid, start.failure.
- /var/run/forkop_list_update.pid.
- subscription-bootstrap-retry.pid.
- LIST_UPDATE_RELOAD_FILE: durable list apply.
- RULESET_REFRESH_AFTER_LIST_FILE.
- /var/run/forkop.internal-config-change: 30 s + md5.
- service-triggers.sync.
- managed-upgrade sing-box marker: pid+ticks.
- /etc/forkop/autotune-apply.json: durable Stage 5 state.
- isolation active.json.
- nft guards ForkopConfigRestoreDpiGuard, ForkopTableDpiGuard, forkop_transition_guard chain.

Actual acquisition orders:
- autotune apply: L5 -> L4 -> L3 -> L12 -> L1 (try).
- restore: L3 -> L12 -> L1 (try).
- reload: L12 -> L1 -> L3 (try).
- start: L12 (released) -> L1 (dead owner) -> L2 -> L3 (try).
- subscription update: L2 -> L1 (INVERSION with start).
- list update: L1 -> (release) -> L12 -> L1.
- latency: L10 -> L1.
- dns-failover-apply: L1.
- stop: L12 only.

##### 3. Operation compatibility matrix (as implemented)

X = mutually excluded, ok = allowed concurrently and safe, RACE = allowed and unsafe.

| | snapshot | restore | reload | start | stop | at-run(probe) | at-apply | component | list upd | subscr upd | full_uninstall |
|---|---|---|---|---|---|---|---|---|---|---|---|
| snapshot (create/delete) | X | X | ok (reload's auto snapshot is try-lock) | ok (confirm-working silently skipped if busy) | ok | ok (probe refuses at start while L3 exists) | X | ok | ok | ok | RACE-low (can re-create /etc/forkop after the files phase) |
| restore | | X | ok (L12 serializes init.d reloads) | RACE (dead L1 owner) | RACE (restore reload after stop restarts Forkop) | ok (probe fails closed on production_changed) | X (L3) | RACE (component stop/restart unserialized with the restore reload) | RACE (queued reload reported as success) | RACE (same) | RACE-low (CLI does not block restore) |
| reload | | | X (L12, else queued) | RACE (dead L1 owner) | X for init.d reload vs init.d stop (L12) | ok (fail-closed) | ok (apply refuses or detects the queue) | partial (init.d stop/restart serialized by L12, opkg file replacement is not) | X (L1 + handoff) | X (L1) | ok (CLI blocks forkop reload) |
| start | | | | RACE (second start steals dead L1; only the UI checks start.in-progress) | RACE (stop ignores start.in-progress; detached start not under L12) | ok | RACE-low (service_action() sees a dead owner; mostly refused by runtime checks) | RACE (component restart = stop + detached start) | RACE (list-update-after-start steals L1) | RACE (steals L1; lock inversion once fixed) | X (CLI) |
| stop | | | | | X (L12) | ok | RACE (apply reload after stop restarts Forkop) | X for init.d stop (L12) | ok-ish (list worker killed by PID-only TERM) | RACE (sub update restarts sing-box after stop) | ok |
| autotune run (probe) | | | | | | X (L5/L4) | X (L4) | ok (exe mismatch -> fail closed) | ok (fail-closed) | ok (fail-closed) | ok-ish (CLI blocks new runs; running probe tears down from memory) |
| autotune apply | | | | | | | X | RACE (component stop/restart during verification -> rollback reload may restart) | X (L1 check + queue detection) | X (same) | RACE-low (in-flight rollback rewrites config) |
| component update/install | | | | | | | | X (L7) | RACE-low | RACE (component stop vs subscription transition) | X (L7 + CLI) |
| list update | | | | | | | | | X (pidfile check + L1) | X (L1) | X (CLI; running worker killed by stop) |
| subscription update | | | | | | | | | | X (L2) | X for new (CLI); running one RACE-low |
| full_uninstall | | | | | | | | | | | X (L8) |

##### 4. Tests that should exist

1. Detached init.d start (fd 1000 open, as in repro_detached_start_lock.sh): a competing reload.lock acquire fails for the whole start, and release does not remove a foreign lock.
2. init.d start/restart exit-status contract: component set_direct_proxy rolls back when the runtime never becomes running although restart exits 0.
3. Restore with reload.lock held by a live non-init.d owner, and with a pre-existing reload.pending: no success, LKG unchanged, guard kept (repro_restore_queued_reload.sh as template).
4. Stop vs a subscription update or dns_failover_apply in flight: no sing-box start after stop succeeds.
5. Reload of a cleanly stopped runtime (shutdown_correctly=1) with reasons ruleset-cache or pending does not start Forkop; stop cancels ruleset-refresh workers.
6. foreign_pid_stop.sh extended to stop-list-update, stop-deferred-bootstrap-worker and cancel-scheduled-start-retry (repro_foreign_pid_kill.sh).
7. Lock helper: mkdir->pid window, two contenders on a dead owner, PID reused by another process, release by a non-owner (repro_lock_gap.sh).
8. Forced subscription update vs start: no lock-order stall.
9. Autotune worker lock not inherited by descendants: a SIGKILLed manager leaves the lock free and state crashed.
10. Full-uninstall lock blocks every mutating CLI command (table-driven over command_spec).
11. List update holding reload.lock does not starve DNS-failover apply indefinitely.
12. Start deferred by lock timeout schedules a retry.

##### 5. Further observations (not filed as findings)

- initd.uc:604-607: a start deferred because reload.lock was not released within 30 s returns 1 before mark_start_retry, so no retry is scheduled and, for non-UI starts, it is silent except for a warn log.
- lifecycle.uc:2168-2173: confirm-working after a successful start is a try-lock and is silently skipped when a snapshot operation holds L3, leaving LKG older. Safe direction.
- snapshots.uc apply mode (autotune): any unrelated actor that creates reload.pending during the apply's reload (a config trigger queued, a subscription 'reload_busy') makes the apply treat its successful reload as queued. It then rolls back: a spurious 'recovered', fail-safe.
- Read-only ACL includes get_ui_state, service_action_status, component_action_status, subscription_update_status and get_zapret_status. Polling these rewrites stale job state and removes old job files (ui.uc:716-767, updates.uc cleanup) and unlinks dead pidfiles (nfqueue/runtime.uc:279-290). This is runtime bookkeeping only; flagged for the RO-boundary auditor (invariant 1 wording).
- Ruleset-cache refresh (singbox/ruleset_cache.uc) has no lock. Concurrent refreshes from start, reload and the list worker can race on the manifest; entries are atomically renamed, so the worst case is a redundant download.
- UI restore is a synchronous rpc with a 120 s timeout (fe-app-forkop/src/forkop/methods/shell/index.ts:465-470). A long restore times out in the UI while snapshots.uc continues and holds L3 (later clicks report busy).

##### 6. Reproduction scripts

All in scratch/audit-a6a7\. Run with `wsl.exe -e bash -lc 'bash <path>'`; each uses a private mktemp directory.
- repro_detached_start_lock.sh
- repro_restore_queued_reload.sh
- repro_foreign_pid_kill.sh
- repro_lock_gap.sh
- flock_inherit.sh / flock_inherit2.sh (flock_inherit3.sh and 4.sh were debugging; on Ubuntu dash `1000>&-` becomes an argv word)

The procd.sh and rc.common sources used for the fd-1000 claim are in ~/.cache/flint2-openwrt/openwrt (package/system/procd/files/procd.sh:48-76,686; package/base-files/files/etc/rc.common).

## A8/A9 Атомарность, crash safety, износ flash

### Вывод

I audited every persistent write in forkop/files and the packaging and shell scripts at 07872084. The full inventory is in `extra`.

Most flash state is handled correctly. Snapshots, LKG, the list and rule-set caches, the subscription cache, the autotune state and apply record, the opkg recovery marker and binary installs all write a temp file and rename it into place. Most of them also skip rewriting identical content. All runtime, job and lock state lives in RAM (/var/run or /tmp), and no UI polling endpoint writes to flash.

Main defects:
1. **UCI commit failures are always reported as success (P2).** core/uci.uc checks `c.commit(pkg) != false`, but the ucode uci binding returns null on failure, and in ucode `null != false` is true (repro confirmed). dns/apply.uc also ignores the commit result entirely. So start/stop, the component toggles, urltest overrides and the postinst migration all report a failed write as saved. A failed dhcp restore can leave dnsmasq pointing at the stopped sing-box.
2. **No fsync before rename (P2, UBIFS).** No critical flash write is fsynced. ucode has no fsync, and the only `sync` in the backend is for the opkg recovery marker. On UBIFS, a power cut shortly after an autotune apply or a snapshot restore can leave /etc/config/forkop and the new snapshot and apply record as zero-length files.
3. **Runtime lock can be taken by two owners (P2).** The mkdir+pid lock in state.uc/initd.uc treats a lock whose owner has not yet written its pid as stale (repro confirmed). The reload lock and other locks can end up with two owners.
4. **Known P2, root cause confirmed:** the postinst chain aborts before package_postinst when the mirror is unreachable, so Forkop stays stopped after an upgrade.

Lower-severity (P3) findings:
- The sing-box config is published with a cross-filesystem `mv` (unlink then copy, not atomic). It is also rewritten on every DNS-failover transition.
- The dnsmasq reload rollback copies a whole-file backup over /etc/config/dhcp with `cp`. This is not atomic, bypasses the UCI lock and can overwrite dhcp edits made during the reload.
- The persistent list cache (up to 8 MiB) is fully rewritten on every successful list update, even when nothing changed, and the update interval has no lower bound (repro confirmed).
- A torn last line in history.jsonl swallows the next event (repro confirmed), and rotation is unlocked.
- An unreadable autotune-apply.json is read as 'no recorded apply'.
- Autotune state recovery renames the corrupt file away before the replacement is written, so a failed write loses the recovery cooldown.
- The autotune worker writes state.json to flash twice every 15 minutes while it is blocked (for example needs_attention).
- Shared system files (rt_tables, package feeds) are overwritten in place.

There are also some cleanup items (rewrites of identical content, stale temp files, crontab erase risk) and one FUTURE item (/etc/forkop is not kept across sysupgrade). No finding needs a product decision except the FUTURE item.

### Проверено и корректно

- autotune/state.uc:68-89 state.json written as tmp.<pid> + chmod 0600 + rename, and only when the content changed; a corrupt or foreign-version file reads as recovered_from and starts a cooldown (fails closed, autoapply.uc:45-46); applies capped at 20 (state.uc:28,85)
- autotune/manager.uc:218-238 every state.json read-modify-write is serialized by flock(STATE_LOCK); the worker lock is a kernel flock, released automatically if the worker crashes
- autotune/manager.uc:471-495 a crash during the 'applying' phase is recorded, counted against the daily limit and cooled down on the next run
- autotune/manager.uc:183-198 cron_write refuses an unreadable crontab and rewrites only when the text changed
- autotune/manager.uc:242-262 policy/target UCI edits use a private savedir (-t) and are refused when /tmp/.uci/forkop has staged changes; the uci exit status is checked
- autotune/apply.uc:686-687 apply state is persisted before any mutation (refuses with state_write_failed); refusals keep the previous record with last_attempt (656-667)
- config/snapshots.uc:93-116 snapshot lock: the owner record is written in a pending dir that is renamed into place, with pid + start-ticks identity (no half-initialised lock is visible)
- config/snapshots.uc:50-57,202,360,442 snapshot files and LKG pointer written as tmp + chmod 0600 + rename; create() dedupes by hash so reloads and confirm-working do not rewrite identical snapshots; retention of 10 protects manual snapshots, LKG and keep ids
- config/snapshots.uc:326-349 guarded_replace releases the restore guard only after a successful validate+reload; every failure path keeps the guard active or reports needs_attention (invariant 4)
- service/lifecycle.uc:399-404 confirm-working runs only after a successful reload with an unchanged fingerprint and no restore guard; start confirms only on success (2168-2173)
- components/updates.uc:736-757,1025-1081 list cache uses generation dirs with a manifest (size+md5), a stage that is never trusted, recovery of the previous generation after an interrupted swap, and capacity guards (8 MiB cap + free reserve); tests/list_cache.sh covers the phase-failure injection
- components/updates.uc:997-1003 the runtime (RAM) list generation is not re-published when unchanged
- singbox/ruleset_cache.uc:421-477 persistent rule sets are staged in the same dir, validated, then renamed; an unchanged download (md5 equal) is not rewritten; the manifest uses tmp+rename with a capacity check
- subscription/cache.uc:670-700,1377-1381 persistent subscription files are written only when changed (tmp+rename); the JSON is written before its URL/UA/HWID identity, so a crash leaves a detectably stale identity
- singbox/runtime.uc:679-692 the sing-box config is replaced only when its md5 changed (no identical rewrites)
- singbox/generator.uc:431,499-502 sing-box cache_file defaults to /tmp/sing-box/cache.db (RAM), so FakeIP/cache DB writes do not hit flash (etc/config/forkop:47)
- All runtime/job/lock/UI state is in RAM: lifecycle.uc:25-52, initd.uc:22-35, ui.uc:13-23, manager.uc:47-50, dns_failover.uc:12-14, health.uc:6-7 (EVENT_FILE); /var/run/forkop.internal-config-change is one-shot, tmp+rename (lifecycle.uc:515-527, initd.uc:390-399)
- Read-only UI/API endpoints (autotune_status manager.uc:98-114, get_health_status/get_history, get_ui_state, component_update_check_cache) do not write to flash; no per-poll flash writes found
- components/action.uc:2175-2182 opkg package-set recovery marker: tmp + rename + sync; action.uc:2320-2337 config backup: tar into a same-dir temp, verified with tar -t, then renamed; action.uc:1326-1352 binaries installed via a same-dir staged copy + rename (cross-fs safe)
- Managed /etc/init.d/sing-box is written to a temp file in /etc/init.d and renamed (runtime.uc:427-436, action.uc:858-867, validator.uc:1834-1846)
- full-uninstall.sh:99-103 repository restore uses a same-dir temp + mv (atomic)
- libuci behaviour checked locally with the OpenWrt uci CLI (scratch uci_behaviour.sh): setting an identical value creates no delta, and commit without a delta does not rewrite the file, so each start/stop costs only one /etc/config/forkop rewrite for shutdown_correctly; a stray '/etc/config/forkop.<ts>.tmp' is ignored by 'uci show/export'
- diagnostics/health.uc:13-16,89-111 history journal is on flash but bounded (<=200 records / 64 KiB, rewritten to the newest 150), accepts only 10 low-frequency event kinds (never probes/measurements), and skips unparsable lines on read

### Инвентарь

##### Persistent write inventory (tree 07872084)

Legend: FLASH = /etc,/www,/usr (overlay), RAM = /tmp,/var/run (tmpfs). Pattern: T+R = temp file + rename (none fsync unless noted), DIRECT = writefile/cp/> onto the live path (truncate-then-write), APPEND = O_APPEND.

###### Flash (overlay)
| Path | Writer (file:line) | Pattern | Frequency | Rewrites unchanged content? | Reader on partial/corrupt | Stale temp cleanup |
|---|---|---|---|---|---|---|
| /etc/config/forkop (UCI) | core/uci.uc:545 via lifecycle.uc:530 (shutdown_correctly 0/1 on start :1016, stop :1476, restart), action.uc:2513/2551 (UI toggles), urltest_override.uc:46/67/71, migration.uc:1600 (postinst) | libuci (temp .forkop.uci-X + fsync + rename) | per start/stop, user action, postinst | no (identical set -> no delta, commit w/o delta -> no rewrite; verified locally) | libuci parse error -> ucode load() null masked (uci.uc load returns true) -> defaults | libuci |
| /etc/config/forkop (UCI CLI) | autotune/manager.uc:253-262 `uci -c -t <private> commit` | libuci | user policy/target edits | no | same | private savedir rm -rf |
| /etc/config/forkop (raw) | config/snapshots.uc:330/340 atomic() (restore, autotune apply, rollback) | T+R `forkop.<s>.<ns>.tmp`, chmod 0600, **no fsync** (finding) | per restore/apply/rollback (<= max_applies_per_day autonomous) | n/a | uci ignores dotted temp names (verified) | never |
| /etc/config/forkop (defaults) | service/package.uc:201-213 | DIRECT | postinst only when missing/empty | - | - | - |
| /etc/config/forkop (mirror) | mirror-migration.sh:216-221 `uci set/add_list/commit` | libuci | every postinst | no | - | - |
| /etc/config/dhcp | dns/apply.uc:244/265 via uci commit | libuci; **result ignored** (finding) | start (configure), stop (restore), reload when the plan says | no (only real changes) | libuci | - |
| /etc/config/dhcp | lifecycle.uc:606-615 `cp backup /etc/config/dhcp` | DIRECT cp (finding) | reload failure after dnsmasq step | - | - | backup in /tmp removed |
| /etc/config/sing-box | singbox/runtime.uc:382 (configure_service :462-500 only if changed; disable_service_config :447-451) ; action.uc:885 | libuci | start / component actions | no | - | - |
| /etc/config/network | action.uc:2477 | libuci | user action | - | - | - |
| /etc/sing-box/config.json (default config_path) | singbox/runtime.uc:679-692 save_config_file `mv -f /tmp/tmp.X` ; restore :706/:831 ; patch_dns_config :769-825 | cross-fs mv = unlink + copy (finding) | start/reload when generated config changed; every DNS-failover transition | no (md5 compare) | Forkop regenerates at start | temp in /tmp |
| /etc/init.d/sing-box | runtime.uc:427-436, action.uc:858-867, validator.uc:1834-1846 | T+R same dir | runtime.uc on **every start** for the compressed variant (identical) | yes (cleanup) | - | `sing-box.forkop.<pid>` never cleaned |
| /etc/forkop/config-snapshots/<id>.json | snapshots.uc:196-204 | T+R + chmod 0600, no fsync | reload (dedupe by hash), confirm-working (dedupe), manual, pre-restore, before-autotune; retention 10, <=2 MiB each | no (dedupe) | read_snapshot validates id/hash/content (sha verify for restore/diff) -> invalid skipped (never deleted) | never |
| /etc/forkop/config-snapshots/last-known-working | snapshots.uc:344/360/442 | T+R | only when the LKG id changes | no | invalid id -> no LKG -> autotune 'config_not_last_known_good' (fail closed) | never |
| /etc/forkop/history.jsonl | diagnostics/health.uc:89-111 | APPEND one line; rotation T+R to 150 records when >200 or >64 KiB | per recorded event (start, reload, restore, recovery, autotune_apply/mode/recommendation/run failure, manual snapshot create/delete) | no | unparsable lines skipped; torn last line swallows the next event (finding) | never |
| /etc/forkop/autotune/state.json | autotune/state.uc:68-89 via manager with_state (flock) | T+R `.tmp.<pid>` chmod 0600; only if changed | >= 2 per worker run (begin_run, merge) + applying phase; every 15 min while blocked (finding) | no, but timestamps always change | corrupt/foreign -> recovered_from -> cooldown (fail closed); missing -> fresh; `.corrupt` kept | never |
| /etc/forkop/autotune-apply.json | autotune/apply.uc:211-216 | T+R `.tmp.<pid>` | per apply phase / refusal | n/a | read_json null -> treated as no record (finding) | never |
| /etc/forkop/list-cache (+.stage/.previous) | components/updates.uc:1025-1081 (also legacy migration :690-734) | copy files -> manifest (size+md5) -> timestamp -> validate -> dir swap | **every successful list update, even unchanged** (finding); cap 8 MiB + free reserve | yes | manifest md5/size validation; previous recovered after an interrupted swap (:736-757) | stage/previous removed at recovery |
| /etc/forkop/list-cache/last-success.timestamp | inside the generation (updates.uc:1051) | part of the generation | per update | - | int parse -> 0 -> due | - |
| /etc/forkop/ruleset-cache/*.srs,*.json | singbox/ruleset_cache.uc:421-436,452-477 | download /tmp -> cp to `<target>.download.<ts>` same dir -> validate -> rename | only when md5 changed | no | valid_cache (decompile / JSON rules) | temp unlinked on failure |
| /etc/forkop/ruleset-cache/manifest.json | ruleset_cache.uc:312-326 | T+R + capacity check | per refresh (last_success timestamps) | yes (timestamps) | object_or_empty -> entries due | - |
| /etc/forkop/ruleset-cache/*.validated | ruleset_cache.uc:234-237 | DIRECT | on first validation; **identical rewrite on unchanged refresh** (:472-474) | yes (cleanup) | mismatch -> re-validate | - |
| /etc/forkop/subscription-cache/<src>.json/.url/.ua/.hwid/metadata | subscription/cache.uc:1377-1390 (write_text_if_changed :670-690, copy_file :509-520) | T+R only if changed (chmod every time) | per subscription update per source | no | file_nonempty/identity compare -> stale -> refetch | copy_file temp not unlinked on writefile failure |
| /etc/forkop/subscription-cache/format | migration.uc:1532, cache.uc:655 | DIRECT | once (format change) | - | mismatch -> wipe + recreate cache | - |
| persistent subscription JSON links | subscription/share_link.uc:385-394 (migration.uc:1522 populate) | T+R | postinst when links must be populated | no | - | - |
| /etc/forkop/automatic-latency-test.pending | updates.uc:1181-1206 (write_state_file :265-279), diagnostics/runtime.uc:1699-1711 | T+R | usable-proxy-set change, failure backoff (<= 6 h) | - | read_json null -> discard marker | temp removed on failure |
| /etc/forkop/sing-box-variant, sing-box-version | singbox/runtime.uc:217-239 | DIRECT | component install only | - | first line | - |
| /etc/forkop/opkg-package-set-recovery/pending | components/action.uc:2175-2182 | T+R + `sync` | Forkop opkg upgrade | - | - | dir removed on failure |
| /etc/forkop-backups/configuration.tar.gz | action.uc:2320-2337 | mktemp in same dir, tar, tar -t verify, rename | explicit-version install | - | - | temp removed on failure |
| /etc/crontabs/root | updates.uc:1637-1650 (`crontab tmp`), lifecycle.uc:809-829 ; manager.uc:183-198 | busybox crontab (.new + rename) | updates.uc: **every start and stop unconditionally**; manager: only when changed | yes (updates.uc) | updates.uc reads `readfile ||\"\"` -> may erase lines on read error (cleanup) | temp in /tmp |
| /etc/iproute2/rt_tables | nft/apply.uc:1344-1354 ; service/package.uc:108-124 | DIRECT (finding) | first start after install; every prerm | no | iproute2 | - |
| /etc/opkg/distfeeds.conf, /etc/apk/repositories(.d), keys/forkop-mirror.pem, repositories.d/forkop.list | mirror-migration.sh:116,193,202 ; rollback :56 | DIRECT cp (finding); `.pre-forkop-mirror` created once (:115) | postinst when a change is needed | no (cmp -s) | - | transaction dir removed |
| same (restore) | full-uninstall.sh:99-103 | same-dir temp + mv (atomic) | uninstall | - | - | - |
| /www/forkop-uninstall.XXXX.json | full-uninstall.sh:47-50 | temp + mv | per uninstall phase | - | - | removed after 300 s by a background sleep (not across reboot) |
| /usr/bin/sing-box, /usr/lib/libcronet.so (component binaries) | action.uc:1326-1352 | same-dir staged copy + rename | component actions | - | - | staged temp removed on failure |

###### RAM (tmpfs) — crash irrelevant, listed for concurrency and completeness
- /var/run/forkop/{reload-state (DIRECT, service/state.uc:356-362), reload-state.snapshot.*, reload.pending, list-update.reload, ruleset-refresh-after-list, start.in-progress, start.failure, start.retry, start-retry.pid, service-triggers.sync (DIRECT, initd.uc:163-165/249/259/307; lifecycle.uc:264-266)}
- /var/run/forkop/{dns-failover.json (T+R dns_failover.uc:66-78), health-events.json (T+R, <=10 events, health.uc:130-143), system-info.json (T+R diagnostics/runtime.uc:960-972), ui-state/** (T+R ui.uc:163-179), component-actions, subscription-update-jobs, component-update-checks, list SRS validation stamps (updates.uc:559-566), runtime list generation (dir swap), section-cache (runtime.uc:709-735 fixed '.tmp' name; generator.uc:77-90), subscription runtime dirs, rule-condition-cache}
- /var/run/forkop/autotune/{worker.lock, state.lock (flock), lock (pending dir rename, autotune/lock.uc), jobs/*.json (T+R manager.uc:744-756, keep 10), last/*.json (T+R state.uc:117-120), active.json (DIRECT isolation.uc:917/1060)}
- /var/run/forkop/{snapshot-hash/.hash.* (temp, snapshots.uc:38-48), config-snapshot.lock (pending-dir rename)}; /var/run/forkop.internal-config-change (T+R, one-shot); /var/run/forkop.reload.lock and other mkdir+pid locks (race: finding); pid records via core/process_identity.uc:60-72 (T+R)
- /tmp: sing-box rulesets/subscriptions, /tmp/sing-box/cache.db (default cache_path), /tmp/forkop-package-was-running (package.uc:178, the upgrade hand-off), /tmp/forkop.latest-version.cache, /tmp/forkop-torrserver-direct.nft (fixed name, torrserver/direct.uc:92-101; the worker and reconcile could clobber each other, harmless), /tmp/forkop-full-uninstall.lock, mktemp work files (nft batches, candidates, backups).

###### Facts verified locally
- ucode (WSL build): `null != false` -> true; `fs.writefile` returns a byte count (0 for empty content, so `!fs.writefile(...)` treats an empty write as failure); file handles have no fsync (flush/fileno/truncate/lock only).
- Upstream ucode lib/uci.c: commit()/set() return null on error (err_return).
- OpenWrt uci CLI: setting an identical value creates no delta; commit without a delta keeps the inode (no rewrite); a file named 'forkop.<n>.<n>.tmp' in the confdir is ignored by `uci show`/`uci export`.
- Scratch repros (scratch/\audit-atomicity\\): repro_uci_commit.sh, repro_history_torn.sh, repro_lock_steal.sh, repro_list_persist.sh, uci_behaviour.sh, nullcmp.uc.

###### Answers to specific questions
- history.jsonl (698e6229): /etc/forkop/history.jsonl on flash. One O_APPEND line (~80-120 B) per recorded event; every append re-reads the file. Rotation happens only when >200 records or >64 KiB, rewriting the newest 150 via temp+rename (bounded ~64 KiB). Only 10 low-frequency kinds; probes and measurements are never recorded. Weak points: torn line, no lock, no fsync.
- Corrupt autotune state -> cooldown/daily-limit reset? For a corrupt or foreign file, no: it fails closed via recovered_from + recovered_at. The gaps are a missing file (rename-before-write ordering) and a corrupt autotune-apply.json (read as absent).
- UCI commits: no identical rewrites. Failures are masked (core/uci.uc `!= false`; dns/apply.uc ignores the result).
- Snapshots/LKG: atomic via temp+rename, deduped, retention bounded, lock record published atomically; no fsync.
- Generated sing-box config: md5-guarded, but published with a non-atomic cross-fs mv.
- Job/async state, component update caches, UI state, locks, DNS-failover state: all in RAM.
- Unbounded growth: none found on flash. Largest: snapshots (10 x <=2 MiB, manual snapshots and LKG excluded from retention), list cache (<=8 MiB), history (<=64 KiB). Leftover temp files (*.tmp, *.tmp.<pid>, sing-box.forkop.<pid>) accumulate only after crashes and are never cleaned.
- High-frequency flash writes found: full list-cache persistence per list update (interval unbounded), state.json twice per 15 min while autotune is blocked, config.json per DNS-failover transition, crontab and managed init script per start/stop. No per-poll or per-request flash writes.

###### Known hardware-report items in this area
- The P2 'upgrade leaves Forkop stopped' item is confirmed in code: build.sh:300-302/438/461 and forkop/Makefile:55-57 chain; mirror-migration.sh:131-145,168 exits 1 under set -e when the default mirror index is unreachable; the prerm marker /tmp/forkop-package-was-running (service/package.uc:178) is then never consumed. The core/uci commit masking finding means the 'migrate' step itself practically never fails, even when its commit did.
- The other listed hardware items (UI layout, i18n, snapshot diff '***', modal focus) are outside A8/A9.

## A10 Снимки, LKG, восстановление

### Вывод

The snapshot and restore design mostly holds on 07872084. Storage is 0700/0600 with atomic writes. Diff masking is allowlist-based. The lock uses PID plus start ticks and never kills a process. The guard stays on every failure branch. Invariant 6 holds: `ensure-dpi-transition-guard` reuses a valid guard. Retention protects manual, LKG and keep snapshots. Delete refuses LKG. Autotune apply and restore are serialised by the snapshot lock. The tests `config_snapshots`, `config_restore_guard` and `history_journal` pass.

The main defect (P1, reproduced): restore treats a reload that `initd.uc` only queued as applied. When another lifecycle action holds `reload.lock`, `/etc/init.d/forkop reload` queues the request and exits 0. The restore passes no queued-detection flag (only autotune apply mode does), so it reports success, releases the restore guard and moves LKG to a target that never ran. This breaks invariants 3 and 4, and the UI shows a success it did not observe.

P2 findings:
- **Autotune rollback overwrites concurrent edits (reproduced).** When verification fails, autotune rolls back to its pre-apply snapshot unconditionally. A Save & Apply or restore made during verification is reverted and reported as a clean `rolled_back`.
- **Snapshot diff loses changes in anonymous sections (reproduced, and seen in the hardware diff).** The diff parser does not recognise anonymous UCI sections (`config section_interface` with no name), which child items use. Their options are counted under the previous named section and collide. Changes disappear from the diff and the restore preview, or appear under the wrong section.
- **A kept lifecycle DPI guard makes restore unreliable (static trace).** The guard `ForkopTableDpiGuard` stays after a failed DPI rollback. Restores that need a DPI restart then always fail, and other restores report success while the DPI guard is still active.

P3 findings:
- The second-resolution pending-reload marker defeats queued detection in autotune apply mode (reproduced 5 out of 5).
- Ten manual snapshots use up retention. Restore, LKG advancement and autotune stop working, the UI gives only a generic message, and a refused restore is recorded as a failure.
- The History page shows needs_attention as "In progress".
- Autotune writes duplicate and premature history events.
- The label "Before applying changes" is wrong: the snapshot holds the new configuration.
- Restore ignores staged UCI changes.
- The restore rollback overwrites edits made during the reload.
- Restoring an old-version snapshot skips config migration.
- Snapshot commands are not blocked during full uninstall.
- Known hardware item: the diff shows *** for absent values. Cause: absent is modelled as "" and `safe_value` masks ""; a product decision is needed.

### Проверено и корректно

- Snapshot storage: ROOT and the lock parent are created 0700, files are chmod 0600 through atomic tmp+rename (snapshots.uc:50-63). Snapshot content is never printed: list gives metadata only, diff gives masked rows (142-148, 391-403).
- Diff masking is an allowlist: only enabled/action/dns_type/dns_strategy/disable_quic with a token regex, and dns_server/bootstrap_dns_server with an IP-character regex (206-212). Everything else, including every multi-line value, is '***'. Quoted multi-line values are parsed as one value, continuation lines included (215-260; tests/config_snapshots.sh multi-line cases pass). A read-only session can reach only list and diff (ACL read section lines 21-22, readonlyCommandGuard.ts). fixture-diff cannot be reached from the CLI (forkop:194-198 maps diff with 1 arg).
- Invariant 3 on the non-queued path: LKG is written only after validator success, reload success and guard release (snapshots.uc:336-338, 359-361). The recovered path writes LKG=pre only after the rollback reload succeeded and the guard was released (342-345). The lifecycle runs confirm-working only for status 0 with an unchanged fingerprint and no ForkopConfigRestoreDpiGuard (lifecycle.uc:400-404). Apply mode never moves LKG. Autotune confirms only after verification and after re-checking the fingerprint (autotune/apply.uc:741-753).
- Invariants 4 and 5: every failure branch of guarded_replace keeps the guard (guard:'active') and returns needs_attention (snapshots.uc:327, 331, 337, 341, 343, 347). The CLI exits 1 for failed/needs_attention (447). History records 'failure' (429-430). The UI shows an error toast (initController.ts:279-284), and Overview shows 'Protection is active' while any guard table exists (health.uc:211-213).
- Invariant 6: ensure-dpi-transition-guard reuses a guard whose nft -j structure matches exactly, creates a missing one, and fails closed on anything else (nft/apply.uc:1740-1764). tests/config_restore_guard.sh (6 cases, including a second restore after needs_attention) and dpi_restore_guard_verify.sh pin this; config_restore_guard PASSes on this tree.
- Pre-restore snapshot: created before any mutation, with the target protected through keep (snapshots.uc:356). A concurrent change between the snapshot and the guard is refused (358). A restore never prunes its own target (pinned by tests/autotune_apply.sh:667-675).
- Retention: RETENTION=10. Manual snapshots, LKG and keep ids are never pruned; the oldest automatic one goes first (164-178). Autotune apply reserves room for the before-autotune snapshot plus a rollback pre-restore snapshot, and one more slot when LKG is manual (378-383).
- Delete refuses the LKG id (snapshots.uc:422), and the UI disables delete for is_lkg (model.ts:219-220). The guard does not reference any snapshot, so no delete can orphan a guard.
- Snapshot lock: the owner record is owner.<pid>.<start ticks> and is published complete via rename. A stale lock is reclaimed only when the owner is dead or its PID was reused, with argv identity checked. A symlink or garbage lock is never followed. Release cannot remove a lock that replaced ours, and no process is ever signalled (snapshots.uc:64-128; tests/config_snapshots.sh lock scenarios pass). Invariants 13 and 14 hold here.
- Autotune/restore serialisation: snapshots.uc apply and restore take the same lock. apply.uc refuses when a guard is present, a snapshot operation or service action is running, a reload is pending, or uncommitted uci changes exist (apply.uc:561-568). Its transaction calls run under setsid (86-91).
- Restore history: exactly one restore event per snapshots.uc run (success/recovered/failure). autotune_apply is recorded by snapshots.uc only when the transaction started (snapshots.uc:435).
- The UI restore flow confirms with a diff preview, maps busy/success/recovered/other to distinct toasts, and blocks double actions (snapshotBusy). is_lkg is now returned by list (list_snapshots:158).
- Crash safety of persistent state: the config file is replaced atomically, so it is never partial. LKG moves only at the end of a successful transaction. A stale snapshot lock lives on tmpfs and is reclaimed. The pre-restore snapshot preserves the previous file.
- Tests run on this tree: config_snapshots, config_restore_guard and history_journal all PASS (tests/runner backend lane).

### Инвентарь

##### A10 inventory: snapshot / LKG / restore / recovery (commit 07872084)

###### Property matrix
| Property | Status | Where |
|---|---|---|
| Inv 3: failed target never becomes LKG | Holds only while the reload really runs. **Broken when initd.uc merely queues the reload** (P1). In apply mode it is fragile because the pending stamp has 1 s resolution (P3). | snapshots.uc:314-347, 359-361; initd.uc:712-756 |
| Inv 4: restore guard removed only after a coherent runtime | Same queued-reload hole (P1). A kept lifecycle ForkopTableDpiGuard is not considered (P2). | snapshots.uc:336-347; lifecycle.uc:1225, 1291 |
| Inv 5: needs_attention never shown as success | Backend is correct (exit 1, event failure, guard kept). UI shows it as 'In progress' (P3). Queued reload shown as success (P1). | health.uc:164-180; model.ts:68-72 |
| Inv 6: an existing valid guard allows recovery | OK for ForkopConfigRestoreDpiGuard (ensure + JSON structure check; test config_restore_guard.sh). Not OK for a kept lifecycle ForkopTableDpiGuard (P2). | nft/apply.uc:1740-1764 |
| Pre-restore snapshot | OK: created before any mutation, keep=[target], concurrent-change check. Refused when retention is full of manual snapshots (P3). | snapshots.uc:356-358 |
| Rollback on failed restore | OK: before is written back, reloaded, guard released, LKG=pre, 'recovered'. Can overwrite edits made during the reload (P3). | 340-347 |
| Crash mid-restore | Before guard: nothing changes, stale lock reclaimed. After guard, before write: guard stays until a restore succeeds or reboot (stop/restart do not remove it: lifecycle.uc:1086 removes only ForkopTableDpiGuard). After write: file = target, LKG = old, no event. Reboot: guard gone, boot starts the target, nothing flags it (FUTURE). Persistent files are always whole (atomic). | — |
| Retention | 10 total. Manual, LKG and keep never pruned. Apply reserves 2-3 slots. Ten manual snapshots block every automatic snapshot, confirm-working and restore (P3, reproduced). | 164-187, 378-383 |
| Delete LKG / guard-referenced | LKG refused (backend + UI). The guard references no snapshot. Autotune's before-autotune snapshot is deletable or prunable; rollback() then falls back to LKG only if the fingerprint matches, else 'pre_apply_snapshot_missing' (fail closed). | 422; apply.uc:771-781 |
| Diff masking | Allowlist; multi-line values parsed whole; no content leak; read-only sessions reach only list/diff. Anonymous sections misattributed (P2). Absent value shown as *** (P3, known). Output silently truncated at 100 rows (UI 'and N more' then under-counts). | 206-295 |
| Events | One restore event per run. Refused restores recorded as failure (P3). Autotune duplicates: snapshots.uc 'autotune_apply' + manager.uc 'autotune_apply' + rollback 'restore' (P3). A restore also yields lifecycle 'reload' events (expected). 'recovery' kind is dead (CLEANUP). | snapshots.uc:417-437; manager.uc:450 |
| Autotune ↔ restore interleaving | Transactions are serialised by the snapshot lock. Apply refuses on guard, snapshot operation, service action, pending reload or staged uci changes. **Gap:** the lock is released during verification; a user restore or Save & Apply there makes verification fail and the automatic rollback reverts it (P2, reproduced). Restore has no staged-uci check (P3). | apply.uc:561-593, 738 |
| Autotune creates snapshot/LKG correctly | Yes: before-autotune snapshot (dedupe off) inside the transaction; LKG not moved by apply; confirm-working only after verification and a fingerprint re-check. Small TOCTOU between that check and the separate confirm-working process (ms window, not reported). | snapshots.uc:369-390; apply.uc:741-753 |

###### Known hardware item: '***' for absent values
Root cause: at snapshots.uc:286-290 an absent option is modelled as "", and safe_value (206-212) masks "" because its allowlist regexes need at least 1 character. It is pinned by tests/config_snapshots.sh (`diff('', lines("option action 'x'"))` gives `before: '***'`). The UI's diffValue already renders ''/undefined as '—' but never receives them. Options: (A) null for an absent side, rendered as '—'/'not set' (recommended); (B) '' allowed for all options (conflates empty with absent); (C) explicit presence flags. No secret exposure: the option name is already shown. The hardware probe rows 'Alloha · section' and 'Alloha · name' are also evidence of the anonymous-section defect.

###### Other observations (not reported as findings)
- Restore on a stopped service starts Forkop: reload goes to restart_runtime_for_reload (lifecycle.uc:1708-1711). Consider stating this in the confirm dialog.
- A 'recovered' restore sets LKG to the pre-restore snapshot even when the target was the previous LKG. The old LKG loses its protection and becomes prunable once automatic.
- ForkopConfigRestoreDpiGuard is not removed by stop, restart or full uninstall (only by a successful restore/apply or reboot).
- The synchronous restore RPC uses a 120 s client timeout (shell/index.ts:465-470). A long reload returns a generic error while the restore continues; not verified on hardware.
- A manual create during autotune verification with 10 snapshots can prune the before-autotune snapshot; the rollback then fails closed as needs_attention.

###### Reproductions (scratch, WSL)
All in scratch/audit-a10\
- restore_queued.sh: P1 (real initd.uc queueing)
- apply_queued.sh: P3 stamp resolution (5/5 'recovered' with 0 reloads)
- at_harness.sh (+ scenario_rollback_overwrite.sh): P2 autotune rollback overwrite
- anon_diff.sh: P2 anonymous sections (libuci-written fixture, empty diff)
- retention_manual.sh: P3 retention exhaustion

Tests run: config_snapshots, config_restore_guard and history_journal all PASS. The audit tree is unchanged (git status shows only the pre-existing untracked tests/runner/).

## A11/A12 Autotune и каталог Zapret/nfqws

### Вывод

I walked the whole autotune pipeline in this order: catalog, validation, contract, isolation, probe, select, groups, state, hysteresis, scheduler/manager, autoapply, manual apply, apply.uc Stage 5, rollback, history, crash recovery, and the frontend Autotune page. The safety core holds. "direct" never mutates anything. The only mutation is one nfqws_opt of an existing zapret rule, proven by a semantic diff. Group conflicts are never auto-resolved. apply.uc is the only mutation engine. Probe queues and marks stay isolated from production. PID reuse is handled.

The product layer around that core has four P2 defects:
(1) Autotune does not work at all with default settings. The default policy uses probes=5 (the UI allows 3..7). There are 8 supported TCP candidates, and 8x5=40 is above the isolation limit of 32 probes per run. So every real tune is refused with too_many_probes, and no recommendation is ever produced. I reproduced this in WSL, the router's catalog output confirms all 8 candidates are supported, and it is hidden because the manager tests use a stand-in isolation tool.
(2) Recommendations for rules with a multi-profile strategy can never be applied. This includes the default strategy that the rule editor writes for every new zapret rule. The UI still shows "Recommendation confirmed" and an Apply button. The apply fails with no explanation, and auto mode silently retries it on every scheduled run.
(3) If the process crashes or is interrupted between reload and verification, the unverified candidate stays live. The next lifecycle start or reload confirms it as last-known-good (LKG). Autotune then only records the crash and blocks further runs. There is no rollback path in the CLI or UI, although design H.7/H.8 promises one.
(4) If a rollback's restore reload fails, snapshots.uc moves LKG to the candidate that just failed production verification (invariant 3).

There are also several P3 honesty and UI issues:
- Every apply writes two history events, and the first says success before verification. The rollback is recorded as "restore", not as its own kind as design H.6 requires.
- The UI shows the candidate_bypassed reason with a positive text.
- A "failed" outcome shows as "Outcome unknown", and every needs_attention shows as "Rollback did not finish".
- Changing the autotune policy or targets during an apply's verification forces needs_attention.
- Manual runs count toward the confirmations that autonomous apply relies on.
- The orphan cleanup can kill a foreign nfqws that matches its signature.

I confirmed two known hardware-report items with root causes: the Russian plural strings, and the missing Overview autotune card. The Zapret/nfqws catalog inventory and the Stage 7 opportunities are in 'extra'.

### Проверено и корректно

- Invariant 7 ('direct' never mutates): select may pick direct, but groups.uc:66-69 turns it into direct_stable, autoapply.uc:39 and manager.uc:624 refuse it, apply.uc:467-476 returns no_change_required/direct_not_applicable before any mutation, and valid_plan (apply.uc:639) rejects selected==direct
- Invariant 8 (only an existing DPI rule changes): build_candidate (apply.uc:184-206) sets one <section>.nfqws_opt on a private uci copy and proves exactly one semantic change (section, nfqws_opt) with snapshots fixture-diff; stale_reason (apply.uc:561-593) re-derives the candidate from the catalog and requires TCP/443 profiles on both sides
- Invariant 9 (conflicts not auto-resolved): groups.aggregate (groups.uc:70-84) returns conflict with no recommendation when targets need different strategies or the candidate is not stable for all; hysteresis resets on conflict (hysteresis.uc:72-79); decide requires status recommendation
- Invariant 10 (single mutation engine): autoapply (manager.uc:545-558) and manual apply (manager.uc:699) both go through apply_group, i.e. apply.uc plan + apply; manager's own uci writes touch only autotune/autotune_target sections, and target_set refuses ids of other sections (manager.uc:295-296 id_in_use); no other nfqws_opt writer in autotune
- Invariant 12 (no production NFQUEUE): probe queues 4600-4607 are checked against zapret 4000-4255 and zapret2 4300-4555 (isolation.uc:92-95,140-144,1158-1162); queue_check refuses a run-range queue that is bound or referenced in the ruleset (isolation.uc:362-369); the probe rule queues without bypass, and 'candidate_bypassed' invalidates a fail-open run
- Invariant 11: contract.uc proves the probe-mark bypass, the reply path, foreign chains and policy routing semantically from the live ruleset and ip rules; it relies on nothing but 'bypass first' order within a chain (contract.uc:444-476); the snapshot table is re-checked against the contract (isolation.uc:829-837), and production before/after equality is enforced (isolation.uc:987-1007)
- Invariant 14 / PID reuse: nfqws pidfiles and the autotune lock use start ticks plus exe plus argv (process_identity.matches_record; lock.uc:32-40; isolation.uc:432-440)
- Invariant 1 (RO): the ACL read group exposes only autotune_status/target/groups/run_status (acl.d), and all four are read-only in manager.uc (status/target/groups/run_status write nothing; worker_view opens the lock file read-only)
- Invariant 2: state, UI and history carry catalog ids only, never raw user strategies (state.uc summarize; dpi_strategy.view; health.uc event_view candidate regex); the clash API secret goes through a mktemp header file, never argv (apply.uc:309-321)
- Invariant 5: apply.uc needs_attention propagates to autoapply.outcome (counted, cooldown, failure), to the manual result status 'failed', and to the UI attention alert with a History link; it is never reported as success
- A cached result is never counted as a new measurement: run_locked aggregates only updates.targets (manager.uc:536-538); results[] gates apply on the representative measured in this run (manager.uc:548)
- Plan/candidate consistency: apply_group requires plan.owner.section == group and plan.selected == aggregate.candidate (manager.uc:433-434); verify checks the production nfqws argv exactly equals [--qnum, --dpi-desync-fwmark, ...candidate words] (apply.uc:376-384), which matches the production supervisor argv (providers/nfqueue/runtime.uc:374-379; zapret/common.uc base_args)
- One resolver implementation: groups (manager.uc:153), plan/verify owner_of (apply.uc:138-157) and diagnostics all use routing/resolve.uc with the same TCP/443 target defaults (resolve.uc:151-161); the group key (section_for_outbound) and the zapret identity (routing mark and tag convention) cannot diverge, because UCI names cannot contain '-'
- Target IP: the tune pins one resolved address, and any probe answered by another IP makes the run inconclusive (isolation.uc:995-1010); apply re-resolves via the same resolver and requires the pinned IP to still be present (apply.uc:583-584); production verification uses the real FakeIP path (FakeIP answers, queue plus rule counters, clash tracker chain) (apply.uc:396-430)
- Scheduler: the WORKER_LOCK flock is non-blocking (manager.uc:588-589), so cron, manual runs and jobs never overlap; if_due checks mode, next_run_at and enabled targets; skipped runs retry after 900 s; at most one apply per run (manager.uc:545)
- Daily limit: a rolling 24 h epoch window (autoapply.uc:24-29) with no timezone or day-boundary issue; manual applies never counted (manager.uc:447); applies that crashed in auto mode counted and cooled down (manager.uc:477-487); stale/busy/no_change and plan refusals are not counted and cause no cooldown
- Hysteresis math: count capped at required; the confidence gate; inconclusive streak of 2 resets; fingerprint change resets; ready = count >= required (hysteresis.uc:32-85); select.median rounds even samples correctly; stability thresholds are consistent with MIN_STABLE_SUCCESSES
- Crash bookkeeping: begin_run detects a worker left 'running' in flash, records autotune_run failure and pushes an 'unknown' apply record (counted only if automatic) plus a cooldown; manual_apply's finish() restores the previous worker record without double counting
- State file: atomic temp+rename, written only on change; a corrupt/foreign file is kept as .corrupt and recovered_at is set; autonomous apply waits cooldown_seconds after recovery (state.uc:49-89, autoapply.uc:45-46)
- Manual apply (6.9.1) rechecks mode, readiness, confidence, age (<= 2 intervals), cooldown, catalog support, custom strategy, rule fingerprint, current strategy, target set, representative full measurement and host, and the resolver before any plan (manager.uc:619-713); every refusal happens before mutation
- Concurrent edits during measurement: merge() keeps a target's summary only if its host is unchanged (manager.uc:382-405); mode is re-read before apply (manager.uc:423)
- Probe teardown: probe rule released to accept before nfqws stops, hold until no socket of the tuple remains (TIME_WAIT), table kept if not settled, recovery data removed only after verified clean (isolation.uc:651-724)

### Инвентарь

##### A11 pipeline walk (07872084)

**catalog -> validation**
- catalog.uc has 9 fixed templates; 8 are TCP (direct plus 7 DPI templates).
- validate_entry blocks ipfrag, runs the zapret validator, checks the binary exists, then runs `nfqws --dry-run --qnum=4600 --dpi-desync-fwmark=MARK`.
- udp_fake is disabled with reason quic_probe_unavailable.
- On the router all 8 TCP templates are "supported" (s5-hw-ro.out).

**contract.uc**
- It proves 7 properties from nft JSON, ip rules and legacy iptables:
  - the probe-mark bypass comes first in every production output-path chain;
  - foreign output-path chains are safe;
  - the inbound/reply path is safe;
  - policy routing and mark layout are safe.
- It is thoroughly tested in tests/autotune_contract.sh.

**isolation.uc**
- Temporary table `ForkopAutotuneProbe` with chains premark@-152 and output@-151 (route type).
- Traffic is confined to the tuple dst IP:443 from source ports 61000-61031.
- One nfqws per candidate on queues 4600+.
- Candidates are switched by atomic `replace rule`.
- Teardown: release the probe rule, stop nfqws by identity, hold until no socket of the tuple is left, check the production queues are quiet, delete the table, verify clean.
- The production before/after snapshot (ForkopTable hash, queues, zapret children, guards, ip rule hash, route) must be equal.

**probe.uc**
- curl with `--resolve` pinned to the IP and `--local-port` range.
- It classifies transport stages; the HTTP status is informational only.

**select.uc**
- Stability classes: stable >= 0.8 with at least 3 successes; unstable >= 0.5.
- Among the best-ratio stable candidates it takes the simplest, unless another is materially faster (25 ms / 20%).
- Confidence is high only when success is 100% and direct failed, the choice is direct, or there is no control.

**groups.uc**
- classify via routing/resolve.uc, zapret only.
- aggregate:
  - conflict if targets need different strategies or the candidate is not stable for all;
  - direct_stable if everything works directly;
  - no_change if the candidate equals the current strategy;
  - representative = the highest-confidence target.

**state.uc**
- Flash state.json holds summaries, groups, applies (at most 20), worker, rotation, next_run_at, recovered_at.
- tmpfs `last/<id>.json` holds the full tune output.

**hysteresis.uc**
- N same-candidate confident observations make the group ready.

**manager.uc**
- if_due via cron `*/15`; worker flock; one group per scheduled run (rotation).
- Blocker via `apply.uc status`.
- apply_group: plan, owner/candidate check, apply, outcome.
- Manual apply (6.9.1) re-checks everything.
- Jobs; crash detection (6.8.6).

**autoapply.uc**
- decide gates: mode auto, trigger schedule, ready, high confidence, not custom, no cooldown, recovery cooldown, rolling daily limit.
- outcome mapping: applied is counted; rolled_back is counted with cooldown; stale/busy are free; everything else is counted, cooled down and recorded as failure.

**apply.uc (Stage 5)**
- plan: FakeIP-routed target, decided zapret owner, single TCP/443 profile, candidate built by uci on a private copy, exact-one-change diff.
- apply:
  1. unresolved-previous check;
  2. stale_reason (guards, snapshot operation, service action, probe table, uncommitted uci, config hash, LKG fingerprint, strategy, owner, runtime on the planned strategy, target resolution, candidate re-derived);
  3. snapshots apply (before-autotune snapshot, guarded reload);
  4. verify_production: 13 checks, plus 3 production curl probes, queue and rule counters, and the clash tracker path;
  5. rollback_to (restore), or confirm-working.

##### Findings index
- **P2:**
  - probes budget mismatch (autotune dead with defaults);
  - non-TCP443 rules shown as applicable;
  - crash/interrupt in verification: LKG promotion, no rollback path;
  - restore "recovered" branch moves LKG to the failed candidate.
- **P3:**
  - double history events and rollback recorded as restore;
  - candidate_bypassed shown as a positive finding;
  - failed / needs_attention labels;
  - policy writes during verification;
  - manual runs count as confirmations;
  - orphan kill by signature;
  - known: plural forms, Overview card.
- **CLEANUP:** duplicated production_dns / tcp443_profile.
- **FUTURE:** A12.

##### Additional observations (not filed, low impact or theoretical)
- **Apply-record trimming.** `state.applies` is trimmed by count (MAX_APPLY_RECORDS=20), not by time. With max_applies_per_day >= 2 and one always-ready but never-applicable group producing a not_applied record every run, a counted record could fall out of the 24 h window. That needs about 20 attempts in under 24 h, which is practically unreachable at interval >= 1 h with alternating groups. Trimming only records older than 24 h would be safer.
- **Manual apply after state corruption.** The manual path refuses state_recovered only while `recovered_from` is set, and ignores recovered_at. Cooldowns lost with a corrupt state do not stop a manual re-apply once confirmations rebuild.
- **Clock jumps.** `if_due` uses `now < next_run_at`. A backward clock jump on an RTC-less router (a previously wrong future time) can postpone scheduling until the clock catches up. A sanity cap (next_run_at - now > interval + retry means due) would help.
- **UI poll timeout.** The UI stops following a run job after 20 min (`JOB_TIMEOUT_MS`) with no toast. A full "Check all" with 12 or more targets exceeds this, because each target costs at least the ~60 s TIME_WAIT hold plus up to 32 probes of up to 10 s each.
- **UDP traffic after apply.** Production queues the rule's UDP to nfqws too, and a TCP-only candidate leaves QUIC untransformed. This is identical to the previous TCP-only profile, so nothing is lost, but QUIC-dependent targets are never tuned.
- **Fingerprint exposure.** The rule fingerprint (FNV-1a of zapret rule options) is visible to RO via autotune_status/groups. It covers zapret rules only (no secrets); acceptable.

##### Test coverage gaps and stub realism
- **Manager-level suites use stand-ins.** autotune_scheduler, autotune_autoapply, autotune_manual_apply and autotune_recovery all use stand-ins for isolation.uc and apply.uc (tests/helpers/autotune_scheduler). Three contracts between the layers are never exercised:
  - the probe budget (finding P2-1: the scheduler test even asserts probes=5 is passed);
  - real apply.uc plan refusals for default-strategy rules (P2-2);
  - the snapshots and health history side effects (P3 double events).
- **autotune_apply.sh** uses the real snapshots and LKG but stubs guard, validator, health, reload, uci, curl and nft. Nothing covers:
  - restore failure during rollback (P2-4);
  - a crash in phase verifying followed by lifecycle start confirm-working (P2-3).
- **Stub realism:**
  - The nfqws stub accepts every `--dry-run` (reject only through NFQWS_STUB_REJECT). This matches the v72 device output.
  - The nft stub is a simulated rule-state machine, not real nft semantics. The contract logic is exercised on recorded real rulesets (fixtures), which is good.
  - The curl stub simulates per-queue outcomes and queue counters.
  - dig is stubbed.
  - No test covers ClientHello realism or real port and TIME_WAIT behaviour of `curl --local-port`. The 32-port budget assumption is not validated on hardware beyond a 12-probe run (hw3: 4 candidates x 3 probes).
- **Missing tests:**
  - a full catalog tune with policy defaults;
  - an Overview autotune card;
  - UI mapping tests for failed/needs_attention and for candidate_bypassed;
  - an ACL/CLI test for a rollback command (the command does not exist).

##### A12 Zapret/nfqws catalog inventory

###### CURRENT COVERAGE
All entries are TCP/443 only, with `--filter-tcp=443`, IPv4, no hostlists (the analyzer forbids them), and `--dpi-desync-fwmark` from Forkop.

| Template | Rank | Options |
|---|---|---|
| direct (control) | 0 | — |
| multisplit | 1 | `split-pos=1,midsld` |
| fake | 2 | `fooling=badsum`, `fake-tls-mod=rnd,dupsid,sni=www.google.com` |
| multidisorder | 2 | `split-pos=1,midsld` |
| fakedsplit | 3 | `split-pos=midsld`, badsum |
| fake,multisplit | 3 | `1,midsld`, badsum, tls-mod |
| hostfakesplit | 3 | badsum |
| fake,multidisorder | 4 | `1,midsld`, `repeats=11`, badsum, tls-mod (the TCP/443 part of the Forkop default) |
| udp_fake (QUIC Initial fake, `repeats=11`) | 2 | defined but disabled (no QUIC probe) |

Covered dimensions:
- desync modes: fake, multisplit, multidisorder, fakedsplit, hostfakesplit, and 2-stage fake+split;
- fooling: badsum only;
- split positions: 1, midsld;
- fake payload: built-in TLS fake with mod rnd, dupsid, sni;
- repeats: 1 or 11.

###### MISSING SAFE CAPABILITIES
These use the same TCP/443 outbound-only shape and are measurable by the current isolation.

**New strategy families:**
- fakeddisorder;
- split-seqovl variants (`--dpi-desync-split-seqovl`, `--dpi-desync-split-seqovl-pattern`);
- syndata (`--dpi-desync=syndata`, `--dpi-desync-fake-syndata`).

**Variations of existing templates:**
- alternative split positions (host+1, sniext+1, endhost-1, midsld±2; the legacy default used `1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1`);
- other fooling methods (datanoack, badseq with increments, ts, md5sig — md5sig can break some servers, so needs care);
- fixed `--dpi-desync-ttl`;
- `--dpi-desync-fakedsplit-mod` and `--dpi-desync-hostfakesplit-mod` / `-midhost`;
- custom fake TLS payload files (`--dpi-desync-fake-tls=<file>`);
- `--dpi-desync-fake-tcp-mod`;
- repeats sweep;
- `--dpi-desync-cutoff` / `--dpi-desync-start`;
- `--dup*` options.

All options are already accepted by providers/nfqueue/validator.uc.

###### EXPERIMENTAL CAPABILITIES
These need isolation or probe extensions first.
- **Needs inbound queueing:** `--dpi-desync-autottl`, `--orig/dup-autottl` and `--wssize` need incoming SYN-ACK/replies in nfqws conntrack. The probe path queues outbound only, so these would silently not act.
- **ipfrag1/ipfrag2:** excluded, because fragments lose the TCP header for the tuple rules.
- **UDP/QUIC:** udp_fake, fake-quic/stun/discord/wireguard, and udplen needs a QUIC or UDP probe (curl `--http3` availability on OpenWrt).
- **IPv6 only:** hopbyhop and destopt; probes are IPv4-only (`--ipv4`, public_ipv4).
- **Other modes:** rst/rstack.
- **HTTP (tcp/80):** methodeol, hostcase, split-http-req; the probe is HTTPS only.
- **Other providers:** zapret2 (lua) and byedpi are not supported (groups.uc:28-29).

###### FUTURE STAGE 7 OPPORTUNITIES
1. **Multi-profile strategies.** Let Stage 5 replace only the TCP/443 profile inside a multi-profile strategy (the rule editor's default), with a semantic proof that the other profiles are unchanged. This is the prerequisite for autotune on default installs.
2. **Adaptive search.** A budgeted parameter search (split position, fooling and repeats around the best template) instead of a fixed list, under the 32-port budget or a widened sport range (contract options).
3. **Realistic ClientHello.** The probe and verification use the router's curl ClientHello, which is small. Real browsers send post-quantum (X25519MLKEM768) ClientHellos over 1.5 KB that span 2 segments, so DPI and split behaviour may differ. Consider a probe with a browser-like large ClientHello.
4. **QUIC probe and UDP/443 candidates.**
5. **IPv6 probes.**
6. **Per-target strategy.** Suggest splitting conflicting targets into separate rules (design H.2 text).
7. **Periodic re-validation** of an applied strategy and drift detection.
8. **Outcome-aware catalog pruning** per ISP/ASN.
9. **Inbound-queue isolation** to measure autottl and wssize safely.

##### Known hardware-report items in this area
- **Plural forms:** initController.ts:182,620 and po/ru:323,3458. Filed.
- **Overview autotune card missing:** fe-app-forkop/src/forkop/tabs/dashboard has no autotune reference. Filed.
- The other known items (Components, Rules layout, Monitoring units/sort, node type, RO outbound tags, snapshot diff `***`, uninstall modal focus, upgrade/mirror chain) are outside A11/A12.

##### Scratch
- Reproduction script: scratch/audit-autotune\repro_probes.sh
- Result: probes=5/6/7 -> refused too_many_probes; probes=3/4 pass the limit.
- No files in the audit tree or the main repo were modified.

## A13/A16 Контракты CLI/RPC, ошибки backend

### Вывод

Audited all 89 commands in /usr/bin/forkop's command_spec against the rpcd ACL, the frontend callers in TypeScript and the LuCI views, the backend/cron callers and the tests. The RO boundary holds: the read ACL has no config-mutating command, the FE readonly guard mirrors it, and tests/acl_boundary.sh passes locally. The contract itself has real defects.

(1) P1, reproduced: config_snapshot_restore treats an init.d reload that was only queued (another lifecycle action holds the reload lock, so reload_service marks reload.pending and exits 0) as a completed reload. It releases the restore guard, moves LKG to the restored snapshot, records 'restore success' and the UI says 'restored and reloaded' while the runtime never reloaded. The autotune apply path detects queued reloads; the manual restore path deliberately does not.

(2) P2, reproduced: the dashboard's async single-proxy latency test passes the job-state file path as the 4th clash_api argument. get_proxy_latency uses that argument as the test URL, so the test always probes '/var/run/.../X.json', and the job still reports 'Latency test completed'.

(3) The rc-0 overload shows up in several places: queued reload, clash_api transport or sing-box errors, forkop_releases success:false. Busy, queued and failed are therefore often indistinguishable. On top of that, error envelopes differ per module (7 shapes), and English backend text is shown in the RU UI.

(4) Smaller issues:
- nolog() never prints: its TTY test runs with stdout redirected to /dev/null. Reproduced.
- The URLTest apply flow masks a failed reload as saved.
- The snapshot diff silently truncates at 100 changes.
- The RO ACL grants unused and relatively powerful commands: check_proxy, which spawns sing-box check/fetch, and clash_api latency with an arbitrary URL.

Confirmed root causes for 3 known hardware items: the package postinst chain; the RO Overview showing outbound tags, because the readonly sections allowlist lacks child 'name'; the diff showing *** for absent values.

### Проверено и корректно

- Read ACL group contains no config/runtime-mutating command; FE READONLY_EXEC_PATTERNS (fe-app-forkop/src/forkop/services/readonlyCommandGuard.ts) mirrors luci-app-forkop.json read grants; tests/acl_boundary.sh PASS locally (run via tests/runner, backend lane).
- /usr/bin/forkop shell-quotes every argument (shell_quote/command_from_args) and forwards a fixed per-command arg count (run_spec), so extra RPC args are dropped and no shell injection is possible through rpcd exec.
- Job-id inputs of all *_status/ack commands are validated before path construction: service/ui.uc:536-545 valid_job_id, components/updates.uc:2319-2328, autotune/manager.uc:743 (^[0-9]{1,12}_[0-9]{1,10}$); no traversal through status commands.
- RO-reachable status commands perform only bookkeeping writes (stale job marking ui.uc:716-730, TTL cleanup, system-info cache); autotune status/target/groups/run_status are pure reads (autotune/state.uc:49-66 read() has no side effects; manager.uc:88-96 opens worker.lock read-only; run_status reports 'lost' without rewriting).
- get_readonly_config_sections uses an explicit allowlist and DPI view without raw options (diagnostics/runtime.uc:810-831); get_dashboard_runtime_metadata drops urltest URLs containing ?#@ (runtime.uc:843); check_dns_available masks dns_server (runtime.uc:1382).
- route_trace and connectivity_test validate inputs, drop tool stderr, return {error:'invalid_input'} rc1; FE handles (siteCheck.ts checks data?.target; connectivityMatrix.ts checks data.status).
- Snapshot mutations are serialized by the snapshot lock and return {status:'busy',reason:'snapshot_operation_in_progress'} rc1; FE maps busy/success/recovered/else distinctly and never shows needs_attention as success (history/initController.ts:267-313).
- autotune manager prints exactly one JSON object and exits 0 iff status=='ok'; busy/refused/failed distinct; manual apply (manager.uc:658-713) and scheduled apply (apply_group manager.uc:414-454) both go through autotune/apply.uc plan+apply only (invariant 10 holds at the CLI layer).
- component_action_async restricts a version argument to forkop/install/semver (components/updates.uc:2593-2599).
- enable/disable (init.d, silent) are judged by read-back autostart state, not by stdout (tabs/shared/serviceControl.ts:43-55); runForkopServiceAction checks job-level data.success (serviceControl.ts:19-24).
- Job-level success is honoured by latency, subscription and component followers (dashboard initController.ts:1003, :452; updates initController completeComponentActionJob).
- health.uc get never reports ok while a DPI/restore guard table exists (guard => overall 'error'); needs_attention restore/apply outcomes are recorded as history 'failure'.
- Strategy validators (validate_nfqws/nfqws2/byedpi_strategy_json) consistently return rc0 with {valid,message,needle(s)}.
- Full-uninstall gate in /usr/bin/forkop:259-266 blocks start/main/restart/reload/enable and every async/scheduled component, subscription, list and autotune mutation entry point; it prints a plain stderr message (FE falls back to stderr correctly).
- FE callBaseMethod's non-JSON fallback (success:true,data:string) is defended by every structured caller that uses allowNonZeroWithStdout (checks data.status / data.target / Array.isArray).

### Инвентарь

##### A. /usr/bin/forkop command matrix (commit 07872084)

Notation:
- **args**: CLI positional arguments, forwarded with a fixed count; extra arguments are dropped.
- **out**: stdout format.
- **rc**: exit code.
- **R/W**: mutates router state (W) or not (R).
- **ACL**: rpcd grant. `R` means the read group's pattern allows it. `W` means only the write group's `/usr/bin/forkop` wildcard allows it.
- **FE**: TS or LuCI caller.
- **BE**: in-tree backend caller.
- **T**: tests.

###### Lifecycle and service
- **start** (0) — out: syslog only. rc 0/1. W. ACL W. FE: none (the UI uses service_action_async). BE: initd.uc:615 via init.d, action.uc (init.d start). T: service_start_trap, initd_state.
- **stop** (0) — out: none. rc. W. ACL W. FE: none. BE: initd.uc:666, package.uc:189, full-uninstall.sh:80 (init.d). T: initd_state.
- **reload** [reason] — out: none. rc. W. ACL W. FE: none. BE: initd.uc:758 (init.d reload); snapshots.uc:316 via init.d. T: service_reload_plan. Note: the init.d reload returns rc 0 when merely queued (see P1/P3 findings).
- **restart** (0) — W. ACL W. FE: none. BE: action.uc (init.d restart).
- **enable / disable** (0) — out: none. W. ACL W. FE: serviceControl.ts, which calls /etc/init.d/forkop directly. BE: lifecycle.
- **main** (0) — runs start_main. W. ACL W. FE: none. BE: none found (legacy/manual entry; keep).
- **uninstall** (0) — W. ACL W. FE: none. BE: none (manual).
- **full_uninstall** (0) — out: JSON {success, status_url} or {success:false, message}. rc 0/1. W. ACL W. FE: updates/fullUninstall.ts. T: acl_boundary, full_uninstall_cleanup.
- **dnsmasq_restore / restore_dnsmasq** (0, alias pair) — W. ACL W. FE: none. BE: full-uninstall.sh:83, action.uc:948, package.uc:147, install.sh. T: full_uninstall_cleanup, package_lifecycle.
- **dns_failover_apply** [state] — rc 0 / 1 / 2 (2 = reload lock busy). W. ACL W. FE: none. BE: singbox/dns_failover.uc:228. Not in help.

###### Scheduled updates
- **list_update / list_update_if_due** (0) — out: syslog. rc; busy returns exit 0. W. ACL W. FE: none. BE: cron line (updates.uc:1525), reload.uc/lifecycle. T: updates_due, list_update_reload_policy, cron_preserves_foreign_jobs.
- **subscription_update** [rule] [idx] — rc 0/1; waits up to 300 s for its locks. W. ACL W. FE: none. BE: the async worker (updates.uc:2080). T: subscription_update_job, cli_entrypoint.
- **subscription_update_async** [rule] [idx] — out: JSON {success, job_id, message}. rc 0/1. No upfront validation or busy check. W. ACL W. FE: dashboard/initController.ts:1685. T: subscriptionUpdate.test.ts.
- **subscription_update_status** job — out: job-state JSON; not found/invalid gives {success:false, running:false, message, exit_code:null}. rc 0/1. R (bookkeeping cleanup). ACL R. FE: dashboard. T: subscriptionUpdate.test.ts.
- **subscription_update_if_due** (0) — busy returns rc 0. W. ACL W. BE: cron (updates.uc:1556). T: updates_due.

###### Diagnostics
- **check_proxy** (0) — out: masked sing-box JSON (the verdict is never printed: nolog bug). rc 0/1. R, but heavy (sing-box check, up to 5 `tools fetch`). ACL R. FE: none. T: none.
- **check_nft** (0) — out: nft text. rc. R. ACL R. FE: none. BE: support_report.
- **check_nft_rules** (0) — out: JSON counters. rc 0. R (makes 2 curls). ACL R. FE: runNftCheck.ts. T: none.
- **check_sing_box** (0) — out: JSON. rc 0. R. ACL R. FE: runSingBoxCheck.ts.
- **check_logs** (0) — out: text. rc 1 if empty (silent). R. ACL R. FE: core.service.ts, diagnostic.
- **check_sing_box_logs** (0) — out: text. rc. R. ACL R. FE: none.
- **check_fakeip** (0) — out: JSON. rc 0. R. ACL R. FE: runFakeIPCheck.ts.
- **check_zapret_runtime / check_zapret2_runtime / check_byedpi_runtime** (0) — out: provider JSON passthrough. rc = module rc. R. ACL R. FE: diagnostic/initController.ts.
- **neutralize_zapret_defaults** (0) — no-op, logs only. rc 0. R. ACL W. FE/BE: none (compatibility; keep).
- **check_dns_available** (0) — out: JSON (dns_server masked). rc 0. R. ACL R. FE: runDnsCheck.ts.
- **global_check** [masked|raw] — out: text. rc 0. R. ACL: R only for "masked"; raw is W. FE: diagnostic/initController.ts:572; the admin requests raw and masks client-side. T: callBaseMethod.test.ts.
- **support_report** (0) — out: unmasked text. rc 0. R. ACL W. FE: diagnostic (60 s timeout).
- **route_trace** target src proto port — out: JSON, or {error:"invalid_input"}. rc 1 on invalid input. R (dig, ip route). ACL R. FE: diagnostic/siteCheck.ts. T: route_trace, route_trace_owner, observabilityMethods.test.
- **connectivity_test** host type port — out: JSON, or {error:"invalid_input"}. rc 1 on invalid input; rc 0 on probe failure. R (network probe). ACL R. FE: connectivityMatrix.ts. T: acl_boundary only; no backend unit test found.

###### Clash API
- **clash_api** action a1 a2 a3 — out: JSON.
  - get_proxies / get_connections / get_proxy_latency / get_group_latency: rc 0 always (empty output on transport failure).
  - set_group_proxy / close_connection / close_all: {success, ...}, rc 0/1.
  - get_proxy_latencies: {success, count, failed}, rc 0/1.
  - Bad arguments: {error}, rc 1.
  - Mutability: R except set_group_proxy and close_* (runtime W).
  - ACL R covers get_proxies, get_connections and the latency trio (with `*`).
  - FE: getDashboardSections (proxies), dashboard/monitoring (connections, set, close), runSectionsCheck (latency).
  - BE: ui.uc:1443 latency worker (arg bug).
  - T: diagnostics_status, luci_clash_transport_fallback.

###### Config and status views
- **show_config** [masked|raw] — out: text. rc 1 if missing (silent). R. ACL W. FE: none.
- **show_version** — out: text. rc 0. R. ACL R. FE: methods readForkopVersion. BE: snapshots.uc:198.
- **show_sing_box_config** [masked|raw] — out: JSON (masked) or the raw file. rc 1 if missing (silent). R. ACL: R for masked, W for raw. FE: diagnostic.
- **show_sing_box_version** — out: text. R. ACL R. FE: none.
- **get_status / get_sing_box_status** — out: JSON {running, enabled, status, dns_configured}. rc 0. R. ACL R. FE: fetchServicesInfo.ts. BE: initd.uc:459, action.uc:907, install.sh.
- **get_outbound_metadata** section — out: JSON (empty metadata for an invalid section). rc 0. R. ACL R. FE: none.
- **get_subscription_metadata** section — out: JSON ({} default). rc 0. R. ACL W. FE: none.
- **get_zapret_status / get_zapret2_status / get_byedpi_status** — out: provider JSON. R. ACL R. FE: run*Check.ts.
- **get_system_info** — out: JSON (cached). rc 0. R (cache write). ACL R. FE: systemInfo.service.ts. T: diagnostics_status.
- **get_ui_capabilities** — out: JSON. R. ACL R. FE: none.
- **get_ui_state** — out: JSON {service, capabilities, actions{service, latency, component, subscription}}. rc 0. R (cleanup). ACL R. FE: runtimeUiState.service.ts, componentAction wait. T: ui_runtime_job, acl_boundary.
- **get_health_status** — out: JSON. rc 0. R. ACL R. FE: dashboard, history. T: acl_boundary.
- **get_history** — out: JSON {persistent, events}. rc 0. R. ACL R. FE: history, autotune. T: history_journal.
- **get_readonly_config_sections** — out: JSON array (allowlist). rc 0. R. ACL R. FE: getConfigSections.ts, monitoring. T: acl_boundary.
- **get_dashboard_runtime_metadata** — out: JSON. rc 0. R. ACL R. FE: getDashboardSections.ts.

###### Snapshots
- **config_snapshot_create** [manual|automatic] — out: JSON {status: created | busy | failed}. rc 1 on failed or busy. W. ACL W. FE: history. T: config_snapshots, observabilityMethods.test.
- **config_snapshot_list** — out: JSON array. rc 0. R. ACL R. FE: history, dashboard.
- **config_snapshot_diff** id — out: JSON array, capped at 100 and masked; no output on error. rc 1 on error. R. ACL R. FE: history (without allowNonZero).
- **config_snapshot_restore** id — out: JSON {status: success | recovered | failed | needs_attention | busy}. rc 1 for failed, needs_attention and busy. W. ACL W. FE: history (120 s). T: config_restore_guard, config_snapshots.
- **config_snapshot_delete** id — out: JSON {status: deleted | failed | busy}. W. ACL W. FE: history.

###### UI jobs
- **service_action_async** start|stop|restart|reload — out: JSON {success, job_id, message}. rc 0/1. W. ACL W. FE: serviceControl.ts, dashboard URLTest. T: serviceAction.test.ts.
- **service_action_status** job — out: job JSON (rc 0) or {success:false, ...} (rc 1). R (stale marking). ACL R.
- **latency_test_async** type section tag [timeout] — out: JSON {success, job_id, message}. W (runtime). ACL W. FE: dashboard. T: latencyAction.test.ts, ui_runtime_job.
- **latency_test_status** job — same as service_action_status. ACL R.
- **ui_action_ack** kind job — out: {success, job_id, message}. rc 0/1. W (ui-state). ACL W. FE: updates, serviceControl, dashboard, diagnostic. T: none.

###### Components and packaging
- **component_action** component action [ver] — out: JSON updates_response. rc 0/1. W. ACL W. FE: none. BE: install.sh. T: components_updater_job, installer_*.
- **component_action_async** component action [ver] — out: {success, job_id, message}. No component/action validation or busy check up front. W. ACL W. FE: updates. T: components_updater_job, componentAction.test.
- **component_action_status** job — out: job JSON or an error JSON. rc 0/1. R. ACL R. FE: updates, plus a direct fs.read of the state file.
- **forkop_releases** — out: JSON {success, releases}. rc 0 always, even when success is false. R (network). ACL W. FE: releaseSelector.ts (JSON.parse without try/catch). T: none.
- **component_updates_if_due** — rc; busy returns exit 0. W. BE: cron (updates.uc:1567). T: updates_due.
- **component_update_check_cache** — out: JSON {enabled, results}. rc 0. R. ACL R. FE: updates. T: cli_entrypoint.
- **validate_nfqws_strategy_json / validate_nfqws2_strategy_json / validate_byedpi_strategy_json** str — out: JSON {valid, message, needle(s)}. rc 0. R. ACL W. FE: section.js (3 direct fs.exec copies), dpiPlayground.ts. T: observabilityMethods.test, acl_boundary.
- **package_prerm** [action] / **package_postinst** / **luci_postinst** — out: none. rc. W. ACL W. BE: maintainer scripts (build.sh, Makefile), uci-defaults/50_luci-forkop. T: package_lifecycle, installer_owner.
- **urltest_override_save** (7 args) / **urltest_override_reset** (2 args) — out: none (rc only, no reason). W (UCI commit, no reload). ACL W. FE: dashboard, via raw executeShellCommand.

###### Autotune
All autotune commands print a single JSON object {status: ok | failed | refused | busy, ...}; rc 0 iff status is ok.
- **autotune_status** — R. ACL R. FE: tabs/autotune. T: autotune_state, acl_boundary.
- **autotune_target** id — R. ACL R. FE: none (guard list only).
- **autotune_groups** — R (DNS lookups). ACL R. FE: autotune (45 s timeout).
- **autotune_policy_set** option value — W (UCI and crontab). ACL W. FE: autotune.
- **autotune_target_set** id host enabled resolver / **autotune_target_remove** id — W. ACL W. FE: autotune.
- **autotune_run** scope — W. ACL W. FE: none. BE: none (CLI). T: autotune_recovery.
- **autotune_run_async** scope — W. ACL W. FE: autotune.
- **autotune_run_status** job — R. ACL R. FE: autotune. T: autotune_manual_apply.
- **autotune_apply** group — W; goes through Stage 5. ACL W. FE: none.
- **autotune_apply_async** group — W. ACL W. FE: autotune. T: autotune_manual_apply.
- **autotune_if_due** — W. BE: cron line (manager.uc:178-179). T: autotune_scheduler.

##### B. Error-concept inventory

Envelopes currently in use:
- **E1** (UI actions, subscription and component start): {success, job_id, message}
- **E2** (snapshots, autotune): {status, reason}
- **E3** (route_trace, connectivity, clash args): {error: code}
- **E4** (clash HTTP): {success:false, error, message} or {success:false, http_code, body}
- **E5** (component job): {success:false, kind, component, action, message, ...}
- **E6** (subscription status): {success:false, running:false, message, exit_code}
- **E7** (/usr/bin/forkop gate, loader failure, urltest_override, nolog paths): plain stderr text or empty output.

How each concept is expressed:
- **invalid_input**
  - Proper codes: E3 "invalid_input" (route_trace, connectivity); autotune reason invalid_* (good).
  - Free text: E1 "Invalid service action" / "Invalid ... job id".
  - Surfaces only later as a job failure: component_action_async ("Unknown component action"); subscription_update_async with an invalid rule.
  - Generic {status:"failed"} with no reason: snapshot create with a bad kind, delete of an invalid id.
  - Rc-only, no text: urltest_override.
  - Silent, rc 0: get_outbound_metadata / get_subscription_metadata return empty metadata.
- **unsupported**
  - route_trace rule.status "unsupported" (inside the result).
  - FE state 'unsupported' for RO outbound checks (good).
  - Autotune "candidate_unsupported" is reported as refused.
  - connectivity DNS with an IP target is reported as invalid_input.
- **busy**
  - Proper codes: snapshots E2 "busy"; autotune E2 "busy" (good).
  - Free text "Another ... already running": service, latency, component (E1, or a job failure for component). The FE renders it as "Service action failed: ...".
  - Busy returns rc 0 (fine for cron): list/subscription/component `*_if_due` and list_update.
  - init.d reload returns rc 0 when queued, which is treated as success: service actions, snapshot restore (P1).
- **timeout**
  - connectivity {status:"timeout"}.
  - Service job: "did not reach expected state", with success:false.
  - FE-side only: "Operation timed out" / withTimeout.
- **failure**: E1–E6 as above; clash read ops return rc 0 on failure.
- **stale**
  - autotune apply/job "stale" / "lost"; manual apply "recommendation_stale" (refused); snapshots do_apply "stale".
  - Restore has no stale or busy pre-check.
- **forbidden**
  - RO is refused locally by the FE guard (code 126, READONLY_REFUSED). An rpcd ACL denial rejects fs.exec and executeShellCommand catches it (code 1, message).
  - Deleting the LKG snapshot returns generic {status:"failed"}.
- **needs_attention**
  - snapshots status needs_attention, rc 1.
  - Autotune outcome needs_attention, with the FE showing attention.
  - health.uc has no needs_attention state: it maps to 'error' only via a guard table or when the last history event is a failure. A later successful event (e.g. snapshot_create) turns overall back to ok even when a guard-less needs_attention such as lkg_update_failed is unresolved (low impact).

##### C. Frontend-side contract notes
- callBaseMethod treats rc 0 with empty stdout as failure (error ''), and non-JSON stdout as success with data being a string. Structured callers defend themselves.
- Job-status commands have two success levels: MethodResponse.success is RPC-level, data.success is job-level. The URLTest reload is the only caller found that ignores the job level.
- releaseSelector.ts and fullUninstall.ts call JSON.parse on stdout without try/catch; errors are caught by the outer try, but the SyntaxError text can reach the UI.
- The global_check FE timeout is the callBaseMethod default of 15 s. With broken upstream DNS the backend runs up to about 5 sequential `dig +timeout=2` in check_dns_available (plus curl -m 3 and sleep 1 in check_nft_rules), which can approach or exceed 15 s exactly when diagnostics matter. Not verified on hardware; confidence low, so it is not listed as a finding.

##### D. Known hardware items mapped to this area
- **P2 postinst chain**: confirmed (build.sh:300-302/438/461, forkop/Makefile:55-57, package.uc:189).
- **RO Overview shows outbound tags**: confirmed; root cause is runtime.uc:814-815 (allowlist lacks `name`).
- **Snapshot diff shows *** for absent values**: confirmed (snapshots.uc:206-212, 286-290).
- The other P3 UI items (layout, plurals, units, Direct label, modal focus) are outside the CLI/RPC area.

##### E. Scratch reproductions (read-only; nothing written to the audit tree)
Directory: scratch/audit-cli-rpc/
- restore_queued_reload.sh: P1.
- latency_proxy_url.sh: P2.
- tty_probe.sh: nolog.
- callers.sh / show.py: caller map.
- tests/runner acl_boundary: PASS.

## A14/A15 ACL и секреты

### Вывод

The per-subcommand read ACL (the F-001 fix) holds against argument tricks: rpcd builds "cmd arg1 arg2..." and fnmatches it against the patterns; the dispatcher keys on ARGV[0] exactly, shell-quotes every argument via command_from_args, and truncates arguments past each command's fixed count. Job/snapshot/target ids are regex-validated, the UI guard mirrors the ACL, and tests/acl_boundary.sh pins parity (stop/full_uninstall/raw/snapshot-mutation blocked for the read role). The boundary is nonetheless bypassable through a different channel: rpcd file.exec applies a caller-supplied env table with NO name filtering, and the backend honours dozens of FORKOP_*/TMP_* path and binary env overrides at runtime, so a read-only session using only allowed commands can read any file as root, overwrite any file as root, and execute any existing binary as root (P1, reproduced locally). Secret masking is deny-list based with confirmed leaks: the read-only-reachable "global_check masked" prints `list outbound_jsons` JSON verbatim (uuids, wireguard keys) and leaks l2tp/pptp WAN credentials (P1, reproduced); the masked sing-box config keeps pre_shared_key, ssh passphrase, hysteria1 auth/obfs, auth headers, ws path, plugin_opts, DoH path and rule_set URL tokens (P2, reproduced). Clash API defaults to LAN_IP:9090 with no secret so any LAN host or RO LuCI user can switch selectors and read all clients' connections (P2, product decision). Minor: masker/generator secret mismatch, world-readable generated config, browser console logging the Clash token, unused RO grants.

### Проверено и корректно

- rpcd argument authorization: forkop/files/usr/bin/forkop dispatches on ARGV[0] via command_spec() exact-key lookup, shell-quotes every arg (shell_quote/command_from_args:14-23) and only forwards spec[2] fixed args, so no allowed read command can smuggle a mutating subcommand or extra args past the ACL glob (confirmed against rpcd file.c rpc_file_exec_run: full command line is re-checked when the bare executable is not itself granted).
- RO command guard parity: fe-app-forkop/src/forkop/services/readonlyCommandGuard.ts READONLY_EXEC_PATTERNS is byte-identical to the ACL read.file exec grants, and tests/acl_boundary.sh independently asserts the read role cannot exec stop/full_uninstall/show_sing_box_config raw/snapshot mutations/autotune mutating verbs and has no wildcard '/usr/bin/forkop' grant.
- No raw UCI or raw JSON to read role: acl read has NO uci grant (only luci-app-forkop-admin reads uci forkop), and /etc/sing-box/config.json + section-cache appear only under write.file, never read; asserted by acl_boundary.sh.
- get_readonly_config_sections (diagnostics/runtime.uc:810) uses an explicit allow-list of safe keys plus dpi_strategy.view (provider+strategy name only, never raw nfqws/byedpi options); reproduced that it drops password/subscription_urls.
- get_dashboard_runtime_metadata strips urltest url when it contains [?#@] (diagnostics/runtime.uc:1240) so subscription tokens in urltest urls are not exposed.
- route_trace/connectivity_test validate target host/ip/port/protocol with strict regexes and only ever run dig/curl/ip with quoted args; provenance fields correctly label simulated vs observed (route_trace.uc, connectivity.uc).
- Job/snapshot/target id validation: config_snapshots valid_id ^[a-z0-9_-]{1,64}$, autotune valid_job_id ^[0-9]{1,12}_[0-9]{1,10}$, ui.uc/updates.uc job ids reject empty/./..//[^A-Za-z0-9._-]; no path traversal via ids.
- Snapshot files, hash dir, autotune state/jobs, subscription persistent cache, ruleset cache and history event file are created 0700/0600 (config/snapshots.uc:38-62, autotune/state.uc, subscription/cache.uc chmod 600/700, diagnostics/health.uc:139).
- Shell interpolation: all system()/popen() call sites build argv through quote()/shell_quote()/command_from_args(); no unquoted UCI/user value reaches a shell (spot-checked catalog.uc, process_identity kill uses regex-validated numeric pid, migration rm -f path only for internally-built glob paths).
- Forkop self-update selected-version path verifies sha256 of each downloaded asset and only accepts catalog entries whose assets carry a 64-hex sha256 and a URL under the release's own directory (components/action.uc:706-760,2339-2351).

### Инвентарь

##### RO (luci-app-forkop) exec allow-list and risk

Group `luci-app-forkop.read.ubus.file=[exec]` is the only ubus method (plus luci-rpc getDHCPLeases/getHostHints, network.interface dump, service list). rpcd re-checks the full "cmd args" line against read.file globs only because the bare executable is NOT granted (confirmed against rpcd file.c). Fixed-arg truncation + shell_quote in the dispatcher means args cannot smuggle extra subcommands. All read.file exec entries:

| Grant (glob) | What it does | Reads secrets? | Risk |
|---|---|---|---|
| get_status / get_sing_box_status / get_zapret*/byedpi_status | service state json | no | ok |
| get_system_info | version/mem/flags json | no | ok, but writes SYSTEM_INFO_CACHE_FILE (env-overridable -> P1 write primitive) |
| get_ui_capabilities / get_ui_state | capability/action json | no | ok, but execs SING_BOX_BIN_PATH (env-overridable -> P1 exec primitive) |
| get_health_status / get_history | health + event journal | no | ok |
| autotune_status / autotune_target * / autotune_groups / autotune_run_status * | autotune state, strategy IDs only (dpi_strategy.view) | no (strategy names only) | ok; autotune_target unused by UI (CLEANUP) |
| route_trace * | simulated routing, strict input validation | no | ok |
| config_snapshot_list / config_snapshot_diff * | snapshot metadata; diff safe_value() reduces most values to *** | mostly no (see diff note) | ok |
| connectivity_test * | dig/curl probe, validated host/port | no | ok |
| get_readonly_config_sections | allow-list of safe keys + dpi strategy | no | ok |
| get_dashboard_runtime_metadata | urltest groups; url dropped if [?#@] | no | ok |
| get_outbound_metadata * | names/countries/protocol/transport/security only | no | ok |
| show_version / show_sing_box_version | version strings | no | ok; show_sing_box_version unused by UI (CLEANUP) |
| check_proxy | starts sing-box tools fetch | no (masked IP) | DoS/egress + OOM vector, unused by UI (CLEANUP) |
| check_nft / check_nft_rules | nft list table/ruleset | no | check_nft unused by UI (CLEANUP) |
| check_sing_box | sing-box check + masked config + proxy fetch | masked only | ok |
| check_logs / check_sing_box_logs | logread filtered | no (logs are info-level) | ok |
| check_fakeip / check_dns_available / check_zapret*/byedpi_runtime | probes/state | no | ok |
| clash_api get_proxies / get_connections / get_proxy_latency(ies) * / get_group_latency * | Clash controller GET | connection metadata of all clients | see Clash P2 |
| service_action_status * / latency_test_status * / component_action_status * / subscription_update_status * | job state json | job message = last output line (masked upstream) | ok |
| component_update_check_cache | cached version check | no | ok |
| global_check masked | masked global report | LEAKS list outbound_jsons + l2tp/pptp WAN creds | P1 |
| show_sing_box_config masked | masked sing-box json | LEAKS pre_shared_key/ssh/hysteria/headers/path/plugin/url | P2 |

read.file also grants `read` on /var/run/forkop/component-actions/*, ui-state/*, service-actions/*, latency-actions/* (job state json - no secrets). NOT granted: uci forkop (admin only), /etc/sing-box/config.json, section-cache/* (write group only). Good.

##### Admin (write) allow-list
- write.file exec: /usr/bin/forkop (full CLI), /etc/init.d/forkop (full service control) - intended for admins.
- write.file read: /etc/sing-box/config.json, /tmp/sing-box/config.json (RAW, unmasked - admin can read cleartext creds; acceptable for admin), section-cache/* (raw share links), ui-state/* write.
- write.uci: forkop. luci-app-forkop-admin.read.uci: forkop (config read for admins). All appropriate for the admin role.

##### Env-override inventory (the P1 channel)
Backend reads security-relevant values from getenv with production fallbacks. rpcd passes the caller env unfiltered. Notable exec/read/write primitives reachable from RO commands:
- FORKOP_UI_SING_BOX_BIN_PATH (service/ui.uc:25) -> executed (get_ui_capabilities) => arbitrary exec.
- FORKOP_UI_SING_BOX_VERSION_CACHE_FILE (ui.uc:22) -> written (get_ui_capabilities) => arbitrary write.
- FORKOP_CONFIG (diagnostics/runtime.uc:14) -> printed by global_check masked => arbitrary read.
- FORKOP_SYSTEM_INFO_CACHE_FILE (runtime.uc:19) -> written by get_system_info => arbitrary write.
- FORKOP_LIB / PATH -> module loading and every sub-tool (dig/curl/nft/opkg/apk/sing-box) => arbitrary exec if PATH honoured (PATH is a standard env var rpcd forwards).
Dozens more (FORKOP_SNAPSHOT_DIR, FORKOP_AUTOTUNE_*, FORKOP_HISTORY_FILE, ...) are only reachable from write-group commands, but the RO-reachable ones above already give full root read/write/exec.

##### Secret-masking coverage matrix (mask points)
- forkop-config-masked (status.uc:351): masks proxy_string, hwid, subscription_url(s), urltest_proxy_links, selector_proxy_links(list form), server_*, mtproto_*, reality_*, hysteria2_obfs_password, tailscale_*, dns_server, listen*, public_host, yacd_secret_key, option outbound_json. GAP: `list outbound_jsons` (P1), and single `option outbound_json` multiline works but list form has no handler.
- wan-config-masked (status.uc:258): masks static ipaddr/netmask/gateway, pppoe user/pass, wireguard private_key. GAP: l2tp/pptp/3g/wwan user/pass (P1).
- mask-sing-box-config keys (status.uc:1501): GAP pre_shared_key, peer_public_key, private_key_passphrase, auth_str, obfs, path, headers, plugin, plugin_opts, url, host (P2).
- maskSupportReportText (maskDiagnostics.ts:241): strips vless://... links and url token/key/uuid/password/secret query - reasonable; relies on the same underlying maskGlobalCheckText (shares the outbound_jsons list gap).
- monitoring safeText (initController.ts:985): masks userinfo@ and token/secret/password/uuid/authorization query. OK-ish; the key-name masking edge is cosmetic.
- support_report (runtime.uc:2195) is admin-only (write CLI), intentionally UNMASKED, with a bilingual confidentiality banner - acceptable; only the admin/write role can invoke it (not RO). Good.

##### RO initial-render RPC audit (no mutation on load)
Page load path: page/*.js -> shell.detectAccess() (uci.load forkop; on failure setReadonlyMode(true)) then shell.startPage(). startPage -> loadUiCapabilities() (get_ui_capabilities, fallback get_ui_state, fallback check_zapret/zapret2/byedpi_runtime) + coreService (log watcher: check_logs on a 10s timer). All read-only. Per tab initController first calls: dashboard get_health_status/getDashboardSections(get_status,get_readonly_config_sections,clash get_proxies)/snapshotList; monitoring getReadonlyConfigSections + clash get_connections; diagnostics status/check_* reads; autotune autotune_status/groups/getHistory; history snapshotList/getHistory/getHealthStatus. No mutating RPC (serviceAction/subscriptionUpdate/snapshotCreate/uci.set/save/apply/autotune_*_set/apply) is issued on load; those are behind explicit button handlers, and executeShellCommand -> shouldRefuseCommand blocks anything outside READONLY_EXEC_PATTERNS in RO mode. UI-guard is defense-in-depth, not the boundary (ACL is), and the ACL correctly omits the mutating verbs. Verified OK.

##### Command-injection / path-traversal
- All system()/popen() build argv via quote()/shell_quote()/command_from_args; no unquoted UCI/user value reaches sh -c. process_identity kill uses a numeric-validated pid. migration remove_cache_path only globs internally-built paths.
- Snapshot/job/target ids strictly regex-validated before path building; no traversal.
- component/subscription names validated ([A-Za-z0-9._-], reject . / ..). safe_section/section_safe gate metadata paths.
- Digest: selected-version Forkop update verifies sha256 (action.uc:2339); F-008 (latest-version path + apk --allow-untrusted, action.uc:406) remains as prior audit noted (accepted as tech debt) - not re-raised as new.

##### Reproductions (scratch/audit-acl-secrets/)
env_exec_repro.sh (exec+write via get_ui_capabilities), env_read_repro.sh (read arbitrary file via global_check masked), env_write_repro.sh (overwrite arbitrary file via get_system_info), mask_repro.sh (outbound_jsons + WAN cred leak), wan_mask_repro.sh (l2tp cred leak), sb_mask_repro.sh (sing-box key leak). All run under WSL ucode as the unprivileged user; no router contacted.

## A16/A17 Архитектура frontend

### Вывод

Pollers and remounts are well contained. Each Forkop page is a full LuCI view load, every onPageMount first calls onPageUnmount, store listeners live in a Set, and all timers are guarded. The WebSocket-to-RPC fallback has no reconnect storm. Generation ids protect most async results. The bundle is in sync: tsup + prettier (yarn format:js) reproduces the committed main.js byte for byte.

Main problems found:
1. (P2) The "snapshot-first Save & Apply" on the Settings page never runs. The code overrides forkopMap.handleSaveApply, but LuCI's view.handleSaveApply calls only map.save() and ui.changes.apply(), and form.Map has no handleSaveApply. So there is no pre-apply snapshot, no busy guard and no reload-confirmation notice. The only test checks the source with a regex.
2. (P2) Select lists whose choices are filtered by provider availability or rule enabled state drop the value that is already configured. LuCI then shows the first choice, and the next Save writes it. A rule's action flips zapret→connection and its nfqws_opt is deleted. dns_detour / download_*_via_proxy_section are silently re-pointed to another rule.
3. (P2) The Overview Recovery card says "No recovery needed" (healthy) while the backend reports recovery.pending or package_recovery.pending. When health is unavailable, the state card says "healthy / running". Reproduced.

P3 items:
- A transient failure of the backend strategy validator is cached for the whole page as "invalid strategy", and Save stays blocked.
- A forced refresh of the runtime UI state joins an older in-flight poll, so turning on autostart shows a false "Could not change autostart" (reproduced).
- Poll failures never mark data as stale, and config-derived data is frozen for the page lifetime (uci.load caches it).
- When a probe RPC fails, the UI shows it as an observed negative result: the site check says "did not open from the router" (reproduced).
- The Components tab is blank after Save.
- The Clash API secret is printed to the browser console, and the logger keeps an unbounded in-memory buffer.
- The direct Clash controller is chosen from window.location.hostname (wrong source when LuCI is opened through a tunnel).
- The log viewer calls check_logs back to back (every 250 ms).
- Service-action outcomes are handled inconsistently: busy is shown as a failure, and a restored job's failure is ignored.
- diagnostics#host= runs a router probe automatically on page open.

CLEANUP:
- The unified async/status layer (createAsyncLoader, renderAsyncState, isStale, describeStatus, renderForbiddenState, timeoutMessage) is used only by tests.
- There are 5 dead RPC wrappers.
- Provider availability is stored in three places.

All hardware-report frontend items are confirmed in code; root causes are in extra.

### Проверено и корректно

- Poll lifecycle: every Forkop menu entry is a separate LuCI view (full page load), so no controller timer survives navigation; bfcache restore is handled via pagehide/pageshow flags (dashboard/initController.ts:218-225, updates/initController.ts:93-100)
- No duplicate pollers on remount: onPageMount calls onPageUnmount first in dashboard (initController.ts:1935-1939), monitoring (2077-2080), history (initController.ts:431-440), autotune (1148-1160), updates (1456-1459), diagnostic (997-1003); store.subscribe uses a Set so the same onStoreUpdate cannot be added twice; timers guarded (startClashRpcPolling, startConnectionsPolling, startDashboardDataUpdates)
- WebSocket to Clash API: no reconnect storm. SocketManager.connect dedupes by URL (socket.service.ts:49); dashboard fallBackToClashRpcPolling resets sockets once and starts one 2 s interval (initController.ts:818-825); monitoring disconnects and polls every 1.5 s (1956-1968); stale messages are dropped via dashboardDataUpdatesId/connectionsUpdatesId; the WS is retried only on a service stopped->running transition
- Dashboard never closes the Monitoring connections socket: resetAll only when clashUpdatesStarted (overview host) (dashboard/initController.ts:846-851)
- Stale-response protection: mountId checks in all controllers, fetchServicesInfo/ensureSystemInfo/provider-info request ids, section.js remote validation request ids (4651-4659), siteCheck/connectivity/dpiPlayground drop answers for edited input, autotune pollApply identity check `applying !== current`, sectionsRefreshQueued forces a re-fetch after a node switch
- Busy vs failure: snapshot create/restore/delete busy -> warning toast in History (history/initController.ts:269-305); autotune busy/refusals -> warning (autotune/initController.ts:293-297, model.ts applyResultView); component action already running -> follow the existing job (updates/initController.ts:743-758)
- needs_attention mapping: history/overview event outcomes map needs_attention to a 'Needs attention' error tone (ui/status.ts:223-257); autotune applyResultView maps needs_attention/unknown/interrupted_after_apply to attention=true, and 'failed' agrees with the backend (apply.uc:713-721 promotes a non-restored config to needs_attention)
- Read-only role: executeShellCommand refuses non-allowlisted commands locally (readonlyCommandGuard.ts mirrors the ACL read list); mutating controls hidden in RO (history, autotune, monitoring, dashboard, startService); the section cache is not read in RO (getDashboardSections.ts:799); RO config sections never carry yacd_secret_key (diagnostics/runtime.uc:810-828), so the WS token is empty for RO and the UI falls back to RPC
- sessionStorage keys are versioned (:v1), schema-validated, TTL-bounded (diagnostic run 30 min) and wrapped in try/catch (diagnosticRunPersistence.ts, logNotificationDeduper.service.ts, uiActionNotification.service.ts); connectivity targets validated with legacy TLS->HTTPS migration (connectivityMatrix.ts:31-53); monitoring prefs parse inside try/catch (1215-1233)
- Event listener cleanup: monitoring selectionchange/copy removed on unmount (2134-2135); overflow menu uses one global listener (overflowMenu.ts:54-69); confirmAction disconnects its MutationObserver and focuses Cancel (confirmAction.ts:19-24,68); renderModal stops refresh when detached (renderModal.ts:325-339)
- Pages without a form null Save/Apply/Reset (page/overview.js etc.; pinned by tests/luci_readonly_view.sh:88-90)
- Full uninstall does not blindly retry after a lost RPC response (fullUninstall.ts:82-90)
- Latency, subscription and component job waits have transient-RPC grace (methods/shell/index.ts:652-681, 754-857, 915-940)
- Bundle in sync: tsup build of 07872084 sources + prettier (yarn format:js, no .prettierrc under luci-app-forkop) reproduces luci-app-forkop/.../main.js byte-identically (sha256 7e5170f7747066ddf53b7285a9b4675e4fcfa4fd45d5a93a2cbdaa7bc72695b2); `yarn build` alone gives an unformatted file

### Инвентарь

##### 1. Poll / timer / socket inventory (who starts, who stops)
| Poller | Start | Stop | Notes |
|---|---|---|---|
| get_ui_state loop (setTimeout 1 s idle / 0.5 s during actions) | coreService once per page (shell.startPage) | never (page lifetime) | skips the RPC while document.hidden; forced refresh on visibilitychange/pageshow/focus. Page lifetime is fine because each menu entry is a full page load. Forced refresh joins the in-flight poll (autostart finding) |
| ForkopLogWatcher check_logs setInterval 10 s | 5 s after coreService, after capabilities | never; paused while hidden | notifications deduped via sessionStorage `forkop:shown-log-error-notifications:v1` |
| Dashboard sections setInterval 10 s | startDashboardDataUpdates (mount + service not stopped) | stopDashboardDataUpdates (unmount / stopped / loading) | config part is cached by uci.load (stale-config finding) |
| Dashboard health setInterval 10 s | onPageMount, overview host only | onPageUnmount | |
| Clash WS traffic+connections | overview host, http pages | resetAll on stop/unmount/fallback | fallback: one 2 s RPC interval; no WS retry until stopped→running |
| Monitoring render setInterval 500 ms | onPageMount | onPageUnmount | |
| Monitoring connections WS / RPC 1.5 s | setServiceAvailability('running') | stopConnectionsUpdates | WS error → disconnect + poll; no storm |
| History setInterval 15 s | onPageMount | onPageUnmount | loadAll has no overlap guard (refresh + retry click can interleave; the last response wins; low impact) |
| Autotune status 15 s + groups 120 s | onPageMount | onPageUnmount | pollJob/pollApply 2 s loops bounded to 20 min. If pollApply times out, `applying` stays set and the page stays locked until reload (minor) |
| Job waits: service 1 s ≤2 min, latency 1 s ≤30 s, subscription 1.5 s unbounded, component 1.5 s unbounded | action handlers / ui_state followers | job end / page unload | forkop self-install path loops until the version matches (endless spinner if the state file is lost and the version never matches; edge) |
| Log modal 250 ms | View logs | modal detach | back-to-back check_logs (log-viewer finding) |
| MutationObservers: TabService (body subtree, permanent), onMount (until visible), confirmAction/renderModal (disconnected) | | | onMount observer stays alive forever if its element never becomes visible (e.g. Monitoring opened on #view=nodes and never switched); perf only |
Navigation: menu pages are separate LuCI views (78877c17), so old pollers do not survive navigation. Remounts (Monitoring connections↔nodes view switch, Settings form tabs) do not duplicate pollers.

##### 2. Deep links / Back-Forward
- Hash params: monitoring#search= (resetMonitoringState 2052), monitoring#view=nodes (views.ts; MonitoringTab.initController switches the controller before mount), diagnostics#host= (auto-run; separate finding). There is no hashchange/popstate listener: a manual hash edit on the same page needs a reload. showMonitoringView uses replaceState and rewrites the URL to `…#view=nodes` or no hash, so switching views drops `#search=` from the URL and a later reload loses the search. The view switch also calls resetMonitoringState, which resets filters (prefs reloaded from localStorage). Low impact.
- All cross-page links are full navigations (openForkopPage / href).

##### 3. Browser storage keys
| Key | Store | Versioned | Corrupt-value handling |
|---|---|---|---|
| forkop:shown-log-error-notifications:v1 | session | yes | JSON try/catch, type filter, cap 500 |
| forkop:owned-ui-action-notifications:v1 | session | yes | try/catch, schema filter, cap 100 |
| forkop:diagnostic-run:v1 | session | yes | full schema check + 30 min TTL, removed when invalid |
| forkop.diagnostic.lastRun | local | no | Number() with try/catch around getItem; the call sites pass the global `localStorage` (evaluated outside the try) |
| forkop.monitoring.preferences | local | no | load in try/catch with whitelist; save (initController.ts:1204-1213) has no try/catch |
| forkop.connectivity.targets | local | no | validated, TLS→HTTPS legacy migration, falls back to defaults |
Naming is inconsistent (colon + v1 vs dotted, unversioned); functionally safe.

##### 4. State stores
Global StoreService (JSON-diffed; listeners run synchronously and are not isolated, so a throwing listener stops later listeners). Per-controller module state (history/autotune/monitoring). Three copies of provider availability (CLEANUP finding). localActionOverlay + uiActionNotification (session ownership). No duplicate store for the same widget.

##### 5. Duplicate data paths for one backend fact
- Service state: get_ui_state (poll) vs get_status + get_sing_box_status (fetchServicesInfo fallback) vs shell capabilities (get_ui_capabilities → get_ui_state → check_*_runtime).
- Clash proxies: direct HTTP :9090/proxies with bearer vs rpcd `clash_api get_proxies`. Connections: WS vs rpcd get_connections (overview on https polls the full connection list every 2 s just for totals).
- Strategy validation: section.js fs.exec vs ForkopShellMethods.validateDpiStrategy.
- Health: overview (10 s) + history (15 s) + settings (dead code).

##### 6. Unified UI status concepts → code (✓ consistent, ✗ inconsistent)
- invalid_input: route_trace {error:'invalid_input'} → 'Enter a valid domain or IP address' (siteCheck.ts:197-209) ✓; autotune reasons invalid_host/invalid_resolver → mutationErrorText ✓; connectivity_test invalid_input merged with transport failure ✗; nfqws/nfqws2/byedpi editor: transport failure cached as invalid strategy ✗; DPI playground distinguishes 'Syntax check is unavailable' ✓.
- unsupported: diagnostic check state 'unsupported' → muted ✓; autotune candidate unsupported ✓; provider not installed in rule editor/settings → configured value silently replaced ✗ (P2).
- busy: snapshot busy → warning ✓ (History); autotune busy → warning ✓; component already running → follow ✓; service action busy → red 'Service action failed: Another service action is already running' (untranslated) ✗; full uninstall: all start failures read 'Could not start removal. Another component action may be running.' ~.
- timeout: timeoutMessage()/renderAsyncState timeout phase unused ✗; executeShellCommand timeout → code 1 'Operation timed out' → generic failure everywhere; waitServiceActionJob timeout → 'Service action failed' ✗; connectivity backend status 'timeout' → warning ✓.
- failure: toasts / renderErrorState with Retry (history, autotune) ✓; logger-only paths: runtime poll failure, dashboard sections refresh failure with data, loadRouteDisplayNames (falls back to raw tags silently), followServiceActionState result, diagnostic runner exceptions (the check can stay 'loading' if a runner throws before updateCheckStore; edge).
- stale: autotune recommendation stale / snapshot stale ✓; UI data staleness never shown (isStale unused, poll failures, page-lifetime uci cache) ✗.
- forbidden: renderForbiddenState unused; RO hides controls and the guard returns code 126 'forkop: not available in read-only mode', which would render as a generic failure if reached ~.
- needs_attention: history/overview events ✓; autotune apply ✓; snapshot restore needs_attention → error toast 'Restore failed; check the recovery state' ✓; Overview Recovery card ignores recovery.pending/package_recovery.pending ✗ (P2); health null → 'healthy' ✗; Settings reload-confirmation notice dead ✗ (P2).
- configured/simulated vs observed (inv. 15): site check rows carry provenance ✓ but the conclusion upgrades 'unknown' to an observed failure ✗; Monitoring route 'Observed' + strategy 'From configuration' ✓, but the configured strategy is frozen at mount ✗.

##### 7. Hardware-report items: root causes confirmed in code
- 'Choose version' overflow: updates/styles.ts:144-149 `.fkp_updates-page__component__actions-main { … flex-wrap: nowrap; }` plus an extra button only on the Forkop card (updates/initController.ts:1278-1294).
- Overview lacks the 'Autotune DPI' card (G.1): dashboard/overviewCards.ts renderOverview (~238-250) renders state/routing/recovery/event only; OverviewInput (overview.ts:21-33) has no autotune data; no autotune reference in tabs/dashboard.
- Russian plurals: autotune/initController.ts:182 `_('At most %d change(s) per day; …').replace('%d', …)` and :620 `_('up to %d automatic change(s) per day')`; po/ru/forkop.po:324, 3459. N_() (LuCI plural) is used nowhere in fe-app-forkop/src.
- Units KB/s, B/s, KB, MB not localized: helpers/prettyBytes.ts:3 hard-coded `['B','KB','MB',…]`, used by the overview live line (overview.ts ~224) and Monitoring formatBytes.
- 'Скачать' next to 'Отправлено': monitoring/render.ts:101-102 reuse msgid 'Download'/'Upload'; po/ru/forkop.po:1067-1068 'Download'→'Скачать' (a verb, shared with button contexts such as the renderModal footer 'Download'), 3476-3477 'Upload'→'Отправлено'. Needs msgctxt or distinct msgids.
- Raw type 'Direct' on the node card: dashboard/partials/getOutboundFooterLabel.ts:4-9 falls back to `outbound.type` (sing-box/Clash type string).
- RO Overview shows outbound tags where admin sees the interface name: likely diagnostics/runtime.uc:813-814 safe_keys lacks `name`, so section_interface children arrive without a name and getDashboardSections.ts:272-276 (`interfaceItems.map((item) => item.name || '')`) yields nothing; the display falls back to the tag (medium confidence; `name` of section_interface is not secret).
- Snapshot diff shows *** for a value absent in the snapshot: backend config/snapshots.uc:206-212 safe_value returns '***' for any value that is not allow-listed, including null. The frontend (history/model.ts:212-215) would render '—' for undefined but never receives it. Pinned by tests/config_snapshots.sh; product decision.
- Full-uninstall modal focuses the dialog: updates/fullUninstall.ts:95-114 opens ui.showModal without focusing Cancel (confirmAction.ts:68 does `cancelButton.focus()`).
- Package upgrade leaves Forkop stopped (P2): not frontend (build.sh postinst chain).

##### 8. Bundle
Rebuilt in the scratch copy with the main checkout's node_modules (tsup 8.5.0) and formatted with prettier (the `format:js` script). The result is byte-identical to the committed main.js (sha256 7e5170f7…95b2). `yarn build` alone (tsup) differs only in formatting. The `ci` script formats src but not the bundle, so contributors must remember `yarn format:js`.

##### 9. Reproduction artifacts (scratch, not in the audit tree)
scratch/audit-frontend\build\fe-app-forkop\src\forkop\tabs\dashboard\tests\audit_repro.test.ts (Overview recovery/state), ...\tabs\diagnostic\tests\audit_sitecheck_repro.test.ts (probe failure → 'did not open'), ...\tabs\shared\audit_autostart_repro.test.ts (stale autostart read-back). Run from ...\build\fe-app-forkop with `node_modules\.bin\vitest.cmd run <file>` (node_modules is a junction to the main checkout, used read-only).

##### 10. Not reported (checked, low value or false positive)
- Clash WS close+error double-fire: the second event finds its listeners cleared; no double fallback.
- A UI-action ack racing the initiator's status poll: ack only stamps acked_at (service/ui.uc:1519-1549); status stays readable; no false failure.
- localStorage access throwing when site data is blocked: LuCI needs cookies to log in, so not reachable in practice.
- Autotune 'failed' outcome text 'previous configuration is kept' matches backend guarantees (apply.uc:713-721).

## A18/A22 Очистка UI и мёртвый код

### Вывод

I audited the whole tree read-only with tooling: a TypeScript language-service import graph and export-reference scan, TS noUnusedLocals, a Babel AST pass over the LuCI views, a dead-CSS scan of every rendered class, a replica of the locale extractor diffed against the POT and PO files, and ucode reachability plus duplicate-helper scans. I also rebuilt the bundle with tsup and prettier into scratch. It is byte-identical to the committed main.js.

There is no orphan TS module and no unused local. i18n is in sync with no stale msgids, and no shell function is left unreferenced.

Three low-severity defects came out of the dead-code work:
- **Monitoring → Nodes loads forever when Forkop is stopped.** Its stopped-state CSS hook targets a wrapper that the Stage 6.5 rewrite removed.
- **The read-only ACL (and its frontend mirror) still grants CLI commands that no page issues.** `check_nft` returns the full `nft list table`, including rule and set data the masked global check hides.
- **Component-install success toasts show raw English backend text.** `translate('Forkop has been installed')` hides that msgid from extraction, so it never reaches the POT.

The rest is cleanup:
- Two status vocabularies. The "single" `ui/status.ts` map is only exercised by tests, and Diagnostics keeps its own dictionary; labels already differ.
- Unused Stage 6.0 foundation modules, 4 unused icons, dead wrappers and exports, and 11 dead CSS classes.
- 6 dead functions in `section.js`.
- About 1000 lines of backend helper-module CLI modes with no production caller. Some are tested in place of the live code: the updater job-refresh logic, and the tag allocator in `helpers.uc`.
- Dead duplicate chains in `runtime.uc` and `validator.uc`.
- A no-op `restore_list_nft_snapshot` that a grep test presents as a rollback guarantee.
- `nft/apply.uc` and `config/rule.uc` each carry their own copy of the list parser.
- Runtime constants such as 127.0.0.42 are defined in seven or more places, and one of those ignores the environment override that the others honour.

I also located the root cause of each known hardware-report UI item that falls in this area (see extra).

### Проверено и корректно

- Generated bundle is in sync: fe-app-forkop/src/main.ts rebuilt with tsup (same options as tsup.config.ts) + baseclass patch + prettier defaults (format:js) into scratch -> 0 diff lines vs luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js
- Import graph: all 182 non-test TS files under fe-app-forkop/src are reachable from src/main.ts (TS LanguageService resolution); no orphan modules
- TS noUnusedLocals over tsconfig program: 0 unused-local diagnostics in non-test files (only exported-but-unused symbols remain, listed in findings)
- i18n: replica of extract-calls.js logic -> 1210 _() keys == 1210 POT msgids == 1210 RU msgids; 0 stale, 0 missing, 0 empty msgstr; fe-app-forkop/locales/{forkop.pot,forkop.ru.po} byte-identical to luci-app-forkop/po/*; committed locales/calls.json fresh (+0/-0). Only unextracted strings: translate('Forkop has been installed') (finding), settings.js:115 _(label) for DNS brand labels (intentional), menu title 'Forkop X' (brand)
- View -> bundle contract: every main.* symbol referenced by luci views exists in main.ts exports (store 14, ForkopShellMethods 13, validators, constants, 6 Tab controllers, coreService, setReadonlyMode, setForkopPage, injectGlobalStyles, applyUiStateToStore); only bulkValidate/showToast/confirmAction exports are unused by views
- Every Forkop.AvailableMethods enum value (types.ts:347-414) is referenced by a method wrapper
- READONLY_EXEC_PATTERNS (readonlyCommandGuard.ts:8-54) is an exact mirror of acl.d read grants, pinned by tests/luci_readonly_command_guard.sh
- Toast/notification: single toast implementation (helpers/showToast.ts); ui.addNotification used only for persistent log/update alerts (core.service.ts:42,51) and settings save errors (page/settings.js:101,175); uiActionNotification/logNotificationDeduper are dedupe trackers, not a second toast system
- Legacy tab code: TabService/isActiveLuciTab/forkopPage.ts are still load-bearing (standalone pages register controller id via shell.startPage; Monitoring switches dashboard/monitoring controller; Settings keeps real cbi-tabs for Components) - not dead
- Shell scripts: no unreferenced functions in install.sh (97), build.sh (26), forkop/files/usr/lib/full-uninstall.sh (6), usr/share/forkop/mirror-migration.sh (8), etc/init.d/forkop (12), init.d/forkop-torrserver-direct (2)
- Hand-written views settings.js, local_devices.js, shell.js, updates.js, page/*.js: no unreachable top-level declarations (Babel reachability)
- CLI commands with no frontend caller are all kept intentionally: internal (package_prerm/postinst, luci_postinst, dns_failover_apply from singbox/dns_failover.uc:228, main, dnsmasq_restore, *_if_due from cron in components/updates.uc & autotune/manager.uc:179) or documented operator diagnostics (show_config, check_proxy, check_nft, show_sing_box_version, neutralize_zapret_defaults = documented compatibility no-op, usr/bin/forkop:85)
- Kept intentionally (public CLI, documented in help): get_outbound_metadata, get_subscription_metadata, check_sing_box_logs remain valid CLI even though their frontend wrappers are dead
- autotune_target in the RO ACL is intentional: pinned as a required read diagnostic by tests/acl_boundary.sh:48
- support_report is intentionally unmasked (usr/bin/forkop:136 'complete unmasked support report'), admin-only (not in RO ACL read list), UI warns (diagnostic/initController.ts:176-182)
- shell_quote: 26 copies across ucode modules are byte-identical (single variant) - no quoting drift today
- Frontend compat adapters for older backends (getDnsCheckPresentation.ts:9, connectionView.ts:139, getDashboardSections.ts:1250,1304 snake_case metadata) are cheap and justified by independent forkop/luci-app-forkop package upgrades - keep
- Dead frontend symbols (except bulkValidate and ForkopShellMethods members) are tree-shaken by esbuild - zero bundle cost; cost is maintenance/test noise only
- Settings global CSS (#cbi-forkop-section .cbi-section-table-row.drag-over-above/below, .placeholder) targets LuCI GridSection sortable classes (page/settings.js:57 sortable=true) - live, not dead

### Инвентарь

SCRATCH TOOLS (read-only, in scratch/audit-deadcode\):
- unused-exports.cjs: import graph + export-reference scan.
- dead-css.cjs.
- i18n-diff.mjs: replica of extract-calls.js.
- unused-locals.cjs.
- views_dead.cjs.
- uc_dead.py / uc_reach.py / mode_reach.py: ucode dead-code scans.
- dup_helpers.py: ucode duplicate-helper scan.
- sh_dead.py: shell dead-function scan.
- build_check.cjs: bundle rebuild.

Outputs are the *.txt files next to the scripts. The worktree was not modified; its git status is still clean except the pre-existing untracked tests/runner/.

== 1. Frontend import graph / export inventory ==
- Entry: src/main.ts.
- 182 non-test TS files, all reachable. No orphan modules.
- TS noUnusedLocals finds 0 unused locals.

Exported but no production reference (non-test refs outside the declaring file = 0):
- ui/asyncState: createAsyncLoader, isStale (used by tests only).
- ui/states: renderAsyncState (tests only), renderForbiddenState (not used anywhere).
- ui/styles: BREAKPOINTS.
- diagnostic/statusLabels: eventStatus, healthStatus (tests only), formatTime (not used).
- renderCheckSection: checkDetailsOpen.
- maskDiagnostics: maskSupportReportText (tests only).
- helpers/isCopyableProxyLink (tests only, plus a stale mock).
- ui/status: describeStatus (tests only). DOMAIN_MAP/toSemantic are reached only through it.
- localActionOverlay: clearLocalActionOverlay (test reset helper, acceptable).
- Icons: CircleStop, CirclePlay, BookOpenText, Link.
- main.ts exports that no view uses: bulkValidate (dead everywhere, in bundle), showToast and confirmAction (used internally).
- ForkopShellMethods members with no caller: checkSingBoxLogs, componentActionStatus, getClashApiProxyLatencies, getOutboundMetadata, getSubscriptionMetadata.
- Store slices written but never read: trafficTotalWidget, tabService.all.
- Only bulkValidate and the ForkopShellMethods members reach the bundle; everything else is tree-shaken.

View -> bundle symbol usage (count of main.X references in views):
- store 14, ForkopShellMethods 13.
- validateUrl 4, parseValueList 4, applyUiStateToStore 4, LATENCY_TEST_URL_OPTIONS 4, FORKOP_UCI_PACKAGE 4.
- validateOutboundJson 3, validateIP 3, validateDNS 3, SECONDARY_RULESET_OPTIONS 3, DashboardTab 3, DEFAULT_LATENCY_TEST_URL 3.
- validateSubnet 2, getClashUIUrl 2, UpdatesTab 2, MonitoringTab 2, HistoryTab 2, FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT 2, DiagnosticTab 2, DOMAIN_LIST_OPTIONS 2, AutotuneTab 2.
- 1 each: validateProxyUrl, validatePath, validateDomain, validateBootstrapDNS, setReadonlyMode, setForkopPage, injectGlobalStyles, getProxyUrlName, domainListLabel, coreService, DNS_SERVER_OPTIONS, BOOTSTRAP_DNS_SERVER_OPTIONS.

Validators: all used except bulkValidate. The URL-scheme validators are used through validateProxyUrl.

== 2. Dead CSS ==
- 329 classes defined, 17 with no literal usage.
- 6 of those are LuCI-rendered classes and are legitimate: cbi-section-actions, cbi-section-remove, cbi-section-table-row, cbi-value-field/title, drag-over-above/below (LuCI sortable GridSection).
- The remaining 11 are dead (see finding).
- 30 classes are matched only through template prefixes (fkp-status--*, fkp-check--*, fkp-diag-badge--*, toast-*, path-kind--*). All their prefixes are rendered.

== 3. Localization ==
- POT, PO and calls.json are in sync.
- extract-calls.js logs a parse error for src/luci.d.ts; this is harmless (no _() calls there).
- The extractor handles only _(). There is no N_() plural support in the tooling or anywhere in the code, which is the root cause of the plural bugs listed in section 7.
- Non-literal _() calls: settings.js:115 DNS brand labels (fine) and shell/index.ts:30 translate() (finding).

== 4. CLI command inventory (usr/bin/forkop command_spec, 86 commands) ==
- Frontend-used: every Forkop.AvailableMethods value.
  - Also: show_version (shell/index.ts:132), forkop_releases, urltest_override_save/reset, full_uninstall, start/stop/restart/reload/enable/disable (via service_action_async and init.d).
- Internal:
  - package_prerm/package_postinst: build.sh postinst/prerm chain.
  - luci_postinst: uci-defaults 50_luci-forkop.
  - dns_failover_apply: singbox/dns_failover.uc:228.
  - main, dnsmasq_restore/restore_dnsmasq: init.d/lifecycle.
  - list_update_if_due, subscription_update_if_due, component_updates_if_due: cron from components/updates.uc.
  - autotune_if_due: cron from autotune/manager.uc:179.
  - list_update, subscription_update, component_action, autotune_run, autotune_apply: operator CLI or background workers.
- Operator-only diagnostics, documented and kept intentionally: show_config, check_proxy, check_nft, show_sing_box_version, neutralize_zapret_defaults (compatibility no-op, runtime.uc:1134), autotune_target (RO-pinned by acl_boundary.sh:48).
- Commands with no in-repo caller but documented as public CLI: get_outbound_metadata, get_subscription_metadata, check_sing_box_logs. Keep them in the CLI, but drop them from the RO ACL (finding).

== 5. Backend dead-code proof commands (run from repo root) ==
- `grep -rn "recover_persistent_list_cache_transaction\|recover_runtime_list_generation_transaction\|restore_list_nft_snapshot" forkop tests`
  -> the definitions (updates.uc:759, 763, 3654) plus the tests/list_update_reload_policy.sh:121 grep.
- `grep -rnw get_wan_ip_addresses forkop` -> runtime.uc:478 only.
  - The same holds for server_inbound_tag, resolve_public_host_ips, first_nonblank_line and selector_group_for_outbound.
- `grep -rnw valid_suffix forkop fe-app-forkop/src tests` -> domain.uc:365 and 375 only.
- helpers.uc modes: for each mode, `grep -rn '"<mode>"' forkop/files install.sh` excluding helpers.uc.
  - Only version-at-least (action.uc:520, runtime.uc:1509), url-get-host (runtime.uc:1247) and server-inbound-tag (dead caller runtime.uc:542) have callers.
  - stdin-first-line-last-field in action.uc:1319 goes to updater.uc, not helpers.uc (helper_output targets components/updater.uc, action.uc:176).
- Unused library exports that are only used inside their own module (acceptable, no action): connections.uc item_*/priority_*, migration.uc migrate_*_model, ip.uc valid_ipv6_cidr, select.uc median, state.uc summarize/save_full/LAST_DIR, singbox/constants.uc FAKEIP_*_DNS_RULE_TAG (used inside RESERVED_TAGS), autotune/manager.uc export block (module is CLI-only; nothing requires it).
- Test-only exports (test hooks, fine): routing/resolve.uc zapret_owner, nfqueue/check.uc nft_queue_overlap, ip.uc CLOUDFLARE_SHARED_CIDRS, singbox/dns.uc runtime_state, filter_identity.uc connection_key/inherit_names.

== 6. Duplicate pure helpers (copies / distinct variants) ==
- as_string 56/2, shell_quote 26/1 (identical), quote 11/6 (same escaping, different wrapper), command_from_args 21/4, object_or_empty 18/2, command_output 16/6, read_json_file 14/4, array_or_empty 13/1.
- valid_ipv4 7/6: core/ip.uc is canonical. probe.uc:ipv4_octets, singbox/country.uc and helpers.uc have their own implementations. Low drift risk because they are used for display/probe paths.
- owner_pid 7/4 (see section 8).
- text_list_values 4/1, strip_list_comment 4/1, filter_domain_subnet_values 2/1 (finding).
- version_compare 2/1 (validator.uc, helpers.uc).
- sing_box_version_is_extended 3/2.
- job_pid_valid 3/1, pid_running 4/2.
- Frontend duplicates:
  - formatTime ×3: autotune/initController.ts:87, history/model.ts:18, statusLabels.ts:66 (dead).
  - Byte formatters: formatBytes ×2 (renderSections.ts:54, monitoring/initController.ts:328) wrapping prettyBytes (fine).
  - StatusTone type ×2 (ui/status.ts vs diagnostic/statusLabels.ts).
  - Local tone dictionaries in connectivityMatrix.ts:102 and autotune/model.ts:83,327.

== 7. Known hardware-report items: root cause in code (confirmation only, not new findings) ==
- **Russian plural agreement.** autotune/initController.ts:182 `_('At most %d change(s) per day; a rolled back strategy waits %s.')` and :620 `_('up to %d automatic change(s) per day')`. The same pattern is at overviewCards.ts:187 `'%d more groups'`. No N_() anywhere, and extract-calls.js cannot extract N_. RU po lines 324 and 3459.
- **Traffic units not localized.** helpers/prettyBytes.ts:3 has a hard-coded `UNITS ['B','KB','MB',...]` and overview.ts:214 appends `'/s'`; none of this goes through _().
- **Monitoring sort 'Скачать' vs 'Отправлено'.** The single msgid "Download" is shared by the modal button verb (partials/modal/renderModal.ts:253) and the traffic noun (monitoring/render.ts:101, initController.ts:1034). RU po:1067 = "Скачать", po:3476 "Upload" = "Отправлено". Fix with distinct msgids ('Downloaded'/'Uploaded') or msgctxt.
- **Node card shows raw type "Direct".** dashboard/partials/getOutboundFooterLabel.ts falls back to `outbound.type`, the untranslated Clash API type.
- **Overview lacks the Autotune DPI card.** dashboard/overviewCards.ts renders only State (:136), Routing (:153), Recovery (:206) and Last important event (:219); OverviewInput carries no autotune data.
- **Full uninstall modal focuses the dialog, not Cancel.** updates/fullUninstall.ts:93 opens its own ui.showModal and never calls cancel.focus(). confirmAction.ts:66 does focus Cancel, but fullUninstall does not use it.
- Not analysed in depth (outside this area): Components 'Choose version' overflow and Rules at 768 (updates/styles.ts, src/styles.ts #cbi-forkop-section rules), RO outbound tags vs interface names, snapshot diff *** (config/snapshots.uc), and the upgrade postinst chain (build.sh).

== 8. Notes for other auditors (outside this area, unverified) ==
- owner_pid has 4 variants:
  - components/action.uc, updates.uc, service/lifecycle.uc and singbox/runtime.uc use `sh -c 'echo $PPID'` via popen.
  - autotune/lock.uc and config/snapshots.uc use readlink /proc/self.
  - action.uc:261,275 write this value to COMPONENT_LOCK_DIR/pid. Whether $PPID is the ucode PID depends on BusyBox ash exec-last-command behaviour. Worth checking by the process-identity auditor (invariants 13/14).
- Component job staleness (updates.uc:2376-2398 refresh_component_running_job_state) uses `kill -0 pid` without start-tick identity (PID reuse, invariant 14), as does pid_running at updates.uc/service/ui.uc.
- TabService (tab.service.ts:35-41) keeps a MutationObserver on the whole document.body (subtree plus class attributes) on every page, including Monitoring, which re-renders every second. This is a performance cost, not a correctness issue.

## A19–A21 Адаптивность, доступность, локализация

### Вывод

Static audit of the tree at commit 07872084, read-only. I found the root cause of every known hardware P3 item in this area:
- Components button overflow: `flex-wrap: nowrap` on the card action rows.
- Rules page at 768: the row-actions cell never wraps, some columns have fixed widths, and there is no narrow-screen rule.
- Full-uninstall focus: the dialog never focuses Cancel, and LuCI's `showModal` focuses the overlay.
- Russian plural bugs: two `change(s)` strings are translated with one fixed plural form. LuCI has `N_()`, but Forkop's locale tooling cannot extract it.
- Units: `prettyBytes` has hardcoded B/KB/MB, and `/s` and `ms` are hardcoded in Overview.
- "Скачать" next to "Отправлено": the msgid "Download" is shared by a verb button and a traffic noun.
- Raw "Direct": `getOutboundFooterLabel` falls back to the raw Clash type.
- Read-only Overview tags: the read-only config allowlist drops the child option `name`.
- No Autotune card: `renderOverview` has only 4 cards.
- `***` for absent values: `safe_value('')` returns `***`, and a test pins this.

New findings, all P3 or CLEANUP (nothing P1/P2 in this area):
- Escape does nothing in `confirmAction` and the other custom dialogs. LuCI's `cancelModal` only clicks `.right > button` or `.button-row > .btn`, and the code comment claims otherwise.
- Overview, Autotune and History re-render their whole block inside `role=status` on every poll or traffic tick (Overview about once a second). This destroys keyboard focus and makes screen readers re-read the block.
- The node cards used to pick a node are click-only `div`s, so they cannot be reached from the keyboard.
- Labels are not associated with their fields in the Autotune and URLTest dialogs and in the connectivity table.
- Toasts have no live region, error toasts disappear after 3 s, and the green success toast has low contrast.
- 29 VLESS/VMess/Trojan validation messages are hardcoded in English.
- Component install/remove results show raw English backend messages. The `translate()` wrapper hides the one frontend message from extraction.
- Dates use the browser locale instead of the LuCI language.
- CLEANUP: the shared breakpoint constants are unused (5 different sets are in use), and two CSS selectors are stale.

The translation catalogs are fully in sync: 1210 msgids, 0 missing, 0 untranslated, 0 fuzzy, 0 format mismatches, and `tests/luci_localization.sh` passes. Icon-only buttons are labelled, destructive actions go through confirmations, and event and status enums are localized.

### Проверено и корректно

- Catalog sync: a Babel extraction over fe-app-forkop/src/**/*.ts and view/forkop/**/*.js (excluding main.js) finds 1210 literal _() msgids; all are present in luci-app-forkop/po/templates/forkop.pot and po/ru/forkop.po, calls.json is not stale, and the ru.po has 0 untranslated, 0 fuzzy, 0 obsolete and 0 %s/%d mismatches; bash tests/luci_localization.sh passes on this tree
- Source and packaged catalogs are byte-identical (fe-app-forkop/locales vs luci-app-forkop/po). The ru.po header has correct Russian Plural-Forms (ru/forkop.po:18). No _() key has leading or trailing whitespace; LuCI _() trims (cbi.js trimws) and so does the extractor
- The LuCI menu titles in menu.d/luci-app-forkop.json (Overview, Monitoring, Diagnostics, DPI autotune, History and recovery, Settings) all have Russian translations
- Every backend history event kind (diagnostics/health.uc:17-18 EVENT_KINDS) is mapped in ui/status.ts:261-286; unknown kinds show the localized 'Other event', never a raw enum. Status and provenance mappers fall back to localized 'Unknown' / 'Not determined'
- Built-in list names are localized through domainListLabel (constants.ts:47-70); rule action labels are localized (section.js getActionOptionLabel ~3752); the monitoring path kind 'direct' → _('Direct') (connectionView.ts:117)
- Country names use Intl.DisplayNames with the LuCI language (section.js:554-555)
- Icon-only buttons have aria-label and title: monitoring close-all/pause (monitoring/render.ts:126-141), row actions (monitoring/initController.ts:940), overflow ⋯ summary (ui/overflowMenu.ts:18-24), connectivity ✕ (connectivityMatrix.ts:277-280), URLTest/Priority info (renderSections.ts:443-466), dynlist settings span with role=button, tabindex and keydown (section.js:1118-1143)
- Monitoring filters, sort and search have aria-labels (monitoring/render.ts:79-114); monitoring view tabs and autotune mode buttons use aria-pressed (autotune/initController.ts:657-671)
- Destructive actions go through confirmAction with Cancel focused (ui/confirmAction.ts:27-68): stop service, component removal, close all connections, snapshot restore/delete, autotune apply, auto mode and remove target (pinned by tests/luci_destructive_confirmations.sh). In every modal where LuCI's Escape handler applies (.right containers in fullUninstall.ts:111 and releaseSelector.ts:49,110), Cancel is the first button, so Escape can never trigger a destructive action
- Foundation tokens use LuCI theme variables with fallbacks (forkop/ui/styles.ts:15-29). The remaining literal colours are theme-neutral translucent rgba overlays or toasts with their own backgrounds; I found no hardcoded dark text on theme backgrounds
- The Overview grid follows design J.2 (dashboard/styles.ts:51-55, repeat(auto-fit, minmax(min(100%, 320px), 1fr))). The connectivity matrix and monitoring tables switch to stacked cards at 860/900px. The autotune and history tables scroll only inside their own wrapper (autotune/styles.ts:90, history/styles.ts:58)
- The 'N/A' literal is absent from TS sources; log levels and storage names are translatable (pinned by luci_localization.sh)
- Rule and grid summaries avoid plural agreement with a 'Label: %d' pattern (Lists: %d → Списки: %d, %d rules → Правил: %d, and others)

### Инвентарь

##### A. Known hardware P3 items: code root causes
1. Components 'Выбрать версию' overflow: updates/styles.ts:144-149 actions-main `flex-wrap: nowrap`; 'Choose version' is added to the same row at updates/initController.ts:1279-1296. The 1100/760 breakpoints keep 2 columns at 768. The same overflow will hit zapret/zapret2/byedpi once 'Обновить' appears after a check.
2. Rules at 768 is 21px wider than the viewport: styles.ts:38-42 makes the actions container inline-flex (never wraps) inside LuCI's `nowrap` cell (☰ + Изменить + Удалить, about 222px); section.js:6811/6827 fix widths at 6rem/8rem; no media rule for #cbi-forkop-section.
3. No Autotune card on Overview: overviewCards.ts:14-20 and :236-250 have only 4 cards.
4. Plurals: autotune/initController.ts:182 and :620 (default max_applies_per_day=1, policy.uc:28). LuCI has N_() (cbi.js:167), but extract-calls.js, generate-pot.js and luci.d.ts do not support it. Rewording to the 'Label: %d' pattern needs no tooling change.
5. Units: helpers/prettyBytes.ts:3,6; overview.ts:214 ('/s') and :228 ('ms', although '%d ms' → '%d мс' exists).
6. 'Скачать' vs 'Отправлено': msgid 'Download' is shared by renderModal.ts:253 (verb) and monitoring/render.ts:101 plus initController.ts:1034 (noun).
7. Raw 'Direct': dashboard/partials/getOutboundFooterLabel.ts:8 falls back to the raw Clash `outbound.type`.
8. Read-only Overview raw tags: runtime.uc:814-815 read-only safe_keys lack 'name' → getDashboardSections.ts:272-276 cannot build interface names. The read-only role has no uci read (ACL), so getConfigSections.ts falls back.
9. Snapshot diff '***' for absent values: snapshots.uc:206-211 (safe_value('') → '***'), pinned by tests/config_snapshots.sh:178-183. Product decision.
10. Full removal focus: fullUninstall.ts:93-113 never calls cancel.focus(); LuCI showModal focuses #modal_overlay.
(The P2 packaging item is outside this area.)

##### B. Breakpoint matrix (design J.8: 1279/899/599; BREAKPOINTS constant in forkop/ui/styles.ts is unused)
| Page | Media max-width values |
|---|---|
| updates/Components | 1100 (2 columns), 760 (1 column) |
| dashboard/Overview and Nodes | 900, 560, 700 (subscription meta), 560 (URLTest modal) |
| diagnostic | 860 (connectivity cards), 560 |
| monitoring | 900 (cards), 520 |
| autotune, history | 599 |
| rules grid (global styles.ts) | none |
| LuCI bootstrap | no table-to-card mode at 768 |

##### C. nowrap and fixed-width inventory
- Problems: updates/styles.ts:97 (info-row nowrap), :148 (actions-main), :167 (variants-buttons); styles.ts:38-42 (rules actions inline-flex); section.js:6811, :6827 (6rem/8rem columns).
- Acceptable, truncated with ellipsis plus title: monitoring/styles.ts:301, :309, :382, :401, :409, :528, :732; dashboard/styles.ts:207, :241, :662, :668 (short keys and meta).
- Low risk: diagnostic/styles.ts:137 (.fkp-diag-badge nowrap; statuses are short; an events override exists at :156); :352 (.fkp-conn__actions .btn, short 'Проверить'/✕).
- Overview/autotune/history cards use overflow-wrap:anywhere and min-width:0 (OK). Toast min-width 220 / max 340 (OK). .fkp-button-add-dynlist fixed 210px, capped by max-width:100% (OK).

##### D. Modal inventory (LuCI showModal focuses the overlay; Escape clicks the first '.right > button' or '.button-row > .btn')
| Modal | Initial focus | Escape |
|---|---|---|
| confirmAction (ui/confirmAction.ts) | Cancel (OK) | does nothing (.fkp-confirm__actions) |
| fullUninstall | overlay (bug) | Cancel (.right; disabled while removing) |
| releaseSelector, loading | overlay | nothing; no close button for up to 75 s |
| releaseSelector, list | overlay | Cancel |
| releaseSelector, error | overlay | nothing (Close is outside .right) |
| confirmVersionChange | overlay | Cancel |
| autotune policy/target/history-detail (modalActions .fkp-confirm__actions) | overlay | nothing |
| dashboard URLTest editor and URLTest/Priority info (footer class) | overlay | nothing |
| diagnostic info modals (initController.ts:578/615/653) | overlay | not individually checked |
| section.js nested settings modal (reuses LuCI .button-row, Close first) | — | Close (OK) |

All destructive confirmations put Cancel first, so Escape can never confirm.

##### E. i18n inventory
- Catalog: 1210 literal _() msgids, 0 missing in pot/po, 0 stale calls.json entries, 0 untranslated/fuzzy/obsolete, 0 format mismatches (scratch tool: scratch/audit-css-a11y-i18n/extract.cjs, using the main repo's @babel/parser read-only).
- Identical msgid/msgstr (technical, OK): Bootstrap DNS, DNS, DPI, JSON outbound, tiny, URLTest.
- Non-literal _() (not extractable): shell/index.ts:30 _(message) via translate(); its only caller :836 'Forkop has been installed' is missing from the pot. settings.js:115 _(label) for DNS provider labels (technical names, acceptable).
- Hardcoded user-facing English: 29 validator messages (vless 15, trojan 7, vmess 7); backend component action messages shown as toasts; 'ms' and '/s' in overview.ts; prettyBytes units.
- Composed phrases: settings.js:671, :675, :688, :691 _('Flash')/_('RAM') + ' (path)'. Acceptable; a test forbids untranslatable storage names.
- Plural candidates: 'At most %d change(s)…' and 'up to %d automatic change(s)…' (bugs); 'The strategy is changed only after %d checks' is OK for the allowed range 2-10; 'каждые %s' reads awkwardly as 'каждые 1 ч' when the interval is 1h (minor, not reported); '%d d' → '%d дн.' OK.
- Date/time: 7 toLocaleString call sites use the browser locale (finding); duplicate formatTime helpers in autotune/initController.ts:87, history/model.ts:18, diagnostic/statusLabels.ts:66 and ui/time.ts.
- Raw enums: event kinds, statuses and provenance are all mapped. Remaining raw values: Clash outbound type (Direct/Selector) in node footers, and read-only interface tags.
- LuCI base strings shown in English on the test router ('Name' grid header, 'Add', 'Save & Apply') come from missing luci-i18n-base-ru, not from Forkop.

##### F. Accessibility inventory
- OK: icon buttons labelled; aria-pressed toggles; monitoring filter aria-labels; overflow menu is a native details/summary with an aria-label.
- Minor, not reported: role=menu on .fkp-menu__list without arrow-key or Escape handling.
- Reported: node card div with a click handler; unassociated labels; role=status on large, frequently replaced containers; Escape handling; toast semantics.
- Monitoring rebuilds its table every second, which also drops focus from row buttons, but the Pause button mitigates it.

##### G. Observations outside this area (not verified)
- components-768.png shows Forkop X 1.0.26-6 as 'Установлена версия новее релиза' while still offering 'Обновить' to 1.0.26 (really a downgrade or reinstall). The updates/versions auditor should check shouldShowInstallAfterCheck for status 'dev'.
- confirmAction keeps a MutationObserver on document.body until the next showModal if the dialog is hidden by a foreign ui.hideModal(). Leak-level only.

## A23–A25 Производительность, shell, ucode

### Вывод

Main result: the global get_ui_state poll is expensive, and its cost grows with the number of processes on the router. Every Forkop LuCI page polls it once per second (every 0.5 s while an action runs). Each poll runs about 6 ucode interpreters and roughly N+25 other programs, where N is the number of /proc entries. Most of them come from state.uc sing_box_process_count(), which starts a shell plus `readlink` for every /proc/<pid>/exe entry. service/package.uc already does the same count in-process with fs.readlink. Measured in WSL on x86: 140-169 ms with about 80 processes and 363-398 ms with 277. The same poll also reads the whole package database (apk/opkg), dumps the full ForkopTable including set elements with `nft list table`, and fetches /proxies from the Clash API with curl. get_health_status repeats all of this every 10 s.

Second P2: every Clash API curl in diagnostics/runtime.uc has no --connect-timeout/--max-time. When the API accepts connections but never answers, clash-api-ready blocks with no time limit (reproduced: still blocked after 12 s). This probe is part of every get_ui_state poll and of reload/start verification (wait-forkop-stable-start). rpcd kills only its direct child. So stuck ucode/curl chains pile up about every 4 s per open tab, and a reload can hang with the transition guard in place.

Other findings: Clash API calls go through three extra ucode interpreters each; the Priority worker triggers this every 5 s per group, 24/7. A syslog warning is written on every poll when service_listen_address is set. UI job liveness uses `kill -0` with no guard against PID reuse. Two CLEANUP items. The known hardware P2 (upgrade leaves Forkop stopped when the mirror is unreachable) is confirmed; root cause is in build.sh, forkop/Makefile and mirror-migration.sh.

Areas that passed: shell quality and ucode compatibility. OpenWrt 24.10 ships ucode 2025-07-18, which is newer than the CI pin v0.0.20250529. The code uses no newer syntax and only the fs and uci modules. json() calls are try-guarded, and autotune numeric code is correct under ucode's integer division.

### Проверено и корректно

- ucode compatibility: no optional chaining, nullish operator, template literals or import/export anywhere in forkop/files/usr/lib or usr/bin/forkop. Only the fs and uci modules are required. Builtins used (signal, clock(true), b64enc/b64dec, localtime, sourcepath, fs.glob/readlink/lsdir/lstat/rename/chmod, file.lock) all exist in the CI pin v0.0.20250529 (file.lock and signal confirmed in the local build). OpenWrt 24.10 ships ucode 2025-07-18 (package/utils/ucode/Makefile PKG_SOURCE_DATE), newer than the CI pin.
- Forward references: tests/ucode_forward_reference.sh guards calls. My extra scan for functions passed as values (sort/map comparators: config/connections.uc:396 priority_level_sort, autotune/manager.uc:69 quote, autotune/select.uc:119/181 by_simplicity) found all of them declared above their use.
- json() parsing is wrapped in try/catch at every checked site: nft/apply.uc:1746-1751, config/snapshots.uc:133-139, routing/resolve.uc:108-111, diagnostics/health.uc:24-33 and 206-209, components/updates.uc:2485, singbox/priority.uc:207, service/state.uc:443-450.
- core/uci.uc:265-300 caches the UCI cursor and each loaded package per process, so a single ucode process never reloads UCI. The repeated loads happen only across the spawned sub-processes (see findings).
- autotune/select.uc numeric semantics: ucode integer division truncates (verified: 5/2 = 2), the median uses int(n/2) and a float mean of the two middle values, ratios use *1.0, and comparators return numbers. autotune/policy.uc:55-58 checks values against a regex before int(), which avoids int('') = NaN (verified that int('') is NaN in ucode).
- Bounded external probes: autotune/probe.uc:139-143 (curl --connect-timeout 5 --max-time 10), diagnostics/connectivity.uc:55-61 (curl bounded, dig +timeout=3 +tries=1), singbox/dns_failover.uc:114-124 (dig +timeout +tries=1), subscription/cache.uc:1541-1547 (connect-timeout plus speed-limit), singbox/ruleset_cache.uc:390.
- autotune/lock.uc: stale locks are recovered through a pid plus start-ticks owner record (active_owner), so a crashed or excepting process cannot wedge the autotune lock.
- service/lifecycle.uc has no internal exit()/die() apart from the final exit(status) at 2212, so start() always removes START_IN_PROGRESS unless a runtime exception occurs.
- full-uninstall.sh: set -eu, EXIT trap finish() marks the job failed and releases both lock dirs, and only fixed product paths are rm -rf'd, never UCI-supplied ones. `1000>&-` is valid in BusyBox ash (procd.sh itself uses fd 1000). dnsmasq_restore always exits 0 (dns/apply.uc:270-288), so it cannot abort the uninstall. rc.common procd stop() ends with an if that returns 0.
- mirror-migration.sh: transaction manifest with rollback on the EXIT trap, private mktemp -d under TMPDIR, set -eu. The sed -E, awk -v and cmp -s forms are BusyBox-compatible.
- init.d/forkop: reload_service captures the status of the command substitution correctly and resets the trap. The service_triggers tab-separated read is safe because only the trailing field can be empty (initd.uc:778-789).
- shellcheck 0.9.0: ops/hosting/*.sh and ops/mirror/*.sh are clean at all severities, including -o all. install.sh, build.sh and init.d have only benign items (unused variables, enumerated unquoted arguments, SC2155 in build.sh:106, rc.common boilerplate).
- No GNU-only tools or flags in router-side shell: no sed -i suffix, grep -P, date -d, readlink -f, stat -c, xargs -r, find -printf, mktemp --suffix, sort -V or timeout in install.sh, full-uninstall.sh, mirror-migration.sh or init.d.
- Frontend: the get_ui_state poller skips while document.visibilityState != 'visible' (runtimeUiState.service.ts:21-27, 74-76) and serializes in-flight requests. Dashboard, history, autotune and monitoring interval timers are cleared on unmount (dashboard/initController.ts:1978-1984, history:432, autotune:1162-1167).
- Background job start and owner pid: `sh -c 'echo $PPID'` via popen returns the ucode PID (measured on 25.12, docs/upstream/2026-09-16.md). Workers are recorded with process_identity (dns_failover.uc:335-338, priority.uc:440-443).
- service/ui.uc action JSON state files are written atomically (write_state_file, tmp file plus rename, ui.uc:167-181).

### Инвентарь

##### A23 Polling inventory: what each UI poll costs on the router

Frontend sources are under fe-app-forkop/src/forkop. Backend is `/usr/bin/forkop` = ucode dispatcher -> system() -> ucode <module>. Every CLI call starts at least 2 ucode interpreters.

| Poller (file:line) | Interval | Hidden tab | Backend command and per-call cost |
|---|---|---|---|
| runtimeUiState.service.ts:6-8, started by core.service.ts:117 on every page | 1 s idle / 0.5 s during actions (after the previous call completes) | stops | `get_ui_state`: ui.uc (4 action-dir globs, kill -0 per running job), `apk list --installed --manifest` or `opkg list-installed`, `ucode state.uc forkop-stably-running` (3x `ubus call service list`, N+4 readlink, `cat /proc/self/stat`, `netstat -ln`, `ucode runtime.uc clash-api-ready` -> `ucode singbox/runtime.uc service-listen-address` (+ubus/ip) + `curl /proxies` with full JSON parse, `nft list table inet ForkopTable` (full, incl. set elements), `ucode nft/apply.uc tproxy-route-rule-present` (+ip route/rule)). About 6 ucode interpreters and N+25 programs. WSL: 63 spawns and 281 ms with N=35. |
| core.service.ts:21 log watcher `check_logs` | 10 s | pauses | runtime.uc: `logread` (whole ring buffer) -> mktemp temp file -> ucode status.uc forkop-logs |
| dashboard/initController.ts:61 sections | 10 s | continues (browser-throttled) | LuCI uci read + `/proxies` (direct fetch on http; over HTTPS the CLI clash_api get_proxies = +3 ucode) + `get_dashboard_runtime_metadata` (parses the whole sing-box config JSON) |
| dashboard/initController.ts:1949 health | 10 s | continues | health.uc: full `ui.uc get-ui-state` again + up to 3 `nft list` |
| dashboard/initController.ts:62 clash RPC | 2 s | continues | only when ws unavailable (HTTPS): clash_api get_connections = runtime.uc + singbox/runtime.uc + curl + mktemp + status.uc stdin-json re-parse |
| monitoring/initController.ts:96 | 1.5 s | continues (pausable) | same as above (HTTPS fallback) |
| monitoring RENDER_INTERVAL 500 ms | - | - | client-only |
| history/initController.ts:25 | 15 s | continues | get_health_status (= get-ui-state again) + get_history (flash jsonl <=64 KiB) |
| autotune/initController.ts:43/46 | 15 s status; 120 s groups; 2 s job poll | continues | autotune_status; autotune_groups (up to 16 dig lookups, 2 s timeout each) |
| shell/index.ts action polls | 1 s service/latency; 1.5 s component/subscription; +15 s get_ui_state | - | cheap (JSON file read + kill -0) |

Background, with the UI closed:
- Priority worker: probe every 5 s per group (4 ucode + 2 mktemp + 2 ubus + curl), recovery every 15 s, fastest every 3 min, plus `sleep 1` fork every second.
- DNS failover worker: `sleep 1` fork every second; dig probes every 10 s and 60 s.
- torrserver direct worker: `nft list chain` every 60 s.

Estimated magnitude on MT7986 (unverified on hardware, extrapolated from x86 WSL at ~4-6x): about 0.5-1.5 s CPU per get_ui_state with 150-250 /proc entries. Recommended hardware check: `time /usr/bin/forkop get_ui_state` and `ls -d /proc/[0-9]* | wc -l` on the router.

##### A24 Shell review summary
- shellcheck 0.9.0 (all severities):
  - ops/**/*.sh clean.
  - install.sh: SC2015 at 1978 (benign: continue), SC2034 unused SING_BOX_TINY_SWITCHED and FORKOP_INSTALL_REQUIRED_KB, SC2086 at 2340 and 2506 (enumerated values).
  - build.sh: SC2155 at 106, SC2016 at 410 and 587 (intentional sh -c).
  - init.d: rc.common boilerplate only.
  - full-uninstall.sh: SC3023 fd 1000 (valid in BusyBox ash, used by procd.sh).
  - mirror-migration.sh: SC2317 false positives inside trap functions.
- Manual notes (not findings):
  - mirror-migration.sh:95-100 interpolates MIRROR_BASE_URL into sed regex and replacement unescaped. Only a custom URL containing `&` would corrupt the rewrite; `#` makes sed fail and the change rolls back, i.e. fails safe.
  - config/validator.uc:195 uses `/tmp/forkop-validator-version.$$` (predictable, root). Mitigated by /tmp sticky bit plus fs.protected_symlinks.
  - full-uninstall.sh leaves $JOB (mktemp dir with output.log) in /tmp.
  - ops/mirror/sync-lists.sh:25 has no trap for its mktemp archive on failure, and :57-59 has a short window where MIRROR_ROOT is absent during the swap (server-side only).
  - install.sh:215-219 falls back to `/tmp/forkop.$$` when mktemp is absent (BusyBox always has mktemp).

##### A25 ucode compatibility matrix
- CI: ucode v0.0.20250529, built with UCI/UBUS/ULOOP OFF (.github/workflows/backend-ci.yml:47-51).
- OpenWrt 24.10: ucode 2025-07-18 (newer than CI).
- 25.12: newer still.
- Syntax: none of ?. / ?? / template literals / import / export / ** / logical assignment. Spread and arrow functions are old features.
- Modules: fs and uci only.
- Builtins: signal, clock(true), sleep (unused), localtime, b64enc/dec, sourcepath, fs.readlink/glob/lsdir/lstat, file.lock (autotune/manager.uc:92, 222). All present in the CI pin.
- Semantics verified locally:
  - integer division truncates;
  - int('') and int('abc') give NaN, and NaN comparisons are false;
  - int(null) = 0 and null+1 = 1;
  - sprintf('%J', NaN) = "NaN" (string), while 0.0/0.0 printed 1e309;
  - large int64 serializes exactly.
- Coverage gap (note): CI has UCI_SUPPORT=OFF, so tests use FORKOP_UCI_STATE_FILE fixtures and the real libuci branch of core/uci.uc (cursor, anonymous `@type[n]` resolution via foreach) is exercised only on hardware.

##### Other observations (low / out of area, not reported as findings)
- diagnostics/runtime.uc:1582-1587 passes `Authorization: Bearer <yacd_secret_key>` on the curl command line, so it is visible in /proc/*/cmdline to local processes (secrets area).
- autotune/isolation.uc:754-761 summary() uses the upper-middle element as median_tls_ms, while autotune/select.uc:32-37 averages the two middle values. The isolation summary is display/diagnostic only (selection uses select.uc), so this is duplicate logic with different semantics (CLEANUP candidate).
- singbox/dns_failover.uc:270-274 re-reads settings() each loop to detect config changes, but core/uci.uc caches the loaded package for the process lifetime. The in-loop change detection is likely ineffective; lifecycle restarts the worker on reload, so there is no observed impact (unverified: no libuci module in WSL).
- Dashboard, history and autotune interval pollers are not visibility-gated (only get_ui_state and the log watcher are). Browsers throttle them in hidden tabs.

##### Scratch reproductions
All under scratch/audit-perf-shell-ucode\:
- count_spawns.sh, scale.sh, count_ui_state.sh: readlink/spawn counts and scaling.
- count_latency.sh: Priority probe cost.
- curl_hang.sh: unbounded Clash API curl.
- listen_log.sh: syslog warning per call.
- compile_time.sh: ucode start/compile times.
- sem.uc, api.uc, sleep.uc: ucode semantics.
- fwdref_values.py: function value forward-reference scan.
- sc.sh: shellcheck.

## A26 Сборка и пакеты

### Вывод

Worktree 07872084, read-only. Packaging is mostly consistent. Dependencies and conflicts are the same across forkop/Makefile, build.sh IPK/APK and the install.sh preflight. Version placeholders are substituted in both constants.uc and main.js. The committed main.js is byte-identical to a fresh tsup + prettier build of fe-app-forkop/src (rebuilt in scratch). The duplicated po/pot files are identical. The targeted tests package_lifecycle, package_upgrade_wait, mirror_migration and full_uninstall pass.

Confirmed the known P2 and traced its root cause. The postinst/post-upgrade `&&`/`|| exit` chain skips package_postinst whenever mirror-migration.sh fails. mirror-migration.sh makes network calls on every install, not only on first migration: the platform index, and on APK the signing key.

New findings:
- (P2) In-app Forkop install/upgrade stops Forkop first and never restarts it when the action later fails or is refused before any package change. Reproduced in scratch.
- (P2, cross-area core) core/uci.uc reports success when libuci commit/set/delete fail, because ucode's uci module returns null on error and the code only checks for false. This affects the migration commit on upgrade.
- (P2) Package removal and Full uninstall ignore a refused Forkop stop (ambiguous sing-box ownership). Packages are removed and the job reports "complete" while ForkopTable, ip rules and cron entries stay behind until reboot.
- (P3) package_postinst's missing/empty-config recovery can never run in the real chain because migration and mirror-migration run first; `uci set` on a missing config fails (verified).
- (P3) forkop-torrserver-direct is never stopped on remove/uninstall or restarted on upgrade. Its worker caches UCI and keeps re-adding its nft table.
- (P3) The failsafe dnsmasq fallback in package.uc calls ucode without -L and always fails (verified).
- (P3) The SDK Makefile path is broken: a ucode prerm sourced by sh, default_postinst auto-enables and starts Forkop, and the torrserver init script is missing.
- (P3) Full uninstall leaves /etc/forkop-backups (a full config archive with secrets).
- (P3) Residual of F-008: the latest-release path still skips SHA-256 verification.
- (P3, product decision) Official feeds are re-pointed to the mirror on every upgrade.
- CLEANUP: the legacy `forkop uninstall` command; torrserver-direct START/STOP values out of rc.d order.
- FUTURE: sysupgrade keep list for /etc/forkop state.

### Проверено и корректно

- Dependencies consistent in 3+1 places: forkop/Makefile:25 DEPENDS == build.sh:63 BACKEND_DEPENDS_IPK == build.sh:64 BACKEND_DEPENDS_APK (+!conflicts) == install.sh:1986-1989 preflight list (+luci-base); conflicts identical (Makefile:26, build.sh:64-65) and verified post-build (build.sh:611-645)
- Runtime command/module coverage: only ucode modules fs and uci are required (both declared); nft->nftables-json, ip rule fwmark/mask->ip-full, curl+ca-bundle, dig->bind-dig, base64->coreutils-base64; unzip and kmod-nft-socket are installed on demand (action.uc:1176, 2541-2544); remaining tools (sha256sum, md5sum, tar, flock, crontab, pgrep, killall, nslookup, netstat, readlink, logger) are default busybox applets
- Version substitution: build.sh:200-201 (constants.uc) and :219-220 (main.js) replace __COMPILED_VERSION_VARIABLE__ with RELEASE_VERSION; Makefiles do the same (luci.mk honors Build/Prepare/$(LUCI_NAME)); APK x.y.z-N -> x.y.z-rN (build.sh:49, pinned by package_contract.sh); forkop_release_matches handles -rN (action.uc:2029-2034)
- Committed luci-app main.js is byte-identical to a fresh tsup build of fe-app-forkop/src at this commit plus default prettier formatting (scratch rebuild, 624133 bytes, 0 diff lines)
- fe-app-forkop/locales/forkop.ru.po and forkop.pot are identical to luci-app-forkop/po/ru/forkop.po and po/templates/forkop.pot
- File modes: normalize_package_root_modes sets 0644/0755 and then 0755 on init scripts, /usr/bin/forkop and mirror-migration.sh (build.sh:175-209); full-uninstall.sh (0644) is run with `sh` (components/uninstall.uc:5); .uc files are always run through `ucode`; uci-defaults and control scripts are 0755; root ownership via fakeroot/unshare
- Conffiles: /etc/config/forkop declared for IPK (build.sh:293-295, Makefile:60-62) and APK (.conffiles + .conffiles_static, build.sh:245-266); pristine defaults copy at /usr/share/forkop/defaults/forkop
- Secrets-bearing artifacts are protected: config backup archive chmod 600 in a 700 dir (action.uc:2321-2337), opkg recovery dir 0700 (action.uc:2152), legacy config backup 0600 (install.sh:2637-2641), full-uninstall runs with umask 077
- package prerm records the restart hand-off from the actual service status, not the opkg action argument (package.uc:164-181); postinst waits for the old sing-box to exit without killing anything by name (package.uc:79-95, invariant 13)
- mirror-migration.sh is transactional (backup manifest plus rollback on EXIT, :48-118) and never runs apk/opkg update from package-script context (:212-214)
- opkg in-app package-set upgrade: staged previous release, --noaction preflight, durable pending marker, rollback and service-state restore (action.uc:2073-2209, pinned by tests/forkop_opkg_set.sh)
- Version-picker path verifies SHA-256 against the catalog and backs up the config before installing (action.uc:2339-2352, 2383-2389); the catalog accepts only x.y.z tags whose URLs point into the release directory (action.uc:708-741)
- full-uninstall.sh: restores feeds only from a non-mirror .pre-forkop-mirror or /rom source and fails closed otherwise; checks every package was removed; deletes only fixed product paths; status file is non-sensitive; the CLI refuses start/reload/etc while the uninstall lock exists (bin/forkop:259-266)
- Plain package removal: pre-deinstall/prerm stops Forkop (which removes cron lines including autotune, nft tables and ip rules/routes when the stop proceeds), restores dnsmasq, removes the Forkop-managed sing-box binary variant and removes the 105 forkop rt_tables entry (package.uc:183-194, lifecycle.uc:1066-1100)
- Obsolete packaged files (pre-Stage-6 views dashboard.js/diagnostic.js/forkop.js/monitoring.js, server.js, service.uc, servers.uc, route_owner.uc, old usr/lib/service/mirror-migration.sh) were package-owned, so opkg/apk remove them on upgrade; the LuCI index cache is cleared by uci-defaults 50_luci-forkop -> luci_postinst and by the in-app flow
- install.sh update mode records and restores the previous enabled/running state on any later failure (install.sh:2151-2161, 2803-2808), verifies SHA-256 of release assets (:1625-1637) and gates on the mirror platform index
- Targeted backend tests pass on this tree: package_lifecycle, package_upgrade_wait, mirror_migration, full_uninstall

### Инвентарь

##### A26 inventory

###### Version matrix
- RELEASE_VERSION = 1.0.26, but the tag 1.0.26 (65787ed4) is 48 commits behind HEAD 07872084. build.sh takes the version as an argument. The workflow reads RELEASE_VERSION only when no tag or input is given and enforces x.y.z. Building this tree as 1.0.26 would create a second, different "1.0.26": opkg/apk see the same version, and the in-app "previous release" would be the published 1.0.26. The version must be bumped before release.
- build.sh accepts x.y.z or x.y.z-N (APK: x.y.z-rN). forkop/Makefile, prepare-release.sh, publish-forkop-feed.sh, the catalog, updater forkop_release_version_valid and previous_forkop_release accept only x.y.z. So an -N build reports itself as "dev", is never offered updates, and on opkg every in-app install of it is refused (Forkop left stopped, see P2 finding).
- The version in constants.uc and main.js is the same RELEASE_VERSION (build.sh:200, 219). fe-app-forkop/package.json "1.0.0" is unused.
- luci-app-forkop depends on unversioned `forkop`, and i18n on unversioned `luci-app-forkop`. Partial CLI upgrades can mix UI and backend versions; the in-app opkg path checks consistency, CLI paths do not (FUTURE: `forkop (=VER)` pin).

###### Dependencies (declared vs used)
Declared (all 3 places identical): ca-bundle kmod-inet-diag kmod-tun curl ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy coreutils-base64 bind-dig nftables-json kmod-nft-nat ip-full (+libc).
- Used ucode modules: only fs and uci.
- External commands: nft, ip, curl, dig, base64, sha256sum/md5sum, tar, mktemp, find, readlink, logger, crontab, pgrep, killall, nslookup, netstat, ubus, sing-box, apk/opkg, modprobe/lsmod.
- On demand: unzip (zapret bundles), kmod-nft-socket (TorrServer Direct).
- No missing hard dependency found.
- Residual risk (not a finding): Forkop start triggered from an opkg postinst (package_postinst -> init start) may call `opkg list-installed` (validator.uc:221 fallback, packages.uc via singbox/runtime.uc:306-318). opkg-lede locks for every command, so these return empty inside the parent's lock. Only fallbacks/tiny detection are affected; the in-app flow avoids it because it starts after opkg exits.

###### Maintainer scripts
- build.sh IPK:
  - forkop: postinst (sh) = migrate `|| exit`, mirror-migration `|| exit`, package_postinst. prerm (ucode) = `package_prerm <arg>`, always exit 0. No postrm.
  - luci-app / i18n: default_postinst / default_prerm.
- build.sh APK:
  - pre-install: no-op.
  - post-install / post-upgrade: migrate && mirror && postinst.
  - pre-deinstall: `prerm remove`, exit 0.
  - pre-upgrade: `prerm upgrade`, propagates status. Upstream apk_ipkg_run_script only marks broken_script, so this does not abort the upgrade.
  - app/i18n: add_group_and_user + default_postinst/default_prerm.
  - .list and .conffiles/.conffiles_static are generated.
- SDK Makefile: broken; see the P3 finding.
- None of the scripts enable Forkop on install. install.sh and the UI own enablement; rc.d links survive plain removal (harmless; reinstall re-enables autostart).

###### Upgrade path and failure outcomes
1. In-app path: stop_old_sing_box_before_forkop_upgrade stops Forkop first. Any failure after this, including opkg preflight refusals and apk add errors, leaves it stopped (P2 finding).
2. prerm / pre-upgrade: records /tmp/forkop-package-was-running only if Forkop is still running, then stops it.
3. Files replaced; obsolete package-owned files are removed by apk/opkg.
4. migration.uc migrate:
   - Failure aborts; Forkop stays stopped. That is fail-closed, but it is silent.
   - Commit failures are reported as success (core uci P2).
   - Migrations are forward-only. On opkg automatic rollback, the older backend runs with the forward-migrated config; the latest path takes no config backup.
5. mirror-migration.sh: network failure -> known P2. Missing or empty config -> P3.
6. package_postinst:
   - Waits 15 s for the old sing-box to exit; a timeout leaves Forkop stopped (logged).
   - Otherwise starts Forkop only if the marker exists.
   - opkg: a failed postinst leaves the package "unpacked"; the in-app opkg path still restores the service.
   - APK: broken_script is set and the in-app APK path does not restart.
7. install.sh: stops and disables first, then restores the enabled/running state on failure. OK.

###### Remove / purge matrix
- Plain `apk del` / `opkg remove forkop`:
  - Done: prerm stops Forkop (cron, nft, ip rules/routes, DNS failover), restores dnsmasq, removes the managed sing-box binary variant and the rt_tables entry.
  - Left behind: /etc/forkop, /etc/forkop-backups, /etc/sing-box, modified /etc/config/forkop (OpenWrt convention), rc.d links, the torrserver-direct worker and nft table, feeds/key.
- Full uninstall:
  - Done: everything above, plus feed restore, removal of the key, forkop.list and packages, product paths, LuCI caches, and /var/run/forkop.
  - Left behind: /etc/forkop-backups (P3), torrserver-direct worker/table/rc.d links (P3), zapret/zapret2/byedpi packages (external providers), packet_steering setting, /tmp job dir with output.log (tmpfs).
  - Continues after a refused stop (P2).
  - On ext4 images without /rom and without .pre-forkop-mirror, preflight refuses (fail-closed, cannot uninstall).
- `forkop uninstall`: legacy non-package remover (CLEANUP finding).

###### Permissions
- Package payload: 0644 files, 0755 dirs and executables.
- /etc/config/forkop is 0644 (OpenWrt convention; holds secrets but readable only by local processes).
- 0600/0700: config backup, opkg recovery, subscription cache (migration.uc:1531-1533), legacy backup.
- /etc/apk/keys/forkop-mirror.pem is 0644 and is trusted globally by apk: the mirror operator's key can sign packages for any repository (supply-chain note; product scope).

###### Ops
- publish-forkop-feed.sh / update-forkop-from-git.sh rebuild packages from the tag on the mirror. Their sha256 therefore differs from the GitHub/fold8 artifacts of the same version: two distribution channels with different package hashes.
- sync-forkop.sh downloads SHA256SUMS but does not verify the assets against it.
- prepare-release.sh / build-release-catalog.py write per-asset sha256 and accept only x.y.z.
- No defects affecting routers found in ops beyond these notes.

###### Other checks
- Committed main.js equals a fresh tsup build plus default prettier (scratch). There is no automated check for this; a test comparing `tsup` output to the committed bundle would catch stale bundles, since build.sh packages the committed file without rebuilding.

###### Scratch artifacts
All under scratch/audit-a26\:
- refused_upgrade.sh: in-app refusal repro.
- noL.sh: missing -L repro.
- uci_missing.sh: uci set on missing/empty config.
- rcorder.sh: rc.d ordering.
- eq.uc: ucode null != false.
- fe/: bundle rebuild.

###### Tests run
Backend lane, isolated: package_lifecycle, package_upgrade_wait, mirror_migration, full_uninstall — all PASS.

## A27/A28 Качество тестов

### Вывод

I found no test that can never fail: all 158 backend tests run under set -e, the assertion helpers exit non-zero, and no assertion compares a value with itself. Most stubs agree with the real tools wherever production depends on them. I checked this with real nft 1.0.9 in a throwaway user+net namespace and with the real OpenWrt uci CLI.

The main problems are CI coverage, portability and a few weak spots.
- **P2, CI:** Backend CI builds ucode without the uci CLI. Five autotune tests (groups, manual_apply, autoapply, scheduler, recovery) therefore fail with no output. Confirmed locally: without uci on PATH they exit 1 in 0.2-0.6 s; with it they pass. The release job needs backend-checks, so releases are blocked.
- **P3, CI paths:** Backend CI does not trigger on luci-app-forkop/** or fe-app-forkop/**, yet 31 backend tests read those files, including acl_boundary.sh (read-only boundary).
- **P3, portability:**
  - list_cache.sh does not isolate TMP_SING_BOX_FOLDER, so production code runs `mkdir -p /tmp/sing-box` and `df` on the host. The test also assumes the host has less than about 931 GiB free.
  - config_contract_matrix depends on git history and may `git fetch` from origin into the developer's repo.
  - Fixed-sleep races remain in tests the foreign diff does not touch.
- **P3, bug found by an A28 differential check:** config/domain.uc lowercases only ASCII, Latin-1, Russian and basic Greek. Uppercase Ukrainian, Belarusian, Polish, Turkish and accented Greek IDNs get wrong punycode, so the rule never matches. Example: "Їжак.укр" becomes xn--2za6frar instead of xn--80aln7i.
- **CLEANUP:**
  - Frontend status tests use toBeTruthy against functions that always return a fallback string.
  - The ui/status.ts DOMAIN_MAP is used only by tests.
  - There are duplicate /proc stat parsers (index vs rindex) and duplicate hand-rolled UCI parsers.
  - About 405 assertions grep production source text instead of testing behaviour.
  - Real nft is available and works unprivileged, but no test uses it.

I also list cheap property/permutation tests for the route resolver, hysteresis, mark/mask ranges, selection, the domain parser, config normalization and status mapping.

### Проверено и корректно

- All 158 tests/*.sh start with set -e (71 'set -eo pipefail', 65 'set -euo pipefail', 17 'set -eu', 1 'set -eu; set -o pipefail'); every standalone '! cmd' negation has an explicit '|| fail' (e.g. autotune_select.sh:220)
- No self-comparison assertions in tests/ or fe-app-forkop/src (rg for equal(x,x), expect(x).toBe(x), [ "$a" = "$a" ] found nothing)
- Assertion helpers inside embedded node/ucode scripts exit non-zero: config_migration.sh:180/387 (process.exit(1)), connection_cascade.sh:117 and remote_lists_routing.sh:119 (die), sing_box_runtime.sh:1183 and dns_failover.sh:96 (exit(1)), subscription_reorder.sh:15 (die)
- assert_rejects in config_validator_detour.sh:17, config_validator_download_section.sh:27 and config_validator_runtime.sh:39 also checks the rejection message, not only the exit code
- Every file targeted by a negative source-grep ('if grep ... "$VAR" ...; then fail') resolves to an existing path today (script: scratch/audit-tests/neg_grep_targets.sh); the sed-extracted function anchors exist (service/ui.uc:148 ensure_dir, :743 cleanup_dir; service/state.uc:539 process_age_seconds; subscription/cache.uc:666 move_file)
- tests/core_uci_runtime.sh covers the real-cursor branch of core/uci.uc (anonymous section resolution, list add/del) with a fake 'uci' module; dns_apply.sh covers the fixture branch
- autotune_apply.sh uci stub: refuses the live config (line 113 'uci touched the live config'); set-then-commit on the private package is asserted from the log (line 513), so the stub's immediate-write 'set' cannot hide a missing commit
- Real nft 1.0.9 in a private netns (unshare -rn) accepts the batch production generates in FORKOP_NFT_BATCH_FILE mode, the way service/lifecycle.uc:307 runs it (runtime base, output rules, provider queues, priority rules, set chunks; 137 lines): both 'nft -c -f' and a real 'nft -f' succeed. Script: scratch/audit-tests/nft_batch_real_check.sh
- The autotune probe batch pinned by autotune_isolation.sh:90-99 and the 'replace rule ... handle N' release are valid for real nft. Real handles differ from the stub (probe rule is handle 6 in real nft, the stub says 5), which is harmless because isolation.uc:570-612 reads handles from the -j listing
- isolation.uc nft_listing()/probe_counters() tolerate the real 'nft -j' shape (a metainfo object and chain objects the stub omits); the dpi_restore_guard_verify.sh fixture was captured from real nft 1.1.6
- routing/resolve.uc parse_config() (same rules as config/snapshots.uc uci_value) matches the real OpenWrt uci CLI on the canonical file written by 'uci commit': single/double quotes, '\'' escapes, backslashes, '#', tab, embedded newline, UTF-8, lists, anonymous sections (scratch/audit-tests/uci_parser_diff.sh)
- autotune_select.sh #11 already checks all input permutations of 5 candidates (select.uc is documented as order-independent)
- The last-known-working (LKG) assertions in autotune_apply.sh can fail: reset_apply confirms a working snapshot before PRE_LKG, and the success path asserts that LKG changed (line 338)
- Frontend autotune/model.ts applyOutcomeView/applyResultView fail closed: an unknown status gives 'Outcome unknown' with error tone, or attention:true (invariant 5)
- autoapply.decide + hysteresis: ready && status=='recommendation' implies result.candidate == pending.candidate (a different or low-confidence candidate resets pending), so auto-apply cannot apply a candidate that was not confirmed
- Frontend CI regenerates main.js and fails when the committed bundle is stale (frontend-ci.yml 'Build project' + git diff --exit-code)
- list_cache free-space logic in the module is correct: updates.uc:933-941 parses 'df -Pk' (last line, 4th field) and compares 'available >= required + reserve'; the failure is caused by the test's assumptions (see finding)
- The audit worktree stayed clean after in-place runner runs (git status: only the pre-existing '?? tests/runner/')

### Инвентарь

##### 1. Foreign uncommitted edits in the main tree (read with `git -C <main-tree> diff -- tests/`) and the environment assumption each one fixes

| File | Change | Assumption it removes |
|---|---|---|
| components_updater_job.sh:399-440 | 5×`sleep 1` → 50×`sleep 0.1` poll | Only faster polling; same ~5 s budget, which is still tight under load |
| dpi_runtime_snapshot.sh:30-40 | `sleep 1; [ -s child.pid ]` → poll until child.pid exists and `/proc/<pid>/cmdline` contains `sleep 300` | Fork/exec race: the supervisor writes the child PID before exec, so the identity (cmdline) check sees the parent's cmdline |
| full_uninstall_cleanup.sh:47-51 | 20×1 s → 200×0.1 s | Coarse polling (same 20 s budget) |
| initd_state.sh:149-152 | 5×1 s → 50×0.1 s | Coarse polling |
| list_cache.sh:280 | `df` stub (4096 KB free) plus a 2^62 reserve | The test assumed host /tmp has less than ~931 GiB free. Second root cause, not fixed by the diff: TMP_SING_BOX_FOLDER is not isolated, so production code runs `mkdir -p /tmp/sing-box` and `df` on the host |
| process_identity.sh | `wait_cmdline` after every `cmd &` | The `$!` PID is recorded before exec, so the cmdline identity mismatches |
| ui_runtime_job.sh:288 | `sleep 2` → poll up to 2 s | Fixed sleep |

What the diff does not cover: autotune_scheduler.sh:128-130 (0.3 s flock assumption), dpi_runtime_snapshot.sh:63 and :236, and list_cache TMP_SING_BOX_FOLDER isolation.

##### 2. Stub vs real tool matrix

- **nft**
  - autotune_stubs.sh, nft_apply.sh, nft_atomic_apply.sh accept any `-f` content. With real nft, the production batch and the probe/release batches are valid (see findings).
  - Stub handle numbering (probe rule 5) differs from real nft (6). Harmless: isolation.uc reads handles from the listing.
  - The stub's `-j list` omits the metainfo and chain objects; the parsers tolerate this. The DPI guard fixture is real nft 1.1.6 output.
  - Atomicity is modelled only as an exit code. Real `nft -f` is all-or-nothing; production relies on this (nft/apply.uc:110-121 comment), and no test exercises partial application.
- **uci**
  - autotune_apply.sh stub: `set` writes immediately and `commit` is a no-op, whereas real uci stages in the `-t` savedir. Mitigated by the log assertion at :513.
  - The stub does not canonicalise quoting; the test acknowledges this at :334. Real uci agrees with the hand-rolled parsers (differential run).
  - The dns_apply.sh stub is dead (production uses core/uci.uc fixture mode).
  - CI lacks the uci CLI (P2 finding).
- **curl**: the stub's `-w` record `exitcode|local_port|ip|http_code|times|errormsg` and exit codes 7/28/35/52/56 match production parsing. Times use 3 decimals (real curl prints 6); the float parse is fine.
- **dig**: the stub prints bare A lines. Real `dig +short` can print CNAME lines first; probe/route_trace filter valid IPv4 lines, so this is OK.
- **nslookup**
  - Stubs use the legacy BusyBox format `Address 1: x`. The modern BusyBox format (`Address: x`, and a server line with `:53`) is accepted by the updates.uc and cache.uc regexes but is not exercised.
  - singbox/country.uc first_nslookup_address has no stub in country_detection.sh. If dig stubs miss, it would call the host's nslookup (network), though that path is blocked by the runner netns.
- **ip**: the autotune stub `-j route get ... mark X ipproto tcp sport ... uid 0` matches the production call shape. The nft_apply ip stub returns empty lists.
- **procd/ubus**: the `service list` stubs match the real `{"sing-box":{"instances":{"instance1":{"running":true,"pid":N}}}}` shape.
- **/proc/<pid>/stat**: real processes are used (no stub). The duplicate parsers differ in comm handling (CLEANUP finding).
- **date/TZ**: the only localtime use is timeline display (isolation.uc:116-121). Tests use epoch comparisons with slack (autotune_scheduler.sh:42,94). No TZ dependence found.

##### 3. Host-dependence inventory

- **Tools required**: cc and flock (autotune_stubs.sh compiles nfqws.c), node, python3 (zapret_mirror_cache, dns_reload_snapshot, forkop_opkg_set, forkop_recovery_boundary), the uci CLI (5 autotune tests), and git history (config_contract_matrix). None of these is checked up front; the uci-dependent tests fail with empty logs.
- **Host /tmp**: list_cache.sh (/tmp/sing-box). WSL /tmp/sing-box/{rulesets,subscriptions} (empty) exists, created 17:55 today, possibly by my scratch run of nft/apply.uc outside a namespace. I left it in place because it might be someone else's.
- **Network**: config_contract_matrix `git fetch origin`. The runner netns blocks the rest.
- **Timing**: see section 1.

##### 4. Known hardware-report items in this area

- **Snapshot diff shows `***` for a value absent from the snapshot.** Root cause: config/snapshots.uc:206-211 safe_value() whitelists `action` and `enabled` only for `^[A-Za-z0-9_-]{1,32}$`, so the empty string (absent) falls through to `***`. Pinned by tests/config_snapshots.sh:178-183 (`diff('', "option action 'x'")` → before `***`). Fix requires a product decision: represent an absent value as null or "(not set)", then update the pin.
- The other report items (layout, plural agreement, units, Overview card) have no test pins in this area. luci_localization.sh checks only selected strings.

##### 5. A28 cost notes

All proposals reuse existing patterns (node generator + one ucode process + node asserts, as in route_owner/run_resolver.js and autotune_select.sh), take about 1-2 s each, and use fixed seeds for reproducibility. The real-nft lane needs `unshare -rn` (works in WSL; GitHub runners may need `sudo unshare -n` because of AppArmor userns restrictions).

##### 6. Scratch artefacts (not in the repo)

`scratch/audit-tests\`: nftcheck.sh, nft_batch_real_check.sh (+ generated-batch.nft), probe_batch_check.sh, idn_diff.sh (+ idn.out), uci_parser_diff.sh (+ ucidiff.out), neg_grep_targets.sh.
