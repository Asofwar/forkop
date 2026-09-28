import { Forkop } from '../../types';
import {
  eventKindLabel,
  eventOutcomeView,
  toEventOutcome,
  type StatusTone,
} from '../../ui/status';
import { formatRelativeTime } from '../../ui/time';

// Pure view model of the History & Recovery page.

export interface RecoveryRow {
  label: string;
  value: string;
  tone: StatusTone;
}

function formatTime(timestamp: number) {
  return new Date(timestamp * 1000).toLocaleString();
}

// A plain reload is not a recovery: only restores, recovery runs and events
// that ended in a rollback ("recovered") count.
export function lastRecoveryEvent(health: Forkop.HealthStatus) {
  const events = [
    ...health.recent_activity,
    ...(health.recovery.last_event ? [health.recovery.last_event] : []),
  ].filter(
    (event) =>
      event.kind === 'restore' ||
      event.kind === 'recovery' ||
      event.status === 'recovered',
  );
  return events.sort((a, b) => b.timestamp - a.timestamp)[0] ?? null;
}

function eventText(event: { kind: string; status: string; timestamp: number }) {
  const outcome = eventOutcomeView(toEventOutcome(event.status));
  return {
    value: `${eventKindLabel(event.kind)}: ${outcome.label} · ${formatTime(event.timestamp)}`,
    tone: outcome.tone,
  };
}

export function recoveryRows(
  health: Forkop.HealthStatus,
  snapshots: Forkop.SnapshotMetadata[] | null,
): RecoveryRow[] {
  const last = lastRecoveryEvent(health);
  const reload = health.last_reload;
  const lkg = snapshots?.find((snapshot) => snapshot.is_lkg);
  const reloadOutcome = reload
    ? eventOutcomeView(toEventOutcome(reload.status))
    : null;

  return [
    {
      label: _('DPI guard'),
      ...(health.guard.active
        ? {
            value: _('Active: DPI switch not confirmed'),
            tone: 'error' as const,
          }
        : { value: _('Inactive'), tone: 'success' as const }),
    },
    {
      label: _('Last recovery'),
      ...(health.recovery.pending
        ? { value: _('In progress'), tone: 'loading' as const }
        : last
          ? eventText(last)
          : { value: _('Not needed'), tone: 'success' as const }),
    },
    {
      label: _('Package recovery'),
      ...(health.package_recovery.pending
        ? { value: _('Waiting to finish'), tone: 'warning' as const }
        : { value: _('Not needed'), tone: 'success' as const }),
    },
    {
      label: _('Last reload'),
      ...(reload && reloadOutcome
        ? {
            value: `${reloadOutcome.label} · ${formatTime(reload.timestamp)}`,
            tone: reloadOutcome.tone,
          }
        : { value: _('No reload recorded yet'), tone: 'neutral' as const }),
    },
    {
      label: _('Last known good configuration'),
      ...(lkg
        ? { value: formatTime(lkg.created_at), tone: 'success' as const }
        : snapshots
          ? { value: _('Not recorded yet'), tone: 'neutral' as const }
          : { value: _('Unknown'), tone: 'neutral' as const }),
    },
  ];
}

export type HistoryFilter = 'all' | 'config' | 'service' | 'autotune';

const CATEGORY: Record<string, Exclude<HistoryFilter, 'all'>> = {
  reload: 'config',
  restore: 'config',
  snapshot_create: 'config',
  snapshot_delete: 'config',
  start: 'service',
  recovery: 'service',
  autotune_apply: 'autotune',
};

export function historyFilterLabel(filter: HistoryFilter) {
  switch (filter) {
    case 'config':
      return _('Configuration');
    case 'service':
      return _('Service');
    case 'autotune':
      return _('Autotune');
    default:
      return _('All');
  }
}

export interface HistoryItem {
  title: string;
  outcome: { label: string; tone: StatusTone };
  time: string;
  relative: string;
}

// Newest first.
export function historyItems(
  events: Forkop.HistoryEvent[],
  filter: HistoryFilter,
  nowMs = Date.now(),
): HistoryItem[] {
  return events
    .filter((event) => filter === 'all' || CATEGORY[event.kind] === filter)
    .slice()
    .sort((a, b) => b.timestamp - a.timestamp)
    .map((event) => ({
      title: eventKindLabel(event.kind),
      outcome: eventOutcomeView(toEventOutcome(event.status)),
      time: formatTime(event.timestamp),
      relative: formatRelativeTime(event.timestamp, nowMs),
    }));
}

export function snapshotReasonLabel(reason: string) {
  switch (reason) {
    case 'manual':
      return _('Manual');
    case 'before-reload':
      return _('Before applying changes');
    case 'pre-restore':
      return _('Before restore');
    case 'last-known-working':
      return _('Last known good');
    case 'before-autotune':
      return _('Before autotune');
    default:
      return _('Other');
  }
}

// Newest first; the last-known-good snapshot cannot be deleted.
export function snapshotRows(snapshots: Forkop.SnapshotMetadata[]) {
  return snapshots
    .slice()
    .sort((a, b) => b.created_at - a.created_at)
    .map((snapshot) => ({
      id: snapshot.id,
      time: formatTime(snapshot.created_at),
      // The badge already says "last known good" for such snapshots.
      reason:
        snapshot.is_lkg && snapshot.reason === 'last-known-working'
          ? ''
          : snapshotReasonLabel(snapshot.reason),
      lkg: Boolean(snapshot.is_lkg),
      canDelete: !snapshot.is_lkg,
    }));
}

function diffValue(value: string | string[] | undefined) {
  if (Array.isArray(value)) return value.length ? value.join(', ') : '—';
  return value === undefined || value === '' ? '—' : value;
}

// `before` is the snapshot value, `after` the saved configuration now.
export function diffRows(changes: Forkop.SnapshotChange[]) {
  return changes.map((change) => ({
    where: `${change.section} · ${change.option}`,
    snapshot: diffValue(change.before),
    current: diffValue(change.after),
  }));
}
