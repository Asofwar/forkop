export interface OverflowMenuItem {
  label: string;
  onClick: () => void;
  danger?: boolean;
  disabled?: boolean;
}

// Rare actions live behind one "⋯" button instead of a row of equal
// buttons. A native <details> keeps it keyboard accessible.
export function renderOverflowMenu(label: string, items: OverflowMenuItem[]) {
  const menu = E('details', { class: 'fkp-menu' }) as HTMLDetailsElement;
  const close = () => {
    menu.open = false;
  };

  menu.appendChild(
    E(
      'summary',
      {
        class: 'btn cbi-button fkp-menu__toggle',
        title: label,
        'aria-label': label,
      },
      '⋯',
    ),
  );
  menu.appendChild(
    E(
      'div',
      { class: 'fkp-menu__list', role: 'menu' },
      items.map((item) =>
        E(
          'button',
          {
            type: 'button',
            role: 'menuitem',
            class: `fkp-menu__item${item.danger ? ' fkp-action-danger-text' : ''}`,
            disabled: item.disabled ? true : undefined,
            click: () => {
              close();
              item.onClick();
            },
          },
          item.label,
        ),
      ),
    ),
  );

  if (typeof document !== 'undefined' && document.addEventListener) {
    document.addEventListener('click', (event) => {
      if (menu.open && !menu.contains(event.target as Node)) close();
    });
  }

  return menu;
}
