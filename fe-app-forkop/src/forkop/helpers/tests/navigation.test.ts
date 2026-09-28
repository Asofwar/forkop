import { afterEach, describe, expect, it } from 'vitest';

import { forkopPageUrl, readPageParams } from '../navigation';
import { isActiveLuciTab } from '../isActiveLuciTab';
import { setStandalonePage } from '../../services/forkopPage';

const g = globalThis as unknown as { L?: unknown };

afterEach(() => {
  delete g.L;
  setStandalonePage(null);
});

describe('Forkop page links', () => {
  it('builds the page URL through LuCI', () => {
    g.L = { url: (...parts: string[]) => `/cgi-bin/luci/${parts.join('/')}` };

    expect(forkopPageUrl('diagnostics')).toBe(
      '/cgi-bin/luci/admin/services/forkop/diagnostics',
    );
  });

  it('carries page parameters in the hash', () => {
    expect(forkopPageUrl('monitoring', { search: 'youtube.com' })).toBe(
      '/cgi-bin/luci/admin/services/forkop/monitoring#search=youtube.com',
    );
    expect(readPageParams('#search=youtube.com&device=192.168.1.2')).toEqual({
      search: 'youtube.com',
      device: '192.168.1.2',
    });
    expect(readPageParams('')).toEqual({});
  });
});

describe('active page without LuCI tabs', () => {
  it('treats the registered page as the active tab', () => {
    expect(isActiveLuciTab('monitoring')).toBe(false);

    setStandalonePage('monitoring');

    expect(isActiveLuciTab('monitoring')).toBe(true);
    expect(isActiveLuciTab('dashboard')).toBe(false);
  });
});
