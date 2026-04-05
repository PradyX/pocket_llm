#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-/Users/prady/FlutterProjects/llama.cpp}"
ANDROID_PLATFORM="${ANDROID_PLATFORM:-24}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-13.0}"
PUB_CACHE_DIR="${PUB_CACHE_DIR:-${HOME}/.pub-cache}"
LLAMA_CPP_COMMIT="${LLAMA_CPP_COMMIT:-}"
SKIP_GIT_CHECKOUT="${SKIP_GIT_CHECKOUT:-0}"
SKIP_GIT_FETCH="${SKIP_GIT_FETCH:-0}"
ALLOW_DIRTY_LLAMA_CPP="${ALLOW_DIRTY_LLAMA_CPP:-0}"
HOST_OS="$(uname -s)"

if [[ "${HOST_OS}" == "Darwin" ]] && command -v sysctl >/dev/null 2>&1; then
  DEFAULT_JOBS="$(sysctl -n hw.ncpu)"
elif command -v getconf >/dev/null 2>&1; then
  DEFAULT_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
elif command -v nproc >/dev/null 2>&1; then
  DEFAULT_JOBS="$(nproc 2>/dev/null || echo 4)"
else
  DEFAULT_JOBS=4
fi
CMAKE_JOBS="${CMAKE_JOBS:-${DEFAULT_JOBS}}"

ANDROID_ABIS=(
  "arm64-v8a"
  "armeabi-v7a"
  "x86_64"
)

MANAGED_ANDROID_LIBS=(
  "libggml.so"
  "libggml-base.so"
  "libggml-cpu.so"
  "libllama.so"
  "libmtmd.so"
)

MANAGED_LINUX_LIBS=(
  "libggml.so"
  "libggml-base.so"
  "libggml-cpu.so"
  "libllama.so"
  "libmtmd.so"
)

MANAGED_APPLE_LIBS=(
  "libggml.dylib"
  "libggml-base.dylib"
  "libggml-blas.dylib"
  "libggml-cpu.dylib"
  "libggml-metal.dylib"
  "libllama.dylib"
  "libmtmd.dylib"
)

log() {
  printf '[build_llama_native_libs] %s\n' "$*"
}

warn() {
  printf '[build_llama_native_libs] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[build_llama_native_libs] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/build_llama_native_libs.sh [all|android|linux|macos|ios|ios-device|ios-simulator]

The script resolves the locked `llama_cpp_dart` version from `pubspec.lock`,
finds the matching `llama.cpp` commit from your local pub cache, checks out
that commit in `LLAMA_CPP_DIR`, and then builds/copies the native libraries.

With no explicit targets:
  - on macOS hosts: builds Android + macOS + iOS device + iOS simulator
  - on Linux hosts: builds Linux only

Defaults:
  LLAMA_CPP_DIR=/Users/prady/FlutterProjects/llama.cpp
  ANDROID_PLATFORM=24
  IOS_DEPLOYMENT_TARGET=13.0
  CMAKE_JOBS=<host cpu count>
  PUB_CACHE_DIR=$HOME/.pub-cache

Optional overrides:
  LLAMA_CPP_COMMIT=<commit-or-tag>    Force a specific llama.cpp checkout target
  SKIP_GIT_FETCH=1                    Do not fetch latest refs before checkout
  SKIP_GIT_CHECKOUT=1                 Build the current checkout without switching
  ALLOW_DIRTY_LLAMA_CPP=1             Allow building from a dirty llama.cpp repo

Examples:
  scripts/build_llama_native_libs.sh
  scripts/build_llama_native_libs.sh linux
  scripts/build_llama_native_libs.sh android macos
  LLAMA_CPP_DIR=/path/to/llama.cpp scripts/build_llama_native_libs.sh ios
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

find_latest_ndk() {
  local sdk_ndk_root="${HOME}/Library/Android/sdk/ndk"

  if [[ -n "${ANDROID_NDK_ROOT:-}" && -d "${ANDROID_NDK_ROOT}" ]]; then
    printf '%s\n' "${ANDROID_NDK_ROOT}"
    return
  fi

  if [[ -n "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_NDK_HOME}" ]]; then
    printf '%s\n' "${ANDROID_NDK_HOME}"
    return
  fi

  [[ -d "${sdk_ndk_root}" ]] || die "Could not find Android NDK. Set ANDROID_NDK_ROOT."

  find "${sdk_ndk_root}" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1
}

assert_paths() {
  [[ -d "${LLAMA_CPP_DIR}" ]] || die "llama.cpp directory not found: ${LLAMA_CPP_DIR}"
  [[ -f "${LLAMA_CPP_DIR}/CMakeLists.txt" ]] || die "Not a llama.cpp checkout: ${LLAMA_CPP_DIR}"
}

resolve_llama_cpp_dart_version() {
  local lockfile="${PROJECT_DIR}/pubspec.lock"
  local version

  [[ -f "${lockfile}" ]] || die "pubspec.lock not found. Run 'flutter pub get' first."

  version="$(
    awk '
      /^  llama_cpp_dart:$/ { in_pkg = 1; next }
      in_pkg && /^  [^ ]/ { in_pkg = 0 }
      in_pkg && /version:/ {
        gsub(/"/, "", $2)
        print $2
        exit
      }
    ' "${lockfile}"
  )"

  [[ -n "${version}" ]] || die "Could not resolve llama_cpp_dart version from ${lockfile}"
  printf '%s\n' "${version}"
}

find_llama_cpp_dart_package_dir() {
  local version="$1"
  local package_dir

  package_dir="$(
    find "${PUB_CACHE_DIR}/hosted" -maxdepth 2 -type d -name "llama_cpp_dart-${version}" 2>/dev/null \
      | sort \
      | head -n 1
  )"

  [[ -n "${package_dir}" ]] || die "Could not find llama_cpp_dart-${version} in ${PUB_CACHE_DIR}. Run 'flutter pub get' first."
  printf '%s\n' "${package_dir}"
}

resolve_target_llama_cpp_commit() {
  if [[ -n "${LLAMA_CPP_COMMIT}" ]]; then
    printf '%s\n' "${LLAMA_CPP_COMMIT}"
    return
  fi

  local dart_version
  local package_dir
  local package_pubspec
  local target_commit

  dart_version="$(resolve_llama_cpp_dart_version)"
  package_dir="$(find_llama_cpp_dart_package_dir "${dart_version}")"
  package_pubspec="${package_dir}/pubspec.yaml"

  [[ -f "${package_pubspec}" ]] || die "Missing package pubspec: ${package_pubspec}"

  target_commit="$(
    sed -nE 's/^version:[[:space:]]*[^#]+#[[:space:]]*([0-9a-f]{7,40})[[:space:]]*$/\1/p' "${package_pubspec}" \
      | head -n 1
  )"

  [[ -n "${target_commit}" ]] || die "Could not resolve llama.cpp commit from ${package_pubspec}. Set LLAMA_CPP_COMMIT manually."
  printf '%s\n' "${target_commit}"
}

sync_llama_cpp_checkout() {
  local target_ref="$1"
  local current_commit
  local current_tag
  local worktree_status

  require_command git

  current_commit="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD)"
  current_tag="$(git -C "${LLAMA_CPP_DIR}" describe --tags --exact-match HEAD 2>/dev/null || true)"
  worktree_status="$(git -C "${LLAMA_CPP_DIR}" status --short)"

  if [[ -n "${worktree_status}" && "${ALLOW_DIRTY_LLAMA_CPP}" != "1" ]]; then
    die "llama.cpp worktree is dirty. Commit/stash changes first or set ALLOW_DIRTY_LLAMA_CPP=1."
  fi

  if [[ "${SKIP_GIT_CHECKOUT}" == "1" ]]; then
    log "Skipping git checkout. Current llama.cpp commit: ${current_commit}${current_tag:+ (${current_tag})}"
    return
  fi

  if [[ "${SKIP_GIT_FETCH}" != "1" ]]; then
    log "Fetching latest refs from origin"
    git -C "${LLAMA_CPP_DIR}" fetch --tags origin
  fi

  if ! git -C "${LLAMA_CPP_DIR}" cat-file -e "${target_ref}^{commit}" 2>/dev/null; then
    die "Target llama.cpp ref is not available locally after fetch: ${target_ref}"
  fi

  if [[ "${current_commit}" != "$(git -C "${LLAMA_CPP_DIR}" rev-parse "${target_ref}^{commit}")" ]]; then
    log "Checking out llama.cpp ${target_ref}"
    git -C "${LLAMA_CPP_DIR}" checkout "${target_ref}"
  else
    log "llama.cpp already at target ${target_ref}"
  fi

  current_commit="$(git -C "${LLAMA_CPP_DIR}" rev-parse HEAD)"
  current_tag="$(git -C "${LLAMA_CPP_DIR}" describe --tags --exact-match HEAD 2>/dev/null || true)"
  log "Using llama.cpp commit ${current_commit}${current_tag:+ (${current_tag})}"
}

remove_managed_libs() {
  local dest_dir="$1"
  shift
  local lib

  mkdir -p "${dest_dir}"
  for lib in "$@"; do
    rm -f "${dest_dir}/${lib}"
  done
}

remove_managed_apple_libs() {
  local dest_dir="$1"

  mkdir -p "${dest_dir}"
  rm -f \
    "${dest_dir}"/libggml*.dylib \
    "${dest_dir}"/libllama*.dylib \
    "${dest_dir}"/libmtmd*.dylib
}

copy_files() {
  local dest_dir="$1"
  shift
  local copied=0
  local src

  mkdir -p "${dest_dir}"
  for src in "$@"; do
    [[ -e "${src}" ]] || continue
    cp -fL "${src}" "${dest_dir}/$(basename "${src}")"
    copied=1
  done

  [[ "${copied}" -eq 1 ]] || die "No files were copied into ${dest_dir}"
}

sign_apple_libs_if_possible() {
  local dest_dir="$1"
  local lib

  command -v codesign >/dev/null 2>&1 || return 0

  while IFS= read -r -d '' lib; do
    codesign --remove-signature "${lib}" >/dev/null 2>&1 || true
    codesign --force --sign - "${lib}" >/dev/null 2>&1 || true
  done < <(find "${dest_dir}" -maxdepth 1 -type f -name 'lib*.dylib' -print0)
}

set_linux_rpath_if_possible() {
  local dest_dir="$1"
  local lib

  command -v patchelf >/dev/null 2>&1 || return 0

  while IFS= read -r -d '' lib; do
    patchelf --set-rpath '$ORIGIN' "${lib}" >/dev/null 2>&1 || true
  done < <(find "${dest_dir}" -maxdepth 1 -type f -name 'lib*.so' -print0)
}

normalize_apple_install_names() {
  local dest_dir="$1"
  local lib
  local dep_path
  local dep_name
  local base_name

  command -v install_name_tool >/dev/null 2>&1 || return 0
  command -v otool >/dev/null 2>&1 || return 0

  while IFS= read -r -d '' lib; do
    install_name_tool -id "@rpath/$(basename "${lib}")" "${lib}" >/dev/null 2>&1 || true

    while IFS= read -r dep_path; do
      dep_name="$(basename "${dep_path}")"
      if [[ "${dep_name}" =~ ^(.+)\.[0-9]+(\.[0-9]+)*\.dylib$ ]]; then
        base_name="${BASH_REMATCH[1]}.dylib"
        install_name_tool -change "@rpath/${dep_name}" "@rpath/${base_name}" "${lib}" >/dev/null 2>&1 || true
      fi
    done < <(otool -L "${lib}" | awk '/@rpath\// { print $1 }')
  done < <(find "${dest_dir}" -maxdepth 1 -type f -name 'lib*.dylib' -print0)
}

collect_apple_libs() {
  local build_dir="$1"
  local lib_name

  for lib_name in "${MANAGED_APPLE_LIBS[@]}"; do
    find "${build_dir}/bin" -maxdepth 3 \( -type f -o -type l \) -name "${lib_name}" | sort | head -n 1
  done
}

copy_android_outputs() {
  local abi="$1"
  local build_dir="$2"
  local dest_dir="${PROJECT_DIR}/android/app/src/main/jniLibs/${abi}"
  local -a libs=()

  while IFS= read -r lib; do
    libs+=("${lib}")
  done < <(find "${build_dir}/bin" -maxdepth 1 -type f -name 'lib*.so' | sort)

  [[ "${#libs[@]}" -gt 0 ]] || die "No Android shared libraries found for ${abi} in ${build_dir}/bin"

  remove_managed_libs "${dest_dir}" "${MANAGED_ANDROID_LIBS[@]}"
  copy_files "${dest_dir}" "${libs[@]}"

  if [[ ! -f "${dest_dir}/libmtmd.so" ]]; then
    warn "libmtmd.so was not produced for ${abi}. This usually means the checkout/config is too old for the current runtime."
  fi
}

copy_apple_outputs() {
  local build_dir="$1"
  local dest_dir="$2"
  local -a libs=()

  while IFS= read -r lib; do
    [[ -n "${lib}" ]] || continue
    libs+=("${lib}")
  done < <(collect_apple_libs "${build_dir}")

  [[ "${#libs[@]}" -gt 0 ]] || die "No Apple dylibs found under ${build_dir}/bin"

  remove_managed_apple_libs "${dest_dir}"
  copy_files "${dest_dir}" "${libs[@]}"
  normalize_apple_install_names "${dest_dir}"
  sign_apple_libs_if_possible "${dest_dir}"

  if [[ ! -f "${dest_dir}/libmtmd.dylib" ]]; then
    warn "libmtmd.dylib was not produced in ${build_dir}. This usually means the checkout/config is too old for the current runtime."
  fi

  if [[ ! -f "${dest_dir}/libggml-blas.dylib" ]]; then
    warn "libggml-blas.dylib is missing in ${dest_dir}. Apple builds in this repo expect it."
  fi
}

copy_linux_outputs() {
  local build_dir="$1"
  local dest_dir="${PROJECT_DIR}/linux/lib"
  local -a libs=()

  while IFS= read -r lib; do
    libs+=("${lib}")
  done < <(find "${build_dir}/bin" -maxdepth 1 -type f -name 'lib*.so' | sort)

  [[ "${#libs[@]}" -gt 0 ]] || die "No Linux shared libraries found in ${build_dir}/bin"

  remove_managed_libs "${dest_dir}" "${MANAGED_LINUX_LIBS[@]}"
  copy_files "${dest_dir}" "${libs[@]}"
  set_linux_rpath_if_possible "${dest_dir}"

  if [[ ! -f "${dest_dir}/libmtmd.so" ]]; then
    warn "libmtmd.so was not produced for Linux. Vision models will not work until it is bundled."
  fi
}

build_android_abi() {
  local abi="$1"
  local ndk_root="$2"
  local build_dir="${LLAMA_CPP_DIR}/build-pocketllama-android-${abi}"
  local -a cmake_args=(
    -S "${LLAMA_CPP_DIR}"
    -B "${build_dir}"
    -DCMAKE_TOOLCHAIN_FILE="${ndk_root}/build/cmake/android.toolchain.cmake"
    -DANDROID_ABI="${abi}"
    -DANDROID_PLATFORM="android-${ANDROID_PLATFORM}"
    -DANDROID_STL=c++_shared
    -DBUILD_SHARED_LIBS=ON
    -DCMAKE_BUILD_TYPE=Release
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_TOOLS=ON
    -DLLAMA_NATIVE=OFF
    -DLLAMA_CURL=OFF
    -DGGML_OPENMP=OFF
  )

  if [[ "${abi}" == "armeabi-v7a" ]]; then
    cmake_args+=(
      -DANDROID_ARM_NEON=ON
      -DGGML_LLAMAFILE=OFF
    )
  fi

  log "Configuring Android ${abi}"
  rm -rf "${build_dir}"
  cmake "${cmake_args[@]}"

  log "Building Android ${abi}"
  cmake --build "${build_dir}" --parallel "${CMAKE_JOBS}" --target llama mtmd

  log "Copying Android ${abi} libraries"
  copy_android_outputs "${abi}" "${build_dir}"
}

build_android() {
  local ndk_root

  require_command cmake
  ndk_root="$(find_latest_ndk)"
  [[ -d "${ndk_root}" ]] || die "Android NDK directory not found: ${ndk_root}"

  log "Using Android NDK ${ndk_root}"

  local abi
  for abi in "${ANDROID_ABIS[@]}"; do
    build_android_abi "${abi}" "${ndk_root}"
  done
}

build_linux() {
  local build_dir="${LLAMA_CPP_DIR}/build-pocketllama-linux"

  require_command cmake

  [[ "${HOST_OS}" == "Linux" ]] || die "Linux builds must be run on a Linux host."

  log "Configuring Linux"
  rm -rf "${build_dir}"
  cmake \
    -S "${LLAMA_CPP_DIR}" \
    -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_BUILD_RPATH=\$ORIGIN \
    -DCMAKE_INSTALL_RPATH=\$ORIGIN \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_NATIVE=OFF \
    -DLLAMA_CURL=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_BLAS=OFF \
    -DGGML_VULKAN=OFF

  log "Building Linux"
  cmake --build "${build_dir}" --parallel "${CMAKE_JOBS}" --target llama mtmd

  log "Copying Linux libraries"
  copy_linux_outputs "${build_dir}"
}

build_macos() {
  local build_dir="${LLAMA_CPP_DIR}/build-pocketllama-macos"

  require_command cmake

  log "Configuring macOS"
  rm -rf "${build_dir}"
  cmake \
    -S "${LLAMA_CPP_DIR}" \
    -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DBUILD_SHARED_LIBS=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_TOOLS=ON \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DLLAMA_NATIVE=OFF \
    -DLLAMA_CURL=OFF

  log "Building macOS"
  cmake --build "${build_dir}" --parallel "${CMAKE_JOBS}" --target llama mtmd

  log "Copying macOS libraries"
  copy_apple_outputs "${build_dir}" "${PROJECT_DIR}/macos/Runner/Frameworks"
}

build_ios_variant() {
  local variant_name="$1"
  local sysroot="$2"
  local dest_dir="$3"
  local metal_mode="$4"
  local build_dir="${LLAMA_CPP_DIR}/build-pocketllama-ios-${variant_name}"
  local -a cmake_args=(
    -S "${LLAMA_CPP_DIR}"
    -B "${build_dir}"
    -G Xcode
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_SYSROOT="${sysroot}"
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
    -DBUILD_SHARED_LIBS=ON
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_TOOLS=ON
    -DLLAMA_NATIVE=OFF
    -DLLAMA_CURL=OFF
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=-
  )

  if [[ "${metal_mode}" == "on" ]]; then
    cmake_args+=(
      -DGGML_METAL=ON
      -DGGML_METAL_EMBED_LIBRARY=ON
      -DGGML_ACCELERATE=ON
    )
  else
    cmake_args+=(
      -DGGML_METAL=OFF
      -DGGML_ACCELERATE=OFF
      -DGGML_BLAS=OFF
      -DGGML_CPU_ALL_VARIANTS=OFF
    )
  fi

  log "Configuring iOS ${variant_name}"
  rm -rf "${build_dir}"
  cmake "${cmake_args[@]}"

  log "Building iOS ${variant_name}"
  cmake --build "${build_dir}" --config Release --parallel "${CMAKE_JOBS}" --target llama mtmd -- -sdk "${sysroot}"

  log "Copying iOS ${variant_name} libraries"
  copy_apple_outputs "${build_dir}" "${dest_dir}"
}

build_ios_device() {
  build_ios_variant "device" "iphoneos" "${PROJECT_DIR}/ios" "on"
}

build_ios_simulator() {
  rm -f "${PROJECT_DIR}/ios/Frameworks/ios-libllama.dylib"
  build_ios_variant "simulator" "iphonesimulator" "${PROJECT_DIR}/ios/Frameworks" "off"

  if [[ -f "${PROJECT_DIR}/ios/Frameworks/libllama.dylib" ]]; then
    cp -f "${PROJECT_DIR}/ios/Frameworks/libllama.dylib" "${PROJECT_DIR}/ios/Frameworks/ios-libllama.dylib"
  fi
}

print_summary() {
  log "Android libraries:"
  find "${PROJECT_DIR}/android/app/src/main/jniLibs" -maxdepth 2 -type f | sort

  log "Linux libraries:"
  if [[ -d "${PROJECT_DIR}/linux/lib" ]]; then
    find "${PROJECT_DIR}/linux/lib" -maxdepth 1 -type f -name 'lib*.so' | sort
  fi

  log "iOS device libraries:"
  find "${PROJECT_DIR}/ios" -maxdepth 1 -type f -name 'lib*.dylib' | sort

  log "iOS simulator libraries:"
  find "${PROJECT_DIR}/ios/Frameworks" -maxdepth 1 -type f -name '*.dylib' | sort

  log "macOS libraries:"
  find "${PROJECT_DIR}/macos/Runner/Frameworks" -maxdepth 1 -type f -name 'lib*.dylib' | sort
}

main() {
  if [[ "$#" -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
  fi

  assert_paths
  local target_commit
  target_commit="$(resolve_target_llama_cpp_commit)"
  log "Target llama.cpp ref for current Flutter dependency: ${target_commit}"
  sync_llama_cpp_checkout "${target_commit}"

  local build_android_requested=0
  local build_linux_requested=0
  local build_macos_requested=0
  local build_ios_device_requested=0
  local build_ios_sim_requested=0

  if [[ "$#" -eq 0 ]]; then
    if [[ "${HOST_OS}" == "Linux" ]]; then
      build_linux_requested=1
    else
      build_android_requested=1
      build_macos_requested=1
      build_ios_device_requested=1
      build_ios_sim_requested=1
    fi
  else
    local arg
    for arg in "$@"; do
      case "${arg}" in
        all)
          if [[ "${HOST_OS}" == "Linux" ]]; then
            build_linux_requested=1
          else
            build_android_requested=1
            build_macos_requested=1
            build_ios_device_requested=1
            build_ios_sim_requested=1
          fi
          ;;
        android)
          build_android_requested=1
          ;;
        linux)
          build_linux_requested=1
          ;;
        macos)
          build_macos_requested=1
          ;;
        ios)
          build_ios_device_requested=1
          build_ios_sim_requested=1
          ;;
        ios-device)
          build_ios_device_requested=1
          ;;
        ios-simulator)
          build_ios_sim_requested=1
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          usage
          die "Unknown target: ${arg}"
          ;;
      esac
    done
  fi

  if [[ "${build_android_requested}" -eq 1 ]]; then
    build_android
  fi

  if [[ "${build_linux_requested}" -eq 1 ]]; then
    build_linux
  fi

  if [[ "${build_macos_requested}" -eq 1 ]]; then
    require_command xcodebuild
    build_macos
  fi

  if [[ "${build_ios_device_requested}" -eq 1 ]]; then
    require_command xcodebuild
    build_ios_device
  fi

  if [[ "${build_ios_sim_requested}" -eq 1 ]]; then
    require_command xcodebuild
    build_ios_simulator
  fi

  print_summary
}

main "$@"
