# shellcheck shell=sh
# The in-app Forkop upgrade (components/action.uc `component-action forkop
# install`) run end to end against stand-ins for the router: apk or opkg, the
# release servers (curl), the init script, `forkop get_status`, df and the
# start-and-wait of service/initd.uc. The flow itself is the production code:
# the harness is components/action.uc with its dispatch replaced, and only
# the functions that would touch the host's /tmp or scan the host's processes
# are overridden (other tests run sing-box doubles of their own).
#
# Sourced by the tests that need it, after ROOT_DIR and WORK_DIR are set.
# POSIX sh and bash compatible.
#
#   upgrade_harness_setup                 build the stand-ins (once)
#   upgrade_harness_reset apk|opkg        Forkop 1.0.0 installed and running
#   upgrade_harness_flag NAME [VALUE]     inject a failure (see the stand-ins)
#   upgrade_harness_run                   the action; JSON response in $UPGRADE_OUT
#   upgrade_harness_version PACKAGE       the installed version
#   upgrade_harness_running               Forkop runs
#
# Logs under $UPGRADE_STATE: init.log (init.d calls with FORKOP_STOP_SOURCE),
# initd.log (service/initd.uc calls), pm.log (apk/opkg calls), curl.log.

UPGRADE_LIB="$WORK_DIR/upgrade/lib"
UPGRADE_BIN="$WORK_DIR/upgrade/bin"
UPGRADE_STATE="$WORK_DIR/upgrade/state"
UPGRADE_HARNESS="$WORK_DIR/upgrade/action-harness.uc"
UPGRADE_INIT="$WORK_DIR/upgrade/init"
UPGRADE_FORKOP="$WORK_DIR/upgrade/forkop"
UPGRADE_RECOVERY_DIR="$WORK_DIR/upgrade/state/recovery"
UPGRADE_MARKER="$WORK_DIR/upgrade/state/managed-upgrade-sing-box"
UPGRADE_OUT="$WORK_DIR/upgrade/out.json"

upgrade_harness_setup() {
    upgrade_action_uc="$ROOT_DIR/forkop/files/usr/lib/components/action.uc"
    mkdir -p "$UPGRADE_LIB/service" "$UPGRADE_BIN" "$UPGRADE_STATE"
    ln -s "$ROOT_DIR/forkop/files/usr/lib/core" "$UPGRADE_LIB/core"
    ln -s "$ROOT_DIR/forkop/files/usr/lib/components" "$UPGRADE_LIB/components"

    awk '
        $0 == "let mode = ARGV[0] || \"\";" { found = 1; exit }
        { print }
        END { if (!found) exit 1 }
    ' "$upgrade_action_uc" >"$UPGRADE_HARNESS" ||
        { printf 'FAIL: the dispatch of %s was not found\n' "$upgrade_action_uc" >&2; exit 1; }
    cat >>"$UPGRADE_HARNESS" <<'UCODE'

// Test overrides: the temporary directory and the version caches stay in the
// test's directory, and the host's sing-box processes are not the router's.
const HARNESS_STATE = getenv("UPGRADE_STATE");
function cleanup_stale_tmp_files() {}
function init_tmp_dir() {
    if (tmp_dir != "")
        return true;
    tmp_dir = trim(command_output_from_args([ "mktemp", "-d", HARNESS_STATE + "/updates.XXXXXX" ]));
    return tmp_dir != "";
}
function write_forkop_latest_version_cache(value, timestamp) {}
function clear_version_caches() {}
function upgrade_sing_box_processes() {
    return file_exists(HARNESS_STATE + "/flags/sing_box_ambiguous") ? null : {};
}

component_action(ARGV[0], ARGV[1], ARGV[2]);
UCODE

    # service/initd.uc start-and-wait: the init script's start, then the
    # runtime is checked.
    cat >"$UPGRADE_LIB/service/initd.uc" <<'UCODE'
let fs = require("fs");
let state = getenv("UPGRADE_STATE");
let log = fs.open(state + "/initd.log", "a");
log.write(join(" ", ARGV) + "\n");
log.close();
if (ARGV[0] == "start-and-wait") {
    let status = system([ getenv("FORKOP_SERVICE_INIT"), ARGV[1] ]);
    exit(status == 0 && fs.stat(state + "/running") != null ? 0 : 1);
}
exit(1);
UCODE

    cat >"$UPGRADE_LIB/service/state.uc" <<'UCODE'
let fs = require("fs");
if (ARGV[0] == "write-managed-upgrade-sing-box-marker") {
    fs.writefile(ARGV[1], "format=1\n");
    exit(0);
}
exit(1);
UCODE

    # The init script records every call with the source of a stop. Flags:
    # stop_status (exit status of a stop: 2 is a refusal), start_fail.
    cat >"$UPGRADE_INIT" <<'SH'
#!/bin/sh
state="$UPGRADE_STATE"
printf '%s source=%s\n' "$*" "${FORKOP_STOP_SOURCE:-}" >>"$state/init.log"
case "$1" in
    stop)
        status="$(cat "$state/flags/stop_status" 2>/dev/null || echo 0)"
        [ "$status" -ne 0 ] || rm -f "$state/running"
        exit "$status"
        ;;
    start|restart)
        [ ! -e "$state/flags/start_fail" ] || exit 1
        : >"$state/running"
        ;;
esac
exit 0
SH

    cat >"$UPGRADE_FORKOP" <<'SH'
#!/bin/sh
case "$1" in
    get_status)
        if [ -e "$UPGRADE_STATE/running" ]; then echo '{"running": 1}'; else echo '{"running": 0}'; fi
        ;;
esac
exit 0
SH

    # Release servers: fold8 serves the release to install, GitHub the
    # metadata of the installed one. A package file names the package and
    # version it holds, whatever the file is called. Flags: github_down,
    # download_fail_<version>.
    cat >"$UPGRADE_BIN/curl" <<'SH'
#!/bin/sh
state="$UPGRADE_STATE"
out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --connect-timeout|-m|-x) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\n' "$url" >>"$state/curl.log"
case "$url" in
    https://releases.invalid/updates/latest.json)
        cat "$state/latest.json" >"$out"
        ;;
    https://api.github.com/repos/*/releases/tags/1.0.0)
        [ ! -e "$state/flags/github_down" ] || exit 22
        cat "$state/previous.json" >"$out"
        ;;
    https://releases.invalid/releases/*)
        file="${url##*/}"
        name="${file%%_*}"
        version="${file#*_}"
        version="${version%.*}"
        [ ! -e "$state/flags/download_fail_$version" ] || exit 22
        printf 'name=%s\nversion=%s-r1\n' "$name" "$version" >"$out"
        ;;
    *)
        exit 6
        ;;
esac
SH

    # apk and opkg over one package database ($UPGRADE_STATE/pkg/<name>).
    # Installing the backend runs its maintainer scripts: prerm stops a
    # running Forkop for the package, postinst starts it again. Flags:
    # preflight_fail, fail_new_<package> and fail_old_<package> (installing
    # 1.1.0 or 1.0.0 of that package fails; apk keeps the packages of the
    # transaction installed before it), postinst_starts (postinst always
    # starts Forkop).
    cat >"$UPGRADE_BIN/package-manager" <<'SH'
#!/bin/sh
state="$UPGRADE_STATE"
pm="$(basename "$0")"
printf '%s %s\n' "$pm" "$*" >>"$state/pm.log"

install_file() {
    [ -r "$1" ] || { echo "$1: no such file" >&2; return 1; }
    name="$(sed -n 's/^name=//p' "$1")"
    version="$(sed -n 's/^version=//p' "$1")"
    case "$version" in
        1.1.0-*) age=new ;;
        *) age=old ;;
    esac
    if [ "$name" = forkop ]; then
        if [ -e "$state/running" ]; then
            FORKOP_STOP_SOURCE=package "$FORKOP_SERVICE_INIT" stop || true
            : >"$state/package-was-running"
        fi
    fi
    [ ! -e "$state/flags/fail_${age}_$name" ] || { echo "installing $name $version failed" >&2; return 1; }
    printf '%s\n' "$version" >"$state/pkg/$name"
    if [ "$name" = forkop ] &&
        { [ -e "$state/package-was-running" ] || [ -e "$state/flags/postinst_starts" ]; }; then
        rm -f "$state/package-was-running"
        "$FORKOP_SERVICE_INIT" start || true
    fi
}

install_files() {
    simulate="$1"
    shift
    for file in "$@"; do
        [ -r "$file" ] || { echo "$file: no such file" >&2; exit 1; }
    done
    if [ "$simulate" = 1 ]; then
        [ ! -e "$state/flags/preflight_fail" ] || exit 1
        exit 0
    fi
    for file in "$@"; do
        install_file "$file" || exit 1
    done
    exit 0
}

package_argument() {
    for argument in "$@"; do
        case "$argument" in
            -*) ;;
            *) printf '%s\n' "$argument" ;;
        esac
    done
}

if [ "$pm" = apk ]; then
    case "$1" in
        info)
            [ "$2" = -e ] && [ -s "$state/pkg/$3" ]
            exit
            ;;
        list)
            shift
            for name in $(package_argument "$@"); do
                [ ! -s "$state/pkg/$name" ] ||
                    printf '%s-%s noarch {%s} (GPL-2.0) [installed]\n' "$name" "$(cat "$state/pkg/$name")" "$name"
            done
            exit 0
            ;;
        add)
            shift
            simulate=0
            case " $* " in *" --simulate "*) simulate=1 ;; esac
            # shellcheck disable=SC2046 # one package file per line
            install_files "$simulate" $(package_argument "$@")
            ;;
    esac
    exit 1
fi

simulate=0
[ "$1" != --noaction ] || { simulate=1; shift; }
case "$1" in
    list-installed)
        for path in "$state"/pkg/*; do
            [ ! -s "$path" ] || printf '%s - %s\n' "$(basename "$path")" "$(cat "$path")"
        done
        exit 0
        ;;
    install)
        shift
        # shellcheck disable=SC2046 # one package file per line
        install_files "$simulate" $(package_argument "$@")
        ;;
esac
exit 1
SH
    chmod +x "$UPGRADE_INIT" "$UPGRADE_FORKOP" "$UPGRADE_BIN/curl" "$UPGRADE_BIN/package-manager"

    # Free space: flag df_avail (KiB, plenty by default).
    cat >"$UPGRADE_BIN/df" <<'SH'
#!/bin/sh
available="$(cat "$UPGRADE_STATE/flags/df_avail" 2>/dev/null || echo 1048576)"
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\nfake 2097152 0 %s 0%% /\n' "$available"
SH
    cat >"$UPGRADE_BIN/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$UPGRADE_STATE/logger.log"
SH
    printf '#!/bin/sh\nexit 0\n' >"$UPGRADE_BIN/killall"
    printf '#!/bin/sh\nexit 0\n' >"$UPGRADE_BIN/sync"
    printf '#!/bin/sh\necho "{}"\n' >"$UPGRADE_BIN/ubus"
    chmod +x "$UPGRADE_BIN/df" "$UPGRADE_BIN/logger" "$UPGRADE_BIN/killall" "$UPGRADE_BIN/sync" "$UPGRADE_BIN/ubus"
}

# release_json VERSION EXT
upgrade_harness_release_json() {
    printf '{"tag_name":"%s","html_url":"https://releases.invalid/%s","assets":[' "$1" "$1"
    printf '{"name":"forkop_%s.%s","browser_download_url":"https://releases.invalid/releases/%s/forkop_%s.%s"},' "$1" "$2" "$1" "$1" "$2"
    printf '{"name":"luci-app-forkop_%s.%s","browser_download_url":"https://releases.invalid/releases/%s/luci-app-forkop_%s.%s"},' "$1" "$2" "$1" "$1" "$2"
    printf '{"name":"luci-i18n-forkop-ru_%s.%s","browser_download_url":"https://releases.invalid/releases/%s/luci-i18n-forkop-ru_%s.%s"}' "$1" "$2" "$1" "$1" "$2"
    printf ']}\n'
}

upgrade_harness_reset() {
    rm -rf "$UPGRADE_STATE" "$UPGRADE_BIN/apk" "$UPGRADE_BIN/opkg"
    mkdir -p "$UPGRADE_STATE/pkg" "$UPGRADE_STATE/flags"
    : >"$UPGRADE_STATE/init.log"
    : >"$UPGRADE_STATE/initd.log"
    : >"$UPGRADE_STATE/pm.log"
    : >"$UPGRADE_STATE/curl.log"
    ln -s package-manager "$UPGRADE_BIN/$1"
    case "$1" in
        apk) upgrade_extension=apk ;;
        *) upgrade_extension=ipk ;;
    esac
    upgrade_harness_release_json 1.1.0 "$upgrade_extension" >"$UPGRADE_STATE/latest.json"
    upgrade_harness_release_json 1.0.0 "$upgrade_extension" >"$UPGRADE_STATE/previous.json"
    for upgrade_package in forkop luci-app-forkop luci-i18n-forkop-ru; do
        printf '1.0.0-r1\n' >"$UPGRADE_STATE/pkg/$upgrade_package"
    done
    : >"$UPGRADE_STATE/running"
}

upgrade_harness_flag() {
    printf '%s\n' "${2:-1}" >"$UPGRADE_STATE/flags/$1"
}

upgrade_harness_unflag() {
    rm -f "$UPGRADE_STATE/flags/$1"
}

upgrade_harness_run() {
    upgrade_status=0
    env UPGRADE_STATE="$UPGRADE_STATE" \
        PATH="$UPGRADE_BIN:$PATH" \
        FORKOP_LIB="$UPGRADE_LIB" \
        FORKOP_BIN="$UPGRADE_FORKOP" \
        FORKOP_SERVICE_INIT="$UPGRADE_INIT" \
        FORKOP_VERSION=1.0.0 \
        FORKOP_RELEASE_REPO=slayer326/forkop \
        FORKOP_RELEASE_BASE_URL=https://releases.invalid \
        FORKOP_MIRROR_BASE_URL= \
        FORKOP_RUNTIME_STATE_DIR="$UPGRADE_STATE/run" \
        FORKOP_OPKG_RECOVERY_DIR="$UPGRADE_RECOVERY_DIR" \
        FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$UPGRADE_MARKER" \
        FORKOP_SYSTEM_INFO_CACHE_FILE="$UPGRADE_STATE/system-info.json" \
        FORKOP_UPGRADE_STOP_TIMEOUT_SECONDS=20 \
        ucode -L "$UPGRADE_LIB" "$UPGRADE_HARNESS" forkop install >"$UPGRADE_OUT" 2>"$UPGRADE_STATE/stderr" ||
        upgrade_status=$?
    return "$upgrade_status"
}

upgrade_harness_version() {
    cat "$UPGRADE_STATE/pkg/$1" 2>/dev/null || true
}

upgrade_harness_running() {
    [ -e "$UPGRADE_STATE/running" ]
}

# upgrade_harness_message: the message of the action's response.
upgrade_harness_message() {
    sed -n 's/.*"message": *"\([^"]*\)".*/\1/p' "$UPGRADE_OUT"
}

upgrade_harness_succeeded() {
    grep -Eq '"success": *true' "$UPGRADE_OUT"
}

upgrade_harness_dump() {
    for upgrade_log in out.json state/init.log state/initd.log state/pm.log state/curl.log state/stderr; do
        [ ! -s "$WORK_DIR/upgrade/$upgrade_log" ] || sed "s|^|  $upgrade_log: |" "$WORK_DIR/upgrade/$upgrade_log" >&2
    done
}
