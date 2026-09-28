#!/usr/bin/env ucode

// Derived, read-only view of a DPI rule's strategy: the provider, the name of
// a known strategy (an autotune catalog template or the provider default) and
// whether it is custom. The raw option text never leaves the admin role.
let constants = require("core.constants");

const STRATEGY_OPTIONS = { zapret: "nfqws_opt", zapret2: "nfqws2_opt", byedpi: "byedpi_cmd_opts" };

let catalog = null;

function as_string(value) { return value == null ? "" : "" + value; }
function normalize(value) { return trim(replace(as_string(value), /[ \t\r\n]+/g, " ")); }

function is_dpi_action(action) {
    return STRATEGY_OPTIONS[as_string(action)] != null;
}

function load_catalog() {
    if (catalog == null) {
        try { catalog = require("autotune.catalog"); }
        catch (e) { catalog = false; }
    }
    return catalog;
}

// section: an object with action and the provider's strategy option.
function view(section) {
    let provider = as_string(section.action);
    let raw = normalize(section[STRATEGY_OPTIONS[provider]]);
    let defaults = {
        zapret: [ constants.ZAPRET_DEFAULT_NFQWS_OPT, constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT ],
        zapret2: [ constants.ZAPRET2_DEFAULT_NFQWS2_OPT ],
        byedpi: [ constants.BYEDPI_DEFAULT_CMD_OPTS ]
    };
    let strategy = "";
    if (raw == "")
        strategy = "default";
    else {
        for (let value in defaults[provider])
            if (value != null && raw == normalize(value))
                strategy = "default";
        let known = provider == "zapret" && strategy == "" ? load_catalog() : null;
        for (let entry in (known ? known.entries() : []))
            if (entry.nfqws_opt != "" && raw == normalize(entry.nfqws_opt))
                strategy = entry.id;
    }
    return { dpi_provider: provider, dpi_strategy: strategy, dpi_strategy_custom: strategy == "" };
}

return { is_dpi_action, view };
