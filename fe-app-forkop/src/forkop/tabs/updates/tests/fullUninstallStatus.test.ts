import { describe, expect, it } from 'vitest';

import { describeFailedRemoval } from '../fullUninstallStatus';

describe('failed full removal', () => {
  it('says what Forkop left in place when its stop refused the removal', () => {
    const message = describeFailedRemoval({
      state: 'failed',
      phase: 'stop',
      left: 'nft table inet ForkopTable, IPv4 rule 105',
    });
    expect(message).toContain('nothing was removed');
    expect(message).toContain('nft table inet ForkopTable, IPv4 rule 105');
    expect(message).not.toContain('%s');
  });

  it('says what is still in place after the packages were removed', () => {
    const message = describeFailedRemoval({
      state: 'failed',
      phase: 'files',
      left: 'nft table inet ForkopKillswitch',
    });
    expect(message).toContain('was removed, but this is still in place');
    expect(message).toContain('nft table inet ForkopKillswitch');
  });

  it('keeps the left list as text', () => {
    expect(
      describeFailedRemoval({
        state: 'failed',
        phase: 'stop',
        left: "$& $' x",
      }),
    ).toContain("Still in place: $& $' x.");
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
