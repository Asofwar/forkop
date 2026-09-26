import { ForkopShellMethods } from '../../methods';
import { Forkop } from '../../types';

export function safetyRows(health: Forkop.HealthStatus) {
  return [
    [_('Overall'), health.overall],
    ['Forkop', health.service.forkop],
    ['sing-box', health.service.sing_box],
    ['DNS', health.dns.status],
    ['DPI', health.dpi.status],
    [_('DPI guard'), health.guard.active ? _('Active') : _('Inactive')],
    [
      _('Package recovery'),
      health.package_recovery.pending ? _('Pending') : _('None'),
    ],
    [
      _('Last reload'),
      health.last_reload
        ? `${health.last_reload.status} · ${new Date(health.last_reload.timestamp * 1000).toLocaleString()}`
        : _('Unknown'),
    ],
  ];
}

export function initSafetyCenter() {
  const button = document.getElementById(
    'safety-center-refresh',
  ) as HTMLButtonElement | null;
  const container = document.getElementById('safety-center-state');
  if (!button || !container || button.onclick) return;
  const refresh = async () => {
    const response = await ForkopShellMethods.getHealthStatus();
    if (!response.success || !response.data) {
      container.textContent = _('Health status unavailable');
      return;
    }
    const health = response.data;
    container.replaceChildren(
      ...safetyRows(health).map(([label, status]) =>
        E('div', {}, [E('strong', {}, `${label}: `), E('span', {}, status)]),
      ),
      E('h4', {}, _('Recent activity')),
      ...health.recent_activity
        .slice(-10)
        .reverse()
        .map((event) =>
          E(
            'div',
            {},
            `${new Date(event.timestamp * 1000).toLocaleString()} · ${event.kind}: ${event.status}`,
          ),
        ),
    );
  };
  button.onclick = () => void refresh();
  void refresh();
}
