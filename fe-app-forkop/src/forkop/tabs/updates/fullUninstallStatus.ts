export interface FullUninstallStatus {
  state?: string;
  phase?: string;
  // What of Forkop X is still in place when that failed the removal
  // (full-uninstall.sh find_left_behind; UC-028).
  left?: string;
}

// What the user reads about a removal that failed.
export function describeFailedRemoval(status: FullUninstallStatus): string {
  const left = typeof status.left === 'string' ? status.left : '';
  if (status.phase === 'preflight') {
    return _(
      'Original repositories could not be restored. Removal was cancelled before deleting packages.',
    );
  }
  // The stop left Forkop's interception or its scheduled jobs in place:
  // nothing was disabled, stopped or removed after it.
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
