# Building PocketLlama On Linux

This guide covers the Linux-specific pieces that are easy to miss:

- desktop toolchain prerequisites
- bundled `llama.cpp` runtime libraries for PocketLlama vision support
- bundled `llmfit` benchmark CLI assets

For the platform-agnostic native runtime background, also see `scripts/BUILD_LLAMA_CPP_PREBUILTS.md`.

## Prerequisites

Enable Flutter's Linux desktop target:

```bash
flutter config --enable-linux-desktop
```

Install the Linux build dependencies that Flutter, GTK, and `flutter_secure_storage` need. On Debian/Ubuntu, a typical baseline is:

```bash
sudo apt update
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev patchelf
```

If you want to build the bundled `llmfit` binary too, install Rust with `rustup` and make sure `cargo` is on your `PATH`.

## 1. Build The Linux Runtime Libraries

PocketLlama bundles Linux shared libraries from `linux/lib/`.
Build them from the same `llama.cpp` revision that matches the checked-in `llama_cpp_dart` package:

```bash
export LLAMA_CPP_DIR="$HOME/src/llama.cpp"
cd /path/to/PocketLlama
scripts/build_llama_native_libs.sh linux
```

Expected output files:

```text
linux/lib/libmtmd.so
linux/lib/libllama.so
linux/lib/libggml.so
linux/lib/libggml-base.so
linux/lib/libggml-cpu.so
```

`libmtmd.so` is the important one for multimodal/vision support. If it is missing, text inference may still work, but projector-based models will not.

## 2. Build The Linux `llmfit` Asset

PocketLlama can also bundle a Linux `llmfit` CLI for the benchmark screen.
Build the host-architecture binary with:

```bash
cd /path/to/PocketLlama
scripts/build_llmfit_linux.sh
```

This writes one of:

```text
assets/tools/llmfit/linux/x64/llmfit
assets/tools/llmfit/linux/arm64/llmfit
```

You can override the target triple with `LLMFIT_TARGET` if you already have the matching Rust toolchain installed.

## 3. Run Or Build The App

```bash
cd /path/to/PocketLlama
flutter clean
flutter pub get
flutter run -d linux
```

Or build a distributable bundle:

```bash
flutter build linux
```

## Notes

- Linux notifications depend on a running Freedesktop notification daemon in the desktop session.
- `flutter_secure_storage` uses the Linux keyring when available. PocketLlama falls back to app-local storage if the keyring backend is unavailable at runtime.
- If you change the bundled native libraries, run `flutter clean` before retesting so Flutter rebuilds the Linux bundle cleanly.
