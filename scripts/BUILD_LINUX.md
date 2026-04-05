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

On Arch Linux, the equivalent build packages are typically:

```bash
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 libsecret jsoncpp patchelf
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

## 3. Run The App During Development

```bash
cd /path/to/PocketLlama
flutter clean
flutter pub get
flutter run -d linux
```

## 4. Build The Release Bundle

```bash
cd /path/to/PocketLlama
flutter build linux
```

Flutter writes a relocatable Linux bundle to one of:

```text
build/linux/x64/release/bundle/
build/linux/arm64/release/bundle/
```

The executable inside the bundle is:

```text
bundle/pocket_llm
```

## 5. Create An Installable Archive

To package the Linux bundle into a release archive:

```bash
cd /path/to/PocketLlama
scripts/build_linux_archive.sh
```

That script:

- runs `flutter build linux --release`
- finds the generated Flutter bundle
- creates a compressed archive next to the release bundle

Expected output:

```text
build/linux/x64/release/pocket_llm-linux-x64.tar.gz
build/linux/arm64/release/pocket_llm-linux-arm64.tar.gz
```

## 6. Install On A Linux Machine

On the target machine, install the runtime libraries your distro needs.

On Debian/Ubuntu, a typical runtime set is:

```bash
sudo apt install libgtk-3-0 libsecret-1-0 libjsoncpp1
```

On Arch Linux, the typical runtime set is:

```bash
sudo pacman -S --needed gtk3 libsecret jsoncpp
```

Then extract the archive somewhere permanent, for example:

```bash
sudo mkdir -p /opt/pocket-llm
sudo tar -xzf pocket_llm-linux-x64.tar.gz -C /opt/pocket-llm --strip-components=1
```

Run it with:

```bash
/opt/pocket-llm/pocket_llm
```

Optional convenience symlink:

```bash
sudo ln -sf /opt/pocket-llm/pocket_llm /usr/local/bin/pocket-llm
```

That same extraction flow works on Arch:

```bash
sudo mkdir -p /opt/pocket-llm
sudo tar -xzf pocket_llm-linux-x64.tar.gz -C /opt/pocket-llm --strip-components=1
sudo ln -sf /opt/pocket-llm/pocket_llm /usr/local/bin/pocket-llm
```

## 7. Add A Desktop Launcher

PocketLlama's installed icon inside the Flutter bundle is typically:

```text
/opt/pocket-llm/data/flutter_assets/assets/icons/pocketllm_new.png
```

For a per-user launcher on Ubuntu, Arch, or most other Linux desktops:

```bash
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/pocket-llm.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Pocket LLM
Comment=Privacy-first local AI assistant
Exec=/opt/pocket-llm/pocket_llm
Icon=/opt/pocket-llm/data/flutter_assets/assets/icons/pocketllm_new.png
Terminal=false
Categories=Utility;Development;
StartupNotify=true
EOF

chmod +x ~/.local/share/applications/pocket-llm.desktop
```

For a system-wide launcher:

```bash
sudo tee /usr/share/applications/pocket-llm.desktop >/dev/null <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Pocket LLM
Comment=Privacy-first local AI assistant
Exec=/opt/pocket-llm/pocket_llm
Icon=/opt/pocket-llm/data/flutter_assets/assets/icons/pocketllm_new.png
Terminal=false
Categories=Utility;Development;
StartupNotify=true
EOF
```

On some desktops, logging out and back in or refreshing the application menu may be needed before the launcher appears.

## Notes

- Linux notifications depend on a running Freedesktop notification daemon in the desktop session.
- `flutter_secure_storage` uses the Linux keyring when available. PocketLlama falls back to app-local storage if the keyring backend is unavailable at runtime.
- If you change the bundled native libraries, run `flutter clean` before retesting so Flutter rebuilds the Linux bundle cleanly.
- The release archive is a relocatable bundle, not a `.deb`. If you want distro-native packaging later, use the generated bundle as the input to your packaging tool.
