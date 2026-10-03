#!/bin/sh
set -eu
umask 077

# An optional filesystem root is used only by the isolated regression tests.
ROOT="${FORKOP_UNINSTALL_ROOT:-}"
if [ -n "$ROOT" ]; then ROOT="$(cd "$ROOT" && pwd -P)"; fi
MIRROR="${FORKOP_MIRROR_BASE_URL:-}"
if [ -z "$MIRROR" ]; then MIRROR="$(uci -q get forkop.settings.mirror_base_url 2>/dev/null || true)"; fi
MIRROR="${MIRROR:-https://mirror.infotechtg.ru}"
BIN="$ROOT/usr/bin/forkop"
LOCK="$ROOT/tmp/forkop-full-uninstall.lock"
COMPONENT_LOCK="$ROOT/var/run/forkop/component-action.lock"
PACKAGES="luci-i18n-forkop-ru luci-app-forkop forkop sing-box sing-box-tiny sing-box-extended"
PHASE=preflight

# uci on the filesystem root; a test root keeps the changes uci stages under
# it too, never in the host's /tmp/.uci.
root_uci() {
    if [ -z "$ROOT" ]; then
        uci "$@"
        return
    fi
    mkdir -p "$ROOT/tmp/.uci" && uci -c "$ROOT/etc/config" -t "$ROOT/tmp/.uci" "$@"
}

has_mirror() {
    grep -Fq "${MIRROR%/}/" "$1" || grep -Fq 'mirror.51343.ru/' "$1" ||
        grep -Fq 'mirror.infotechtg.ru/' "$1"
}

repository_plan() {
    : > "$JOB/repositories"
    for file in "$ROOT/etc/opkg/distfeeds.conf" "$ROOT/etc/opkg/customfeeds.conf" \
        "$ROOT/etc/apk/repositories" "$ROOT"/etc/apk/repositories.d/*.list; do
        [ -f "$file" ] || continue
        [ "$file" != "$ROOT/etc/apk/repositories.d/forkop.list" ] || continue
        source="${file}.pre-forkop-mirror"
        if [ -f "$source" ] && ! has_mirror "$source"; then
            :
        elif has_mirror "$file"; then
            source="$ROOT/rom${file#"$ROOT"}"
            if [ ! -f "$source" ] || has_mirror "$source"; then
                echo "Cannot restore original repositories: $file" >&2
                return 1
            fi
        else
            continue
        fi
        printf '%s|%s\n' "$file" "$source" >> "$JOB/repositories"
    done
}

installed() {
    if [ "$MANAGER" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$'; fi
}

# LEFT: what of Forkop is still in place (UC-028), comma-separated: its nft
# table and its fwmark rule at priority 105 (by the table's name, or by
# number once rt_tables lost it), which divert traffic to a listener the
# packages take away, and its lines in the crontab, which would call a
# removed /usr/bin/forkop. With "all" also what the removal itself takes
# away: the TorrServer Direct table, the kill-switch table and its fw4
# loader. The status the UI reads names it when the removal fails over it.
LEFT=
find_left_behind() {
    LEFT=
    if nft -t list table inet ForkopTable >/dev/null 2>&1; then
        LEFT="$LEFT, nft table inet ForkopTable"
    fi
    for family in 4 6; do
        if ip "-$family" rule show 2>/dev/null |
            grep -Eq '^105:.*[[:space:]]lookup[[:space:]]+(forkop|105)([[:space:]]|$)'; then
            LEFT="$LEFT, IPv$family rule 105"
        fi
    done
    if grep -Eqs '# forkop-(list-update|subscription-update|component-update-check|autotune)' \
        "$ROOT/etc/crontabs/root"; then
        LEFT="$LEFT, scheduled jobs in /etc/crontabs/root"
    fi
    if [ "${1:-}" = all ]; then
        for table in ForkopTorrServerDirect ForkopKillswitch; do
            if nft -t list table inet "$table" >/dev/null 2>&1; then
                LEFT="$LEFT, nft table inet $table"
            fi
        done
        loader=/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft
        if [ -e "$ROOT$loader" ]; then LEFT="$LEFT, kill-switch loader $loader"; fi
    fi
    LEFT="${LEFT#, }"
}

state() {
    if [ -n "$LEFT" ]; then
        printf '{"state":"%s","phase":"%s","left":"%s"}\n' "$1" "$PHASE" "$LEFT" > "$STATUS.new"
    else
        printf '{"state":"%s","phase":"%s"}\n' "$1" "$PHASE" > "$STATUS.new"
    fi
    chmod 644 "$STATUS.new"
    mv "$STATUS.new" "$STATUS"
}

finish() {
    code=$?
    trap - EXIT
    if [ "$code" -ne 0 ]; then state failed; fi
    rm -f "$COMPONENT_LOCK/pid"
    rmdir "$COMPONENT_LOCK" 2>/dev/null || true
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
    # A short-lived, non-sensitive status file remains readable after LuCI is
    # uninstalled, so the browser never has to guess whether removal succeeded.
    (sleep 300; rm -f "$STATUS" "$STATUS.new") </dev/null >/dev/null 2>&1 &
    exit "$code"
}

run() {
    trap finish EXIT
    state running
    repository_plan
    if command -v apk >/dev/null 2>&1; then MANAGER=apk
    elif command -v opkg >/dev/null 2>&1; then MANAGER=opkg
    else return 1; fi

    PHASE=stop
    state running
    stop_status=0
    if [ -x "$ROOT/etc/init.d/forkop" ]; then
        "$ROOT/etc/init.d/forkop" stop || stop_status=$?
    fi
    # The exit status of the stop does not tell everything: rc.common drops
    # it unless a hook passes it on, and a stop that could not delete the
    # table or the rule goes on. What decides is what is left. The packages
    # would take away the sing-box that serves it and the code that can take
    # it down, so nothing is disabled, stopped or removed (UC-028).
    find_left_behind
    if [ -n "$LEFT" ]; then
        echo "Forkop is still active after its stop: $LEFT. Nothing was removed; stop Forkop or restart the router, then run the removal again." >&2
        return 1
    fi
    if [ "$stop_status" -ne 0 ]; then
        echo "Forkop could not be stopped (exit status $stop_status). Nothing was removed." >&2
        return 1
    fi
    if [ -x "$ROOT/etc/init.d/forkop" ]; then "$ROOT/etc/init.d/forkop" disable; fi
    # The package's second service: its stop removes its nft table (UC-083).
    if [ -x "$ROOT/etc/init.d/forkop-torrserver-direct" ]; then
        "$ROOT/etc/init.d/forkop-torrserver-direct" stop
        "$ROOT/etc/init.d/forkop-torrserver-direct" disable
    fi
    # The VPN kill-switch outlives a stopped Forkop by design; removing the
    # product must lift it, or protected traffic would stay blocked forever.
    if [ -x "$BIN" ]; then "$BIN" killswitch_disable || true; fi
    if [ -x "$ROOT/etc/init.d/forkop-killswitch" ]; then
        "$ROOT/etc/init.d/forkop-killswitch" stop || true
        "$ROOT/etc/init.d/forkop-killswitch" disable || true
    fi
    if [ -x "$BIN" ]; then "$BIN" dnsmasq_restore; fi
    if [ -x "$ROOT/etc/init.d/sing-box" ]; then
        "$ROOT/etc/init.d/sing-box" stop
        "$ROOT/etc/init.d/sing-box" disable
    fi

    PHASE=repositories
    state running
    while IFS='|' read -r file source; do
        cp "$source" "$file.forkop-restore"
        chmod 644 "$file.forkop-restore"
        mv "$file.forkop-restore" "$file"
    done < "$JOB/repositories"
    rm -f "$ROOT/etc/apk/repositories.d/forkop.list" "$ROOT/etc/apk/keys/forkop-mirror.pem"

    PHASE=packages
    state running
    set --
    for package in $PACKAGES; do
        if installed "$package"; then set -- "$@" "$package"; fi
    done
    if [ "$#" -gt 0 ]; then
        if [ "$MANAGER" = apk ]; then apk del "$@"
        else opkg remove "$@"; fi
    fi
    for package in $PACKAGES; do
        if installed "$package"; then echo "Package was not removed: $package" >&2; return 1; fi
    done

    PHASE=files
    state running
    # Only known product paths are removed. Never recursively delete a path
    # supplied by a UCI option (it might point at /etc or other system data).
    for directory in /etc/forkop /etc/sing-box /tmp/sing-box /usr/lib/forkop \
        /usr/share/forkop /www/luci-static/resources/view/forkop; do
        rm -rf "$ROOT$directory"
    done
    for file in /etc/config/forkop /etc/config/forkop.apk-new /etc/config/forkop.apk-old \
        /etc/config/forkop-opkg /etc/config/forkop.opkg-new /etc/config/forkop.opkg-old \
        /etc/config/forkop.opkg-dist /etc/config/sing-box /etc/config/sing-box.apk-new \
        /etc/config/sing-box.apk-old /etc/config/sing-box-opkg /etc/config/sing-box.opkg-new \
        /etc/config/sing-box.opkg-old /etc/config/sing-box.opkg-dist \
        /usr/bin/forkop /usr/libexec/forkop-ro /usr/bin/sing-box /usr/lib/libcronet.so \
        /etc/init.d/forkop /etc/init.d/forkop-killswitch /etc/init.d/forkop-torrserver-direct \
        /etc/init.d/sing-box /etc/uci-defaults/50_luci-forkop \
        /usr/share/luci/menu.d/luci-app-forkop.json /usr/share/rpcd/acl.d/luci-app-forkop.json \
        /usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft \
        /usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft; do
        rm -f "$ROOT$file"
    done
    # The rc.d links of the removed services. The disable of a release whose
    # TorrServer Direct had START=100 and STOP=9 never removed its links
    # (S100, K9; UC-161).
    rm -f "$ROOT"/etc/rc.d/[SK][0-9][0-9]forkop "$ROOT"/etc/rc.d/[SK][0-9][0-9]forkop-killswitch \
        "$ROOT"/etc/rc.d/[SK][0-9][0-9]forkop-torrserver-direct \
        "$ROOT/etc/rc.d/S100forkop-torrserver-direct" "$ROOT/etc/rc.d/K9forkop-torrserver-direct"
    # Whatever the kill-switch left (its removal above failed or an older
    # Forkop never lifted it) must not outlive the product (UC-191).
    #
    # The normal path detached the block list already: killswitch_disable
    # above edits dhcp through core/uci.uc (a private copy, replaced only
    # while the file is unchanged, without changes someone staged for dhcp).
    # This fallback is a plain uci commit, which also commits what someone
    # staged in /tmp/.uci: Forkop's libraries are gone here, BusyBox sh has
    # no libuci lock for a compare-and-swap of its own, and the detach must
    # not be skipped: /etc/forkop with the servers file is already removed,
    # and dnsmasq must not keep reading a file that Forkop no longer owns.
    if [ -z "$ROOT" ]; then nft delete table inet ForkopKillswitch 2>/dev/null || true; fi
    if [ "$(root_uci -q get dhcp.@dnsmasq[0].serversfile 2>/dev/null || true)" = /etc/forkop/killswitch/dnsmasq.servers ]; then
        if root_uci -q delete dhcp.@dnsmasq[0].serversfile &&
            root_uci -q commit dhcp && [ -x "$ROOT/etc/init.d/dnsmasq" ]; then
            "$ROOT/etc/init.d/dnsmasq" restart || true
        fi
    fi
    for file in "$ROOT"/usr/lib/lua/luci/i18n/forkop.* \
        "$ROOT"/tmp/luci-indexcache* "$ROOT"/tmp/luci-modulecache/*; do
        [ ! -f "$file" ] || rm -f "$file"
    done
    while IFS='|' read -r file source; do
        rm -f "${file}.pre-forkop-mirror"
    done < "$JOB/repositories"
    # Leave the component lock intact until finish() releases it.
    for item in "$ROOT"/var/run/forkop/*; do
        [ "$item" = "$COMPONENT_LOCK" ] || rm -rf "$item"
    done
    # Success only when nothing of Forkop is left (UC-028).
    find_left_behind all
    if [ -n "$LEFT" ]; then
        echo "Forkop was removed, but this is still in place: $LEFT." >&2
        return 1
    fi
    PHASE=complete
    state complete
}

case "${1:-}" in
    start)
        mkdir -p "$ROOT/tmp" "$ROOT/www" "$ROOT/var/run/forkop"
        if ! mkdir "$LOCK" 2>/dev/null; then
            echo '{"success":false,"message":"Removal is already running"}'
            exit 1
        fi
        if ! mkdir "$COMPONENT_LOCK" 2>/dev/null; then
            rmdir "$LOCK"
            echo '{"success":false,"message":"Another component action is running"}'
            exit 1
        fi
        trap 'rm -f "$LOCK/pid" "$COMPONENT_LOCK/pid"; rmdir "$LOCK" "$COMPONENT_LOCK" 2>/dev/null || true' EXIT
        printf '%s\n' "$$" > "$LOCK/pid"
        printf '%s\n' "$$" > "$COMPONENT_LOCK/pid"
        JOB="$(mktemp -d "$ROOT/tmp/forkop-uninstall.XXXXXX")"
        STATUS="$ROOT/www/$(basename "$JOB").json"
        cp "$0" "$JOB/worker.sh"
        state running
        sh "$JOB/worker.sh" worker "$JOB" "$STATUS" "$$" > "$JOB/output.log" 2>&1 </dev/null 1000>&- &
        trap - EXIT
        # The worker writes its own pid only once it runs. Name it now, so the
        # records never name this starter after it exits: a component action
        # would take such a lock as stale and run alongside the removal.
        printf '%s\n' "$!" > "$LOCK/pid" || true
        printf '%s\n' "$!" > "$COMPONENT_LOCK/pid" || true
        # The worker waits for this mark: a write above after its finish()
        # had removed a record would leave the removal lock behind.
        : > "$JOB/started" || true
        printf '{"success":true,"status_url":"/%s.json"}\n' "$(basename "$JOB")"
        ;;
    worker)
        JOB="$2"
        STATUS="$3"
        # Until the starter ($4) has named this worker in the lock records or
        # has exited, it may still write them.
        waited=0
        while [ -n "${4:-}" ] && [ ! -e "$JOB/started" ] && kill -0 "$4" 2>/dev/null &&
            [ "$waited" -lt 60 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        printf '%s\n' "$$" > "$LOCK/pid"
        printf '%s\n' "$$" > "$COMPONENT_LOCK/pid"
        run
        ;;
    *) exit 2 ;;
esac
