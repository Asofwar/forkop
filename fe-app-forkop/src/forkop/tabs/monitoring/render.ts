import { isReadonlyMode } from '../../services/accessMode.service';

export function render() {
  return E(
    'div',
    {
      id: 'monitoring-status',
      class: 'fkp_monitoring-page',
    },
    [
      E('div', { class: 'fkp_monitoring-page__panel' }, [
        E('div', { class: 'fkp_monitoring-page__controls' }, [
          E('div', { class: 'fkp_monitoring-page__tabs' }, [
            E(
              'button',
              {
                id: 'monitoring-tab-active',
                class:
                  'btn cbi-button fkp_monitoring-page__tab fkp_monitoring-page__tab--active',
                type: 'button',
              },
              `${_('Active')} 0`,
            ),
            E(
              'button',
              {
                id: 'monitoring-tab-closed',
                class: 'btn cbi-button fkp_monitoring-page__tab',
                type: 'button',
              },
              `${_('Closed')} 0`,
            ),
          ]),
          E('div', { class: 'fkp_monitoring-page__filters' }, [
            E(
              'select',
              {
                id: 'monitoring-device-filter',
                class: 'cbi-input-select fkp_monitoring-page__device-filter',
              },
              [E('option', { value: 'all' }, _('All'))],
            ),
            ...[
              ['protocol', _('Protocol')],
              ['route', _('Route')],
              ['outbound', _('Outbound')],
              ['rule', _('Rule')],
            ].map(([id, label]) =>
              E('input', {
                id: `monitoring-${id}-filter`,
                class: 'cbi-input-text',
                placeholder: label,
                'aria-label': label,
              }),
            ),
            E(
              'select',
              {
                id: 'monitoring-sort',
                class: 'cbi-input-select',
                'aria-label': _('Sort connections'),
              },
              [
                E('option', { value: 'start' }, _('Start time')),
                E('option', { value: 'duration' }, _('Duration')),
                E('option', { value: 'download' }, _('Download')),
                E('option', { value: 'upload' }, _('Upload')),
                E('option', { value: 'total' }, _('Total traffic')),
              ],
            ),
            E('label', { class: 'fkp_monitoring-page__search' }, [
              E('span', { class: 'fkp_monitoring-page__search-icon' }, []),
              E('input', {
                id: 'monitoring-search',
                class: 'cbi-input-text fkp_monitoring-page__search-input',
                type: 'search',
                placeholder: _('Search'),
                autocomplete: 'off',
              }),
            ]),
          ]),
          E('div', { class: 'fkp_monitoring-page__actions' }, [
            ...(isReadonlyMode()
              ? []
              : [
                  E(
                    'button',
                    {
                      id: 'monitoring-close-all',
                      class: 'btn cbi-button fkp_monitoring-page__icon-button',
                      title: _('Close all connections'),
                      'aria-label': _('Close all connections'),
                      type: 'button',
                      disabled: true,
                    },
                    [],
                  ),
                ]),
            E(
              'button',
              {
                id: 'monitoring-pause-toggle',
                class: 'btn cbi-button fkp_monitoring-page__icon-button',
                title: _('Pause updates'),
                'aria-label': _('Pause updates'),
                type: 'button',
              },
              [],
            ),
          ]),
        ]),
        E(
          'div',
          { id: 'monitoring-connections', class: 'fkp_monitoring-page__body' },
          [
            E(
              'div',
              {
                class:
                  'fkp_monitoring-page__state fkp_monitoring-page__state--loading',
              },
              _('Loading connections'),
            ),
          ],
        ),
        E('div', { id: 'monitoring-connection-details', role: 'region' }),
      ]),
    ],
  );
}
