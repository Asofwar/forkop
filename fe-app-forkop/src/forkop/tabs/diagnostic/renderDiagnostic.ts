import { isReadonlyMode } from '../../services/accessMode.service';

function card(id: string, title: string, hint: string, body: Node[]) {
  return E('section', { class: 'fkp-diag-card', id }, [
    E('h3', { class: 'fkp-diag-card__title' }, title),
    hint ? E('p', { class: 'fkp-diag-hint' }, hint) : '',
    ...body,
  ]);
}

function renderDpiValidator() {
  const explanation = E(
    'p',
    { class: 'fkp-diag-hint' },
    _(
      'Checks that the parameters are valid. It does not test site reachability or bypass effectiveness.',
    ),
  );
  if (isReadonlyMode())
    return [
      explanation,
      E(
        'p',
        { class: 'fkp-diag-hint' },
        _('Available to administrators only.'),
      ),
    ];
  return [
    explanation,
    E('div', { class: 'fkp-diag-form' }, [
      E('label', { class: 'fkp-diag-field' }, [
        E('span', {}, _('Provider')),
        E('select', { id: 'dpi-provider', class: 'cbi-input-select' }, [
          E('option', { value: 'zapret' }, 'Zapret'),
          E('option', { value: 'zapret2' }, 'Zapret2'),
          E('option', { value: 'byedpi' }, 'ByeDPI'),
        ]),
      ]),
      E('label', { class: 'fkp-diag-field fkp-diag-field--wide' }, [
        E('span', {}, _('Strategy')),
        E('textarea', {
          id: 'dpi-strategy',
          class: 'cbi-input-textarea',
          maxLength: 4096,
          rows: 3,
          spellcheck: false,
        }),
      ]),
    ]),
    E('div', { class: 'fkp-diag-actions' }, [
      E(
        'button',
        { id: 'dpi-validate', type: 'button', class: 'btn cbi-button' },
        _('Check'),
      ),
      E('span', { id: 'dpi-playground-result', role: 'status' }),
    ]),
  ];
}

export function render() {
  return E('div', { id: 'diagnostic-status', class: 'fkp-diag' }, [
    E('section', { class: 'fkp-diag-card fkp-diag-system' }, [
      E('div', { class: 'fkp-diag-card__head' }, [
        E('div', {}, [
          E('h3', { class: 'fkp-diag-card__title' }, _('System diagnostics')),
          E('span', {
            id: 'fkp_diagnostic-last-run',
            class: 'fkp-diag-hint',
            role: 'status',
          }),
        ]),
        E('div', { id: 'fkp_diagnostic-page-run-check' }),
      ]),
      E('div', {
        class: 'fkp-diag-checks',
        id: 'fkp_diagnostic-page-checks',
      }),
    ]),
    E('div', { class: 'fkp-diag-row' }, [
      E('div', { id: 'fkp_diagnostic-page-actions' }),
      E('div', { id: 'fkp_diagnostic-page-system-info' }),
    ]),
    card(
      'connectivity-matrix',
      _('Reachability check'),
      _('Checks run on the router and do not prove the path of a LAN client.'),
      [
        E('div', { id: 'connectivity-rows', class: 'fkp-conn', role: 'table' }),
        E('div', { class: 'fkp-diag-actions' }, [
          E(
            'button',
            { id: 'connectivity-add', type: 'button', class: 'btn cbi-button' },
            `+ ${_('Add address')}`,
          ),
          E(
            'button',
            {
              id: 'connectivity-run',
              type: 'button',
              class: 'btn cbi-button cbi-button-apply',
            },
            _('Check all'),
          ),
        ]),
      ],
    ),
    card(
      'route-debugger',
      _('Route check'),
      _(
        'Shows the address the router DNS returns and the interface of the router kernel route.',
      ),
      [
        E('div', { class: 'fkp-route__form' }, [
          E('label', { class: 'fkp-diag-field fkp-diag-field--wide' }, [
            E('span', {}, _('Domain or IP address')),
            E('input', {
              id: 'trace-target',
              class: 'cbi-input-text',
              placeholder: 'example.com',
              maxLength: 253,
            }),
          ]),
          E(
            'button',
            { id: 'trace-run', class: 'btn cbi-button', type: 'button' },
            _('Check'),
          ),
        ]),
        E('div', { id: 'trace-result', role: 'status' }),
      ],
    ),
    E('h3', { class: 'fkp-diag-section-title' }, _('Additional tools')),
    E(
      'details',
      { class: 'fkp-diag-card fkp-diag-details', id: 'safety-center' },
      [
        E('summary', {}, _('Recovery and protection')),
        E('div', { id: 'safety-center-state', role: 'status' }, _('Loading…')),
        E('div', { class: 'fkp-diag-actions' }, [
          E(
            'button',
            {
              id: 'safety-center-refresh',
              type: 'button',
              class: 'btn cbi-button',
            },
            _('Refresh state'),
          ),
        ]),
      ],
    ),
    E(
      'details',
      { class: 'fkp-diag-card fkp-diag-details', id: 'dpi-playground' },
      [
        E('summary', {}, _('DPI strategy syntax check')),
        ...renderDpiValidator(),
      ],
    ),
    E('div', { id: 'fkp_diagnostic-page-wiki' }),
  ]);
}
