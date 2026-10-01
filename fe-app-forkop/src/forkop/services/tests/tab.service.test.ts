import { describe, expect, it, vi } from 'vitest';

vi.hoisted(() => {
  const g = globalThis as unknown as Record<string, unknown>;
  g.MutationObserver = class {
    observe() {}
    disconnect() {}
  };
  g.document = {
    body: {},
    querySelector: () => null,
    querySelectorAll: () => [],
  };
});

import { TabServiceInstance, setForkopPage } from '../tab.service';

describe('tab service on standalone pages', () => {
  it('reports a page registered before the subscription', () => {
    setForkopPage('monitoring');
    const callback = vi.fn();

    TabServiceInstance.onChange(callback);

    expect(callback).toHaveBeenCalledWith('monitoring', []);
  });

  it('reports a page change after the subscription', () => {
    const callback = vi.fn();
    TabServiceInstance.onChange(callback);
    callback.mockClear();

    setForkopPage('dashboard');

    expect(callback).toHaveBeenCalledWith('dashboard', []);
  });
});
