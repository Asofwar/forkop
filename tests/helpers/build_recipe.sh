#!/usr/bin/env bash
# The backend package as build.sh builds it, without an OpenWrt SDK: its
# files and its package scripts, written by build.sh's own functions.
#
# Source this file and call
#   build_recipe_scripts <build.sh> <directory>
#     <directory>/ipk: the ipk's control files (control, conffiles, postinst,
#     prerm); <directory>/apk: the apk's scripts (backend-*.sh).
#   build_recipe_root <build.sh> <version> <directory>
#     the files of the package (build_backend_root).
# Both return non-zero, with a message, when build.sh no longer has what
# they use.

# The text of the shell function $2 of build.sh $1: from "name() {" to the
# first line that is "}".
build_recipe_function() {
  local text
  text="$(awk -v start="$2() {" '$0 == start { copy = 1 } copy { print } copy && $0 == "}" { exit }' "$1")"
  if [ -z "$text" ]; then
    printf 'build_recipe: %s has no function %s\n' "$1" "$2" >&2
    return 1
  fi
  printf '%s\n' "$text"
}

# Defines, in this shell, build.sh's package metadata variables and the
# functions named $2...
build_recipe_load() {
  local script="$1" name assignments
  shift
  assignments="$(grep -E '^(BACKEND_DESCRIPTION|MAINTAINER|PROJECT_URL|BACKEND_DEPENDS_IPK|BACKEND_CONFLICTS_IPK)=' "$script")"
  eval "$assignments"
  for name in "$@"; do
    eval "$(build_recipe_function "$script" "$name")" || return 1
  done
}

build_recipe_scripts() {
  local script="$1" out="$2" names
  names="make_dir write_backend_ipk_control write_backend_apk_scripts"
  # The postinst of every variant comes from one function since UC-026.
  if grep -q '^write_backend_postinst() {$' "$script"; then
    names="$names write_backend_postinst"
  fi
  (
    # shellcheck disable=SC2034 # read by the functions of build.sh
    RELEASE_VERSION=0.0.0
    # shellcheck disable=SC2086 # a list of function names
    build_recipe_load "$script" $names || exit 1
    write_backend_ipk_control "$out/ipk" 4096 || exit 1
    write_backend_apk_scripts "$out/apk" || exit 1
  )
}

build_recipe_root() {
  local script="$1" version="$2" out="$3"
  (
    # shellcheck disable=SC2034 # read by the functions of build.sh
    ROOT_DIR="$(cd "$(dirname "$script")" && pwd)"
    # shellcheck disable=SC2034
    RELEASE_VERSION="$version"
    build_recipe_load "$script" make_dir normalize_package_root_modes build_backend_root || exit 1
    build_backend_root "$out" || exit 1
  )
}
