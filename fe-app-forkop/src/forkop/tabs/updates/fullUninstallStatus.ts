export interface FullUninstallStatus {
  state?: string;
  phase?: string;
  // What of Forkop X is still in place when that failed the removal, as
  // comma-separated item codes (full-uninstall.sh find_left_behind; UC-028).
  left?: string;
}

function describeLeftItem(item: string): string {
  if (item.startsWith('table:')) {
    const table = item.slice('table:'.length);
    return _('nft table %s').replace('%s', () => table);
  }
  switch (item) {
    case 'rule:4':
      return _('IPv4 routing rule at priority 105');
    case 'rule:6':
      return _('IPv6 routing rule at priority 105');
    case 'cron':
      return _('the lines marked "# forkop-" in /etc/crontabs/root');
    case 'loader':
      return _('the kill-switch loader in /usr/share/nftables.d/ruleset-post');
    default:
      return item;
  }
}

// The item codes of the removal status in the language of the UI; a code
// this release does not know is shown as it came.
export function describeLeftItems(left: string): string {
  return left
    .split(',')
    .map((item) => item.trim())
    .filter((item) => item !== '')
    .map(describeLeftItem)
    .join(', ');
}

// What the user reads about a removal that failed.
export function describeFailedRemoval(status: FullUninstallStatus): string {
  const left =
    typeof status.left === 'string' ? describeLeftItems(status.left) : '';
  if (status.phase === 'preflight') {
    return _(
      'Original repositories could not be restored. Removal was cancelled before deleting packages.',
    );
  }
  // The stop left Forkop's interception in place: nothing was disabled,
  // stopped or removed after it.
  if (status.phase === 'stop' && left) {
    return _(
      'Forkop X is still active after its stop, so nothing was removed. Still in place: %s. Stop Forkop X or restart the router, then try again.',
    ).replace('%s', () => left);
  }
  if (left) {
    return _(
      'Forkop X was removed, but this is still in place: %s. See the removal log in /tmp/forkop-uninstall.*/output.log.',
    ).replace('%s', () => left);
  }
  return _(
    'Removal did not finish. See the removal log in /tmp/forkop-uninstall.*/output.log.',
  );
}
