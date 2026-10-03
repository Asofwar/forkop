#!/usr/bin/env bash
# A configuration that the migrations of this release have nothing left to
# do on (config/migration.uc migrated): service/package.uc starts Forkop
# again after an upgrade only on one (UC-026).
#
# Source this file and call
#   migrated_settings_state <forkop lib> <scratch directory>
# It prints the lines of a UCI state file (core/uci.uc FORKOP_UCI_STATE_FILE)
# that record every migration of the release and the current
# config_version in forkop.settings; add them to the case's own.

migrated_settings_state() {
  local lib="$1" scratch="$2" ids
  printf 'print(join(" ", require("config.migration").migration_ids()));\n' >"$scratch/migration-ids.uc"
  ids="$(ucode -L "$lib" "$scratch/migration-ids.uc")" || return 1
  [ -n "$ids" ] || return 1
  printf 'forkop.settings.config_version=1.0.5\nforkop.settings.applied_migrations=%s\n' "$ids"
}
