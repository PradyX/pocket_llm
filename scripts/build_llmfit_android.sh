#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LLMFIT_REPO_URL="${LLMFIT_REPO_URL:-https://github.com/AlexsJones/llmfit.git}"
LLMFIT_REF="${LLMFIT_REF:-main}"
ANDROID_PLATFORM="${ANDROID_PLATFORM:-24}"
ANDROID_TARGET="${ANDROID_TARGET:-arm64-v8a}"
RUST_TARGET="aarch64-linux-android"
OUTPUT_ASSET="${REPO_ROOT}/assets/tools/llmfit/android/arm64-v8a/llmfit"
LLMFIT_PATCH="${REPO_ROOT}/scripts/patches/llmfit-android-hardware-detection.patch"

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

if ! command -v cargo-ndk >/dev/null 2>&1; then
  cargo install cargo-ndk
fi

rustup target add "${RUST_TARGET}"

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  for candidate in \
    "${HOME}/Library/Android/sdk/ndk/29.0.14206865" \
    "${HOME}/Library/Android/sdk/ndk/28.2.13676358" \
    "${HOME}/Library/Android/sdk/ndk/25.1.8937393"; do
    if [[ -d "${candidate}" ]]; then
      export ANDROID_NDK_HOME="${candidate}"
      break
    fi
  done
fi

if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "${ANDROID_NDK_HOME}" ]]; then
  echo "ANDROID_NDK_HOME is not set to a valid NDK directory." >&2
  exit 1
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
  echo "Applying PocketLlama Android hardware-detection patch..."
  git apply "${LLMFIT_PATCH}"
fi

echo "Building llmfit for Android ${ANDROID_TARGET} (API ${ANDROID_PLATFORM})..."
cargo ndk -t "${ANDROID_TARGET}" --platform "${ANDROID_PLATFORM}" build --release -p llmfit
popd >/dev/null

mkdir -p "$(dirname "${OUTPUT_ASSET}")"
cp "${WORK_DIR}/llmfit-src/target/${RUST_TARGET}/release/llmfit" "${OUTPUT_ASSET}"
chmod 755 "${OUTPUT_ASSET}"

LLVM_STRIP="$(find "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt" -type f -name llvm-strip -print -quit)"
if [[ -n "${LLVM_STRIP}" ]]; then
  if ! "${LLVM_STRIP}" "${OUTPUT_ASSET}"; then
    echo "Warning: llvm-strip failed for ${OUTPUT_ASSET}" >&2
  fi
fi

echo "Bundled Android llmfit binary written to:"
echo "  ${OUTPUT_ASSET}"
file "${OUTPUT_ASSET}" || true
ls -lh "${OUTPUT_ASSET}"
