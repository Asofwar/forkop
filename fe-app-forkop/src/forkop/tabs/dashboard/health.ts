import { Forkop } from '../../types';
import { openForkopPage } from '../../helpers/navigation';

export function healthItems(health: Forkop.HealthStatus) {
  return [
    { label: 'Forkop', status: health.service.forkop },
    { label: 'sing-box', status: health.service.sing_box },
    { label: 'DNS', status: health.dns.status },
    { label: 'DPI', status: health.dpi.status },
    { label: 'Lists', status: health.lists.status },
  ];
}

function statusLabel(status: Forkop.HealthLevel) {
  const labels: Record<Forkop.HealthLevel, string> = {
    ok: _('OK'),
    warning: _('Warning'),
    error: _('Error'),
    transitioning: _('Transitioning'),
    recovered: _('Recovered'),
    unknown: _('Unknown'),
  };
  return labels[status] || labels.unknown;
}

export function renderHealth(health: Forkop.HealthStatus) {
  const guard = health.guard.active;
  return E('div', { class: 'fkp-health' }, [
    E(
      'div',
      { class: 'fkp-health__strip', role: 'status' },
      healthItems(health).map((item) =>
        E(
          'span',
          {
            class: `fkp-health__item fkp-health__item--${item.status}`,
            title: `${item.label}: ${statusLabel(item.status)}`,
          },
          `${item.label}: ${statusLabel(item.status)}`,
        ),
      ),
    ),
    ...(guard
      ? [
          E(
            'p',
            { class: 'fkp-health__guard' },
            _(
              'DPI protection active. Traffic may be intentionally blocked during recovery.',
            ),
          ),
        ]
      : []),
    E(
      'button',
      {
        type: 'button',
        class: 'btn cbi-button',
        click: () => openForkopPage('diagnostics'),
      },
      _('Open Diagnostics'),
    ),
    E('div', { class: 'fkp-health__activity' }, [
      E('strong', {}, _('Recent activity')),
      ...health.recent_activity
        .slice(-5)
        .reverse()
        .map((event) =>
          E(
            'div',
            {},
            `${new Date(event.timestamp * 1000).toLocaleTimeString()} · ${event.kind}: ${event.status}`,
          ),
        ),
    ]),
  ]);
}
