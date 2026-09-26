import { describe, expect, it } from 'vitest';
import { matchesConnectionFilters, trafficSortValue } from '../connectionView';

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
