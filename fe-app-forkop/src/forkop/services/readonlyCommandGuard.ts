import { isReadonlyMode } from './accessMode.service';
import { logger } from './logger.service';

// Mirror of the "read" exec grants of the luci-app-forkop ACL group
// (luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json); a test
// keeps both lists identical. A read-only session only ever issues these
// commands, so rendering a page cannot start a mutation or trip the ACL.
export const READONLY_EXEC_PATTERNS = [
  '/usr/bin/forkop get_status',
  '/usr/bin/forkop get_sing_box_status',
  '/usr/bin/forkop get_zapret_status',
  '/usr/bin/forkop get_zapret2_status',
  '/usr/bin/forkop get_byedpi_status',
  '/usr/bin/forkop get_system_info',
  '/usr/bin/forkop get_ui_capabilities',
  '/usr/bin/forkop get_ui_state',
  '/usr/bin/forkop get_health_status',
  '/usr/bin/forkop get_history',
  '/usr/bin/forkop autotune_status',
  '/usr/bin/forkop autotune_target *',
  '/usr/bin/forkop autotune_groups',
  '/usr/bin/forkop route_trace *',
  '/usr/bin/forkop config_snapshot_list',
  '/usr/bin/forkop config_snapshot_diff *',
  '/usr/bin/forkop connectivity_test *',
  '/usr/bin/forkop get_readonly_config_sections',
  '/usr/bin/forkop get_dashboard_runtime_metadata',
  '/usr/bin/forkop get_outbound_metadata *',
  '/usr/bin/forkop show_version',
  '/usr/bin/forkop show_sing_box_version',
  '/usr/bin/forkop check_proxy',
  '/usr/bin/forkop check_nft',
  '/usr/bin/forkop check_nft_rules',
  '/usr/bin/forkop check_sing_box',
  '/usr/bin/forkop check_logs',
  '/usr/bin/forkop check_sing_box_logs',
  '/usr/bin/forkop check_fakeip',
  '/usr/bin/forkop check_zapret_runtime',
  '/usr/bin/forkop check_zapret2_runtime',
  '/usr/bin/forkop check_byedpi_runtime',
  '/usr/bin/forkop check_dns_available',
  '/usr/bin/forkop clash_api get_proxies',
  '/usr/bin/forkop clash_api get_connections',
  '/usr/bin/forkop clash_api get_proxy_latency *',
  '/usr/bin/forkop clash_api get_proxy_latencies *',
  '/usr/bin/forkop clash_api get_group_latency *',
  '/usr/bin/forkop service_action_status *',
  '/usr/bin/forkop latency_test_status *',
  '/usr/bin/forkop component_action_status *',
  '/usr/bin/forkop subscription_update_status *',
  '/usr/bin/forkop component_update_check_cache',
  '/usr/bin/forkop global_check masked',
  '/usr/bin/forkop show_sing_box_config masked',
];

// stderr of a command refused locally in a read-only session.
export const READONLY_REFUSED = 'forkop: not available in read-only mode';

const compiled = READONLY_EXEC_PATTERNS.map(
  (pattern) =>
    new RegExp(
      `^${pattern
        .split('*')
        .map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&'))
        .join('.*')}$`,
    ),
);

// rpcd matches "command arg1 arg2 ..." against the ACL globs.
export function isReadonlyCommandAllowed(command: string, args: string[]) {
  const invocation = [command, ...args].join(' ');
  return compiled.some((pattern) => pattern.test(invocation));
}

const reported = new Set<string>();

export function shouldRefuseCommand(command: string, args: string[]) {
  if (!isReadonlyMode() || isReadonlyCommandAllowed(command, args)) {
    return false;
  }

  const key = [command, args[0] ?? ''].join(' ');
  if (!reported.has(key)) {
    reported.add(key);
    logger.warn('[READONLY]', `refused ${key}`);
  }
  return true;
}
