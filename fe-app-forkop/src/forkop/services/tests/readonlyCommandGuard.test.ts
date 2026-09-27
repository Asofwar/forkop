import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { setReadonlyMode } from '../accessMode.service';
import {
  READONLY_REFUSED,
  isReadonlyCommandAllowed,
} from '../readonlyCommandGuard';
import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { callBaseMethod } from '../../methods/shell/callBaseMethod';
import { Forkop } from '../../types';

// callBaseMethod imports the helpers barrel, which pulls in DOM services;
// only the real executeShellCommand matters here.
vi.mock('../../../helpers', async () => ({
  executeShellCommand: (await import('../../../helpers/executeShellCommand'))
    .executeShellCommand,
}));

const exec = vi.fn();

beforeEach(() => {
  exec.mockReset();
  exec.mockResolvedValue({ stdout: '{}', stderr: '', code: 0 });
  (globalThis as unknown as { fs: unknown }).fs = { exec };
});

afterEach(() => {
  setReadonlyMode(false);
});

describe('read-only exec allowlist', () => {
  it('matches exact commands without extra arguments', () => {
    expect(isReadonlyCommandAllowed('/usr/bin/forkop', ['get_status'])).toBe(
      true,
    );
    expect(
      isReadonlyCommandAllowed('/usr/bin/forkop', ['get_status', 'extra']),
    ).toBe(false);
    expect(
      isReadonlyCommandAllowed('/usr/bin/forkop', ['global_check', 'masked']),
    ).toBe(true);
    expect(
      isReadonlyCommandAllowed('/usr/bin/forkop', ['global_check', 'raw']),
    ).toBe(false);
  });

  it('matches glob arguments, including empty trailing ones', () => {
    expect(
      isReadonlyCommandAllowed('/usr/bin/forkop', [
        'route_trace',
        'example.org',
        '',
        'TCP',
        '',
      ]),
    ).toBe(true);
    expect(
      isReadonlyCommandAllowed('/usr/bin/forkop', [
        'clash_api',
        'get_group_latency',
        'main',
        '5000',
      ]),
    ).toBe(true);
  });
});

describe('executeShellCommand in a read-only session', () => {
  const mutations: Array<[string, string[]]> = [
    ['/usr/bin/forkop', ['service_action_async', 'stop']],
    [
      '/usr/bin/forkop',
      ['latency_test_async', 'group', 'main', 'main-out', ''],
    ],
    ['/usr/bin/forkop', ['subscription_update_async', 'main']],
    ['/usr/bin/forkop', ['clash_api', 'set_group_proxy', 'main-out', 'node']],
    ['/usr/bin/forkop', ['clash_api', 'close_all_connections']],
    ['/usr/bin/forkop', ['ui_action_ack', 'latency', 'job']],
    ['/usr/bin/forkop', ['urltest_override_save', 'main', 'a']],
    ['/usr/bin/forkop', ['component_action_async', 'zapret', 'remove']],
    ['/usr/bin/forkop', ['config_snapshot_restore', '1']],
    ['/usr/bin/forkop', ['support_report']],
    ['/etc/init.d/forkop', ['disable']],
  ];

  it('refuses every mutation locally without issuing an RPC', async () => {
    setReadonlyMode(true);

    for (const [command, args] of mutations) {
      const response = await executeShellCommand({ command, args });
      expect(response).toEqual({
        stdout: '',
        stderr: READONLY_REFUSED,
        code: 126,
      });
    }

    expect(exec).not.toHaveBeenCalled();
  });

  it('passes read commands through', async () => {
    setReadonlyMode(true);

    await executeShellCommand({
      command: '/usr/bin/forkop',
      args: ['get_health_status'],
    });

    expect(exec).toHaveBeenCalledWith('/usr/bin/forkop', ['get_health_status']);
  });

  it('leaves administrator sessions untouched', async () => {
    for (const [command, args] of mutations) {
      await executeShellCommand({ command, args });
    }

    expect(exec).toHaveBeenCalledTimes(mutations.length);
  });

  it('reports a refused shell method as a failed response', async () => {
    setReadonlyMode(true);

    const response = await callBaseMethod(Forkop.AvailableMethods.CLASH_API, [
      'close_all_connections',
    ]);

    expect(response.success).toBe(false);
    expect(exec).not.toHaveBeenCalled();
  });
});
