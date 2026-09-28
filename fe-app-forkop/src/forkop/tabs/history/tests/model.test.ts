import { describe, expect, it } from 'vitest';

import {
  diffRows,
  historyItems,
  recoveryRows,
  snapshotReasonLabel,
  snapshotRows,
} from '../model';
import type { Forkop } from '../../../types';

const health = (
  overrides: Partial<Forkop.HealthStatus> = {},
): Forkop.HealthStatus => ({
  overall: 'ok',
  service: { forkop: 'ok', sing_box: 'ok' },
  dns: { status: 'unknown' },
  dpi: { status: 'unknown' },
  lists: { status: 'unknown' },
  guard: { active: false },
  recovery: {
    pending: false,
    last_event: { kind: 'start', status: 'success', timestamp: 1 },
  },
  package_recovery: { pending: false },
  last_reload: { status: 'success', timestamp: 2 },
  recent_activity: [
    { kind: 'start', status: 'success', timestamp: 1 },
    { kind: 'reload', status: 'success', timestamp: 2 },
  ],
  ...overrides,
});

const snapshot = (
  id: string,
  createdAt: number,
  reason: string,
  isLkg = false,
): Forkop.SnapshotMetadata => ({
  id,
  created_at: createdAt,
  kind: reason === 'manual' ? 'manual' : 'automatic',
  reason,
  config_hash: 'x',
  forkop_version: '1.0.0',
  is_lkg: isLkg,
});

describe('recovery state', () => {
  it('shows recovery facts, localized, with the last known good snapshot', () => {
    const rows = recoveryRows(health(), [
      snapshot('2_b', 20, 'last-known-working', true),
    ]);

    expect(rows.map((row) => row.label)).toEqual([
      'DPI guard',
      'Last recovery',
      'Package recovery',
      'Last reload',
      'Last known good configuration',
    ]);
    expect(rows[0].value).toBe('Inactive');
    expect(rows[1].value).toBe('Not needed');
    expect(rows[3].value).toMatch(/^Succeeded · /);
    expect(rows[4].tone).toBe('success');
    for (const row of rows)
      expect(row.value).not.toMatch(/^(ok|success|unknown|failure)$/);
  });

  it('says when no last known good snapshot exists or snapshots are unknown', () => {
    expect(recoveryRows(health(), [])[4].value).toBe('Not recorded yet');
    expect(recoveryRows(health(), null)[4].value).toBe('Unknown');
  });

  it('never presents an ordinary reload as the last recovery', () => {
    const reloadOnly = health({
      recovery: {
        pending: false,
        last_event: { kind: 'reload', status: 'success', timestamp: 9 },
      },
      recent_activity: [{ kind: 'reload', status: 'success', timestamp: 9 }],
    });
    expect(recoveryRows(reloadOnly, [])[1].value).toBe('Not needed');

    const rolledBack = health({
      recent_activity: [{ kind: 'reload', status: 'recovered', timestamp: 7 }],
    });
    expect(recoveryRows(rolledBack, [])[1].value).toMatch(
      /^Configuration reload: Recovered · /,
    );
  });

  it('maps an active guard and pending package recovery', () => {
    const rows = recoveryRows(
      health({
        guard: { active: true },
        package_recovery: { pending: true },
        last_reload: null,
      }),
      [],
    );

    expect(rows[0]).toMatchObject({
      value: 'Active: DPI switch not confirmed',
      tone: 'error',
    });
    expect(rows[2].value).toBe('Waiting to finish');
    expect(rows[3].value).toBe('No reload recorded yet');
  });
});

describe('history list', () => {
  const events: Forkop.HistoryEvent[] = [
    { kind: 'start', status: 'success', timestamp: 100 },
    { kind: 'reload', status: 'failure', timestamp: 200 },
    { kind: 'autotune_apply', status: 'recovered', timestamp: 300 },
    { kind: 'snapshot_delete', status: 'success', timestamp: 400 },
  ];

  it('lists the newest event first with its own words', () => {
    expect(historyItems(events, 'all').map((item) => item.title)).toEqual([
      'Snapshot deleted',
      'Autotune apply',
      'Configuration reload',
      'Service start',
    ]);
    expect(historyItems(events, 'all')[1].outcome).toEqual({
      label: 'Recovered',
      tone: 'warning',
    });
  });

  it('names manual and automatic autotune applies', () => {
    const titles = historyItems(
      [
        {
          kind: 'autotune_apply',
          status: 'success',
          timestamp: 4,
          trigger: 'manual',
          candidate: 'multisplit',
        },
        {
          kind: 'autotune_apply',
          status: 'recovered',
          timestamp: 3,
          trigger: 'automatic',
          candidate: 'fake',
        },
        { kind: 'autotune_apply', status: 'success', timestamp: 2 },
      ],
      'autotune',
    ).map((item) => item.title);
    expect(titles).toEqual([
      'Autotune: multisplit applied manually',
      'Autotune: automatic apply of fake',
      'Autotune apply',
    ]);
  });

  it('filters by category', () => {
    expect(historyItems(events, 'config').map((item) => item.title)).toEqual([
      'Snapshot deleted',
      'Configuration reload',
    ]);
    expect(historyItems(events, 'autotune')).toHaveLength(1);
    expect(
      historyItems(
        [{ kind: 'autotune_mode', status: 'success', timestamp: 1 }],
        'autotune',
      ).map((item) => item.title),
    ).toEqual(['Autotune mode changed']);
    expect(
      historyItems(
        [
          { kind: 'autotune_run', status: 'failure', timestamp: 2 },
          { kind: 'autotune_recommendation', status: 'success', timestamp: 1 },
        ],
        'autotune',
      ).map((item) => item.title),
    ).toEqual(['Autotune run', 'Autotune recommendation confirmed']);
    expect(historyItems(events, 'service').map((item) => item.title)).toEqual([
      'Service start',
    ]);
  });
});

describe('snapshots', () => {
  it('labels every reason and marks the last known good one', () => {
    expect(snapshotReasonLabel('before-autotune')).toBe('Before autotune');
    expect(snapshotReasonLabel('unexpected')).toBe('Other');

    const rows = snapshotRows([
      snapshot('1_a', 10, 'manual'),
      snapshot('2_b', 20, 'last-known-working', true),
    ]);

    expect(rows.map((row) => [row.id, row.lkg, row.canDelete])).toEqual([
      ['2_b', true, false],
      ['1_a', false, true],
    ]);
    expect(rows[1].reason).toBe('Manual');
    expect(rows[0].reason).toBe('');
  });

  it('shows list changes readably', () => {
    expect(
      diffRows([
        {
          section: 'settings',
          option: 'dns_server',
          kind: 'list',
          before: ['1.1.1.1', '8.8.8.8'],
          after: [],
        },
        { section: 'youtube', option: 'nfqws_opt', before: 'a', after: '' },
      ]),
    ).toEqual([
      {
        where: 'settings · dns_server',
        snapshot: '1.1.1.1, 8.8.8.8',
        current: '—',
      },
      { where: 'youtube · nfqws_opt', snapshot: 'a', current: '—' },
    ]);
  });
});
