import { describe, expect, it } from 'vitest';
import { healthItems } from '../health';
import { Forkop } from '../../../types';

describe('health items', () => {
  it('keeps the observed guard separate from other unknown checks', () => {
    const value = {
      service: { forkop: 'ok', sing_box: 'ok' },
      dns: { status: 'ok' },
      dpi: { status: 'transitioning' },
      lists: { status: 'unknown' },
    } as Forkop.HealthStatus;
    expect(healthItems(value)).toEqual([
      { label: 'Forkop', status: 'ok' },
      { label: 'sing-box', status: 'ok' },
      { label: 'DNS', status: 'ok' },
      { label: 'DPI', status: 'transitioning' },
      { label: 'Lists', status: 'unknown' },
    ]);
  });
});
