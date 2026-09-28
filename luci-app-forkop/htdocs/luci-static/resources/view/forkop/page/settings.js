"use strict";
"require view";
"require form";
"require uci";
"require ui";
"require view.forkop.main as main";
"require view.forkop.shell as shell";
"require view.forkop.settings as settings";
"require view.forkop.section as section";
"require view.forkop.updates as updates";

const UCI_PACKAGE = main.FORKOP_UCI_PACKAGE;

function renderSectionAdd(sectionRef, extra_class) {
  const el = form.GridSection.prototype.renderSectionAdd.apply(sectionRef, [
    extra_class,
  ]);
  const nameEl = el.querySelector(".cbi-section-create-name");

  ui.addValidator(
    nameEl,
    "uciname",
    true,
    (value) => {
      const button = el.querySelector(".cbi-section-create > .cbi-button-add");
      const uciconfig = sectionRef.uciconfig || sectionRef.map.config;

      if (!value) {
        button.disabled = true;
        return true;
      }

      if (uci.get(uciconfig, value)) {
        button.disabled = true;
        return _("Expecting: %s").format(_("unique UCI identifier"));
      }

      button.disabled = null;
      return true;
    },
    "blur",
    "keyup",
  );

  return el;
}

function getRuleEditButtonText() {
  const label = _("Edit rule action");

  return label === "Edit rule action" ? "Edit" : label;
}

function configureGridSection(sectionRef, type, title, addTitle) {
  sectionRef.anonymous = false;
  sectionRef.addremove = true;
  sectionRef.sortable = true;
  sectionRef.rowcolors = true;
  sectionRef.nodescriptions = true;
  sectionRef.modaltitle = function (section_id) {
    const label = uci.get(UCI_PACKAGE, section_id, "label");
    return section_id ? `${title}: ${label || section_id}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "label") || section_id;
  };
  sectionRef.renderSectionAdd = function (extra_class) {
    return renderSectionAdd(sectionRef, extra_class);
  };

  if (type === "section") {
    sectionRef.renderRowActions = function (section_id) {
      return form.TableSection.prototype.renderRowActions.call(
        this,
        section_id,
        getRuleEditButtonText(),
      );
    };
  }
}

const EntryPoint = {
  load() {
    return shell.startPage(null);
  },

  render() {
    const loadUiCapabilities = shell.loadUiCapabilities;
    const uiCapabilities = shell.uiCapabilities;
    const forkopMap = new form.Map(UCI_PACKAGE, _("Settings"), null);
    forkopMap.tabbed = true;
    const originalHandleSaveApply = forkopMap.handleSaveApply;
    forkopMap.handleSaveApply = async function (ev, mode) {
      const applyStartedAt = Math.floor(Date.now() / 1000);
      const snapshot =
        await main.ForkopShellMethods.snapshotCreate("automatic");
      if (
        !snapshot.success ||
        !["created", "existing"].includes(snapshot.data?.status)
      ) {
        ui.addNotification(
          null,
          E(
            "p",
            {},
            snapshot.data?.status === "busy"
              ? _(
                  "Another snapshot operation is already in progress. Changes were not applied; try again in a moment.",
                )
              : _(
                  "Could not save a pre-apply configuration snapshot. Changes were not applied.",
                ),
          ),
          "error",
        );
        return;
      }
      const beforeHealth = await main.ForkopShellMethods.getHealthStatus();
      const previousReloadAt = beforeHealth.success
        ? beforeHealth.data?.last_reload?.timestamp || 0
        : 0;
      const refreshUiState = function () {
        main.ForkopShellMethods.getUiState()
          .then((response) => {
            if (
              response?.success &&
              typeof main.applyUiStateToStore === "function"
            ) {
              main.applyUiStateToStore(response.data);
            }
          })
          .catch(() => null);
      };

      if (main.store && typeof main.store.set === "function") {
        const servicesInfoWidget = main.store.get().servicesInfoWidget;
        main.store.set({
          servicesInfoWidget: {
            ...servicesInfoWidget,
            data: {
              ...servicesInfoWidget.data,
              forkopStatus: "reloading",
            },
          },
        });
      }

      return Promise.resolve(originalHandleSaveApply.call(this, ev, mode))
        .then(async (result) => {
          window.setTimeout(refreshUiState, 250);

          const [diff, health] = await Promise.all([
            main.ForkopShellMethods.snapshotDiff(snapshot.data.snapshot.id),
            main.ForkopShellMethods.getHealthStatus(),
          ]);
          const reload = health.success ? health.data?.last_reload : null;
          const confirmed =
            reload &&
            reload.timestamp >= applyStartedAt &&
            reload.timestamp > previousReloadAt &&
            reload.status === "success";
          const changes =
            diff.success && Array.isArray(diff.data) ? diff.data : [];
          const message = confirmed
            ? [
                _("Configuration applied successfully"),
                ...changes.map(
                  (change) =>
                    `${change.section}.${change.option}: ${Array.isArray(change.before) ? JSON.stringify(change.before) : change.before} → ${Array.isArray(change.after) ? JSON.stringify(change.after) : change.after}`,
                ),
              ].join("\n")
            : _(
                "Configuration saved. Runtime reload has not been confirmed; check History and recovery.",
              );
          ui.addNotification(
            null,
            E("p", { style: "white-space: pre-line" }, message),
            confirmed ? "info" : "warning",
          );

          return result;
        })
        .catch((error) => {
          refreshUiState();

          throw error;
        });
    };

    const rulesSection = forkopMap.section(
      form.GridSection,
      "section",
      _("Sections"),
      _("Drag rows to change priority. The rule at the top is checked first."),
    );
    configureGridSection(
      rulesSection,
      "section",
      _("Section"),
      _("Add a section"),
    );
    section.configureSectionSection(rulesSection, {
      loadActionProvidersAvailability: loadUiCapabilities,
    });
    section.createSectionContent(rulesSection);

    const settingsSection = forkopMap.section(
      form.TypedSection,
      "settings",
      _("General settings"),
    );
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    settingsSection.cfgsections = function () {
      return ["settings"];
    };
    settings.createSettingsContent(settingsSection, uiCapabilities);

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
};

return view.extend(EntryPoint);
