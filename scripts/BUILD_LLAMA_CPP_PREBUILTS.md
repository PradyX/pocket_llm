# Building PocketLlama Llama.cpp Prebuilts

PocketLlama currently depends on:

```yaml
llama_cpp_dart: 0.2.2
```

For this binding version, the matching `llama.cpp` revision is:

```text
4ffc47cb2001e7d523f9ff525335bbe34b1a2858
```

Rules:

- Do not mix `0.1.x`-era prebuilts with `llama_cpp_dart 0.2.2`.
- Do not copy only `libllama` and leave older `libmtmd` / `ggml` libraries in place.
- Replace each platform's full library set together.

## What PocketLlama Loads

PocketLlama resolves:

- Android: `libmtmd.so`
- Apple platforms: `libmtmd.dylib`

Those libraries then depend on the matching `llama` and `ggml` libraries from the same build.

Today the project already contains:

- Android app-local JNI libs under `android/app/src/main/jniLibs/`
- macOS dylibs under `macos/Runner/Frameworks/`

So the safest update flow is:

1. Build a matching runtime set.
2. Replace the whole set for the target platform.
3. Run `flutter clean` before testing.

## Source Checkout To Build From

Build from a checkout of the `llama_cpp_dart` repository that matches the Dart package version you are using.

At minimum, verify:

- the checkout's `pubspec.yaml` says `version: 0.2.2`
- its `src/llama.cpp` submodule is on `4ffc47cb2001e7d523f9ff525335bbe34b1a2858`

Example setup:

```bash
export LLAMA_CPP_DART_SRC="$HOME/src/llama_cpp_dart"
export POCKET_LLAMA="/Users/prady/FlutterProjects/PocketLlama"

cd "$LLAMA_CPP_DART_SRC"
git submodule update --init --recursive
git -C src/llama.cpp checkout 4ffc47cb2001e7d523f9ff525335bbe34b1a2858
```

If your clone is older and does not match `0.2.2`, update the wrapper checkout first before building.

## Android

### Important Differences From The Old Doc

- The old doc cloned bare `llama.cpp`. That is not enough for the current Android build.
- `llama_cpp_dart 0.2.2` defines the Android `mtmd` shared library in the wrapper CMake, not in PocketLlama.
- The current `0.2.2` Android build flow is aligned around `arm64-v8a` and `x86_64`.
- The package ships OpenCL helper libs only for `arm64-v8a` and `x86_64`, not `armeabi-v7a`.

If you still keep `armeabi-v7a` in PocketLlama, treat it as a separate legacy path and test it independently. Do not assume the `0.2.2` OpenCL-enabled flow covers it.

### NDK

The upstream `llama_cpp_dart 0.2.2` Android library build file asks for:

```text
29.0.13846066
```

On this machine, the installed NDKs include:

```text
25.1.8937393
28.2.13676358
29.0.14206865
```

Before building, do one of these:

- install NDK `29.0.13846066`, or
- temporarily change the clone's `android/llamalib/build.gradle` to `29.0.14206865`

Using a 29.x NDK is the right direction for this stack.

### Build The Android AAR

```bash
cd "$LLAMA_CPP_DART_SRC"
./android/build-android-aar.sh
```

Expected output:

```text
$LLAMA_CPP_DART_SRC/android/llamalib/build/outputs/aar/llamalib-release.aar
```

### Extract The Native Libraries

```bash
export AAR="$LLAMA_CPP_DART_SRC/android/llamalib/build/outputs/aar/llamalib-release.aar"
export AAR_UNPACK="$LLAMA_CPP_DART_SRC/android/aar-unpacked"

rm -rf "$AAR_UNPACK"
mkdir -p "$AAR_UNPACK"
unzip -o "$AAR" -d "$AAR_UNPACK"
find "$AAR_UNPACK/jni" -maxdepth 2 -type f | sort
```

You should see ABI folders containing a matching set of `.so` files. The important ones for PocketLlama are:

- `libmtmd.so`
- `libllama.so`
- `libggml.so`
- `libggml-base.so`
- `libggml-cpu.so`

### Copy Into PocketLlama

```bash
mkdir -p "$POCKET_LLAMA/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$POCKET_LLAMA/android/app/src/main/jniLibs/x86_64"

rsync -av "$AAR_UNPACK/jni/arm64-v8a/" "$POCKET_LLAMA/android/app/src/main/jniLibs/arm64-v8a/"
rsync -av "$AAR_UNPACK/jni/x86_64/" "$POCKET_LLAMA/android/app/src/main/jniLibs/x86_64/"
```

If you intentionally maintain `armeabi-v7a`, do not reuse old `0.1.x` binaries with these new ones.

### Quick Validation

```bash
find "$POCKET_LLAMA/android/app/src/main/jniLibs" -maxdepth 2 -type f | sort
```

PocketLlama should no longer be in the state where Android only has `libllama.so` but no `libmtmd.so`.

## macOS

For macOS, PocketLlama already embeds the Apple dylibs from:

```text
macos/Runner/Frameworks/
```

Replace that whole dylib set together.

### Build

From the same matching `llama_cpp_dart` checkout:

```bash
cd "$LLAMA_CPP_DART_SRC"
git submodule update --init --recursive
git -C src/llama.cpp checkout 4ffc47cb2001e7d523f9ff525335bbe34b1a2858
bash darwin/run_build.sh src/llama.cpp <YOUR_APPLE_TEAM_ID> MAC_ARM64
```

If your clone's `darwin/build.sh` hardcodes someone else's Apple Development Team, do not use it as-is.

Expected output directory:

```text
$LLAMA_CPP_DART_SRC/bin/MAC_ARM64
```

Expected files include:

- `libmtmd.dylib`
- `libllama.dylib`
- `libggml.dylib`
- `libggml-base.dylib`
- `libggml-cpu.dylib`
- `libggml-metal.dylib`
- `libggml-blas.dylib`

### Copy Into PocketLlama

```bash
rsync -av "$LLAMA_CPP_DART_SRC/bin/MAC_ARM64/" "$POCKET_LLAMA/macos/Runner/Frameworks/"
```

### Quick Validation

```bash
find "$POCKET_LLAMA/macos/Runner/Frameworks" -maxdepth 1 -type f | sort
```

Do not replace only `libllama.dylib`. Keep the whole dylib family in sync.

## After Replacing Libraries

```bash
cd "$POCKET_LLAMA"
flutter clean
flutter pub get
flutter run -d macos
```

For Android:

```bash
cd "$POCKET_LLAMA"
flutter clean
flutter pub get
flutter run -d android
```

## Known Limitation: Qwen 3.5

Matching the native build to `llama_cpp_dart 0.2.2` fixes version skew. It does not automatically guarantee support for every new GGUF architecture.

Your failing model reports:

```text
general.architecture = qwen35
```

Even after moving PocketLlama to `llama_cpp_dart 0.2.2`, the shipped runtime still appears to expose `qwen3`-family support but not `qwen35`. So:

- rebuilding from the correct commit is still the right thing to do
- but a successful rebuild may still not make Qwen 3.5 load

If Qwen 3.5 still fails after following this doc, the next problem is likely runtime feature support, not build mismatch.
