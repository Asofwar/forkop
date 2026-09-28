import { getForkopPage } from '../services/forkopPage';

export function isActiveLuciTab(tabId: string) {
  if (getForkopPage() === tabId) {
    return true;
  }

  if (typeof document === 'undefined') {
    return false;
  }

  return Boolean(
    document.querySelector(
      `.cbi-tab[data-tab="${tabId}"]:not(.cbi-tab-disabled)`,
    ),
  );
}
