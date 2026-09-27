import { ForkopShellMethods } from '../../methods';
import { showToast } from '../../../helpers/showToast';
import { isReadonlyMode } from '../../services/accessMode.service';
import { serviceActionErrorText } from '../diagnostic/serviceTransition';

let starting = false;

// Starts Forkop X through the same service job as Diagnostics; the page
// follows the new state through the runtime UI state poller.
export async function startForkopService() {
  const start = await ForkopShellMethods.serviceActionStart('start');
  if (!start.success) {
    throw new Error(start.error);
  }

  const jobId = start.data.job_id;
  try {
    const result = await ForkopShellMethods.waitServiceActionJob(jobId);
    if (!result.success) {
      throw new Error(result.error);
    }
    if (result.data.success === false) {
      throw new Error(result.data.message || '');
    }
  } finally {
    void ForkopShellMethods.uiActionAck('service', jobId);
  }
}

// Pages that say "the service is stopped" offer to start it right there.
// Read-only sessions get no button.
export function renderStartServiceAction(): HTMLElement[] {
  if (isReadonlyMode()) {
    return [];
  }

  const button = E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button cbi-button-action fkp-start-service',
      disabled: starting ? true : undefined,
      click: async () => {
        if (starting) {
          return;
        }

        starting = true;
        button.disabled = true;
        button.textContent = _('Starting…');
        try {
          await startForkopService();
        } catch (error) {
          showToast(serviceActionErrorText(error), 'error', 6000);
        } finally {
          starting = false;
          button.disabled = false;
          button.textContent = _('Start Forkop X');
        }
      },
    },
    starting ? _('Starting…') : _('Start Forkop X'),
  );

  return [button];
}
