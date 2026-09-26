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
