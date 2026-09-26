import { ForkopShellMethods } from '../../methods';

export function initDpiPlayground() {
  const button = document.getElementById(
    'dpi-validate',
  ) as HTMLButtonElement | null;
  if (!button || button.onclick) return;
  button.onclick = async () => {
    const provider = (
      document.getElementById('dpi-provider') as HTMLSelectElement
    ).value as 'zapret' | 'zapret2' | 'byedpi';
    const a = (document.getElementById('dpi-strategy-a') as HTMLTextAreaElement)
      .value;
    const b = (document.getElementById('dpi-strategy-b') as HTMLTextAreaElement)
      .value;
    const result = document.getElementById('dpi-playground-result');
    if (!result) return;
    button.disabled = true;
    try {
      const values = await Promise.all(
        [a, b].map((strategy) =>
          ForkopShellMethods.validateDpiStrategy(provider, strategy),
        ),
      );
      result.replaceChildren(
        ...values.map((response, index) =>
          E(
            'div',
            {},
            `${index === 0 ? 'A' : 'B'}: ${JSON.stringify(response.success ? response.data : response.error || _('Validation failed'))}`,
          ),
        ),
      );
    } finally {
      button.disabled = false;
    }
  };
}
