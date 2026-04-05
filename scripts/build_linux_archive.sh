#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

log() {
  printf '[build_linux_archive] %s\n' "$*"
}

die() {
  printf '[build_linux_archive] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

find_bundle_dir() {
  local candidate

  for candidate in \
    "${PROJECT_DIR}/build/linux/x64/release/bundle" \
    "${PROJECT_DIR}/build/linux/arm64/release/bundle"; do
    if [[ -d "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  find "${PROJECT_DIR}/build/linux" -type d -path '*/release/bundle' | sort | head -n 1
}

main() {
  [[ "$(uname -s)" == "Linux" ]] || die "This script must be run on a Linux host."

  require_command flutter
  require_command tar

  cd "${PROJECT_DIR}"

  log "Building Flutter Linux release bundle"
  flutter build linux --release "$@"

  local bundle_dir
  bundle_dir="$(find_bundle_dir)"
  [[ -n "${bundle_dir}" && -d "${bundle_dir}" ]] || die "Could not locate the Linux release bundle."

  local arch
  arch="$(basename "$(dirname "$(dirname "${bundle_dir}")")")"
  local release_dir
  release_dir="$(dirname "${bundle_dir}")"
  local package_name="pocket_llm-linux-${arch}"
  local stage_dir="${release_dir}/package"
  local archive_path="${release_dir}/${package_name}.tar.gz"

  log "Packaging bundle from ${bundle_dir}"
  rm -rf "${stage_dir}"
  mkdir -p "${stage_dir}/${package_name}"
  cp -R "${bundle_dir}/." "${stage_dir}/${package_name}/"

  tar -C "${stage_dir}" -czf "${archive_path}" "${package_name}"

  log "Linux release archive created at:"
  printf '  %s\n' "${archive_path}"
}

main "$@"
