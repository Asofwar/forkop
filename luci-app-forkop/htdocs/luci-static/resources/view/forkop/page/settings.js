"use strict";
"require view";
"require form";
"require view.forkop.shell as shell";
"require view.forkop.settings as settings";
"require view.forkop.updates as updates";
"require view.forkop.configform as configform";

const EntryPoint = {
  load() {
    return shell.startPage(null);
  },

  render() {
    const uiCapabilities = shell.uiCapabilities;
    const forkopMap = configform.createMap(_("Settings"), null);
    forkopMap.tabbed = true;
    // The single "settings" UCI section is shown as four tabs; each tab
    // writes only its own options. LuCI keys map tabs by section type, so
    // each tab gets its own type while editing the same "settings" section.
    const settingsTab = (type, title) => {
      const tab = forkopMap.section(form.TypedSection, type, title);
      tab.anonymous = true;
      tab.addremove = false;
      tab.cfgsections = function () {
        return ["settings"];
      };
      return tab;
    };
    settings.createSettingsContent(
      {
        dns: settingsTab("settings_dns", _("DNS")),
        network: settingsTab("settings_network", _("Network")),
        lists: settingsTab("settings_lists", _("Lists and updates")),
        service: settingsTab("settings_service", _("Service settings")),
      },
      uiCapabilities,
    );

    const updatesSection = forkopMap.section(
      form.TypedSection,
      "updates",
      _("Components"),
    );
    updatesSection.anonymous = true;
    updatesSection.addremove = false;
    updatesSection.cfgsections = function () {
      return ["updates"];
    };
    updates.createUpdatesContent(updatesSection);

    return forkopMap.render();
  },

  // LuCI's footer calls the view's Save & Apply: snapshot first
  // (configform.js).
  handleSaveApply: configform.handleSaveApply,
};

return view.extend(EntryPoint);
