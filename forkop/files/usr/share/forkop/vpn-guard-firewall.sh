#!/bin/sh
[ -f /etc/forkop/vpn-guard/policy.json ] || exit 0
/etc/init.d/forkop-guard restore
