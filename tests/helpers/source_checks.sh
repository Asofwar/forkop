# shellcheck shell=sh
# Source-text assertions that fail loudly instead of passing vacuously.
# A negative grep on a file that no longer exists, a recursive grep whose
# --include filter skips the files named on its command line, or a region
# extracted by sed/awk whose anchor was renamed all pass without reading the
# code they are meant to guard. These helpers fail the test instead.
# POSIX sh and bash compatible; sourced by the tests that need it. In a
# command substitution a failure only ends the subshell: write
#   region="$(source_function "$FILE" name)" || exit 1

source_check_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# source_require PATH...
# Every PATH is a non-empty file or a directory holding at least one file.
source_require() {
    for source_require_path in "$@"; do
        if [ -f "$source_require_path" ]; then
            [ -s "$source_require_path" ] ||
                source_check_fail "checked source is empty: $source_require_path"
        elif [ -d "$source_require_path" ]; then
            [ -n "$(find "$source_require_path" -type f -print 2>/dev/null | head -n 1)" ] ||
                source_check_fail "checked source directory holds no files: $source_require_path"
        else
            source_check_fail "checked source is missing: $source_require_path"
        fi
    done
}

# source_refute MESSAGE GREP_FLAGS PATTERN PATH...
# Fails with MESSAGE and the matching lines when PATTERN occurs in a PATH;
# directories are searched recursively. GREP_FLAGS is one word of grep
# options such as -F or -E. A missing PATH or a grep error fails as well.
source_refute() {
    source_refute_message=$1
    source_refute_flags=$2
    source_refute_pattern=$3
    shift 3
    [ "$#" -gt 0 ] || source_check_fail "$source_refute_message: no source to check"
    source_require "$@"
    # shellcheck disable=SC2086 # GREP_FLAGS is one word of options
    if source_refute_matches="$(grep -R -H -n $source_refute_flags -e "$source_refute_pattern" -- "$@")"; then
        printf '%s\n' "$source_refute_matches" >&2
        source_check_fail "$source_refute_message"
    else
        source_refute_status=$?
    fi
    [ "$source_refute_status" -eq 1 ] ||
        source_check_fail "$source_refute_message: grep failed with status $source_refute_status"
}

# source_refute_text MESSAGE GREP_FLAGS PATTERN TEXT
# source_refute for a region printed by source_function or source_between:
# an empty TEXT fails instead of passing.
source_refute_text() {
    [ -n "$4" ] || source_check_fail "$1: the checked source region is empty"
    # shellcheck disable=SC2086 # GREP_FLAGS is one word of options
    if source_refute_matches="$(printf '%s\n' "$4" | grep -n $2 -e "$3")"; then
        printf '%s\n' "$source_refute_matches" >&2
        source_check_fail "$1"
    else
        source_refute_status=$?
    fi
    [ "$source_refute_status" -eq 1 ] ||
        source_check_fail "$1: grep failed with status $source_refute_status"
}

# source_function FILE NAME
# Prints the top-level function NAME of FILE, from the line starting with
# `function NAME(` (ucode, JavaScript) or `NAME()` (shell) through the next
# line that is a lone `}`. Fails, printing nothing, when there is no such
# function.
source_function() {
    source_require "$1"
    SOURCE_FUNCTION_NAME="$2" awk '
        !copy && (index($0, "function " ENVIRON["SOURCE_FUNCTION_NAME"] "(") == 1 ||
                  index($0, ENVIRON["SOURCE_FUNCTION_NAME"] "()") == 1) { copy = 1 }
        copy { region = region $0 "\n" }
        copy && /^}[[:space:]]*$/ { closed = 1; exit }
        END { if (!closed) exit 1; printf "%s", region }
    ' "$1" || source_check_fail "function $2 is missing or unterminated in $1"
}

# source_between FILE START_ERE END_ERE
# Prints the lines of FILE from the first line matching START_ERE up to, not
# including, the next line matching END_ERE. Fails, printing nothing, when
# either anchor is missing, so a renamed or reordered anchor cannot silently
# widen or empty the region.
source_between() {
    source_require "$1"
    SOURCE_BETWEEN_START="$2" SOURCE_BETWEEN_END="$3" awk '
        copy && $0 ~ ENVIRON["SOURCE_BETWEEN_END"] { closed = 1; exit }
        !copy && $0 ~ ENVIRON["SOURCE_BETWEEN_START"] { copy = 1 }
        copy { region = region $0 "\n" }
        END { if (!closed) exit 1; printf "%s", region }
    ' "$1" || source_check_fail "no region from /$2/ to /$3/ in $1"
}

# source_shell_targets ROOT...
# Prints the files a shell-symbol check reads. A ROOT that is a file is
# printed as named, whatever its language: a file named to be checked is never
# skipped, and the ucode entrypoint that replaced a shell script must not bring
# its retired symbols back. In a ROOT that is a directory only the shell
# scripts are printed: files named *.sh and files whose first line is a sh,
# ash, dash or bash interpreter line, such as init scripts, uci-defaults and
# the libexec wrappers; the ucode modules beside them are left out.
source_shell_targets() {
    source_require "$@"
    for source_shell_targets_root in "$@"; do
        if [ -f "$source_shell_targets_root" ]; then
            printf '%s\n' "$source_shell_targets_root"
        else
            find "$source_shell_targets_root" -type f -exec awk '
                FNR == 1 && (FILENAME ~ /\.sh$/ || $0 ~ /^#![^[:space:]]*\/(env[[:space:]]+)?(ba|da|a)?sh([[:space:]]|$)/) { print FILENAME }
            ' {} + || source_check_fail "cannot list the shell scripts in $source_shell_targets_root"
        fi
    done
}

# source_refute_shell MESSAGE GREP_FLAGS PATTERN ROOT...
# source_refute over the files source_shell_targets prints for the ROOTs:
# every ROOT named as a file and the shell scripts in the ROOT directories.
# Fails when there is nothing to read.
source_refute_shell() {
    source_refute_shell_message=$1
    source_refute_shell_flags=$2
    source_refute_shell_pattern=$3
    shift 3
    source_refute_shell_list="$(source_shell_targets "$@")" || exit 1
    [ -n "$source_refute_shell_list" ] ||
        source_check_fail "$source_refute_shell_message: no shell script found in $*"
    set --
    while IFS= read -r source_refute_shell_path; do
        set -- "$@" "$source_refute_shell_path"
    done <<EOF
$source_refute_shell_list
EOF
    source_refute "$source_refute_shell_message" "$source_refute_shell_flags" "$source_refute_shell_pattern" "$@"
}
