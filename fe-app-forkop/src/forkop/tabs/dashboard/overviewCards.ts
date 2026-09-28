import { openForkopPage } from '../../helpers/navigation';
import { renderOverflowMenu } from '../../ui/overflowMenu';
import { renderStatus, statusTone } from '../../ui/status';
import type { SemanticStatus } from '../../ui/status';
import type {
  OverviewEvent,
  OverviewLine,
  OverviewRecovery,
  OverviewRouting,
  OverviewState,
  OverviewWarning,
} from './overview';

export interface OverviewViewModel {
  warning: OverviewWarning | null;
  state: OverviewState;
  routing: OverviewRouting;
  recovery: OverviewRecovery;
  event: OverviewEvent | null;
}

export interface OverviewActions {
  readonly: boolean;
  serviceBusy: boolean;
  autostart: boolean;
  onStart: () => void;
  onRestart: () => void;
  onStop: () => void;
  onToggleAutostart: () => void;
}

function statusView(status: SemanticStatus, label: string) {
  return { label, tone: statusTone(status) };
}

function linkButton(label: string, onClick: () => void) {
  return E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button fkp-overview__link',
      click: onClick,
    },
    label,
  );
}

function renderLines(lines: OverviewLine[]) {
  return E(
    'ul',
    { class: 'fkp-overview__lines' },
    lines.map((line) =>
      E(
        'li',
        { class: line.tone ? `fkp-overview__line--${line.tone}` : '' },
        line.text,
      ),
    ),
  );
}

function card(
  title: string,
  body: Node[],
  footer: Node[] = [],
  headerExtra: Node[] = [],
) {
  return E('section', { class: 'fkp-overview__card' }, [
    E('div', { class: 'fkp-overview__head' }, [
      E('h3', { class: 'fkp-overview__title' }, title),
      ...headerExtra,
    ]),
    ...body,
    ...(footer.length
      ? [E('div', { class: 'fkp-overview__footer fkp-actions' }, footer)]
      : []),
  ]);
}

function renderWarning(warning: OverviewWarning) {
  return E('section', { class: 'fkp-overview__warning', role: 'alert' }, [
    E('strong', {}, warning.title),
    E('p', {}, warning.text),
    linkButton(warning.link.label, () => openForkopPage(warning.link.page)),
  ]);
}

function renderStateCard(state: OverviewState, actions: OverviewActions) {
  const footer: Node[] = [];
  const menu: Node[] = [];

  if (!actions.readonly) {
    if (state.stopped) {
      footer.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-action',
            disabled: actions.serviceBusy ? true : undefined,
            click: actions.onStart,
          },
          actions.serviceBusy ? _('Starting…') : _('Start Forkop X'),
        ),
      );
    }
    menu.push(
      renderOverflowMenu(_('Service actions'), [
        ...(state.stopped
          ? []
          : [
              {
                label: _('Restart Forkop X'),
                onClick: actions.onRestart,
                disabled: actions.serviceBusy,
              },
              {
                label: _('Stop Forkop X…'),
                onClick: actions.onStop,
                disabled: actions.serviceBusy,
                danger: true,
              },
            ]),
        {
          label: actions.autostart
            ? _('Disable autostart')
            : _('Enable autostart'),
          onClick: actions.onToggleAutostart,
          disabled: actions.serviceBusy,
        },
      ]),
    );
  }

  return card(
    _('State'),
    [
      E('div', { class: 'fkp-overview__status' }, [
        renderStatus(statusView(state.status, state.title)),
      ]),
      renderLines(state.lines),
    ],
    [
      ...footer,
      linkButton(_('Diagnostics'), () => openForkopPage('diagnostics')),
    ],
    menu,
  );
}

function renderRoutingCard(routing: OverviewRouting, readonly: boolean) {
  return card(
    _('Routing'),
    [
      ...(routing.summary
        ? [E('p', { class: 'fkp-overview__summary' }, routing.summary)]
        : []),
      ...(routing.live
        ? [E('p', { class: 'fkp-overview__hint' }, routing.live)]
        : []),
      ...(routing.groups.length
        ? [
            E(
              'ul',
              { class: 'fkp-overview__groups' },
              routing.groups.map((group) =>
                E('li', {}, [
                  E('span', { class: 'fkp-overview__group-name' }, group.name),
                  E('span', { class: 'fkp-overview__group-node' }, [
                    `${group.node} · `,
                    E(
                      'span',
                      { class: `fkp-status--${group.tone}` },
                      group.latency,
                    ),
                  ]),
                ]),
              ),
            ),
          ]
        : []),
      ...(routing.more
        ? [
            E(
              'p',
              { class: 'fkp-overview__hint' },
              _('%d more groups').replace('%d', String(routing.more)),
            ),
          ]
        : []),
    ],
    [
      linkButton(_('Nodes and groups'), () =>
        openForkopPage('monitoring', { view: 'nodes' }),
      ),
      linkButton(_('Connections'), () => openForkopPage('monitoring')),
      ...(readonly
        ? []
        : [linkButton(_('Rules'), () => openForkopPage('settings'))]),
    ],
  );
}

function renderRecoveryCard(recovery: OverviewRecovery) {
  return card(
    _('Recovery'),
    [
      E('div', { class: 'fkp-overview__status' }, [
        renderStatus(statusView(recovery.status, recovery.title)),
      ]),
      renderLines(recovery.lines),
    ],
    [linkButton(_('Recovery details'), () => openForkopPage('history'))],
  );
}

function renderEventCard(event: OverviewEvent | null) {
  return card(
    _('Last important event'),
    event
      ? [
          E('p', { class: 'fkp-overview__summary' }, [
            `${event.title}: `,
            E(
              'span',
              { class: `fkp-status--${event.outcome.tone}` },
              event.outcome.label,
            ),
          ]),
          E('p', { class: 'fkp-overview__hint' }, event.time),
        ]
      : [E('p', { class: 'fkp-overview__hint' }, _('No events recorded yet'))],
    [linkButton(_('All events'), () => openForkopPage('history'))],
  );
}

export function renderOverview(
  vm: OverviewViewModel,
  actions: OverviewActions,
) {
  return E('div', { class: 'fkp-overview' }, [
    ...(vm.warning ? [renderWarning(vm.warning)] : []),
    E('div', { class: 'fkp-overview__grid' }, [
      renderStateCard(vm.state, actions),
      renderRoutingCard(vm.routing, actions.readonly),
      renderRecoveryCard(vm.recovery),
      renderEventCard(vm.event),
    ]),
  ]);
}
