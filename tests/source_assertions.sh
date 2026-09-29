#!/usr/bin/env bash
set -euo pipefail

# Source-text assertions must not pass vacuously (UC-154). The meta-check
# tests/helpers/source_assertions.js reads every test script and checks each
# grep/sed/awk/find that reads production code: the named files exist, a
# recursive grep reads the files named on its command line, sed/awk regions
# are found. tests/helpers/source_checks.sh gives tests assertions that fail
# instead of passing when their target moved. Both are first checked against
# a synthetic tree with every kind of vacuous check, then the meta-check runs
# over the real test suite.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/tests/helpers/source_assertions.js"
HELPER="$ROOT_DIR/tests/helpers/source_checks.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# --- A synthetic repository --------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/lib" "$REPO/etc/init.d" "$REPO/bin" "$REPO/empty-dir" "$REPO/tests"
cat >"$REPO/lib/module.uc" <<'UC'
function alpha(x) {
    return x;
}
function beta() {
    return "mkdir";
}
UC
: >"$REPO/lib/empty.uc"
printf '#!/bin/sh /etc/rc.common\nstart() {\n    legacy_symbol\n}\n' >"$REPO/etc/init.d/service"
printf '#!/usr/bin/ucode\nprint("ok");\n' >"$REPO/bin/tool"
printf '#!/usr/bin/ucode\nsystem(". /lib/legacy.sh; legacy_symbol");\n' >"$REPO/bin/legacy-tool"
printf '#!/bin/sh\necho ok\n' >"$REPO/lib/helper.sh"

cat >"$REPO/tests/bad.sh" <<'SH'
#!/usr/bin/env bash
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT_DIR/lib/module.uc"
if grep -Fq 'retired' "$ROOT_DIR/lib/moved.uc"; then
  fail "missing file"
fi
grep -q 'x' "$ROOT_DIR/lib/empty.uc" && fail "empty file"
if grep -R -n -E 'legacy_symbol' "$ROOT_DIR/etc/init.d/service" "$ROOT_DIR/lib" --include='*.sh' >/dev/null 2>&1; then
  fail "include filter"
fi
if grep -R -q x "$ROOT_DIR/empty-dir"; then fail "empty directory"; fi
if sed -n '/^function gamma(/,/^}/p' "$MODULE" | grep -Fq 'mkdir'; then
  fail "renamed function"
fi
region="$(sed -n '/^function alpha(/,/^function delta(/p' "$MODULE")"
if awk '/^function renamed/ { active = 1 } active && /mkdir/ { found = 1 } END { exit found ? 0 : 1 }' "$MODULE"; then
  fail "renamed awk anchor"
fi
body="$(awk '/^function omega\(/ { copy = 1 } copy { print }' "$MODULE")"
if grep -A3 'function gamma' "$MODULE" | grep -q mkdir; then fail "context window"; fi
text="$(cat <<'EOF'
grep -q x "$ROOT_DIR/lib/in-heredoc.uc"
EOF
)"
SH

cat >"$REPO/tests/good.sh" <<'SH'
#!/usr/bin/env bash
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT_DIR/lib/module.uc"
if grep -Fq 'retired' "$MODULE"; then fail "x"; fi
grep -Fq 'alpha' "$MODULE" || fail "y"
if sed -n '/^function beta(/,/^}/p' "$MODULE" | grep -Fq 'rm'; then fail "z"; fi
if awk '/^function beta\(/ { active = 1 } active && /rm/ { found = 1 } END { exit found ? 0 : 1 }' "$MODULE"; then fail "w"; fi
for file in "$ROOT_DIR/lib/module.uc" "$ROOT_DIR/lib/other.uc"; do grep -q x "$file" || true; done
cat <<'EOF'
grep -q x "$ROOT_DIR/lib/in-heredoc.uc"
EOF
SH

if node "$CHECK" --root "$REPO" "$REPO/tests/good.sh" >"$WORK/good.out" 2>&1; then :; else
  cat "$WORK/good.out" >&2
  fail "the meta-check reported problems in a correct test script"
fi

if node "$CHECK" --root "$REPO" "$REPO/tests/bad.sh" >"$WORK/bad.out" 2>&1; then
  fail "the meta-check accepted vacuous source checks"
fi
expect_problem() {
  grep -Fq -- "$1" "$WORK/bad.out" || {
    cat "$WORK/bad.out" >&2
    fail "the meta-check did not report: $1"
  }
}
expect_problem 'tests/bad.sh:4: grep lib/moved.uc: is missing'
expect_problem 'tests/bad.sh:7: grep lib/empty.uc: is empty'
expect_problem 'tests/bad.sh:8: grep etc/init.d/service: named on the command line but skipped by --include/--exclude, never read'
expect_problem 'tests/bad.sh:11: grep empty-dir: holds no files'
expect_problem "tests/bad.sh:12: sed lib/module.uc: extraction '/^function gamma(/,/^}/p' prints nothing"
expect_problem 'tests/bad.sh:12: sed lib/module.uc: range start /^function gamma(/ matches nothing'
expect_problem 'tests/bad.sh:15: sed lib/module.uc: range end /^function delta(/ matches nothing after the start'
expect_problem 'tests/bad.sh:16: awk lib/module.uc: region anchor /^function renamed/ matches nothing'
expect_problem 'tests/bad.sh:19: awk lib/module.uc: region anchor /^function omega\(/ matches nothing'
expect_problem 'tests/bad.sh:19: awk lib/module.uc: extraction prints nothing'
expect_problem 'tests/bad.sh:20: grep lib/module.uc: extraction /function gamma/ matches nothing'
if grep -Fq 'in-heredoc' "$WORK/bad.out"; then
  fail "the meta-check read a heredoc body as commands"
fi
[ "$(wc -l <"$WORK/bad.out")" -eq 11 ] || {
  cat "$WORK/bad.out" >&2
  fail "the meta-check reported unexpected problems"
}

# --- The shell helpers fail instead of passing -------------------------------
helper() {
  # helper OUTPUT_FILE COMMAND...: runs a helper function in a subshell.
  local out="$1"
  shift
  (
    # shellcheck source=tests/helpers/source_checks.sh
    . "$HELPER"
    "$@"
  ) >"$out" 2>&1
}
expect_helper_failure() {
  local label="$1" message="$2"
  shift 2
  if helper "$WORK/helper.out" "$@"; then
    fail "$label: the helper passed"
  fi
  grep -Fq -- "$message" "$WORK/helper.out" || {
    cat "$WORK/helper.out" >&2
    fail "$label: missing message: $message"
  }
}

expect_helper_failure "refute on a moved file" "checked source is missing: $REPO/lib/moved.uc" \
  source_refute "must not use it" -F 'retired' "$REPO/lib/moved.uc"
expect_helper_failure "refute on an empty file" "checked source is empty" \
  source_refute "must not use it" -F 'retired' "$REPO/lib/empty.uc"
expect_helper_failure "refute on an empty directory" "holds no files" \
  source_refute "must not use it" -F 'retired' "$REPO/empty-dir"
expect_helper_failure "refute with a match" "FAIL: must not return x" \
  source_refute "must not return x" -F 'return x' "$REPO/lib/module.uc"
grep -Fq "$REPO/lib/module.uc:2:    return x;" "$WORK/helper.out" || fail "refute did not print the match"
expect_helper_failure "refute with an invalid pattern" "grep failed with status 2" \
  source_refute "must not match" -E 'a(' "$REPO/lib/module.uc"
helper "$WORK/helper.out" source_refute "no match" -F 'retired' "$REPO/lib/module.uc" "$REPO/lib" ||
  fail "refute failed without a match"

expect_helper_failure "a renamed function" "function gamma is missing or unterminated" \
  source_function "$REPO/lib/module.uc" gamma
[ "$(sed -n '1p' "$WORK/helper.out")" = "FAIL: function gamma is missing or unterminated in $REPO/lib/module.uc" ] ||
  fail "a missing function printed a region"
helper "$WORK/helper.out" source_function "$REPO/lib/module.uc" beta || fail "function extraction failed"
[ "$(cat "$WORK/helper.out")" = "$(printf 'function beta() {\n    return "mkdir";\n}')" ] ||
  fail "function extraction printed the wrong region"
helper "$WORK/helper.out" source_function "$REPO/etc/init.d/service" start || fail "shell function extraction failed"
grep -Fq 'legacy_symbol' "$WORK/helper.out" || fail "shell function extraction printed the wrong region"

expect_helper_failure "a missing end anchor" "no region from" \
  source_between "$REPO/lib/module.uc" '^function alpha\(' '^function delta\('
[ "$(grep -c 'return' "$WORK/helper.out" || true)" -eq 0 ] || fail "an unterminated region was printed"
helper "$WORK/helper.out" source_between "$REPO/lib/module.uc" '^function alpha\(' '^function beta\(' ||
  fail "region extraction failed"
[ "$(wc -l <"$WORK/helper.out")" -eq 3 ] || fail "region extraction printed the wrong lines"

expect_helper_failure "an empty region" "the checked source region is empty" \
  source_refute_text "must not spawn mkdir" -F 'mkdir' ""
expect_helper_failure "a region with a match" "FAIL: must not spawn mkdir" \
  source_refute_text "must not spawn mkdir" -F 'mkdir' 'command("mkdir")'
helper "$WORK/helper.out" source_refute_text "no match" -F 'mkdir' 'return 1;' || fail "refute_text failed without a match"

# A file named to a shell-symbol check is read whatever its language: the
# ucode entrypoint once was a shell script and must not bring the retired
# symbols back. Only inside directories are the ucode modules left out.
expect_helper_failure "a legacy symbol in a named ucode file" "FAIL: legacy shell symbols must not remain" \
  source_refute_shell "legacy shell symbols must not remain" -F 'legacy_symbol' "$REPO/bin/legacy-tool" "$REPO/lib"
grep -Fq "$REPO/bin/legacy-tool:2:" "$WORK/helper.out" || fail "refute_shell did not print the match in the named file"
helper "$WORK/helper.out" source_shell_targets "$REPO/bin/tool" "$REPO/lib" "$REPO/etc" || fail "shell target listing failed"
[ "$(sort "$WORK/helper.out")" = "$(printf '%s\n' "$REPO/bin/tool" "$REPO/etc/init.d/service" "$REPO/lib/helper.sh" | sort)" ] || {
  cat "$WORK/helper.out" >&2
  fail "shell targets are the named files and, in directories, the *.sh files and the sh interpreter files, not the ucode modules"
}
expect_helper_failure "a legacy symbol in an init script" "FAIL: legacy shell symbols must not remain" \
  source_refute_shell "legacy shell symbols must not remain" -F 'legacy_symbol' "$REPO/bin/tool" "$REPO/etc"
helper "$WORK/helper.out" source_refute_shell "shell must not spawn mkdir" -F 'mkdir' "$REPO/lib" || {
  cat "$WORK/helper.out" >&2
  fail "a ucode module found in a directory was read as a shell script"
}
expect_helper_failure "no shell script at all" "no shell script found" \
  source_refute_shell "legacy shell symbols must not remain" -F 'legacy_symbol' "$REPO/bin"

# --- The test suite ----------------------------------------------------------
node "$CHECK" "$ROOT_DIR"/tests/*.sh || fail "source-text assertions above can pass without reading their target"

printf 'source assertion checks passed\n'
