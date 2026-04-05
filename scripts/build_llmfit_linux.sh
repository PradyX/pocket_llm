#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LLMFIT_REPO_URL="${LLMFIT_REPO_URL:-https://github.com/AlexsJones/llmfit.git}"
LLMFIT_REF="${LLMFIT_REF:-main}"
LLMFIT_TARGET="${LLMFIT_TARGET:-}"
LLMFIT_PATCH="${REPO_ROOT}/scripts/patches/llmfit-android-hardware-detection.patch"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must be run on a Linux host." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if [[ ! -f "${HOME}/.cargo/env" ]]; then
  echo "Rust toolchain not found. Install rustup first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${HOME}/.cargo/env"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is not available after sourcing rustup env." >&2
  exit 1
fi

resolve_target() {
  local requested_target="${LLMFIT_TARGET}"
  local host_arch

  if [[ -z "${requested_target}" ]]; then
    host_arch="$(uname -m)"
    case "${host_arch}" in
      x86_64)
        requested_target="x86_64-unknown-linux-gnu"
        ;;
      aarch64|arm64)
        requested_target="aarch64-unknown-linux-gnu"
        ;;
      *)
        echo "Unsupported Linux architecture: ${host_arch}" >&2
        exit 1
        ;;
    esac
  fi

  case "${requested_target}" in
    x86_64-unknown-linux-gnu)
      printf '%s %s\n' "${requested_target}" "x64"
      ;;
    aarch64-unknown-linux-gnu)
      printf '%s %s\n' "${requested_target}" "arm64"
      ;;
    *)
      echo "Unsupported LLMFIT_TARGET: ${requested_target}" >&2
      echo "Supported values: x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu" >&2
      exit 1
      ;;
  esac
}

read -r RUST_TARGET ASSET_ARCH <<<"$(resolve_target)"
OUTPUT_ASSET="${REPO_ROOT}/assets/tools/llmfit/linux/${ASSET_ARCH}/llmfit"

HOST_TARGET="$(rustc -vV | awk '/^host: / { print $2 }')"
if [[ "${RUST_TARGET}" != "${HOST_TARGET}" ]]; then
  rustup target add "${RUST_TARGET}"
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "Cloning llmfit from ${LLMFIT_REPO_URL} (${LLMFIT_REF})..."
git clone --depth 1 --branch "${LLMFIT_REF}" "${LLMFIT_REPO_URL}" "${WORK_DIR}/llmfit-src"

pushd "${WORK_DIR}/llmfit-src" >/dev/null
if [[ -f "${LLMFIT_PATCH}" ]]; then
  echo "Applying PocketLlama Linux/Android hardware-detection patch..."
  git apply "${LLMFIT_PATCH}"
fi

echo "Building llmfit for Linux ${RUST_TARGET}..."
cargo build --release -p llmfit --target "${RUST_TARGET}"
popd >/dev/null

mkdir -p "$(dirname "${OUTPUT_ASSET}")"
cp "${WORK_DIR}/llmfit-src/target/${RUST_TARGET}/release/llmfit" "${OUTPUT_ASSET}"
chmod 755 "${OUTPUT_ASSET}"

if command -v strip >/dev/null 2>&1; then
  if ! strip "${OUTPUT_ASSET}"; then
    echo "Warning: strip failed for ${OUTPUT_ASSET}" >&2
  fi
fi

echo "Bundled Linux llmfit binary written to:"
echo "  ${OUTPUT_ASSET}"
file "${OUTPUT_ASSET}" || true
ls -lh "${OUTPUT_ASSET}"
