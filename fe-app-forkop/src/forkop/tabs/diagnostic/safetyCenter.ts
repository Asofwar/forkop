import { ForkopShellMethods } from '../../methods';
import { Forkop } from '../../types';
import {
  DisplayStatus,
  eventKindLabel,
  eventStatus,
  formatTime,
  renderStatusBadge,
} from './statusLabels';

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

// Only recovery facts: service/DNS/DPI health lives on the Dashboard.
export function recoveryRows(
  health: Forkop.HealthStatus,
): Array<[string, DisplayStatus]> {
  const last = lastRecoveryEvent(health);
  return [
    [
      _('DPI guard'),
      health.guard.active
        ? { text: _('Active: DPI switch not confirmed'), tone: 'warning' }
        : { text: _('Inactive'), tone: 'success' },
    ],
    [
      _('Last recovery'),
      health.recovery.pending
        ? { text: _('In progress'), tone: 'loading' }
        : last
          ? {
              text: `${eventKindLabel(last.kind)}: ${eventStatus(last.status).text} · ${formatTime(last.timestamp)}`,
              tone: eventStatus(last.status).tone,
            }
          : { text: _('Not needed'), tone: 'success' },
    ],
    [
      _('Package recovery'),
      health.package_recovery.pending
        ? { text: _('Waiting to finish'), tone: 'warning' }
        : { text: _('Not needed'), tone: 'success' },
    ],
    [
      _('Last reload'),
      health.last_reload
        ? {
            text: `${eventStatus(health.last_reload.status).text} · ${formatTime(health.last_reload.timestamp)}`,
            tone: eventStatus(health.last_reload.status).tone,
          }
        : { text: _('No reload recorded yet'), tone: 'neutral' },
    ],
  ];
}

export function recentEvents(health: Forkop.HealthStatus) {
  return health.recent_activity
    .slice(-10)
    .reverse()
    .map((event) => ({
      time: formatTime(event.timestamp),
      kind: eventKindLabel(event.kind),
      status: eventStatus(event.status),
    }));
}

export function initSafetyCenter() {
  const button = document.getElementById(
    'safety-center-refresh',
  ) as HTMLButtonElement | null;
  const container = document.getElementById('safety-center-state');
  if (!button || !container || button.onclick) return;
  const refresh = async () => {
    button.disabled = true;
    try {
      const response = await ForkopShellMethods.getHealthStatus();
      if (!response.success || !response.data) {
        container.textContent = _('Recovery state is unavailable');
        return;
      }
      const events = recentEvents(response.data);
      container.replaceChildren(
        E(
          'dl',
          { class: 'fkp-diag-facts' },
          recoveryRows(response.data).flatMap(([label, status]) => [
            E('dt', {}, label),
            E('dd', {}, renderStatusBadge(status)),
          ]),
        ),
        E('h4', {}, _('Recent events')),
        events.length
          ? E(
              'table',
              { class: 'fkp-diag-events' },
              events.map((event) =>
                E('tr', {}, [
                  E('td', {}, event.time),
                  E('td', {}, event.kind),
                  E('td', {}, renderStatusBadge(event.status)),
                ]),
              ),
            )
          : E('p', { class: 'fkp-diag-hint' }, _('No events recorded yet')),
      );
    } catch (_error) {
      container.textContent = _('Recovery state is unavailable');
    } finally {
      button.disabled = false;
    }
  };
  button.onclick = () => void refresh();
  void refresh();
}
