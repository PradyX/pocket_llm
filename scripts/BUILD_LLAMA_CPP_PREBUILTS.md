# Building PocketLlama llama.cpp libraries

The app pins `llama_cpp_dart: 0.9.0-dev.10` and its matching llama.cpp revision:

```
afeebe103bd99cda8f5dfaefcabadf890db7fda7 (b10182)
```

This prerelease is the newest binding compatible with the project's Flutter
3.38.9 SDK. `0.9.0-dev.12` requires Flutter 3.44 and uses the same native pin.
The 0.9 API is a rewrite: PocketLlama uses `LlamaEngine` worker isolates,
`EngineSession`, streaming token events, and `LlamaMedia` for images.

The pinned native source includes `qwen35`, `qwen35moe`, and `qwen3next`
architectures. Individual GGUF files still need compatible quantization,
adequate memory, and (for vision) a matching projector.

## Build

Run `flutter pub get` first. The script resolves the locked package in the pub
cache and reads its `lib/src/version.dart` native ABI pin. It also supports the
older package's pubspec comment format. Never update native libraries alone:
FFI structure layouts and symbols must match the Dart package.

```bash
# macOS: Android, universal macOS, arm64 iOS device and simulator
scripts/build_llama_native_libs.sh all

# Individual targets
scripts/build_llama_native_libs.sh android
scripts/build_llama_native_libs.sh macos
scripts/build_llama_native_libs.sh ios

# Run on a Linux host
LLAMA_CPP_DIR=/path/to/llama.cpp scripts/build_llama_native_libs.sh linux
```

Default source locations are `/Users/prady/FlutterProjects/llama.cpp` on macOS
and `/home/prady/flutter-projects/llama.cpp` on Linux. Override with
`LLAMA_CPP_DIR`. Build products live in `build/llama-native/` (override with
`BUILD_ROOT`). The source checkout must be clean. The script fetches and checks
out the required revision; use `SKIP_GIT_FETCH=1` if it is already available.
`SKIP_GIT_CHECKOUT=1` still verifies that HEAD matches the required ABI pin.

Android requires an NDK (`ANDROID_NDK_ROOT` can select it); the script builds
arm64-v8a, armeabi-v7a, and x86_64. It statically links the C++ runtime and enables
flexible page sizes. PocketLlama manages JNI libraries itself; do not add a
second AAR containing a different llama runtime.

Apple builds require Xcode and the appropriate SDKs. macOS builds arm64 and
x86_64; iOS builds arm64 device and arm64 simulator separately. Metal is enabled
for macOS/device and disabled for the simulator.

## Installed outputs

| Target | Destination |
| --- | --- |
| Android | `android/app/src/main/jniLibs/<abi>/` |
| macOS | `macos/Runner/Frameworks/` |
| iOS device | `ios/` |
| iOS simulator | `ios/Frameworks/` |
| Linux | `linux/lib/` |

Always replace the entire `libllama`, `libmtmd`, and `libggml*` family together.
The app passes the bundled **libllama** path to the engine; the new binding opens
sibling **libmtmd** for multimodal symbols. The existing `POCKET_LLM_MTMD_PATH`
override still selects the containing runtime directory.

Native binaries are gitignored and must be rebuilt on each build machine.
Linux binaries must be rebuilt on Linux before packaging a Linux release.
After rebuilding, restart the app completely so no old native library remains
loaded. Run `flutter test` and exercise text generation, Stop, model switching,
and image generation with a matching projector on each target device.

For a desktop ABI/tokenizer smoke test (no model weights required):

```bash
dart run tool/smoke_llama_runtime.dart \
  "$PWD/macos/Runner/Frameworks/libllama.dylib" \
  "$LLAMA_CPP_DIR/models/ggml-vocab-qwen35.gguf"
```

Pass a full model GGUF as a third argument to also test worker-isolate
inference and repeated session reset. This does not validate image inference;
that requires a full vision model and its matching projector.

## Linux release artifact alternative

On a non-Linux build machine, the exact upstream release also provides
[Ubuntu x64 binaries](https://github.com/ggml-org/llama.cpp/releases/download/b10182/llama-b10182-bin-ubuntu-x64.tar.gz).
The archive SHA-256 is
`9a087d633cc03a8e93f2d689bc80adbfb680efca025bc9a328d5e186d528757a`.
The current local Linux bundle was refreshed from that verified archive.

Copy the complete `libllama.so*`, `libmtmd.so*`, `libggml.so*`,
`libggml-base.so*`, and `libggml-cpu-*.so` families together, preserving the
relative SONAME symlinks. This release loads CPU variants dynamically instead
of using a single `libggml-cpu.so`. Its libraries use `$ORIGIN` to find siblings.
It requires glibc 2.34 or newer plus the C++/OpenMP system runtimes; build from
source on your target Linux distribution when broader compatibility is needed.
Linux execution must still be tested on Linux.

To exercise PocketLlama's service itself with local native libraries:

```bash
POCKET_LLM_TEST_MODEL=/absolute/path/to/model.gguf \
POCKET_LLM_MTMD_PATH="$PWD/macos/Runner/Frameworks/libmtmd.dylib" \
flutter test test/llm_service_native_test.dart
```

This checks generation, Stop, model reuse, the prediction limit, and unloading.
The native integration test is skipped in ordinary test runs without a model.
