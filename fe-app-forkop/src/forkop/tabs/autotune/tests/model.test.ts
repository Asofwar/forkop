import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  applyConfirmation,
  applyPhaseLabel,
  applyResultView,
  candidateRows,
  currentStrategyLabel,
  decisionText,
  durationChoices,
  groupCards,
  mutationErrorText,
  outsideReasonText,
  strategyLabel,
  targetIdFor,
  targetRows,
  workerView,
} from '../model';
import type { Forkop } from '../../../types';

const NOW = 1_800_000_000;

const policy = (
  overrides: Partial<Forkop.AutotunePolicy> = {},
): Forkop.AutotunePolicy => ({
  mode: 'recommend',
  interval: '6h',
  confirmations: 3,
  min_confidence: 'high',
  max_applies_per_day: 1,
  cooldown: '24h',
  probes: 5,
  ...overrides,
});

const summary = (
  overrides: Partial<Forkop.AutotuneTargetSummary> = {},
): Forkop.AutotuneTargetSummary => ({
  at: NOW - 60,
  status: 'selected',
  reason: 'direct_unstable_candidate_stable',
  selected: 'multisplit',
  confidence: 'high',
  candidates: [
    {
      id: 'direct',
      stability: 'unstable',
      success: 2,
      attempted: 5,
      success_ratio: 0.4,
      median_tls_ms: 160,
    },
    {
      id: 'fake',
      stability: 'stable',
      success: 5,
      attempted: 5,
      success_ratio: 1,
      median_tls_ms: 139,
    },
    {
      id: 'multisplit',
      stability: 'stable',
      success: 5,
      attempted: 5,
      success_ratio: 1,
      median_tls_ms: 142.4,
    },
    {
      id: 'udp_fake',
      stability: 'unsupported',
      success: 0,
      attempted: 0,
      success_ratio: null,
      median_tls_ms: null,
    },
  ],
  ...overrides,
});

const status = (
  overrides: Partial<Forkop.AutotuneStatus> = {},
): Forkop.AutotuneStatus => ({
  status: 'ok',
  policy: policy(),
  errors: [],
  targets: [
    {
      id: 't_youtube',
      host: 'youtube.com',
      enabled: true,
      resolver: null,
      last: summary(),
    },
    {
      id: 't_video',
      host: 'googlevideo.com',
      enabled: true,
      resolver: null,
      last: null,
    },
  ],
  groups: {},
  next_run_at: null,
  worker: null,
  recovered_at: null,
  state_recovered: null,
  ...overrides,
});

const recommendation: Forkop.AutotuneGroupResult = {
  status: 'recommendation',
  candidate: 'multisplit',
  confidence: 'high',
  representative: 't_youtube',
  reason: 'direct_unstable_candidate_stable',
  conflict: [],
};

const groupState = (
  overrides: Partial<Forkop.AutotuneGroupState> = {},
): Forkop.AutotuneGroupState => ({
  pending: { candidate: 'multisplit', count: 1 },
  last: {
    status: 'recommendation',
    candidate: 'multisplit',
    confidence: 'high',
    reason: null,
    at: NOW - 60,
  },
  cooldowns: {},
  last_apply: null,
  label: 'YouTube',
  targets: ['t_youtube'],
  current: 'fake',
  ready: false,
  required: 3,
  result: recommendation,
  decision: { reason: 'mode_not_auto', at: NOW - 60 },
  ...overrides,
});

const live = (
  overrides: Partial<Forkop.AutotuneLiveGroup> = {},
): Forkop.AutotuneGroups => ({
  status: 'ok',
  groups: {
    youtube: {
      label: 'YouTube',
      targets: ['t_youtube', 't_video'],
      current: 'fake',
      custom: false,
      result: recommendation,
      ...overrides,
    },
  },
  outside: [],
});

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW * 1000);
});

afterEach(() => {
  vi.useRealTimers();
});

describe('autotune strategy labels', () => {
  it('names the control and the default, keeps catalog ids', () => {
    expect(strategyLabel('direct')).toBe('No bypass (direct)');
    expect(strategyLabel('default')).toBe('Default strategy');
    expect(strategyLabel('multisplit')).toBe('multisplit');
    expect(strategyLabel(null)).toBe('—');
  });

  it('never shows a raw custom strategy', () => {
    expect(currentStrategyLabel('', true)).toBe('Custom strategy');
    expect(currentStrategyLabel(null, null)).toBe('Not determined');
  });
});

describe('groupCards', () => {
  it('shows a recommendation that is still being confirmed', () => {
    const [card] = groupCards(
      status({ groups: { youtube: groupState() } }),
      live(),
    );
    expect(card.id).toBe('youtube');
    expect(card.title).toBe('YouTube');
    expect(card.badge).toEqual({ label: 'Confirming', tone: 'loading' });
    expect(card.current).toBe('fake');
    expect(card.recommended).toBe('multisplit');
    expect(card.progress).toEqual({ count: 1, required: 3 });
    expect(card.targets).toEqual(['youtube.com', 'googlevideo.com']);
    expect(card.explanation.join(' ')).toContain('3 checks in a row');
    expect(card.manualHint).toBe(false);
    expect(card.applyCandidate).toBeNull();
  });

  it('offers a manual apply only for a confirmed recommendation in recommend mode', () => {
    const ready = groupState({
      pending: { candidate: 'multisplit', count: 3 },
      ready: true,
    });
    const [card] = groupCards(status({ groups: { youtube: ready } }), live());
    expect(card.badge.label).toBe('Recommendation confirmed');
    expect(card.applyCandidate).toBe('multisplit');
    expect(card.manualHint).toBe(false);

    const [off] = groupCards(
      status({ policy: policy({ mode: 'off' }), groups: { youtube: ready } }),
      live(),
    );
    expect(off.applyCandidate).toBeNull();
    expect(off.manualHint).toBe(true);

    const [cooling] = groupCards(
      status({
        groups: { youtube: { ...ready, cooldowns: { multisplit: NOW + 60 } } },
      }),
      live(),
    );
    expect(cooling.applyCandidate).toBeNull();

    const [custom] = groupCards(
      status({ groups: { youtube: ready } }),
      live({ custom: true }),
    );
    expect(custom.applyCandidate).toBeNull();

    const [direct] = groupCards(
      status({
        groups: {
          youtube: {
            ...ready,
            pending: { candidate: 'direct', count: 3 },
            result: { ...recommendation, candidate: 'direct' },
          },
        },
      }),
      live(),
    );
    expect(direct.applyCandidate).toBeNull();

    const [auto] = groupCards(
      status({
        policy: policy({ mode: 'auto' }),
        groups: {
          youtube: {
            ...ready,
            decision: { reason: 'daily_limit_reached', at: NOW },
          },
        },
      }),
      live(),
    );
    expect(auto.manualHint).toBe(false);
    expect(auto.applyCandidate).toBeNull();
    expect(auto.explanation).toContain(decisionText('daily_limit_reached'));
  });

  it('explains a conflict with the target names, not ids', () => {
    const conflict: Forkop.AutotuneGroupResult = {
      status: 'conflict',
      candidate: null,
      confidence: null,
      reason: 'targets_need_different_strategies',
      conflict: [
        { target: 't_youtube', selected: 'multisplit' },
        { target: 't_video', selected: 'fake' },
      ],
    };
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({ pending: null, result: conflict }),
        },
      }),
      live(),
    );
    expect(card.badge).toEqual({ label: 'Conflict', tone: 'warning' });
    expect(card.recommended).toBeNull();
    expect(card.progress).toBeNull();
    const text = card.explanation.join(' ');
    expect(text).toContain('youtube.com: multisplit');
    expect(text).toContain('googlevideo.com: fake');
    expect(text).not.toContain('t_video');
  });

  it('never suggests turning DPI off when direct works', () => {
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({
            pending: null,
            result: {
              status: 'direct_stable',
              candidate: null,
              confidence: null,
              reason: 'direct_not_applicable',
            },
          }),
        },
      }),
      live(),
    );
    expect(card.badge.label).toBe('Bypass not needed');
    expect(card.recommended).toBeNull();
    expect(card.explanation.join(' ')).toContain(
      'never turns DPI bypass off by itself',
    );
  });

  it('marks a group never measured as not checked', () => {
    const [card] = groupCards(status(), live());
    expect(card.badge).toEqual({ label: 'Not checked', tone: 'neutral' });
    expect(card.checkedAt).toBeNull();
  });

  it('follows the current routing and falls back to the recorded groups', () => {
    const recorded = status({ groups: { old_rule: groupState() } });
    expect(groupCards(recorded, live()).map((c) => c.id)).toEqual(['youtube']);
    expect(groupCards(recorded, null).map((c) => c.id)).toEqual(['old_rule']);
  });

  it('reports the last apply and active cooldowns only', () => {
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({
            last_apply: {
              at: NOW - 100,
              group: 'youtube',
              candidate: 'multisplit',
              status: 'rolled_back',
              reason: 'verification_failed',
            },
            cooldowns: { multisplit: NOW + 3600, fake: NOW - 10 },
          }),
        },
      }),
      live(),
    );
    expect(card.lastApply?.outcome.label).toBe(
      'Check failed, rolled back automatically',
    );
    expect(card.cooldowns).toEqual([
      { candidate: 'multisplit', until: NOW + 3600 },
    ]);
  });

  it('hides a not-applied record', () => {
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({
            last_apply: {
              at: NOW,
              group: 'youtube',
              candidate: 'multisplit',
              status: 'not_applied',
              reason: 'dpi_guard_present',
            },
          }),
        },
      }),
      live(),
    );
    expect(card.lastApply).toBeNull();
  });

  it('says a custom rule strategy is kept', () => {
    const [card] = groupCards(
      status({ groups: { youtube: groupState() } }),
      live({ custom: true, current: '' }),
    );
    expect(card.current).toBe('Custom strategy');
    expect(card.explanation.join(' ')).toContain('custom strategy');
  });
});

describe('candidateRows', () => {
  it('orders stable first and shows latency only for successes', () => {
    const rows = candidateRows(summary());
    expect(rows.map((r) => r.name)).toEqual([
      'fake',
      'multisplit',
      'No bypass (direct)',
      'udp_fake',
    ]);
    expect(rows[1]).toMatchObject({
      result: '5 / 5',
      latency: '142 ms',
      selected: true,
    });
    expect(rows[3]).toMatchObject({ result: '—', latency: '—' });
    expect(rows[3].stability.label).toBe('Not supported');
  });
});

describe('targetRows', () => {
  it('describes each target in words', () => {
    const rows = targetRows([
      ...status().targets,
      {
        id: 't_off',
        host: 'example.org',
        enabled: false,
        resolver: null,
        last: null,
      },
      {
        id: 't_bad',
        host: 'bad.example',
        enabled: true,
        resolver: '192.0.2.53',
        last: summary({
          status: 'inconclusive',
          selected: null,
          reason: 'all_failed',
        }),
      },
    ]);
    expect(rows[0]).toMatchObject({ tone: 'success' });
    expect(rows[0].result).toContain('multisplit');
    expect(rows[1]).toMatchObject({ result: 'Not checked', tone: 'neutral' });
    expect(rows[2]).toMatchObject({ result: 'Disabled', tone: 'muted' });
    expect(rows[3].tone).toBe('warning');
    expect(rows[3].result).toContain('unreachable');
  });
});

describe('workerView', () => {
  it('distinguishes running, interrupted and postponed checks', () => {
    expect(workerView(null)).toBeNull();
    expect(workerView({ state: 'running', phase: 'measuring' })?.tone).toBe(
      'loading',
    );
    expect(workerView({ state: 'crashed' })?.tone).toBe('warning');
    expect(
      workerView({
        state: 'finished',
        result: 'skipped',
        reason: 'dpi_guard_present',
      })?.label,
    ).toContain('DPI protection is active');
    expect(workerView({ state: 'finished', result: 'completed' })?.tone).toBe(
      'success',
    );
  });
});

describe('texts', () => {
  it('explains every outside reason without raw codes', () => {
    for (const reason of [
      'target_disabled',
      'target_unresolved',
      'target_not_fakeip_routed',
      'rule_owner_undecidable',
      'dpi_identity_unproven',
      'provider_not_supported',
      'routed_through_connection',
      'no_dpi_rule',
      'bypassed',
      'blocked',
      'not_a_dpi_rule',
      'outbound_without_rule',
      'something_new',
    ]) {
      const text = outsideReasonText(reason);
      expect(text).not.toMatch(/_/);
      expect(text.length).toBeGreaterThan(5);
    }
  });

  it('names the unsaved changes refusal', () => {
    expect(mutationErrorText('uncommitted_uci_changes')).toContain(
      'unsaved configuration changes',
    );
    expect(mutationErrorText(undefined)).toBe('The change was not saved.');
  });
});

describe('targetIdFor', () => {
  it('builds a valid unique UCI id', () => {
    expect(targetIdFor('YouTube.com', [])).toBe('t_youtube_com');
    expect(targetIdFor('youtube.com', ['t_youtube_com'])).toBe(
      't_youtube_com_2',
    );
    const long = targetIdFor('a'.repeat(80) + '.example', []);
    expect(long).toMatch(/^[A-Za-z0-9_]{1,32}$/);
    expect(targetIdFor('x.io', ['t_x_io', 't_x_io_2'])).toBe('t_x_io_3');
  });
});

describe('durationChoices', () => {
  it('keeps a custom configured value selectable', () => {
    expect(durationChoices(['1h', '6h'], '6h')).toEqual(['1h', '6h']);
    expect(durationChoices(['1h', '6h'], '90m')).toEqual(['1h', '6h', '90m']);
  });
});

describe('manual apply', () => {
  const ready = groupState({
    pending: { candidate: 'multisplit', count: 3 },
    ready: true,
  });

  it('confirms with the rule, the targets and both strategy names only', () => {
    const [card] = groupCards(status({ groups: { youtube: ready } }), live());
    const confirm = applyConfirmation(card);
    expect(confirm.title).toBe('Apply multisplit?');
    expect(confirm.message).toContain('"YouTube"');
    expect(confirm.message).toContain('whole group');
    expect(confirm.consequences).toEqual(['youtube.com', 'googlevideo.com']);
    expect(confirm.notes[0]).toBe('Now: fake. Will be: multisplit.');
    expect(confirm.notes[1]).toContain('snapshot');
    expect(confirm.notes[1]).toContain('restored automatically');
    expect(JSON.stringify(confirm)).not.toMatch(/dpi-desync|nfqws|--/);
  });

  it('labels only the reported steps', () => {
    expect(applyPhaseLabel(null)).toBe('Checking the recommendation');
    expect(applyPhaseLabel({ phase: 'applying', apply_phase: null })).toBe(
      'Preparing the change',
    );
    expect(
      applyPhaseLabel({ phase: 'applying', apply_phase: 'verifying' }),
    ).toBe('Checking the real production path');
    expect(
      applyPhaseLabel({ phase: 'applying', apply_phase: 'rolling_back' }),
    ).toBe('Restoring the previous configuration');
  });

  it('explains every outcome', () => {
    const view = (result: string | undefined, reason: string | null = null) =>
      applyResultView({ status: 'failed', result, reason }, 'multisplit');
    expect(
      applyResultView({ status: 'ok', result: 'applied' }, 'multisplit'),
    ).toEqual({
      tone: 'success',
      text: 'Strategy multisplit applied and checked.',
      attention: false,
    });
    expect(view('rolled_back').tone).toBe('warning');
    expect(view('rolled_back').text).toContain('restored the previous');
    expect(view('stale', 'config_changed').text).toContain('outdated');
    expect(view('refused', 'rule_changed').text).toContain('outdated');
    expect(view('refused', 'owner_changed').text).toContain('outdated');
    expect(view('refused', 'not_confirmed').text).toBe(
      'The recommendation is not confirmed yet.',
    );
    expect(view('refused', 'dpi_guard_present').text).toContain(
      'DPI protection is active',
    );
    expect(view('failed', 'reload_failed_recovered')).toMatchObject({
      tone: 'warning',
      attention: false,
    });
    expect(view('needs_attention', 'lkg_confirm_failed')).toEqual({
      tone: 'error',
      text: 'Automatic recovery did not finish.',
      attention: true,
    });
    expect(view('failed', 'interrupted_after_apply').attention).toBe(true);
    expect(applyResultView(null, 'multisplit').attention).toBe(true);
    expect(
      applyResultView({ status: 'failed', reason: 'invalid_group' }, null)
        .attention,
    ).toBe(false);
    expect(
      applyResultView(
        {
          status: 'busy',
          result: 'refused',
          reason: 'autotune_worker_running',
        },
        null,
      ).text,
    ).toBe('Another autotune operation is running.');
  });

  it('marks a manual last apply', () => {
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({
            last_apply: {
              at: NOW - 10,
              group: 'youtube',
              candidate: 'multisplit',
              status: 'applied',
              reason: null,
              counted: false,
              trigger: 'manual',
            },
          }),
        },
      }),
      live(),
    );
    expect(card.lastApply?.candidate).toBe('multisplit (manually)');
  });
});
