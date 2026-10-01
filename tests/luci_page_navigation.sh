#!/usr/bin/env bash
set -euo pipefail

# Every Forkop page must offer the other pages. LuCI can build that bar from the
# menu tree, but it is the theme's menu script that fills #tabmenu, and a theme
# is free to ship one that never does: menu-footstrap.js has no mention of
# tabmenu, so on footstrap the container keeps the display:none its template
# gives it and a page is reachable only by walking the Services menu again.
# shell.js therefore renders the bar itself, in LuCI's own tab markup so each
# theme styles it natively.
#
# The bar is built from the menu subtree LuCI serves, never from a list kept in
# shell.js. Two things depend on that. The bar cannot drift from the menu when a
# page is added or renamed. And the subtree a session is served is already
# filtered by the ACL each entry depends on, so a read-only session is not
# offered Rules or Settings, which require luci-app-forkop-admin: a hardcoded
# list would hand it tabs leading to a refusal.
#
# renderPage stays synchronous, so the tree has to be in hand before LuCI calls
# render(): startPage, whose promise LuCI resolves in load(), fetches it.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW_DIR="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop"
SHELL_JS="$VIEW_DIR/shell.js"
MENU_JSON="$ROOT_DIR/luci-app-forkop/root/usr/share/luci/menu.d/luci-app-forkop.json"

# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

source_require "$SHELL_JS" "$MENU_JSON"

grep -Fq '"require ui";' "$SHELL_JS" ||
  fail 'shell.js must require ui to reach the LuCI menu'

# The bar reaches the page, and the page content still follows it.
render_page="$(source_function "$SHELL_JS" renderPage)" || exit 1
printf '%s' "$render_page" | grep -Fq 'renderNav(' ||
  fail 'renderPage must render the page navigation'
printf '%s' "$render_page" | grep -Fq 'content' ||
  fail 'renderPage must still render the page content'

# Built from the menu, in LuCI's own tab markup, through LuCI's URL builder.
render_nav="$(source_function "$SHELL_JS" renderNav)" || exit 1
printf '%s' "$render_nav" | grep -Fq 'ui.menu.getChildren(' ||
  fail 'renderNav must take the pages from the LuCI menu subtree'
printf '%s' "$render_nav" | grep -Fq 'cbi-tabmenu' ||
  fail 'renderNav must use the LuCI cbi-tabmenu markup'
printf '%s' "$render_nav" | grep -Fq 'cbi-tab-disabled' ||
  fail 'renderNav must mark the inactive tabs as cbi-tab-disabled'
printf '%s' "$render_nav" | grep -Fq 'L.url(' ||
  fail 'renderNav must build hrefs through L.url'

# The tree is fetched while the view loads, so renderPage needs no await.
start_page="$(source_function "$SHELL_JS" startPage)" || exit 1
printf '%s' "$start_page" | grep -Fq 'loadMenuTree(' ||
  fail 'startPage must fetch the menu tree so renderPage can stay synchronous'
printf '%s' "$start_page" | grep -Eq 'Promise\.all\(|\.then\(' ||
  fail 'startPage must resolve only once the menu tree is in hand'

# No second list of pages to drift from the menu, and none that would bypass
# the ACL filtering the served subtree already carries.
for page in overview rules monitoring diagnostics autotune history settings; do
  source_refute "shell.js must not name the \"$page\" page; the menu lists the pages" \
    -F "\"$page\"" "$SHELL_JS"
done

printf 'LuCI page navigation checks passed\n'
