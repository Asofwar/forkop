import { renderSections } from './partials';

export function render() {
  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'fkp_dashboard-page',
    },
    [
      E(
        'div',
        { id: 'dashboard-overview', role: 'status' },
        E('p', { class: 'fkp-overview__hint' }, _('Loading…')),
      ),
      // Until Monitoring gets its Nodes view (Stage 6.5) node selection
      // stays here, below the summary.
      E('section', { class: 'fkp_dashboard-page__content' }, [
        E(
          'h3',
          { class: 'fkp-overview__section-title' },
          _('Nodes and groups'),
        ),
        E(
          'div',
          { id: 'dashboard-sections-grid' },
          renderSections({
            loading: true,
            failed: false,
            section: {
              code: '',
              sectionName: '',
              displayName: '',
              outbounds: [],
              withTagSelect: false,
            },
            onTestLatency: () => {},
            onChooseOutbound: () => {},
            onShowUrlTestInfo: () => {},
            onShowPriorityInfo: () => {},
            onUpdateSubscription: () => {},
            latencyFetching: false,
            latencyProgress: undefined,
            subscriptionUpdating: false,
            selectorSwitchingTag: undefined,
            isPriorityMembersExpanded: () => false,
            onPriorityMembersToggle: () => {},
          }),
        ),
      ]),
    ],
  );
}
