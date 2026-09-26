export function render() {
  return E('div', { id: 'diagnostic-status', class: 'fkp_diagnostic-page' }, [
    E('div', { class: 'fkp_diagnostic-page__left-bar' }, [
      E('div', { id: 'fkp_diagnostic-page-run-check' }),
      E('div', {
        class: 'fkp_diagnostic-page__checks',
        id: 'fkp_diagnostic-page-checks',
      }),
    ]),
    E('div', { class: 'fkp_diagnostic-page__right-bar' }, [
      E('section', { class: 'fkp-tool', id: 'safety-center' }, [
        E('h3', {}, _('Safety Center')),
        E(
          'div',
          { id: 'safety-center-state', role: 'status' },
          _('Loading health status'),
        ),
        E(
          'button',
          {
            id: 'safety-center-refresh',
            type: 'button',
            class: 'btn cbi-button',
          },
          _('Refresh safety status'),
        ),
      ]),
      E('section', { class: 'fkp-tool', id: 'dpi-playground' }, [
        E('h3', {}, _('DPI Strategy Playground')),
        E('select', { id: 'dpi-provider' }, [
          E('option', { value: 'zapret' }, 'Zapret'),
          E('option', { value: 'zapret2' }, 'Zapret2'),
          E('option', { value: 'byedpi' }, 'ByeDPI'),
        ]),
        E('label', {}, [
          _('Strategy A'),
          E('textarea', { id: 'dpi-strategy-a', maxLength: 4096 }),
        ]),
        E('label', {}, [
          _('Strategy B'),
          E('textarea', { id: 'dpi-strategy-b', maxLength: 4096 }),
        ]),
        E(
          'button',
          { id: 'dpi-validate', type: 'button', class: 'btn cbi-button' },
          _('Validate and compare'),
        ),
        E('div', { id: 'dpi-playground-result', role: 'status' }),
        E(
          'p',
          {},
          _(
            'Runtime test is unavailable without changing the active configuration. Comparison covers validation only.',
          ),
        ),
      ]),
      E('section', { class: 'fkp-tool', id: 'connectivity-matrix' }, [
        E('h3', {}, _('Connectivity matrix')),
        E(
          'p',
          {},
          _(
            'Tests originate from the router and do not prove LAN client routing.',
          ),
        ),
        E('div', { id: 'connectivity-rows' }),
        E(
          'button',
          { id: 'connectivity-add', type: 'button', class: 'btn cbi-button' },
          _('Add target'),
        ),
        E(
          'button',
          { id: 'connectivity-run', type: 'button', class: 'btn cbi-button' },
          _('Run tests'),
        ),
      ]),
      E('section', { class: 'fkp-tool', id: 'route-debugger' }, [
        E('h3', {}, _('Route Debugger')),
        E('label', {}, [
          _('Target domain or IP'),
          E('input', { id: 'trace-target', class: 'cbi-input-text' }),
        ]),
        E('label', {}, [
          _('Source IP (optional)'),
          E('input', { id: 'trace-source', class: 'cbi-input-text' }),
        ]),
        E('label', {}, [
          _('Protocol'),
          E('select', { id: 'trace-protocol' }, [
            E('option', { value: 'TCP' }, 'TCP'),
            E('option', { value: 'UDP' }, 'UDP'),
          ]),
        ]),
        E('label', {}, [
          _('Port (optional)'),
          E('input', {
            id: 'trace-port',
            class: 'cbi-input-text',
            type: 'number',
            min: '1',
            max: '65535',
          }),
        ]),
        E(
          'button',
          { id: 'trace-run', class: 'btn cbi-button', type: 'button' },
          _('Trace'),
        ),
        E('div', { id: 'trace-result', role: 'status' }),
      ]),
      E('div', { id: 'fkp_diagnostic-page-wiki' }),
      E('div', { id: 'fkp_diagnostic-page-actions' }),
      E('div', { id: 'fkp_diagnostic-page-system-info' }),
    ]),
  ]);
}
