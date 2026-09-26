import { describe, expect, it, vi } from 'vitest';
vi.mock('../../../methods', () => ({ ForkopShellMethods: {} }));
vi.mock('../../../../icons', () => ({}));
import { routeStages } from '../routeDebugger';
import { loadTargets } from '../connectivityMatrix';
import { safetyRows } from '../safetyCenter';
import { diagnosticActionSummary } from '../partials/renderCheckSection';
import type { Forkop } from '../../../types';

describe('observability presentation', () => {
  it('keeps unknown route stages distinct from observed DNS and interface', () => {
    const unknown = { value: null, provenance: 'unknown' as const };
    const trace = {
      target: {
        value: 'example.org',
        source: '',
        source_applied: false,
        protocol: 'TCP',
        port: '443',
        provenance: 'simulated',
      },
      dns: { address: '93.184.215.14', provenance: 'observed' },
      rule: unknown,
      action: unknown,
      outbound: unknown,
      dpi: unknown,
      interface: { value: 'wan', provenance: 'observed', context: 'router' },
      runtime: unknown,
    } satisfies Forkop.RouteTrace;
    const stages = routeStages(trace);
    expect(stages).toHaveLength(8);
    expect(stages[1].stage.provenance).toBe('observed');
    expect(stages[2].stage.provenance).toBe('unknown');
    expect(stages[6].stage.provenance).toBe('observed');
  });

  it('drops malformed browser-stored targets and bounds the matrix', () => {
    const stored = Array.from({ length: 12 }, (_, index) => ({
      host: `host${index}.example`,
      type: 'TCP',
      port: '443',
    }));
    stored[1].host = 'x'.repeat(254);
    expect(loadTargets({ getItem: () => JSON.stringify(stored) })).toHaveLength(
      9,
    );
    expect(loadTargets({ getItem: () => '{broken' })).toHaveLength(2);
  });

  it('shows an active guard and unconfirmed reload as distinct facts', () => {
    const health = {
      overall: 'error',
      service: { forkop: 'ok', sing_box: 'ok' },
      dns: { status: 'ok' },
      dpi: { status: 'transitioning' },
      guard: { active: true },
      package_recovery: { pending: false },
      last_reload: null,
    } as Forkop.HealthStatus;
    const rows = safetyRows(health);
    expect(rows.find(([label]) => label === 'DPI guard')?.[1]).toBe('Active');
    expect(rows.find(([label]) => label === 'Last reload')?.[1]).toBe(
      'Unknown',
    );
  });

  it('keeps the failed check detail available for copying', () => {
    const value = diagnosticActionSummary({
      title: 'Bootstrap DNS failed',
      description: '8.8.8.8 timed out',
      items: [{ key: 'DNS', value: 'timeout', state: 'error' }],
    } as Parameters<typeof diagnosticActionSummary>[0]);
    expect(value).toContain('Bootstrap DNS failed');
    expect(value).toContain('DNS: timeout');
  });
});
