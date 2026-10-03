import { describe, expect, it } from 'vitest';

import {
  describeFailedRemoval,
  describeLeftItems,
} from '../fullUninstallStatus';

describe('failed full removal', () => {
  it('says what Forkop left in place when its stop refused the removal', () => {
    const message = describeFailedRemoval({
      state: 'failed',
      phase: 'stop',
      left: 'table:ForkopTable,rule:4',
    });
    expect(message).toContain('nothing was removed');
    expect(message).toContain(
      'Still in place: nft table ForkopTable, IPv4 routing rule at priority 105.',
    );
    expect(message).not.toContain('%s');
  });

  it('says what is still in place after the packages were removed', () => {
    const message = describeFailedRemoval({
      state: 'failed',
      phase: 'files',
      left: 'table:ForkopKillswitch,cron',
    });
    expect(message).toContain('was removed, but this is still in place');
    expect(message).toContain(
      'nft table ForkopKillswitch, the lines marked "# forkop-" in /etc/crontabs/root',
    );
  });

  it('keeps the left list as text', () => {
    expect(
      describeFailedRemoval({
        state: 'failed',
        phase: 'stop',
        left: "table:$& $' x",
      }),
    ).toContain("Still in place: nft table $& $' x.");
  });

  it('keeps the messages of failures that name nothing left', () => {
    expect(describeFailedRemoval({ state: 'failed', phase: 'preflight' })).toBe(
      'Original repositories could not be restored. Removal was cancelled before deleting packages.',
    );
    expect(describeFailedRemoval({ state: 'failed', phase: 'stop' })).toBe(
      'Removal did not finish. See the removal log in /tmp/forkop-uninstall.*/output.log.',
    );
    expect(describeFailedRemoval({ state: 'failed', phase: 'packages' })).toBe(
      'Removal did not finish. See the removal log in /tmp/forkop-uninstall.*/output.log.',
    );
  });
});

describe('what a removal left', () => {
  it('names each item the backend reports in the language of the UI', () => {
    expect(
      describeLeftItems(
        'table:ForkopTable,rule:4,rule:6,cron,table:ForkopTableDpiGuard,loader',
      ),
    ).toBe(
      'nft table ForkopTable, IPv4 routing rule at priority 105, ' +
        'IPv6 routing rule at priority 105, ' +
        'the lines marked "# forkop-" in /etc/crontabs/root, ' +
        'nft table ForkopTableDpiGuard, ' +
        'the kill-switch loader in /usr/share/nftables.d/ruleset-post',
    );
  });

  it('shows an item it does not know as the backend sent it', () => {
    expect(describeLeftItems(' something new ,, cron')).toBe(
      'something new, the lines marked "# forkop-" in /etc/crontabs/root',
    );
    expect(describeLeftItems('')).toBe('');
  });
});
