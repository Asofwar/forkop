# Предложение для отдельного CI PR (UC-009, UC-048, UC-153)

**Статус:** предложение, не применено. По решению D-5(b) (раздел 8.1 плана) этап S0 не меняет `.github/`; ниже приведены точные правки для отдельного PR, который владелец может открыть сам. Всё, что можно было сделать вне `.github/`, уже сделано в S0:

- `a8192da4`, `bb91ccb5` — тестовая замена uci CLI `tests/helpers/uci_cli/uci` (`uci.uc`), выбор CLI `tests/helpers/uci_cli/select.sh`, проверка замены `tests/uci_cli_shim.sh` по транскрипту настоящего uci (`tests/fixtures/uci_cli/transcript.txt`); пять тестов autotune проходят и без uci в PATH (UC-009).
- `3e269ec2` — из `core/uci.uc` убраны общие `UCI_STATE`/`UCI_LOG` (UC-155).

Поэтому **Backend CI станет зелёным и без этого PR**: без uci CLI тесты autotune пишут через замену и печатают `NOTE: no OpenWrt uci CLI on PATH, using the test shim ...`. PR нужен, чтобы в CI работал настоящий uci (реальная семантика `-c/-t` и перепроверка транскрипта), чтобы backend-тесты запускались на изменения LuCI/фронтенда и чтобы ShellCheck видел все скрипты роутера.

| Находка | Что меняется | Файл |
|---|---|---|
| [UC-009](ULTRACODE_FINDINGS.md#uc-009) | сборка libubox + uci на закреплённых коммитах; `FORKOP_TEST_UCI_CLI=real` в шаге тестов | `.github/workflows/backend-ci.yml` |
| [UC-048](ULTRACODE_FINDINGS.md#uc-048) | `luci-app-forkop/**` и `fe-app-forkop/**` в path-фильтрах `pull_request` и `push` | `.github/workflows/backend-ci.yml` |
| [UC-153](ULTRACODE_FINDINGS.md#uc-153) | path-фильтры и `find` для `forkop/files/usr/**` (включая `libexec/forkop-ro`) и обёртки замены uci; отдельный шаг `--severity=warning` для скриптов роутера вне `init.d` | `.github/workflows/shellcheck.yml` |

## 1. UC-009: uci CLI в backend CI

**Проблема.** `backend-ci.yml` собирает только ucode (`-DUCI_SUPPORT=OFF`); `autotune/manager.uc` пишет политику и цели через `uci -c DIR -t SAVEDIR set/delete/commit`. До S0 пять тестов autotune падали на первом `policy-set` с пустым выводом.

**Вариант A (рекомендуется): настоящий uci в CI.** Шаг собирает libubox и uci из зеркал `github.com/openwrt/*` на тех коммитах, на которых записан транскрипт (`libubox e7608b69`, `uci 74f6277a` от 2026-03-12). Зависимости (`build-essential cmake git libjson-c-dev pkg-config`) уже ставит шаг ucode. `FORKOP_TEST_UCI_CLI=real` в шаге тестов запрещает тихий откат на замену: если сборка uci сломается, тесты autotune упадут с сообщением `FAIL: FORKOP_TEST_UCI_CLI=real: the OpenWrt uci CLI (uci -c/-t) is not on PATH`. `tests/uci_cli_shim.sh` при этом сверяет транскрипт и с настоящим uci (`OK: the recorded transcript matches the real uci CLI`); расхождение с ним — провал только при `FORKOP_TEST_UCI_CLI=real`, то есть на закреплённой ревизии. В режиме по умолчанию (`auto`) другая ревизия uci на машине разработчика даёт diff и `NOTE`, а не провал: замена по-прежнему сверяется с записанным транскриптом.

**Вариант B: без uci в CI.** Правка `backend-ci.yml` для uci не нужна, тесты проходят через замену. Минус: семантика настоящего CLI в CI не проверяется, а транскрипт сверяется только с заменой. Годится как временное состояние до PR.

При смене закреплённых коммитов транскрипт переписывается командой `FORKOP_TEST_UCI_RECORD=1 bash tests/uci_cli_shim.sh` (нужен uci в PATH), затем проверяется, что замена его воспроизводит.

## 2. UC-048: path-фильтры backend CI

Сейчас `luci-app-forkop/` и `fe-app-forkop/` не запускают Backend CI, хотя на текущем HEAD их читают 36 и 10 backend-тестов соответственно (`grep -l luci-app-forkop tests/*.sh`, `grep -l fe-app-forkop tests/*.sh`): граница RO ACL (`acl_boundary.sh`, `luci_readonly_*`, `readonly_*`), локализация (`luci_localization.sh` читает `fe-app-forkop/locales/*`), guard команд фронтенда (`luci_readonly_command_guard.sh` читает `fe-app-forkop/src/forkop/services/readonlyCommandGuard.ts`). Предлагается добавить оба каталога целиком в `pull_request` и `push`. `node_modules` не коммитится, лишних срабатываний нет; `build.yml` вызывает backend-ci через `workflow_call` и фильтров не имеет.

## 3. UC-153: ShellCheck

Замеры на текущем HEAD (ShellCheck 0.9.0, как в `ubuntu-24.04`):

- `find` в шаге ShellCheck берёт `*.sh`, поэтому `full-uninstall.sh` и `mirror-migration.sh` проверяются, но только если PR задел другие пути: в фильтрах нет `forkop/files/usr/**`.
- Два shell-скрипта без `.sh` не проверяются вообще: `forkop/files/usr/libexec/forkop-ro` (граница RO-сессии из S1) и обёртка `tests/helpers/uci_cli/uci`.
- На уровне `error` весь набор чист (204 скрипта с учётом двух новых). На уровне `warning` — 158 замечаний в 52 файлах, почти все в тестах; в `etc/init.d/forkop` (8) и `forkop-torrserver-direct` (3) это идиомы `rc.common` (SC2034 `START/STOP/USE_PROCD`, SC2154 `initscript`, SC3043 `local`, SC2097/SC2098, SC3023 fd 1000), а диалекта busybox в ShellCheck 0.9.0 нет.
- Скрипты роутера вне `init.d` (`forkop/files/usr/**/*.sh`, `usr/libexec/*`, `uci-defaults/*`) и `ops/**/*.sh` — 12 файлов — чисты на `warning`, кроме намеренного SC3023 в `full-uninstall.sh:164` (закрытие procd lock fd 1000 у фонового worker).

Предложение: общий шаг остаётся на `--severity=error` с расширенным `find`; добавляется второй шаг `--severity=warning -e SC3023` для 12 скриптов роутера и ops. Вместо `-e SC3023` можно поставить `# shellcheck disable=SC3023` на строку `full-uninstall.sh:164`; это правка вне `.github`, её можно внести отдельным коммитом. Замечание вне этого PR: ShellCheck запускается только для PR и push в `main` и `rc/**`, поэтому PR в feature-ветки он не проверяет.

## 4. Точные правки

Применяются из корня репозитория командой `git apply` (проверено `git apply --check` и `patch --dry-run -p1` на текущем HEAD). Пустые строки контекста в диффах записаны без ведущего пробела: оба инструмента принимают их как контекст, а в документе не остаётся хвостовых пробелов.

```diff
--- a/.github/workflows/backend-ci.yml
+++ b/.github/workflows/backend-ci.yml
@@ -9,6 +9,8 @@
       - 'forkop/Makefile'
       - 'build.sh'
       - 'install.sh'
+      - 'luci-app-forkop/**'
+      - 'fe-app-forkop/**'
       - 'ops/hosting/**'
       - 'ops/mirror/**'
       - 'tests/**'
@@ -22,6 +24,8 @@
       - 'forkop/Makefile'
       - 'build.sh'
       - 'install.sh'
+      - 'luci-app-forkop/**'
+      - 'fe-app-forkop/**'
       - 'ops/hosting/**'
       - 'ops/mirror/**'
       - 'tests/**'
@@ -55,6 +59,29 @@
           command -v ucode
           ucode -e 'print("ucode ready\n")'

+      - name: Build OpenWrt uci CLI
+        shell: bash
+        run: |
+          # The autotune tests write through `uci -c DIR -t SAVEDIR` (UC-009),
+          # and tests/uci_cli_shim.sh re-checks its recorded transcript against
+          # this build: the revisions are the ones the transcript was recorded
+          # with (tests/fixtures/uci_cli/transcript.txt).
+          fetch() {
+            git init -q "/tmp/$1"
+            git -C "/tmp/$1" fetch -q --depth 1 "https://github.com/openwrt/$1.git" "$2"
+            git -C "/tmp/$1" checkout -q FETCH_HEAD
+          }
+          fetch libubox e7608b69283d919d031d13cc8e21692503f5dbea
+          fetch uci 74f6277aabffc943d026f406df57c22595134c42
+          cmake -S /tmp/libubox -B /tmp/libubox/build -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
+          cmake --build /tmp/libubox/build --parallel
+          sudo cmake --install /tmp/libubox/build
+          cmake -S /tmp/uci -B /tmp/uci/build -DBUILD_LUA=OFF
+          cmake --build /tmp/uci/build --parallel
+          sudo cmake --install /tmp/uci/build
+          sudo ldconfig
+          command -v uci
+
       - name: Check ucode syntax
         shell: bash
         run: |
@@ -63,6 +90,10 @@

       - name: Run backend tests
         shell: bash
+        env:
+          # A missing uci CLI fails the autotune tests with its name instead of
+          # falling back to the test shim (tests/helpers/uci_cli/select.sh).
+          FORKOP_TEST_UCI_CLI: real
         run: |
           failed=0
           for test_file in tests/*.sh; do
```

```diff
--- a/.github/workflows/shellcheck.yml
+++ b/.github/workflows/shellcheck.yml
@@ -11,8 +11,11 @@
       - 'install.sh'
       - 'ops/**/*.sh'
       - 'forkop/files/etc/init.d/**'
+      - 'forkop/files/usr/**/*.sh'
+      - 'forkop/files/usr/libexec/**'
       - 'luci-app-forkop/root/etc/uci-defaults/**'
       - 'tests/**/*.sh'
+      - 'tests/helpers/uci_cli/uci'
       - '.github/workflows/shellcheck.yml'
   pull_request:
     branches:
@@ -23,8 +26,11 @@
       - 'install.sh'
       - 'ops/**/*.sh'
       - 'forkop/files/etc/init.d/**'
+      - 'forkop/files/usr/**/*.sh'
+      - 'forkop/files/usr/libexec/**'
       - 'luci-app-forkop/root/etc/uci-defaults/**'
       - 'tests/**/*.sh'
+      - 'tests/helpers/uci_cli/uci'
       - '.github/workflows/shellcheck.yml'

 permissions:
@@ -51,7 +57,22 @@
             find . -type f \
               \( -name '*.sh' -o -path './build.sh' -o -path './install.sh' \
                  -o -path './forkop/files/etc/init.d/*' \
-                 -o -path './luci-app-forkop/root/etc/uci-defaults/*' \) \
+                 -o -path './forkop/files/usr/libexec/*' \
+                 -o -path './luci-app-forkop/root/etc/uci-defaults/*' \
+                 -o -path './tests/helpers/uci_cli/uci' \) \
               -print0
           )
           shellcheck --severity=error "${scripts[@]}"
+
+      - name: ShellCheck shipped router scripts (warnings)
+        shell: bash
+        run: |
+          # Router-side scripts outside init.d are clean at warning level.
+          # SC3023: full-uninstall.sh closes procd's lock fd 1000 on purpose.
+          mapfile -d '' scripts < <(
+            find forkop/files/usr luci-app-forkop/root ops -type f \
+              \( -name '*.sh' -o -path 'forkop/files/usr/libexec/*' \
+                 -o -path 'luci-app-forkop/root/etc/uci-defaults/*' \) \
+              -print0
+          )
+          shellcheck --severity=warning -e SC3023 "${scripts[@]}"
```

## 5. Что проверено локально (без `.github/`)

- Шаг сборки uci повторён в чистом каталоге: libubox и uci получены из `github.com/openwrt/{libubox,uci}` по SHA (`fetch --depth 1`), собраны с `-DBUILD_LUA=OFF` (libubox ещё `-DBUILD_EXAMPLES=OFF`). С этим uci в PATH `tests/uci_cli_shim.sh` подтвердил транскрипт, `FORKOP_TEST_UCI_CLI=real bash tests/autotune_groups.sh` — PASS.
- Обе правки YAML разбираются (`yaml.safe_load`), `git apply --check` проходит.
- Команды обоих шагов ShellCheck выполнены с ShellCheck 0.9.0 из корня репозитория: шаг `error` — 204 скрипта, чисто; шаг `warning -e SC3023` — 12 скриптов, чисто.
- Полный backend lane (`tests/*.sh`, 181 тест) дважды: с настоящим uci и `FORKOP_TEST_UCI_CLI=real` (как в варианте A) и без uci в PATH (как в нынешнем CI, через замену) — в обоих случаях 180 PASS, 1 FAIL: `installer_owner` («deadline watchdog left a descendant running»), известный средовой сбой контейнера из baseline Phase B (раздел 12 плана), к этим правкам не относится.

## 6. Проверка в самом CI PR

1. Backend CI зелёный; в логе шага сборки `command -v uci` печатает `/usr/local/bin/uci`, а `tests/uci_cli_shim.sh` — `OK: the recorded transcript matches the real uci CLI (/usr/local/bin/uci)`.
2. Негативная проверка (временный коммит в PR): без шага `Build OpenWrt uci CLI` пять тестов autotune и `tests/uci_cli_shim.sh` падают с `FAIL: FORKOP_TEST_UCI_CLI=real: the OpenWrt uci CLI (uci -c/-t) is not on PATH`, а не с пустым выводом.
3. PR, меняющий только `luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json`, запускает Backend CI (UC-048).
4. PR в `main`, меняющий только `forkop/files/usr/lib/full-uninstall.sh` или `forkop/files/usr/libexec/forkop-ro`, запускает ShellCheck, и в списке проверенных есть `forkop-ro` (UC-153).

## 7. Риски

- Сеть: сборка зависит от `github.com/openwrt/*` так же, как сборка ucode от `github.com/jow-/ucode`. Коммиты закреплены SHA.
- Время: сборка libubox и uci добавляет порядка 20–30 с.
- Новый шаг ShellCheck на `warning` может потребовать правок при изменении скриптов роутера; это и есть цель UC-153.

## 8. Дополнение: настоящий sing-box для `tests/routing_resolve_rule_set_real.sh`

Тест сверяет заглушку `tests/helpers/sing_box_rule_set_stub.uc` с настоящим `sing-box rule-set match` (ответ в stderr, перенос состояния «адрес совпал» между правилами списка, адреса IPv4 и IPv6) и прогоняет резолвер с настоящим бинарником ([UC-198](ULTRACODE_DELTA_FINDINGS.md#uc-198), [UC-218](ULTRACODE_DELTA_FINDINGS.md#uc-218)). Без бинарника он печатает `SKIP`, поэтому в CI проверяется только заглушка. Предложение для того же PR: шаг перед тестами скачивает закреплённый релиз sing-box для linux-amd64 с `github.com/SagerNet/sing-box/releases` (локально тест проверен с v1.12.0), сверяет sha256, записанный в самом шаге, и передаёт путь к бинарнику шагу тестов в `FORKOP_TEST_SING_BOX`. Тогда расхождение заглушки с настоящим контрактом становится провалом CI, а не пропуском.
