// Deep links between Forkop pages (admin/services/forkop/<page>). Page
// parameters travel in the URL hash, so a reload or a shared link keeps them.
export type ForkopPage =
  | 'overview'
  | 'monitoring'
  | 'diagnostics'
  | 'autotune'
  | 'history'
  | 'settings';

const FORKOP_MENU_PATH = 'admin/services/forkop';

interface LuciUrlBuilder {
  url?: (...parts: string[]) => string;
}

function luci(): LuciUrlBuilder | undefined {
  return (globalThis as unknown as { L?: LuciUrlBuilder }).L;
}

export function forkopPageUrl(
  page: ForkopPage,
  params: Record<string, string> = {},
) {
  const base =
    typeof luci()?.url === 'function'
      ? luci()!.url!(FORKOP_MENU_PATH, page)
      : `/cgi-bin/luci/${FORKOP_MENU_PATH}/${page}`;
  const query = new URLSearchParams(params).toString();

  return query ? `${base}#${query}` : base;
}

export function openForkopPage(
  page: ForkopPage,
  params: Record<string, string> = {},
) {
  window.location.href = forkopPageUrl(page, params);
}

export function readPageParams(hash = window.location.hash) {
  return Object.fromEntries(new URLSearchParams(hash.replace(/^#/, '')));
}
