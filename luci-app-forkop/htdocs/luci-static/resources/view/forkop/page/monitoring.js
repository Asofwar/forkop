"use strict";
"require view";
"require view.forkop.main as main";
"require view.forkop.shell as shell";
"require view.forkop.local_devices as localDevices";

const EntryPoint = {
  load() {
    return shell
      .detectAccess()
      .then((readonly) => shell.startPage("monitoring").then(() => readonly));
  },

  // Connections run the monitoring controller; the Nodes view runs the
  // dashboard controller (node selection).
  render() {
    main.DashboardTab.initController();
    main.MonitoringTab.initController({
      loadLocalDeviceChoices: localDevices.loadLocalDeviceChoices,
    });
    return shell.renderPage(_("Monitoring"), main.MonitoringTab.render());
  },

  handleSave: null,
  handleSaveApply: null,
  handleReset: null,
};

return view.extend(EntryPoint);
