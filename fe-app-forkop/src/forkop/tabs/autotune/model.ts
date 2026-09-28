import { Forkop } from '../../types';
import type { StatusTone } from '../../ui/status';

// Pure view model of the Autotune page (autotune/manager.uc status and
// groups). Every backend code becomes words here; raw codes never reach the
// page.

export const MODES: Forkop.AutotuneMode[] = ['off', 'recommend', 'auto'];

export function modeLabel(mode: string) {
  switch (mode) {
    case 'recommend':
      return _('Recommendations only');
    case 'auto':
      return _('Automatic');
    default:
      return _('Off');
  }
}

export function modeDescription(mode: string) {
  switch (mode) {
    case 'recommend':
      return _(
        'Forkop X measures the targets on schedule and shows recommendations. It does not change rules.',
      );
    case 'auto':
      return _(
        'Forkop X measures the targets on schedule and applies a confirmed recommendation by itself, with a production check and automatic rollback.',
      );
    default:
      return _(
        'Scheduled measurements are off. An administrator can still check targets manually.',
      );
  }
}

// Catalog candidate ids are strategy names users see in zapret; "direct" is
// the control without any bypass.
export function strategyLabel(id: string | null | undefined) {
  if (!id) return '—';
  if (id === 'direct') return _('No bypass (direct)');
  if (id === 'default') return _('Default strategy');
  return id;
}

export function currentStrategyLabel(
  current: string | null | undefined,
  custom: boolean | null | undefined,
) {
  if (custom) return _('Custom strategy');
  if (!current) return _('Not determined');
  return strategyLabel(current);
}

export function confidenceLabel(confidence: string | null | undefined) {
  switch (confidence) {
    case 'high':
      return _('high');
    case 'medium':
      return _('medium');
    case 'low':
      return _('low');
    default:
      return '—';
  }
}

export function stabilityView(stability: string | undefined): {
  label: string;
  tone: StatusTone;
} {
  switch (stability) {
    case 'stable':
      return { label: _('Stable'), tone: 'success' };
    case 'unstable':
      return { label: _('Unstable'), tone: 'warning' };
    case 'failed':
      return { label: _('Failed'), tone: 'error' };
    case 'unsupported':
      return { label: _('Not supported'), tone: 'muted' };
    default:
      return { label: _('Not checked'), tone: 'neutral' };
  }
}

// Why the measurement of a target ended the way it did (select.uc,
// isolation.uc and manager.uc reason codes).
export function targetReasonText(reason: string | null | undefined) {
  switch (reason) {
    case 'direct_stable':
      return _('Works without bypass.');
    case 'direct_failed_candidate_stable':
      return _('Does not work without bypass; a stable strategy was found.');
    case 'direct_unstable_candidate_stable':
      return _('Unstable without bypass; a stable strategy was found.');
    case 'candidate_more_reliable_than_direct':
      return _('The strategy is more reliable than no bypass.');
    case 'materially_faster_than_direct':
    case 'materially_faster':
      return _('The strategy is noticeably faster.');
    case 'simplest_stable':
      return _(
        'Several strategies are stable with similar latency; the simplest one was chosen.',
      );
    case 'candidate_bypassed':
      return _('The target is reachable only through a bypass strategy.');
    case 'no_stable_candidate':
      return _('No strategy is stable. The current strategy is kept.');
    case 'all_failed':
    case 'target_unreachable':
      return _(
        'The target is unreachable in every way; the problem may not be DPI.',
      );
    case 'target_ip_mismatch':
    case 'target_unresolved':
      return _(
        'The target address could not be determined reliably during the check.',
      );
    case 'isolation_unavailable':
    case 'route_unavailable':
      return _('A safe isolated check is not possible right now.');
    case 'autotune_in_progress':
    case 'lock_unavailable':
      return _('Another check was running.');
    case 'resolver_missing':
      return _(
        'No DNS server for measurements: set a plain IPv4 DNS server in Forkop X or on the target.',
      );
    default:
      return reason ? _('The check gave no usable result.') : '';
  }
}

// Why a target has no DPI group (groups.uc classify).
export function outsideReasonText(reason: string) {
  switch (reason) {
    case 'target_disabled':
      return _('The target is disabled.');
    case 'target_unresolved':
      return _('The router could not resolve the address.');
    case 'target_not_fakeip_routed':
      return _(
        'The router does not route this address through FakeIP, so Forkop X cannot check a strategy change for it.',
      );
    case 'rule_owner_undecidable':
      return _(
        'The rule that routes it cannot be determined unambiguously (for example, a remote list comes first).',
      );
    case 'dpi_identity_unproven':
      return _('The DPI rule that routes it could not be identified safely.');
    case 'provider_not_supported':
      return _(
        'It goes through a Zapret2 or ByeDPI rule; autotune supports Zapret rules only.',
      );
    case 'routed_through_connection':
      return _(
        'It goes through a proxy or VPN rule. DPI autotune does not apply.',
      );
    case 'no_dpi_rule':
      return _(
        'It goes directly and is not in a DPI rule. No bypass is configured for it.',
      );
    case 'bypassed':
      return _('It is excluded from Forkop X routing.');
    case 'blocked':
      return _('It is blocked by a rule.');
    case 'not_a_dpi_rule':
    case 'outbound_without_rule':
      return _('It is not routed by a DPI rule.');
    default:
      return _('It is not in a DPI rule.');
  }
}

// Why autonomous apply did not happen on the last run (autoapply.uc).
export function decisionText(reason: string | null | undefined) {
  switch (reason) {
    case 'mode_not_auto':
      return _('Forkop X does not apply recommendations in this mode.');
    case 'manual_run':
      return _(
        'Manual checks only measure; changes are applied only on schedule.',
      );
    case 'not_confirmed':
      return _('The recommendation is not confirmed yet.');
    case 'confidence_too_low':
      return _('Automatic apply requires high confidence.');
    case 'custom_strategy_kept':
      return _('The rule has a custom strategy; Forkop X keeps it.');
    case 'candidate_in_cooldown':
      return _(
        'This strategy was rolled back recently; it waits for the cooldown.',
      );
    case 'state_recovered':
      return _(
        'The autotune state was restored after damage; automatic apply waits for the cooldown.',
      );
    case 'applies_disabled':
      return _('Automatic applies are disabled by the policy (0 per day).');
    case 'daily_limit_reached':
      return _('The daily limit of automatic applies is reached.');
    case 'one_apply_per_run':
      return _(
        'Another group was changed in this run; at most one change per run.',
      );
    case 'direct_not_applicable':
      return _('Forkop X never turns DPI bypass off by itself.');
    case 'representative_not_measured':
    case 'no_recommendation':
      return '';
    default:
      return '';
  }
}

export function applyOutcomeView(status: string): {
  label: string;
  tone: StatusTone;
} {
  switch (status) {
    case 'applied':
      return { label: _('Applied, check passed'), tone: 'success' };
    case 'rolled_back':
      return {
        label: _('Check failed, rolled back automatically'),
        tone: 'warning',
      };
    case 'no_change_required':
      return { label: _('No change was needed'), tone: 'neutral' };
    case 'not_applied':
    case 'stale':
    case 'busy':
      return { label: _('Not applied'), tone: 'neutral' };
    case 'needs_attention':
      return { label: _('Rollback did not finish'), tone: 'error' };
    default:
      return { label: _('Outcome unknown'), tone: 'error' };
  }
}

export interface GroupCard {
  id: string;
  title: string;
  targetCount: number;
  badge: { label: string; tone: StatusTone };
  current: string;
  recommended: string | null;
  confidence: string | null;
  explanation: string[];
  progress: { count: number; required: number } | null;
  checkedAt: number | null;
  lastApply: {
    at: number;
    candidate: string;
    outcome: { label: string; tone: StatusTone };
  } | null;
  cooldowns: { candidate: string; until: number }[];
  // The confirmed recommendation an administrator may apply now (mode
  // "recommend" only); the backend checks everything again.
  applyCandidate: string | null;
  // Mode "off" with a confirmed recommendation: how to apply it.
  manualHint: boolean;
  targets: string[];
}

function conflictText(
  result: Forkop.AutotuneGroupResult,
  hosts: Record<string, string>,
) {
  const parts = (result.conflict ?? []).map(
    (item) =>
      `${hosts[item.target] ?? item.target}: ${strategyLabel(item.selected)}`,
  );
  const base =
    result.reason === 'candidate_not_stable_for_all'
      ? _('The best strategy is not stable for every target of the rule.')
      : _('Targets of this rule need different strategies.');
  return [
    base,
    ...(parts.length ? [parts.join('; ') + '.'] : []),
    _(
      'A strategy is set for the whole rule, so Forkop X does not change it. You can split the targets into separate rules.',
    ),
  ];
}

function inconclusiveText(reason: string | null) {
  if (reason === 'not_measured' || reason === 'no_targets' || !reason)
    return _('No measurements yet.');
  if (reason === 'no_conclusive_result')
    return _(
      'The last check gave no usable result. The current strategy is kept.',
    );
  return `${targetReasonText(reason)} ${_('The current strategy is kept.')}`;
}

// One card per DPI rule. `live` is the membership calculated now (null
// while it loads or when it failed), `state` what the worker recorded.
export function groupCards(
  status: Forkop.AutotuneStatus,
  live: Forkop.AutotuneGroups | null,
): GroupCard[] {
  const hosts = Object.fromEntries(status.targets.map((t) => [t.id, t.host]));
  const ids = new Set<string>([
    ...Object.keys(live?.groups ?? {}),
    ...(live ? [] : Object.keys(status.groups ?? {})),
  ]);

  return [...ids].sort().map((id) => {
    const state = status.groups?.[id] ?? null;
    const now = live?.groups[id] ?? null;
    const targets = now?.targets ?? state?.targets ?? [];
    const current = now?.current ?? state?.current ?? null;
    const custom = now?.custom ?? null;
    // The worker result belongs to the last run; the live result is built
    // from cached target results and may be newer (another group's run).
    const result = state?.result ?? now?.result ?? null;
    const required = state?.required ?? status.policy.confirmations;
    const pending = state?.pending ?? null;
    const ready = state?.ready === true;
    const explanation: string[] = [];
    let badge: GroupCard['badge'];
    let recommended: string | null = null;

    if (!result || !state?.last) {
      badge = { label: _('Not checked'), tone: 'neutral' };
      explanation.push(_('No measurements yet.'));
    } else if (result.status === 'recommendation') {
      recommended = result.candidate;
      badge = ready
        ? { label: _('Recommendation confirmed'), tone: 'warning' }
        : { label: _('Confirming'), tone: 'loading' };
      const why = targetReasonText(result.reason);
      if (why) explanation.push(why);
      if (!ready)
        explanation.push(
          _(
            'The strategy is changed only after %d checks in a row with the same result.',
          ).replace('%d', String(required)),
        );
    } else if (result.status === 'no_change') {
      badge = { label: _('No change needed'), tone: 'success' };
      explanation.push(_('The current strategy is already the best.'));
    } else if (result.status === 'direct_stable') {
      badge = { label: _('Bypass not needed'), tone: 'success' };
      explanation.push(
        _('The targets work without bypass.'),
        _(
          'Forkop X never turns DPI bypass off by itself; remove the targets from the rule manually if you want.',
        ),
      );
    } else if (result.status === 'conflict') {
      badge = { label: _('Conflict'), tone: 'warning' };
      explanation.push(...conflictText(result, hosts));
    } else {
      badge = { label: _('No data'), tone: 'neutral' };
      explanation.push(inconclusiveText(result.reason));
    }

    const decision =
      status.policy.mode === 'auto' && result?.status === 'recommendation'
        ? decisionText(state?.decision?.reason)
        : '';
    if (decision) explanation.push(decision);
    if (custom && result?.status === 'recommendation')
      explanation.push(_('The rule has a custom strategy; Forkop X keeps it.'));

    const apply = state?.last_apply ?? null;
    const nowSeconds = Math.floor(Date.now() / 1000);
    const cooling = (candidate: string | null) =>
      Boolean(candidate && (state?.cooldowns?.[candidate] ?? 0) > nowSeconds);
    const applyCandidate =
      status.policy.mode === 'recommend' &&
      result?.status === 'recommendation' &&
      ready &&
      !custom &&
      result.candidate &&
      result.candidate !== 'direct' &&
      !cooling(result.candidate)
        ? result.candidate
        : null;

    return {
      id,
      title: now?.label || state?.label || id,
      targetCount: targets.length,
      badge,
      current: currentStrategyLabel(current, custom),
      recommended,
      confidence:
        result?.status === 'recommendation' || result?.status === 'no_change'
          ? result.confidence
          : null,
      explanation,
      progress:
        pending && result?.status === 'recommendation'
          ? { count: Math.min(pending.count, required), required }
          : null,
      checkedAt: state?.last?.at ?? null,
      lastApply:
        apply && apply.status !== 'not_applied'
          ? {
              at: apply.at,
              candidate:
                apply.trigger === 'manual'
                  ? `${strategyLabel(apply.candidate)} (${_('manually')})`
                  : strategyLabel(apply.candidate),
              outcome: applyOutcomeView(apply.status),
            }
          : null,
      cooldowns: Object.entries(state?.cooldowns ?? {})
        .filter(([, until]) => until > nowSeconds)
        .map(([candidate, until]) => ({
          candidate: strategyLabel(candidate),
          until,
        })),
      applyCandidate,
      manualHint:
        status.policy.mode === 'off' &&
        result?.status === 'recommendation' &&
        ready,
      targets: targets.map((target) => hosts[target] ?? target),
    };
  });
}

export interface CandidateRow {
  name: string;
  result: string;
  stability: { label: string; tone: StatusTone };
  latency: string;
  selected: boolean;
}

// Candidates of one target's last check, best first as select.uc ranks
// them: stable, then success ratio. Latency only exists for successes.
export function candidateRows(
  summary: Forkop.AutotuneTargetSummary,
): CandidateRow[] {
  const order: Record<string, number> = {
    stable: 0,
    unstable: 1,
    failed: 2,
  };
  return summary.candidates
    .slice()
    .sort(
      (a, b) =>
        (order[a.stability ?? ''] ?? 3) - (order[b.stability ?? ''] ?? 3) ||
        (b.success_ratio ?? -1) - (a.success_ratio ?? -1),
    )
    .map((candidate) => ({
      name: strategyLabel(candidate.id),
      result:
        typeof candidate.attempted === 'number' && candidate.attempted > 0
          ? `${candidate.success ?? 0} / ${candidate.attempted}`
          : '—',
      stability: stabilityView(candidate.stability),
      latency:
        typeof candidate.median_tls_ms === 'number'
          ? _('%d ms').replace(
              '%d',
              String(Math.round(candidate.median_tls_ms)),
            )
          : '—',
      selected: candidate.id === summary.selected,
    }));
}

export interface TargetRow {
  id: string;
  host: string;
  enabled: boolean;
  resolver: string | null;
  result: string;
  tone: StatusTone;
  checkedAt: number | null;
}

export function targetRows(targets: Forkop.AutotuneTarget[]): TargetRow[] {
  return targets.map((target) => {
    const last = target.last;
    let result: string;
    let tone: StatusTone = 'neutral';
    if (!target.enabled) {
      result = _('Disabled');
      tone = 'muted';
    } else if (!last) {
      result = _('Not checked');
    } else if (last.status === 'selected' && last.selected) {
      result = `${_('Best')}: ${strategyLabel(last.selected)} (${_('confidence')} ${confidenceLabel(last.confidence)})`;
      tone = 'success';
    } else {
      result = targetReasonText(last.reason) || _('No usable result');
      tone = 'warning';
    }
    return {
      id: target.id,
      host: target.host,
      enabled: target.enabled,
      resolver: target.resolver,
      result,
      tone,
      checkedAt: last?.at ?? null,
    };
  });
}

// Worker state for the summary line.
export function workerView(
  worker: Forkop.AutotuneWorker | null,
): { label: string; tone: StatusTone } | null {
  if (!worker) return null;
  if (worker.state === 'running')
    return worker.phase === 'applying'
      ? { label: _('Applying a strategy'), tone: 'loading' }
      : { label: _('Checking targets'), tone: 'loading' };
  if (worker.state === 'crashed')
    return {
      label: _('The last check was interrupted'),
      tone: 'warning',
    };
  switch (worker.result) {
    case 'completed':
      return { label: _('Last check completed'), tone: 'success' };
    case 'interrupted':
      return { label: _('The last check was interrupted'), tone: 'warning' };
    case 'skipped':
      return {
        label: `${_('Last check postponed')}: ${blockerText(worker.reason)}`,
        tone: 'neutral',
      };
    default:
      return { label: _('The last check failed'), tone: 'error' };
  }
}

// Why a run did not measure (manager.uc blocker()).
export function blockerText(reason: string | null | undefined) {
  switch (reason) {
    case 'dpi_guard_present':
      return _('DPI protection is active');
    case 'snapshot_operation_active':
      return _('a snapshot operation is in progress');
    case 'autotune_in_progress':
      return _('another check is running');
    case 'apply_unresolved':
      return _('a previous apply is not resolved');
    default:
      return reason ? _('the service is busy') : _('unknown reason');
  }
}

// Errors of mutations for toasts.
export function mutationErrorText(reason: string | undefined) {
  switch (reason) {
    case 'uncommitted_uci_changes':
      return _(
        'There are unsaved configuration changes. Save or reset them in Settings first.',
      );
    case 'autotune_worker_running':
      return _('A check is already running.');
    case 'invalid_host':
      return _('Enter a domain name, for example youtube.com.');
    case 'invalid_resolver':
      return _('The DNS server must be an IPv4 address.');
    case 'too_many_targets':
      return _('The maximum number of targets is reached.');
    case 'number_out_of_range':
    case 'duration_out_of_range':
    case 'invalid_number':
    case 'invalid_duration':
      return _('The value is outside the allowed range.');
    default:
      return _('The change was not saved.');
  }
}

// A target id from its host: letters, digits and "_", unique among `taken`.
export function targetIdFor(host: string, taken: string[]) {
  const base = ('t_' + host.toLowerCase().replace(/[^a-z0-9]+/g, '_'))
    .slice(0, 28)
    .replace(/_+$/, '');
  let id = base || 't';
  for (let n = 2; taken.includes(id); n++) id = `${base}_${n}`;
  return id;
}

export const INTERVAL_CHOICES = ['1h', '3h', '6h', '12h', '1d'];
export const COOLDOWN_CHOICES = ['6h', '12h', '1d', '2d', '7d'];

export function durationLabel(value: string) {
  const match = /^(\d+)([hd])$/.exec(value);
  if (!match) return value;
  return match[2] === 'h'
    ? _('%d h').replace('%d', match[1])
    : _('%d d').replace('%d', match[1]);
}

// Choices of a select: the presets plus the configured value, if custom.
export function durationChoices(presets: string[], current: string) {
  return presets.includes(current) ? presets : [...presets, current];
}

// ---- manual apply ----------------------------------------------------------

// The confirmation of a manual apply: what changes, for which targets, and
// what Forkop X does to keep it safe. Strategy names only, never options.
export function applyConfirmation(card: GroupCard) {
  const candidate = strategyLabel(card.applyCandidate);
  return {
    title: _('Apply %s?').replace('%s', candidate),
    message: `${_('The strategy of the DPI rule "%s" will be changed.').replace('%s', card.title)} ${_('The change affects the whole group:')}`,
    consequences: card.targets.length ? card.targets : ['—'],
    notes: [
      `${_('Now')}: ${card.current}. ${_('Will be')}: ${candidate}.`,
      _(
        'Forkop X will create a configuration snapshot, reload the service and check the real production path. If the check fails, the previous configuration is restored automatically.',
      ),
    ],
    confirmLabel: _('Apply'),
  };
}

// The step a running manual apply reports (manager.uc apply progress and
// the Stage 5 transaction phase). Only reported steps are shown.
export function applyPhaseLabel(
  progress: { phase: string; apply_phase: string | null } | null | undefined,
) {
  switch (progress?.apply_phase) {
    case 'checking':
      return _('Checking the configuration before the change');
    case 'applying':
      return _('Creating a snapshot and reloading the service');
    case 'verifying':
      return _('Checking the real production path');
    case 'rolling_back':
      return _('Restoring the previous configuration');
  }
  if (progress?.phase === 'applying') return _('Preparing the change');
  return _('Checking the recommendation');
}

// Refusals and Stage 5 results that mean the measurement no longer fits
// the configuration: the check must run again.
const STALE_REASONS = [
  'recommendation_stale',
  'rule_changed',
  'strategy_changed',
  'targets_changed',
  'owner_changed',
  'recommendation_changed',
  'measurement_unavailable',
  'plan_candidate_differs',
];

export interface ApplyResultView {
  tone: 'success' | 'warning' | 'error' | 'neutral';
  text: string;
  // Recovery did not finish: the user must act (History & Recovery).
  attention: boolean;
}

function refusalText(reason: string | null | undefined) {
  switch (reason) {
    case 'not_confirmed':
      return _('The recommendation is not confirmed yet.');
    case 'no_recommendation':
      return _('There is no recommendation to apply.');
    case 'conflict':
      return _('Targets of this rule need different strategies.');
    case 'direct_not_applicable':
      return _('Forkop X never turns DPI bypass off by itself.');
    case 'candidate_unsupported':
      return _('This strategy is not supported by the installed Zapret.');
    case 'confidence_too_low':
      return _(
        'The confidence of the recommendation is below the policy minimum.',
      );
    case 'candidate_in_cooldown':
      return _(
        'This strategy was rolled back recently; it waits for the cooldown.',
      );
    case 'custom_strategy_kept':
      return _('The rule has a custom strategy; Forkop X keeps it.');
    case 'mode_off':
    case 'mode_not_recommend':
    case 'mode_changed':
      return _(
        'Manual apply is available only in "Recommendations only" mode.',
      );
    case 'state_recovered':
      return _(
        'The autotune state was restored after damage. Run the check again.',
      );
    case 'resolver_missing':
      return targetReasonText(reason);
    case 'autotune_worker_running':
    case 'autotune_in_progress':
      return _('Another autotune operation is running.');
    case 'dpi_guard_present':
    case 'snapshot_operation_active':
    case 'apply_unresolved':
      return `${_('The strategy was not applied')}: ${blockerText(reason)}.`;
    default:
      return reason &&
        /^(reload|restart|start|stop|service)_|_pending$|_running$/.test(reason)
        ? `${_('The strategy was not applied')}: ${blockerText(reason)}.`
        : `${_('The strategy was not applied')}.`;
  }
}

// What the finished apply job means for the user.
export function applyResultView(
  result: { status: string; result?: string; reason?: string | null } | null,
  candidate: string | null,
): ApplyResultView {
  const name = strategyLabel(candidate);
  const outcome = result?.result ?? '';
  const reason = result?.reason ?? null;
  const stale = {
    tone: 'warning' as const,
    text: _(
      'The recommendation is outdated: the configuration changed after the check. Run the check again.',
    ),
    attention: false,
  };
  switch (outcome) {
    case 'applied':
      return {
        tone: 'success',
        text: _('Strategy %s applied and checked.').replace('%s', name),
        attention: false,
      };
    case 'rolled_back':
      return {
        tone: 'warning',
        text: _(
          'The new strategy did not pass the check. Forkop X restored the previous configuration automatically.',
        ),
        attention: false,
      };
    case 'no_change_required':
      return {
        tone: 'neutral',
        text: _('This strategy is already active; nothing was changed.'),
        attention: false,
      };
    case 'stale':
      return stale;
    case 'failed':
      if (reason === 'reload_failed_recovered')
        return {
          tone: 'warning',
          text: _(
            'The new strategy was not applied: the service reload failed and the previous configuration was restored automatically.',
          ),
          attention: false,
        };
      if (reason !== 'interrupted_after_apply')
        return {
          tone: 'error',
          text: _(
            'The strategy could not be applied. The previous configuration is kept.',
          ),
          attention: false,
        };
      break;
    case 'refused':
    case 'not_applied':
      if (STALE_REASONS.includes(reason ?? '')) return stale;
      return { tone: 'warning', text: refusalText(reason), attention: false };
    case 'needs_attention':
    case 'unknown':
      break;
    default:
      if (result?.status === 'busy')
        return {
          tone: 'warning',
          text: refusalText('autotune_worker_running'),
          attention: false,
        };
      // Refused before the transaction (invalid request, no configuration).
      if (!outcome && result)
        return { tone: 'error', text: refusalText(reason), attention: false };
  }
  return {
    tone: 'error',
    text: _('Automatic recovery did not finish.'),
    attention: true,
  };
}
