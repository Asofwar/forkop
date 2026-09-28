export function matchesConnectionFilters(
  values: Record<string, string>,
  filters: Record<string, string>,
) {
  return Object.keys(filters).every(
    (key) =>
      !filters[key] ||
      values[key]?.toLowerCase().includes(filters[key].toLowerCase()),
  );
}

export function trafficSortValue(
  connection: { download?: number; upload?: number },
  mode: string,
) {
  if (mode === 'download') return connection.download || 0;
  if (mode === 'upload') return connection.upload || 0;
  if (mode === 'total')
    return (connection.download || 0) + (connection.upload || 0);
  return null;
}

export type ConnectionActionKind = 'details' | 'trace' | 'copy' | 'close';

export interface ConnectionAction {
  kind: ConnectionActionKind;
  label: string;
  className: string;
}

// Every row action is a compact icon button with a text label for the tooltip
// and screen readers, so all of them fit the actions column at any width.
// Read-only sessions cannot close connections.
export function connectionActions(
  active: boolean,
  readonly = false,
): ConnectionAction[] {
  const actions: ConnectionAction[] = [
    {
      kind: 'details',
      label: _('Details'),
      className: 'fkp-monitoring-details',
    },
    { kind: 'trace', label: _('Trace'), className: 'fkp-monitoring-trace' },
    {
      kind: 'copy',
      label: _('Copy details'),
      className: 'fkp-monitoring-copy',
    },
  ];
  if (active && !readonly)
    actions.push({
      kind: 'close',
      label: _('Close connection'),
      className: 'fkp_monitoring-page__row-action',
    });
  return actions;
}
