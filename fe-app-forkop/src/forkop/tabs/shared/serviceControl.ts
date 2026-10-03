import { ForkopShellMethods } from '../../methods';
import { confirmAction } from '../../ui/confirmAction';
import { refreshRuntimeUiState } from '../../services/runtimeUiState.service';
import { store } from '../../services/store.service';
import { markUiActionOwned } from '../../services/uiActionNotification.service';
import {
  beginAwaitedServiceAction,
  endAwaitedServiceAction,
} from '../../services/serviceActionOutcome.service';
import { ActionFailureError, failureReason } from '../../helpers/actionReason';
import { Forkop } from '../../types';

export type ForkopServiceAction = 'start' | 'restart' | 'stop';

// Runs a service action through the same job as Diagnostics and resolves to
// the finished job. A refusal, or a job not confirmed in time, throws an
// ActionFailureError with its reason (UC-119, UC-120). The job is owned by
// this browser tab: when the page is gone before it finishes, its failure
// is still reported (services/serviceActionOutcome.service).
export async function runServiceActionJob(action: Forkop.ServiceAction) {
  const start = await ForkopShellMethods.serviceActionStart(action);
  if (!start.success) {
    throw new ActionFailureError(start.error, failureReason(start));
  }

  const jobId = start.data.job_id;
  let finished = false;
  markUiActionOwned('service', jobId);
  beginAwaitedServiceAction(jobId);
  try {
    const result = await ForkopShellMethods.waitServiceActionJob(jobId);
    if (!result.success) {
      throw new ActionFailureError(result.error, failureReason(result));
    }
    finished = true;
    return result.data;
  } finally {
    endAwaitedServiceAction(jobId, finished);
    void ForkopShellMethods.uiActionAck('service', jobId);
  }
}

// Pages follow the resulting state through the runtime UI state poller.
export async function runForkopServiceAction(action: ForkopServiceAction) {
  const state = await runServiceActionJob(action);
  if (state.success === false) {
    throw new ActionFailureError(state.message || '', state.reason);
  }
}

export function confirmStopForkop() {
  return confirmAction({
    title: _('Stop Forkop X?'),
    message: _('Forkop X stops handling traffic until it is started again.'),
    consequences: [
      _('Routing, DNS and DPI bypass rules stop applying'),
      _('Devices keep using the router without Forkop X'),
      _(
        'Sections with the VPN kill-switch are blocked instead of going directly',
      ),
    ],
    confirmLabel: _('Stop'),
    danger: true,
  });
}

// init.d enable/disable print nothing, so the result is judged by the
// autostart state read back afterwards. Resolves to that state.
export async function setForkopAutostart(enabled: boolean) {
  try {
    await (enabled
      ? ForkopShellMethods.enable()
      : ForkopShellMethods.disable());
  } finally {
    await refreshRuntimeUiState({ force: true });
  }

  return Boolean(store.get().servicesInfoWidget.data.forkopEnabled);
}
