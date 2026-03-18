Bundled llmfit assets live here.

Current contents:
- `macos/arm64/llmfit`: bundled Apple Silicon macOS binary used by the app.
- `android/arm64-v8a/llmfit`: bundled Android arm64 binary used by the app.

Planned / supported asset paths in app code:
- `android/arm64-v8a/llmfit`
- `android/x86_64/llmfit`
- `linux/x64/llmfit`
- `linux/arm64/llmfit`
- `macos/x64/llmfit`
- `windows/x64/llmfit.exe`

Android arm64 build hook:
- Set `POCKET_LLMFIT_ANDROID_ARM64_SOURCE=/absolute/path/to/llmfit`
- Then run your normal Android build command.
- The Gradle task `bundleLlmfitAndroidArm64` will copy that binary to:
  `assets/tools/llmfit/android/arm64-v8a/llmfit`
- The Gradle task `syncLlmfitAndroidArm64JniLib` will also copy it into:
  `build/generated/llmfit/jniLibs/arm64-v8a/libllmfit_cli.so`
  so Android installs it under the app native library directory.

Android arm64 source build script:
- Run `./scripts/build_llmfit_android.sh`
- It will:
  clone upstream `llmfit`
  install/prepare Rust target tooling if needed
  cross-compile `llmfit` for `arm64-v8a`
  copy the result to `assets/tools/llmfit/android/arm64-v8a/llmfit`
  strip the binary with the Android NDK toolchain when available

Notes:
- On Android, the app resolves the packaged binary from the native library directory.
- On macOS and desktop-style targets, the app extracts bundled binaries to app support storage and runs them from there.
- iOS is intentionally excluded because the app hides the LLMFit tab on iOS and simulator targets.
