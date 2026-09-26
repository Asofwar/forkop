import { ForkopShellMethods } from '../../methods';

interface Target {
  host: string;
  type: 'DNS' | 'TCP' | 'TLS' | 'HTTP';
  port: string;
}
const KEY = 'forkop.connectivity.targets';
const DEFAULTS: Target[] = [
  { host: 'cloudflare.com', type: 'TCP', port: '443' },
  { host: 'telegram.org', type: 'TCP', port: '443' },
];

export function loadTargets(storage: Pick<Storage, 'getItem'>): Target[] {
  try {
    const value = JSON.parse(storage.getItem(KEY) || 'null');
    if (Array.isArray(value))
      return value
        .slice(0, 10)
        .filter(
          (item) =>
            typeof item.host === 'string' &&
            item.host.length <= 253 &&
            ['DNS', 'TCP', 'TLS', 'HTTP'].includes(item.type) &&
            typeof item.port === 'string' &&
            item.port.length <= 5,
        );
  } catch (_error) {
    /* use defaults */
  }
  return DEFAULTS;
}

export function initConnectivityMatrix() {
  const root = document.getElementById('connectivity-rows');
  const add = document.getElementById('connectivity-add');
  const run = document.getElementById(
    'connectivity-run',
  ) as HTMLButtonElement | null;
  if (!root || !add || !run || add.onclick) return;
  const targets = loadTargets(localStorage);
  const save = () => localStorage.setItem(KEY, JSON.stringify(targets));
  const render = () => {
    root.replaceChildren(
      ...targets.map((target, index) => {
        const host = E('input', {
          class: 'cbi-input-text',
          value: target.host,
          placeholder: _('Host'),
        }) as HTMLInputElement;
        const type = E(
          'select',
          {},
          ['DNS', 'TCP', 'TLS', 'HTTP'].map((kind) =>
            E('option', { value: kind, selected: target.type === kind }, kind),
          ),
        ) as HTMLSelectElement;
        const port = E('input', {
          class: 'cbi-input-text',
          value: target.port,
          type: 'number',
          min: '1',
          max: '65535',
        }) as HTMLInputElement;
        const result = E('span', { role: 'status' });
        host.onchange = () => {
          target.host = host.value.trim();
          save();
        };
        type.onchange = () => {
          target.type = type.value as Target['type'];
          save();
        };
        port.onchange = () => {
          target.port = port.value;
          save();
        };
        const remove = E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button',
            click: () => {
              targets.splice(index, 1);
              save();
              render();
            },
          },
          _('Remove'),
        );
        return E('div', { class: 'fkp-connectivity-row' }, [
          host,
          type,
          port,
          remove,
          result,
        ]);
      }),
    );
  };
  add.onclick = () => {
    if (targets.length >= 10) return;
    targets.push({ host: '', type: 'TCP', port: '443' });
    save();
    render();
  };
  run.onclick = async () => {
    run.disabled = true;
    const rows = Array.from(root.children);
    try {
      for (const [index, target] of targets.entries()) {
        const result = rows[index]?.lastElementChild;
        const response = await ForkopShellMethods.connectivityTest(
          target.host,
          target.type,
          target.port,
        );
        if (result)
          result.textContent =
            response.success && response.data
              ? `${response.data.type === 'TLS' ? _('HTTPS request (TLS and HTTP)') : response.data.type}: ${response.data.status} · ${response.data.latency_ms} ms · ${_('router')}`
              : _('Test failed');
      }
    } finally {
      run.disabled = false;
    }
  };
  render();
}
