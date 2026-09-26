import { beforeEach, describe, expect, it, vi } from 'vitest';

const connectivityTest = vi.fn();
vi.mock('../../../methods', () => ({
  ForkopShellMethods: {
    connectivityTest: (...args: unknown[]) => connectivityTest(...args),
  },
}));
vi.mock('../../../../icons', () => {
  const icon = () => 'svg';
  return {
    renderCheckIcon24: icon,
    renderCircleAlertIcon24: icon,
    renderCircleCheckIcon24: icon,
    renderCircleSlashIcon24: icon,
    renderCircleXIcon24: icon,
    renderLoaderCircleIcon24: icon,
    renderTriangleAlertIcon24: icon,
    renderXIcon24: icon,
    renderSearchIcon24: icon,
  };
});
vi.mock('../../../../partials', () => ({ renderButton: () => 'button' }));

(globalThis as unknown as { document: unknown }).document = {
  querySelector: () => null,
};

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
  appendChild(child: unknown): void;
}
(globalThis as unknown as { E: unknown }).E = (
  tag: string,
  attrs: Record<string, unknown> = {},
  children: unknown = [],
): FakeNode => ({
  tag,
  attrs,
  children: Array.isArray(children) ? children : [children],
  appendChild(child) {
    this.children.push(child);
  },
});

function walk(node: unknown, visit: (node: FakeNode) => void) {
  if (!node || typeof node !== 'object') return;
  const fake = node as FakeNode;
  visit(fake);
  for (const child of fake.children || []) walk(child, visit);
}
function ids(node: unknown) {
  const found: string[] = [];
  walk(
    node,
    (n) => typeof n.attrs?.id === 'string' && found.push(n.attrs.id as string),
  );
  return found;
}
function text(node: unknown): string {
  if (typeof node === 'string') return node;
  if (!node || typeof node !== 'object') return '';
  return ((node as FakeNode).children || []).map(text).join(' ');
}

import {
  changeType,
  loadTargets,
  probe,
  resultView,
  validateTarget,
  type Target,
} from '../connectivityMatrix';
import { routeFacts } from '../routeDebugger';
import { recentEvents, recoveryRows } from '../safetyCenter';
import { validationView } from '../dpiPlayground';
import { checkStatus, eventStatus, healthStatus } from '../statusLabels';
import {
  checkDetailsOpen,
  diagnosticActionSummary,
  renderCheckSection,
} from '../partials/renderCheckSection';
import { lastRunText, saveLastRun } from '../partials/renderRunAction';
import { render } from '../renderDiagnostic';
import { setReadonlyMode } from '../../../services/accessMode.service';
import type { Forkop } from '../../../types';

const target = (overrides: Partial<Target> = {}): Target => ({
  host: 'example.org',
  type: 'HTTPS',
  port: '443',
  ...overrides,
});
const result = (
  overrides: Partial<Forkop.ConnectivityResult> = {},
): Forkop.ConnectivityResult => ({
  host: 'example.org',
  type: 'HTTPS',
  port: 443,
  status: 'ok',
  error: null,
  latency_ms: 42,
  origin: 'router',
  ...overrides,
});

describe('connectivity rows', () => {
  it('defaults to HTTPS targets and migrates stored TLS rows', () => {
    expect(loadTargets({ getItem: () => null })).toEqual([
      { host: 'cloudflare.com', type: 'HTTPS', port: '443' },
      { host: 'telegram.org', type: 'HTTPS', port: '443' },
    ]);
    const stored = [{ host: 'a.example', type: 'TLS', port: '443' }];
    expect(loadTargets({ getItem: () => JSON.stringify(stored) })[0].type).toBe(
      'HTTPS',
    );
    const many = Array.from({ length: 12 }, (_, i) => ({
      host: `h${i}.example`,
      type: 'TCP',
      port: '443',
    }));
    many[1].host = 'x'.repeat(254);
    expect(loadTargets({ getItem: () => JSON.stringify(many) })).toHaveLength(
      9,
    );
    expect(loadTargets({ getItem: () => '{broken' })).toHaveLength(2);
  });

  it('follows type defaults but keeps a port the user typed', () => {
    expect(changeType(target({ type: 'HTTP', port: '80' }), 'HTTPS').port).toBe(
      '443',
    );
    expect(
      changeType(target({ type: 'HTTPS', port: '443' }), 'HTTP').port,
    ).toBe('80');
    expect(
      changeType(target({ type: 'HTTP', port: '8080' }), 'HTTPS').port,
    ).toBe('8080');
    expect(changeType(target({ type: 'HTTPS', port: '443' }), 'DNS').port).toBe(
      '',
    );
    expect(changeType(target({ type: 'DNS', port: '' }), 'HTTPS').port).toBe(
      '443',
    );
    expect(changeType(target({ type: 'HTTPS', port: '443' }), 'TCP').port).toBe(
      '443',
    );
    expect(changeType(target({ type: 'DNS', port: '' }), 'TCP').port).toBe('');
  });

  it('validates input before calling the router', () => {
    expect(validateTarget(target({ host: ' ' }))).toBe('Enter an address');
    expect(
      validateTarget(target({ type: 'DNS', host: '192.0.2.1', port: '' })),
    ).toBe('DNS check needs a domain name');
    expect(validateTarget(target({ type: 'DNS', port: '' }))).toBeNull();
    expect(validateTarget(target({ type: 'TCP', port: '' }))).toBe(
      'Enter a port',
    );
    expect(validateTarget(target({ port: '70000' }))).toBe(
      'Port must be between 1 and 65535',
    );
    expect(validateTarget(target({ host: '2001:db8::1' }))).toBeNull();
  });

  it('renders human-readable results without raw enums or JSON', () => {
    expect(resultView({ state: 'idle' })).toEqual({
      text: 'Not checked',
      tone: 'neutral',
    });
    expect(resultView({ state: 'running' })).toEqual({
      text: 'Checking…',
      tone: 'loading',
    });
    const ok = resultView({
      state: 'done',
      result: result({ http_code: 301 }),
    });
    expect(ok).toEqual({
      text: '✓ Reachable · 42 ms · HTTP 301',
      tone: 'success',
    });
    const dns = resultView({
      state: 'done',
      result: result({ type: 'DNS', port: null, address: '93.184.216.34' }),
    });
    expect(dns.text).toContain('93.184.216.34');
    const cases: Array<[Forkop.ConnectivityResult['error'], string]> = [
      ['timeout', 'Timed out'],
      ['nxdomain', 'Domain does not exist'],
      ['dns_failed', 'DNS name did not resolve'],
      ['connect_failed', 'Connection refused or host unreachable'],
      ['tls_failed', 'TLS or certificate error'],
      ['no_response', 'Server closed the connection without a response'],
      ['tool_missing', 'Probe tool is missing on the router'],
    ];
    for (const [error, message] of cases) {
      const view = resultView({
        state: 'done',
        result: result({
          status: error === 'timeout' ? 'timeout' : 'error',
          error,
        }),
      });
      expect(view.text).toBe(`✕ ${message}`);
      expect(view.text).not.toMatch(
        /[{}]|\b(connect_failed|tls_failed|nxdomain|no_response)\b/,
      );
    }
  });

  beforeEach(() => connectivityTest.mockReset());

  it('never calls the router for invalid rows and sends DNS without a port', async () => {
    expect(await probe(target({ host: '' }))).toEqual({
      state: 'invalid',
      message: 'Enter an address',
    });
    expect(connectivityTest).not.toHaveBeenCalled();
    connectivityTest.mockResolvedValue({
      success: true,
      data: result({ type: 'DNS', port: null }),
    });
    await probe(target({ type: 'DNS', port: '' }));
    expect(connectivityTest).toHaveBeenCalledWith('example.org', 'DNS', '');
  });

  it('only accepts a result whose type and port match the request', async () => {
    connectivityTest.mockResolvedValue({
      success: true,
      data: result({ type: 'TCP' }),
    });
    expect(await probe(target())).toEqual({ state: 'idle' });
    connectivityTest.mockResolvedValue({
      success: true,
      data: result({ port: 8443 }),
    });
    expect(await probe(target())).toEqual({ state: 'idle' });
    connectivityTest.mockResolvedValue({ success: true, data: result() });
    expect(await probe(target())).toMatchObject({ state: 'done' });
    connectivityTest.mockResolvedValue({ success: false, error: 'denied' });
    expect(await probe(target())).toEqual({
      state: 'invalid',
      message: 'The router rejected this check',
    });
  });
});

describe('route check', () => {
  const unknown = { value: null, provenance: 'unknown' as const };
  const trace = (
    overrides: Partial<Forkop.RouteTrace> = {},
  ): Forkop.RouteTrace => ({
    target: {
      value: 'example.org',
      source: '',
      source_applied: false,
      protocol: 'TCP',
      port: '',
      provenance: 'simulated',
    },
    dns: { address: '93.184.216.34', provenance: 'observed' },
    rule: unknown,
    action: unknown,
    outbound: unknown,
    dpi: unknown,
    interface: {
      value: 'pppoe-wan',
      provenance: 'observed',
      context: 'router',
    },
    runtime: unknown,
    ...overrides,
  });

  it('shows only established facts, never permanent unknown rows', () => {
    const facts = routeFacts(trace());
    expect(facts.map((fact) => fact.label)).toEqual([
      'Domain',
      'Resolved IP',
      'Router kernel route',
    ]);
    expect(facts.map((fact) => fact.value)).toEqual([
      'example.org',
      '93.184.216.34',
      'pppoe-wan',
    ]);
    expect(JSON.stringify(facts)).not.toMatch(
      /Unknown|unknown|Matched rule|Outbound/,
    );
  });

  it('describes an IP literal and an unresolved domain truthfully', () => {
    const literal = routeFacts(
      trace({
        target: { ...trace().target, value: '1.1.1.1' },
        dns: { address: '1.1.1.1', provenance: 'simulated' },
      }),
    );
    expect(literal.map((fact) => fact.label)).toEqual([
      'IP address',
      'Router kernel route',
    ]);
    const unresolved = routeFacts(
      trace({
        dns: { address: null, provenance: 'unknown' },
        interface: { value: null, provenance: 'unknown' },
      }),
    );
    expect(unresolved.map((fact) => [fact.label, fact.value])).toEqual([
      ['Domain', 'example.org'],
      ['Resolved IP', 'Not resolved'],
    ]);
  });

  it('keeps provenance of additional stages and never upgrades simulated', () => {
    const facts = routeFacts(
      trace({
        outbound: { value: 'main', provenance: 'configured' },
        rule: { value: 'ru-block', provenance: 'simulated' },
        dpi: { value: 'zapret', provenance: 'observed' },
      }),
    );
    expect(facts.find((f) => f.label === 'Outbound')?.note).toBe(
      'Derived from configuration',
    );
    expect(facts.find((f) => f.label === 'Matched rule')?.note).toBe(
      'Calculated result',
    );
    expect(facts.find((f) => f.label === 'DPI provider')?.note).toBe(
      'Seen in an active connection',
    );
  });
});

describe('recovery and statuses', () => {
  const health = (
    overrides: Partial<Forkop.HealthStatus> = {},
  ): Forkop.HealthStatus => ({
    overall: 'ok',
    service: { forkop: 'ok', sing_box: 'ok' },
    dns: { status: 'unknown' },
    dpi: { status: 'unknown' },
    lists: { status: 'unknown' },
    guard: { active: false },
    recovery: {
      pending: false,
      last_event: { kind: 'start', status: 'success', timestamp: 1 },
    },
    package_recovery: { pending: false },
    last_reload: { status: 'success', timestamp: 2 },
    recent_activity: [
      { kind: 'start', status: 'success', timestamp: 1 },
      { kind: 'reload', status: 'success', timestamp: 2 },
    ],
    ...overrides,
  });

  it('shows only recovery facts, localized, without duplicating Dashboard health', () => {
    const rows = recoveryRows(health());
    expect(rows.map(([label]) => label)).toEqual([
      'DPI guard',
      'Last recovery',
      'Package recovery',
      'Last reload',
    ]);
    expect(rows[0][1].text).toBe('Inactive');
    expect(rows[1][1].text).toBe('Not needed');
    expect(rows[3][1].text).toMatch(/^Succeeded · /);
    for (const [, status] of rows)
      expect(status.text).not.toMatch(/^(ok|success|unknown|failure)$/);
  });

  it('maps active guard, recoveries and failures', () => {
    const rows = recoveryRows(
      health({
        guard: { active: true },
        recovery: {
          pending: false,
          last_event: { kind: 'restore', status: 'recovered', timestamp: 3 },
        },
        package_recovery: { pending: true },
        last_reload: null,
      }),
    );
    expect(rows[0][1]).toMatchObject({
      text: 'Active: DPI switch not confirmed',
      tone: 'warning',
    });
    expect(rows[1][1].text).toMatch(/^Snapshot restore: Recovered · /);
    expect(rows[2][1].text).toBe('Waiting to finish');
    expect(rows[3][1].text).toBe('No reload recorded yet');
    expect(recentEvents(health())[0]).toMatchObject({
      kind: 'Configuration reload',
      status: { text: 'Succeeded' },
    });
  });

  it('uses the shared status vocabulary', () => {
    expect(eventStatus('success').text).toBe('Succeeded');
    expect(eventStatus('failure').text).toBe('Failed');
    expect(eventStatus('recovered').text).toBe('Recovered');
    expect(eventStatus('needs_attention').text).toBe('Needs attention');
    expect(healthStatus('ok').text).toBe('Healthy');
    expect(healthStatus('unknown').text).toBe('Not available for checking');
    expect(checkStatus('skipped').text).toBe('Not checked');
    expect(checkStatus('loading').text).toBe('Checking…');
    expect(checkStatus('warning').text).toBe('Needs attention');
  });
});

describe('DPI syntax check', () => {
  it('reports a human-readable verdict', () => {
    expect(
      validationView({ success: true, data: { valid: true, message: '' } }),
    ).toEqual({
      text: '✓ Syntax is correct',
      tone: 'success',
    });
    expect(
      validationView({
        success: true,
        data: { valid: false, message: "Unknown NFQWS flag '--x'." },
      }).text,
    ).toBe("✕ Unknown NFQWS flag '--x'.");
    expect(validationView({ success: false }).text).toBe(
      'Syntax check is unavailable',
    );
    expect(validationView({ success: true, data: 'garbage' }).tone).toBe(
      'error',
    );
  });
});

describe('system checks', () => {
  it('renders a compact item with a localized status and opens details on problems', () => {
    const failed = renderCheckSection({
      order: 1,
      code: 'DNS',
      title: 'DNS checks',
      description: 'Checks failed',
      state: 'error',
      items: [{ key: 'Bootstrap', value: 'timeout', state: 'error' }],
    });
    expect(text(failed)).toContain('Error');
    let details: FakeNode | undefined;
    walk(failed, (n) => n.tag === 'details' && (details = n));
    expect(details?.attrs.open).toBe(true);
    expect(checkDetailsOpen('success')).toBe(false);
    const idle = renderCheckSection({
      order: 1,
      code: 'DNS',
      title: 'DNS checks',
      description: 'Not running',
      state: 'skipped',
      items: [],
    });
    expect(text(idle)).toContain('Not checked');
    walk(idle, (n) => expect(n.tag).not.toBe('details'));
  });

  it('keeps failed detail available for copying and records the last run', () => {
    const value = diagnosticActionSummary({
      title: 'Bootstrap DNS failed',
      description: '8.8.8.8 timed out',
      items: [{ key: 'DNS', value: 'timeout', state: 'error' }],
    } as Parameters<typeof diagnosticActionSummary>[0]);
    expect(value).toContain('DNS: timeout');
    const store = new Map<string, string>();
    const storage = {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
    };
    expect(lastRunText(storage)).toBe('No check has been run yet');
    saveLastRun(storage, Date.UTC(2026, 8, 27));
    expect(lastRunText(storage)).toMatch(/^Last check: /);
  });
});

describe('page layout', () => {
  it('is a single column without ignored or fake controls', () => {
    setReadonlyMode(false);
    const page = render();
    const found = ids(page);
    expect((page as unknown as FakeNode).attrs.class).toBe('fkp-diag');
    for (const id of [
      'fkp_diagnostic-page-checks',
      'connectivity-rows',
      'trace-target',
      'safety-center',
      'dpi-strategy',
    ])
      expect(found).toContain(id);
    for (const id of [
      'trace-source',
      'trace-protocol',
      'trace-port',
      'dpi-strategy-a',
      'dpi-strategy-b',
    ])
      expect(found).not.toContain(id);
    expect(text(page)).toContain('DPI strategy syntax check');
    expect(text(page)).not.toMatch(/Playground|compare/i);
  });

  it('replaces the DPI validator with an explanation for read-only sessions', () => {
    setReadonlyMode(true);
    const page = render();
    expect(ids(page)).not.toContain('dpi-strategy');
    expect(ids(page)).not.toContain('dpi-validate');
    expect(text(page)).toContain('Available to administrators only.');
    setReadonlyMode(false);
  });
});
