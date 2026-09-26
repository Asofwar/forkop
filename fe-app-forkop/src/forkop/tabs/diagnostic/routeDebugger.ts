import { ForkopShellMethods } from '../../methods';
import { Forkop } from '../../types';
import type { StatusTone } from './statusLabels';

export interface RouteFact {
  label: string;
  value: string;
  note: string;
  tone: StatusTone;
}

function provenanceNote(provenance: Forkop.RouteTraceStage['provenance']) {
  switch (provenance) {
    case 'observed':
      return _('Seen in an active connection');
    case 'configured':
      return _('Derived from configuration');
    default:
      return _('Calculated result');
  }
}

// Only facts the router actually established are returned; stages it cannot
// determine are omitted instead of being shown as a permanent "unknown".
export function routeFacts(trace: Forkop.RouteTrace): RouteFact[] {
  const target = String(trace.target.value || '');
  const isLiteral = trace.dns.provenance === 'simulated';
  const facts: RouteFact[] = [
    {
      label: isLiteral ? _('IP address') : _('Domain'),
      value: target,
      note: '',
      tone: 'neutral',
    },
  ];
  if (!isLiteral) {
    facts.push(
      trace.dns.address
        ? {
            label: _('Resolved IP'),
            value: trace.dns.address,
            note: _('Answer of the router DNS'),
            tone: 'success',
          }
        : {
            label: _('Resolved IP'),
            value: _('Not resolved'),
            note: _('The router DNS returned no address'),
            tone: 'error',
          },
    );
  }
  if (trace.interface.provenance === 'observed' && trace.interface.value) {
    facts.push({
      label: _('Router kernel route'),
      value: trace.interface.value,
      note: _('Interface the router itself would use for this address'),
      tone: 'success',
    });
  } else if (trace.dns.address) {
    facts.push({
      label: _('Router kernel route'),
      value: _('No route'),
      note: _('The router has no route to this address'),
      tone: 'error',
    });
  }
  const extra: Array<[string, Forkop.RouteTraceStage]> = [
    [_('Matched rule'), trace.rule],
    [_('Action'), trace.action],
    [_('Outbound'), trace.outbound],
    [_('DPI provider'), trace.dpi],
    [_('Current runtime'), trace.runtime],
  ];
  for (const [label, stage] of extra)
    if (stage.provenance !== 'unknown' && stage.value)
      facts.push({
        label,
        value: String(stage.value),
        note: provenanceNote(stage.provenance),
        tone: 'neutral',
      });
  return facts;
}

// LuCI tabs switch on the inner link; inactive tabs carry `cbi-tab-disabled`.
const MONITORING_TAB_LINK = '[data-tab="monitoring"] > a';

function openMonitoring() {
  document.querySelector<HTMLElement>(MONITORING_TAB_LINK)?.click();
}

export function initRouteDebugger() {
  const button = document.getElementById(
    'trace-run',
  ) as HTMLButtonElement | null;
  const input = document.getElementById(
    'trace-target',
  ) as HTMLInputElement | null;
  const container = document.getElementById('trace-result');
  if (!button || !input || !container || button.onclick) return;
  input.onkeydown = (event) => {
    if (event.key === 'Enter') button.click();
  };
  input.oninput = () => container.replaceChildren();
  button.onclick = async () => {
    const target = input.value.trim();
    if (!target) {
      container.textContent = _('Enter a domain or IP address');
      return;
    }
    container.textContent = _('Checking…');
    button.disabled = true;
    try {
      // Source, protocol and port are not used by the kernel route lookup.
      const response = await ForkopShellMethods.routeTrace(
        target,
        '',
        'TCP',
        '',
      );
      if (input.value.trim() !== target) return;
      if (!response.success || !response.data?.target) {
        container.textContent = _('Enter a valid domain or IP address');
        return;
      }
      const hasMonitoring = Boolean(
        document.querySelector(MONITORING_TAB_LINK),
      );
      container.replaceChildren(
        E(
          'dl',
          { class: 'fkp-route__facts' },
          routeFacts(response.data).flatMap((fact) => [
            E('dt', {}, fact.label),
            E('dd', {}, [
              E('span', { class: `fkp-diag-text--${fact.tone}` }, fact.value),
              fact.note ? E('small', {}, fact.note) : '',
            ]),
          ]),
        ),
        E('p', { class: 'fkp-diag-hint' }, [
          _(
            'The Forkop rule and outbound are only known for a real connection. The check runs on the router and does not prove the path of a LAN client.',
          ),
          ' ',
          hasMonitoring
            ? E(
                'button',
                {
                  type: 'button',
                  class: 'btn cbi-button',
                  click: openMonitoring,
                },
                _('Trace a real connection in Monitoring'),
              )
            : '',
        ]),
      );
    } finally {
      button.disabled = false;
    }
  };
}
