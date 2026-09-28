import { describe, expect, it } from 'vitest';
import {
  connectionActions,
  matchesConnectionFilters,
  trafficSortValue,
} from '../connectionView';

describe('connection view controls', () => {
  it('filters protocol, route, outbound and rule together', () => {
    const connection = {
      protocol: 'tcp',
      route: 'Telegram',
      outbound: 'Latvia VLESS',
      rule: 'domain_suffix',
    };
    expect(
      matchesConnectionFilters(connection, {
        protocol: 'TCP',
        route: 'tele',
        outbound: 'latvia',
        rule: 'suffix',
      }),
    ).toBe(true);
    expect(matchesConnectionFilters(connection, { outbound: 'germany' })).toBe(
      false,
    );
  });

  it('sorts by the requested traffic metric', () => {
    const connection = { download: 20, upload: 5 };
    expect(trafficSortValue(connection, 'download')).toBe(20);
    expect(trafficSortValue(connection, 'upload')).toBe(5);
    expect(trafficSortValue(connection, 'total')).toBe(25);
    expect(trafficSortValue(connection, 'start')).toBeNull();
  });
});

describe('connection row actions', () => {
  it('offers details, trace, copy and close for active connections', () => {
    const actions = connectionActions(true);
    expect(actions.map((action) => action.kind)).toEqual([
      'details',
      'trace',
      'copy',
      'close',
    ]);
    for (const action of actions) expect(action.label).not.toBe('');
    expect(actions.map((action) => action.className)).toEqual([
      'fkp-monitoring-details',
      'fkp-monitoring-trace',
      'fkp-monitoring-copy',
      'fkp_monitoring-page__row-action',
    ]);
  });

  it('does not offer closing an already closed connection', () => {
    expect(connectionActions(false).map((action) => action.kind)).toEqual([
      'details',
      'trace',
      'copy',
    ]);
  });
  it('does not offer closing a connection to a read-only session', () => {
    expect(connectionActions(true, true).map((action) => action.kind)).toEqual([
      'details',
      'trace',
      'copy',
    ]);
  });
});
