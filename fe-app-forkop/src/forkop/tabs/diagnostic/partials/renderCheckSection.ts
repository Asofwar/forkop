import {
  renderCheckIcon24,
  renderCircleAlertIcon24,
  renderCircleCheckIcon24,
  renderCircleSlashIcon24,
  renderCircleXIcon24,
  renderLoaderCircleIcon24,
  renderTriangleAlertIcon24,
  renderXIcon24,
} from '../../../../icons';
import type { IDiagnosticsChecksStoreItem } from '../../../services';
import { checkStatus, renderStatusBadge } from '../statusLabels';

type IRenderCheckSectionProps = IDiagnosticsChecksStoreItem;

export function diagnosticActionSummary(props: IRenderCheckSectionProps) {
  return [
    props.title,
    props.description,
    ...props.items.map((item) => `${item.key}: ${item.value}`),
  ].join('\n');
}

function renderRecoveryActions(props: IRenderCheckSectionProps) {
  return E('div', { class: 'fkp-check__actions' }, [
    E(
      'button',
      {
        type: 'button',
        class: 'btn cbi-button',
        click: () =>
          document
            .querySelector<HTMLElement>('#fkp_diagnostic-page-run-check button')
            ?.click(),
      },
      _('Retry'),
    ),
    // LuCI tabs switch on the inner link; read-only sessions have no Settings tab.
    document.querySelector('[data-tab="settings"] > a')
      ? E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button',
            click: () =>
              document
                .querySelector<HTMLElement>('[data-tab="settings"] > a')
                ?.click(),
          },
          _('Open settings'),
        )
      : '',
    E(
      'button',
      {
        type: 'button',
        class: 'btn cbi-button',
        click: () =>
          void navigator.clipboard.writeText(diagnosticActionSummary(props)),
      },
      _('Copy details'),
    ),
  ]);
}

function itemIcon(state: IRenderCheckSectionProps['items'][number]['state']) {
  const icon = E('span', { class: 'fkp-check__item-icon' });
  if (state === 'success') icon.appendChild(renderCheckIcon24());
  if (state === 'warning') icon.appendChild(renderTriangleAlertIcon24());
  if (state === 'error') icon.appendChild(renderXIcon24());
  return icon;
}

function stateIcon(state: IRenderCheckSectionProps['state']) {
  switch (state) {
    case 'success':
      return renderCircleCheckIcon24();
    case 'warning':
      return renderCircleAlertIcon24();
    case 'error':
      return renderCircleXIcon24();
    case 'loading':
      return renderLoaderCircleIcon24();
    default:
      return renderCircleSlashIcon24();
  }
}

export function checkDetailsOpen(state: IRenderCheckSectionProps['state']) {
  return state === 'error' || state === 'warning';
}

export function renderCheckSection(props: IRenderCheckSectionProps) {
  const status = checkStatus(props.state);
  const icon = E('span', { class: 'fkp-check__icon' });
  icon.appendChild(stateIcon(props.state));
  const hasDetails = props.items.length > 0 || checkDetailsOpen(props.state);
  return E('div', { class: `fkp-check fkp-check--${status.tone}` }, [
    E('div', { class: 'fkp-check__head' }, [
      icon,
      E('b', { class: 'fkp-check__title' }, props.title),
      renderStatusBadge(status),
    ]),
    hasDetails
      ? E(
          'details',
          {
            class: 'fkp-check__details',
            open: checkDetailsOpen(props.state) || undefined,
          },
          [
            E('summary', {}, _('Details')),
            E('div', { class: 'fkp-check__description' }, props.description),
            ...props.items.map((item) =>
              E(
                'div',
                { class: `fkp-check__item fkp-diag-text--${item.state}` },
                [
                  itemIcon(item.state),
                  E('b', {}, item.key),
                  E('span', {}, item.value),
                ],
              ),
            ),
            checkDetailsOpen(props.state) ? renderRecoveryActions(props) : '',
          ],
        )
      : '',
  ]);
}
