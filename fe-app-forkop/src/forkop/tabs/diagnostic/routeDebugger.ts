import { ForkopShellMethods } from '../../methods';
import { Forkop } from '../../types';

export function routeStages(trace: Forkop.RouteTrace) {
  return [
    { label: _('Target'), stage: trace.target },
    { label: _('DNS resolution'), stage: trace.dns },
    { label: _('Matched rule'), stage: trace.rule },
    { label: _('Action'), stage: trace.action },
    { label: _('Outbound'), stage: trace.outbound },
    { label: _('DPI provider'), stage: trace.dpi },
    { label: _('Interface'), stage: trace.interface },
    { label: _('Current runtime'), stage: trace.runtime },
  ];
}

function field(id: string) {
  return (
    (document.getElementById(id) as HTMLInputElement | null)?.value.trim() || ''
  );
}

export function initRouteDebugger() {
  const button = document.getElementById(
    'trace-run',
  ) as HTMLButtonElement | null;
  if (!button || button.onclick) return;
  button.onclick = async () => {
    const container = document.getElementById('trace-result');
    if (!container) return;
    container.textContent = _('Tracing route');
    button.disabled = true;
    try {
      const response = await ForkopShellMethods.routeTrace(
        field('trace-target'),
        field('trace-source'),
        field('trace-protocol'),
        field('trace-port'),
      );
      if (!response.success || !response.data?.target) {
        container.textContent = _('Invalid target or route trace failed');
        return;
      }
      container.replaceChildren(
        E(
          'p',
          {},
          _(
            'Observed from router; source IP is not applied to the probe and LAN client policy is not proven.',
          ),
        ),
        ...routeStages(response.data).map(({ label, stage }) =>
          E('div', { class: 'fkp-route-stage' }, [
            E('strong', {}, label),
            E('span', {}, String(stage.address || stage.value || _('Unknown'))),
            E('small', {}, stage.provenance),
          ]),
        ),
      );
    } finally {
      button.disabled = false;
    }
  };
}
