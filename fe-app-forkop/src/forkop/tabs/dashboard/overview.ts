import { Forkop } from '../../types';
import { prettyBytes } from '../../../helpers/prettyBytes';
import {
  eventKindLabel,
  eventOutcomeView,
  toEventOutcome,
  type SemanticStatus,
  type StatusTone,
} from '../../ui/status';
import { formatRelativeTime } from '../../ui/time';

// View model of the overview page: short answers, each with a link to the
// page that has the details. Pure, so every state is covered by tests.

export type OverviewPage = 'monitoring' | 'diagnostics' | 'settings';

export interface OverviewInput {
  health: Forkop.HealthStatus | null;
  availability: 'loading' | 'running' | 'stopped' | 'unavailable';
  forkopEnabled: boolean;
  singBoxRunning: boolean;
  groups: Forkop.OutboundGroup[];
  ruleCount: number | null;
  traffic: { up: number; down: number } | null;
  connections: number | null;
  snapshotCount: number | null;
  lastDiagnosticRun: number | null;
  nowMs: number;
}

export interface OverviewWarning {
  title: string;
  text: string;
  link: { page: OverviewPage; label: string };
}

export interface OverviewLine {
  text: string;
  tone?: StatusTone;
}

export interface OverviewState {
  status: SemanticStatus;
  title: string;
  lines: OverviewLine[];
  stopped: boolean;
}

export interface OverviewGroup {
  name: string;
  node: string;
  latency: string;
  tone: StatusTone;
}

export interface OverviewRouting {
  summary: string;
  live: string;
  groups: OverviewGroup[];
  more: number;
}

export interface OverviewRecovery {
  status: SemanticStatus;
  title: string;
  lines: OverviewLine[];
}

export interface OverviewEvent {
  title: string;
  outcome: { label: string; tone: StatusTone };
  time: string;
}

function lastEvent(health: Forkop.HealthStatus | null) {
  const events = health?.recent_activity || [];
  return events.length ? events[events.length - 1] : null;
}

export function overviewWarning(
  health: Forkop.HealthStatus | null,
): OverviewWarning | null {
  if (!health) return null;
  const details = {
    page: 'diagnostics' as const,
    label: _('Recovery details'),
  };

  if (health.guard?.active) {
    return {
      title: _('DPI protection is holding traffic'),
      text: _(
        'A configuration change was not confirmed. Traffic that needs DPI bypass may be blocked until recovery completes.',
      ),
      link: details,
    };
  }
  if (health.package_recovery?.pending) {
    return {
      title: _('Package recovery has not finished'),
      text: _(
        'An interrupted package update is being recovered. Avoid changes until it completes.',
      ),
      link: details,
    };
  }
  if (lastEvent(health)?.status === 'failure') {
    return {
      title: _('The last configuration change failed'),
      text: _('Forkop X kept or restored the previous configuration.'),
      link: details,
    };
  }

  return null;
}

export function overviewState(input: OverviewInput): OverviewState {
  const { health, availability } = input;
  const lines: OverviewLine[] = [];
  let status: SemanticStatus;
  let title: string;

  if (availability === 'stopped') {
    status = input.forkopEnabled ? 'error' : 'off';
    title = _('Forkop X is stopped');
    lines.push({
      text: _('Traffic goes through the router without Forkop X.'),
    });
  } else if (availability === 'loading') {
    status = 'busy';
    title = _('Checking…');
  } else if (availability === 'unavailable') {
    status = 'unknown';
    title = _('State unavailable');
  } else if (health?.overall === 'transitioning') {
    status = 'busy';
    title = _('Applying changes…');
  } else if (health?.overall === 'error') {
    status = 'error';
    title = _('Forkop X needs attention');
  } else {
    status = health?.overall === 'recovered' ? 'warning' : 'healthy';
    title = _('Forkop X is running');
    if (health?.overall === 'recovered') {
      lines.push({
        text: _('The last change was rolled back automatically.'),
        tone: 'warning',
      });
    }
  }

  if (availability === 'running') {
    lines.push(
      input.singBoxRunning
        ? { text: _('sing-box is running') }
        : { text: _('sing-box is not running'), tone: 'error' },
    );
    if (health?.dns?.status === 'warning') {
      lines.push({
        text: _('Router DNS is not pointed to Forkop X'),
        tone: 'warning',
      });
    }
  }
  lines.push({
    text: input.forkopEnabled ? _('Autostart is on') : _('Autostart is off'),
  });
  lines.push({
    text: input.lastDiagnosticRun
      ? _('Last diagnostics: %s').replace(
          '%s',
          formatRelativeTime(input.lastDiagnosticRun / 1000, input.nowMs),
        )
      : _('Diagnostics has not been run yet'),
  });

  return { status, title, lines, stopped: availability === 'stopped' };
}

function latencyTone(latency: number): StatusTone {
  if (!latency) return 'neutral';
  if (latency < 800) return 'success';
  return latency < 1500 ? 'warning' : 'error';
}

const MAX_GROUPS = 3;

export function overviewRouting(input: OverviewInput): OverviewRouting {
  const groups = input.groups.filter((group) => group.outbounds.length);
  // Node groups are only known while sing-box runs.
  const groupsKnown = input.availability === 'running' || groups.length > 0;
  let summary = '';
  if (input.ruleCount !== null && groupsKnown) {
    summary = _('%d rules · %d node groups')
      .replace('%d', String(input.ruleCount))
      .replace('%d', String(groups.length));
  } else if (input.ruleCount !== null) {
    summary = _('%d rules').replace('%d', String(input.ruleCount));
  } else if (groupsKnown) {
    summary = _('%d node groups').replace('%d', String(groups.length));
  }

  let live = '';
  if (input.availability === 'stopped') {
    live = _('Routing is paused while Forkop X is stopped.');
  } else if (input.connections !== null) {
    live = _('%d connections now').replace('%d', String(input.connections));
    if (input.traffic) {
      live += ` · ↓ ${prettyBytes(input.traffic.down)}/s ↑ ${prettyBytes(input.traffic.up)}/s`;
    }
  }

  return {
    summary,
    live,
    groups: groups.slice(0, MAX_GROUPS).map((group) => {
      const selected =
        group.outbounds.find((outbound) => outbound.selected) ||
        group.outbounds[0];
      return {
        name: group.displayName,
        node: selected.displayName,
        latency: selected.latency ? `${selected.latency} ms` : _('no data'),
        tone: latencyTone(selected.latency),
      };
    }),
    more: Math.max(0, groups.length - MAX_GROUPS),
  };
}

export function overviewRecovery(input: OverviewInput): OverviewRecovery {
  const { health } = input;
  if (!health) {
    return { status: 'unknown', title: _('State unavailable'), lines: [] };
  }

  const guard = Boolean(health.guard?.active);
  const lines: OverviewLine[] = [];
  const reload = health.last_reload;
  if (reload) {
    const outcome = eventOutcomeView(toEventOutcome(reload.status));
    lines.push({
      text: _('Last reload: %s').replace(
        '%s',
        `${outcome.label} · ${formatRelativeTime(reload.timestamp, input.nowMs)}`,
      ),
      tone: outcome.tone,
    });
  } else {
    lines.push({ text: _('No reload recorded yet') });
  }
  if (input.snapshotCount !== null) {
    lines.push({
      text: _('Snapshots: %d').replace('%d', String(input.snapshotCount)),
    });
  }

  return {
    status: guard ? 'needs_attention' : 'healthy',
    title: guard ? _('Protection is active') : _('No recovery needed'),
    lines,
  };
}

export function overviewLastEvent(input: OverviewInput): OverviewEvent | null {
  const event = lastEvent(input.health);
  if (!event) return null;

  return {
    title: eventKindLabel(event.kind),
    outcome: eventOutcomeView(toEventOutcome(event.status)),
    time: formatRelativeTime(event.timestamp, input.nowMs),
  };
}
