import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ executeShellCommand: vi.fn() }));
vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { ForkopShellMethods } from '../index';

describe('observability CLI contracts', () => {
  beforeEach(() => mocks.executeShellCommand.mockReset());

  it('passes trace parameters as separate arguments', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      code: 0,
      stdout: '{}',
      stderr: '',
    });
    await ForkopShellMethods.routeTrace(
      'example.org',
      '192.168.1.2',
      'TCP',
      '443',
    );
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        command: '/usr/bin/forkop',
        args: ['route_trace', 'example.org', '192.168.1.2', 'TCP', '443'],
      }),
    );
  });

  it('keeps snapshot creation explicit before apply', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      code: 0,
      stdout: '{"status":"created"}',
      stderr: '',
    });
    await ForkopShellMethods.snapshotCreate('automatic');
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['config_snapshot_create', 'automatic'],
      }),
    );
  });

  it('uses each existing provider validator without runtime mutation', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      code: 0,
      stdout: '{"valid":true}',
      stderr: '',
    });
    for (const provider of ['zapret', 'zapret2', 'byedpi'] as const)
      await ForkopShellMethods.validateDpiStrategy(provider, '--test');
    expect(
      mocks.executeShellCommand.mock.calls.map(([value]) => value.args[0]),
    ).toEqual([
      'validate_nfqws_strategy_json',
      'validate_nfqws2_strategy_json',
      'validate_byedpi_strategy_json',
    ]);
  });
});
