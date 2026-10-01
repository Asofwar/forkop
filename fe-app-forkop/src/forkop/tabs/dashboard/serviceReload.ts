import { Forkop } from '../../types';

// What a finished UI reload job did (service/ui.uc, UC-061): it ran, init.d
// only queued it behind another operation (a list or subscription update, a
// start), it skipped it because Forkop X is stopped, or it failed.
export type ServiceReloadOutcome = 'reloaded' | 'queued' | 'stopped' | 'failed';

export function serviceReloadOutcome(
  state: Forkop.ServiceActionState,
): ServiceReloadOutcome {
  if (state.outcome === 'queued') return 'queued';
  if (state.outcome === 'stopped') return 'stopped';
  return state.success === false ? 'failed' : 'reloaded';
}

// The URLTest settings are saved (or reset) before the reload: only the
// reload's outcome decides whether they are already in effect.
export function urlTestChangeToast(
  outcome: ServiceReloadOutcome,
  reset: boolean,
): { text: string; type: 'success' | 'warning' | 'error'; duration: number } {
  const done = reset
    ? _('URLTest settings reset')
    : _('URLTest settings saved');
  switch (outcome) {
    case 'queued':
      return {
        text: `${done}. ${_('Forkop X is busy with another operation: the change applies when it finishes.')}`,
        type: 'warning',
        duration: 8000,
      };
    case 'stopped':
      return {
        text: `${done}. ${_('Forkop X is stopped: the change applies when it is started.')}`,
        type: 'warning',
        duration: 8000,
      };
    case 'failed':
      return {
        text: `${done}. ${_('Forkop X could not apply the change; see the Forkop X log.')}`,
        type: 'error',
        duration: 10000,
      };
    default:
      return { text: done, type: 'success', duration: 3000 };
  }
}
