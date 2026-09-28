"use strict";
"require view";
"require view.forkop.main as main";
"require view.forkop.shell as shell";

// Until the Stage 6.3 redesign the overview hosts the current dashboard.
const EntryPoint = {
  load() {
    return shell
      .detectAccess()
      .then((readonly) => shell.startPage("dashboard").then(() => readonly));
  },

  render() {
    main.DashboardTab.initController();
    return shell.renderPage(_("Overview"), main.DashboardTab.render());
  },

  handleSave: null,
  handleSaveApply: null,
  handleReset: null,
};

return view.extend(EntryPoint);
