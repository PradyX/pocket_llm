<p align="center">
  <img src="assets/icons/pocketllm_new.png" width="120" alt="Pocket LLM Logo">
</p>

# Pocket LLM

Pocket LLM is a **privacy-first local AI assistant that runs entirely on your device**.  
It enables **on-device Local Language Model (LLM) inference using GGUF models** with `llama_cpp_dart`, allowing you to chat with AI **without sending your data to external servers**.

Unlike most AI apps that rely on cloud APIs, **Pocket LLM performs all inference locally on your phone or desktop**. Your prompts, conversations, and models remain **fully under your control**, making it suitable for users who value **privacy, offline capability, and ownership of their data**.

The app is designed as a **mobile-first local AI runtime** that now also supports desktop workflows, providing a smooth chat experience with model downloads, streaming responses, and per-model chat memory — all running directly **on-device**.

Because inference happens locally:

- No prompts leave your device
- No cloud processing is required
- No usage tracking of your conversations
- Works even without an internet connection (after models are downloaded)

Pocket LLM focuses on bringing **personal AI to your pocket** — lightweight, private, and fully local.

<p align="center">
  <img src="screens/1.png" width="18%" />
  <img src="screens/2.png" width="18%" />
  <img src="screens/3.png" width="18%" />
  <img src="screens/4.png" width="18%" />
  <img src="screens/5.png" width="18%" />
</p>

## Highlights

- Local inference with GGUF models (no server required for generation)
- **Vision Model Support**: Multimodal chat with image support (projector-based)
- **On-device Benchmarking**: Integrated `llmfit` to measure local performance
- Live token streaming in chat with `Thinking...` + progressive output
- Stop generation anytime
- **Multiple local conversations**: create, rename, search, pin and delete chats
- **Switch models inside a conversation** without losing chat history
- Per-message model attribution and generation stats
- Export/import conversations as versioned JSON (clipboard flow)
- Regenerate assistant reply + Edit & Resend user prompts
- Generation stats per assistant message (`tok/s`, elapsed time, token count, input tokens)
- Context usage readout above the composer (used vs. available input tokens, with a note when older messages were trimmed to fit)
- **Inference profiles**: Balanced, Battery Saver, Maximum Performance, or your own saved runtime configuration
- **Personas**: reusable system prompts (General, Coding, Research, Creative, Concise, or your own) chosen per conversation
- Markdown-like code fence rendering + one-tap copy for code blocks
- Adaptive generation mode for mobile performance tuning
- Sampling presets: `Precise`, `Balanced`, `Creative`
- Advanced override for `temperature` and `top-p`
- Built-in model catalog + custom model links
- Chunked/resumable downloads with progress + pause
- Local notification when a model download completes
- **macOS + Linux Desktop Support**: Desktop-ready local runtime and benchmarking flow

### Model Management

- **Model Search**: Quick filtering by name or parameter size
- Built-in model list (Qwen, Qwen Coder, Llama 3.2, SmolLM2, Gemma, Phi, TinyLlama)
- **HF Compatibility Detection**: Automatic detection of model capabilities
- Add custom models from direct `.gguf` URL
- Custom model validation:
  - URL required (`http/https`)
  - direct `.gguf` link required
  - model name required
  - parameter size required (format like `1.5B`, `800M`, `360M`)
- Sort models by parameter size
- Expand each model tile to inspect full metadata
- Select active downloaded model from toolbar dropdown

### Performance & Inference

- Mobile-focused context setup (`nCtx`/`nBatch` tuned for device class)
- Adaptive max-token behavior based on hardware + observed generation speed
- **Token-aware context**: the prompt is assembled against the loaded model's context window and output reservation, keeping the system prompt and the newest turns, and dropping older ones only when the budget runs out
- **Inference profiles**: context size, threads, GPU offload and sampling in one named configuration, applied to every model
- **Personas**: the system prompt lives with the conversation, not with the model, so the same chat history can switch voice without losing context
- GGUF signature checks to reject invalid/corrupt downloads

## Tech Stack

- Flutter + Material 3
- Riverpod (`flutter_riverpod`, `riverpod_annotation`)
- `llama_cpp_dart` for local LLM runtime
- Dio for model downloads (chunked + resumable)
- `flutter_secure_storage` for persisted app data, with Linux compatibility fallback when the system keyring is unavailable
- `flutter_local_notifications` for download-complete notifications
- GoRouter for navigation

## Project Structure

```text
lib/
├── main.dart
├── app.dart
├── core/
│   ├── navigation/app_router.dart
│   ├── services/
│   │   ├── llm_service.dart
│   │   ├── model_storage_service.dart
│   │   ├── storage_info_service.dart
│   │   └── local_notification_service.dart
│   ├── settings/inference_settings_provider.dart
│   └── theme/
├── features/
│   ├── about/
│   │   └── presentation/about_page.dart
│   ├── home/
│   │   ├── domain/chat_message.dart
│   │   └── presentation/
│   │       ├── home_page.dart
│   │       └── home_controller.dart
│   ├── model_selection/
│   │   ├── domain/llm_model.dart
│   │   └── presentation/
│   │       ├── model_selection_page.dart
│   │       ├── model_selection_controller.dart
│   │       └── model_selection_state.dart
│   └── settings/presentation/settings_page.dart
├── storage/secure_storage.dart
```

## Getting Started

### Prerequisites

- Flutter SDK `^3.10.8`
- Android Studio / Xcode / Linux desktop toolchain depending on your target platform

For Linux desktop development, enable the Flutter desktop target and install the Linux build dependencies that Flutter, `flutter_secure_storage`, and the desktop shell need. On Debian/Ubuntu-based systems, a typical setup is:

```bash
flutter config --enable-linux-desktop
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev
```

If you also want the bundled Linux benchmark CLI, install Rust with `rustup` as well.

### Setup

```bash
# 1) Install dependencies
flutter pub get

# 2) Ensure env file exists (required by startup)
cp .env.example .env

# 3) Run app for your target platform
flutter run -d android
# or
flutter run -d macos
# or
flutter run -d linux
```

On macOS, prefer `scripts/run_macos.sh` over a bare `flutter run -d macos`: it renews the development provisioning profile, which Apple issues for only seven days on a free Personal Team and which the Flutter macOS builder cannot renew on its own. See [scripts/run_macos.sh](scripts/run_macos.sh) for the details and flags.

For Linux-specific native runtime, benchmark asset, and installable release archive steps, see [scripts/BUILD_LINUX.md](scripts/BUILD_LINUX.md).

### If you change Riverpod annotations

```bash
dart run build_runner build --delete-conflicting-outputs
```

## How To Use

1. Open **Model Selection** from drawer.
2. Download a built-in model or add your own GGUF link.
3. Select a downloaded model.
4. Start chatting on Home.
5. Use `Stop`, `Regenerate`, or `Edit & Resend` for quick iteration.

### Conversations

- Tap the **new chat** icon on Home to start a conversation.
- Open **Conversations** in the drawer to search, rename, pin, delete, export or import chats.
- Switching models inside a conversation keeps its history; every assistant reply records the model that generated it.
- Conversations are stored locally as versioned JSON (`conversations/` under the app support directory).
- Existing per-model chats from older versions are migrated into conversations automatically on first launch; the original secure-storage backup (`model_chat_threads_v1`) is left untouched.

### Context and memory

- Every request is assembled against a token budget derived from the model's context window, the tokens reserved for the answer and the safety margin; the system prompt always stays, and older turns are dropped oldest-first only when the budget runs out.
- The readout above the composer shows the input budget in use and says when older or shortened messages were trimmed to fit; tap it for the window and reservation details.
- Token counts are estimates (~4 characters per token plus per-message overhead) because the bundled runtime exposes no tokenizer, so the budget is kept conservative on purpose.

### Inference Profiles

- Open **Inference Profiles** in the drawer to see what the active profile resolves to on this device, and to switch between profiles.
- Built-ins: `Balanced` (app defaults), `Battery Saver` (1024 context, 2 threads, CPU only, short answers) and `Maximum Performance` (8192 context, full GPU offload, longer answers). Built-ins are read-only — duplicate one to get an editable copy.
- A custom profile sets only what you choose: context size, prompt batch size, threads, GPU layers, KV cache placement, sampling and maximum answer length. Everything else keeps the app default for the device.
- Profiles are stored locally as versioned JSON (`inference_profiles/` under the app support directory) and apply to every model; switching profiles mid-conversation reloads the model with the new settings.

### Personas

- Tap the persona chip in the chat header to pick the persona for that conversation, or open **Personas** in the drawer to manage them.
- Built-ins: `General` (the app default prompt), `Coding`, `Research`, `Creative` and `Concise`. They are read-only — duplicate one to edit it.
- A custom persona sets a system prompt and can prefer a model and an inference profile; the editor shows what the prompt costs in tokens. Unset preferences keep the app defaults.
- Each conversation remembers its persona, so switching voice never touches history. Conversations from older versions keep working and use the current default persona.
- Personas are stored locally as versioned JSON (`personas/` under the app support directory), and a persona can be copied to the clipboard and imported back as a custom copy.

## Troubleshooting

### `HTTP 401/403` while downloading model

Your link is likely private/protected or not a direct public GGUF file.
Use a public direct URL ending with `.gguf`.

### `Prompt token count exceeds batch capacity`

Your prompt/context is too large for current runtime settings.
The app assembles the prompt against a token budget derived from the model's context window and the configured output length; the readout above the composer shows how full that budget is. Token counts are estimates, so a very long message or attached image can still overflow.
Start a new chat, shorten the prompt, lower the maximum output tokens, or switch to a profile with a smaller context (for example `Battery Saver`).

### Responses ignore my persona

A persona only replaces the system prompt. If the model was trained with a strong chat format, very short prompts can be overridden by the conversation itself — make the persona prompt explicit about tone, length and structure, and check the token cost shown in the editor.

### `Failed to initialize model`

Usually indicates unsupported/corrupt GGUF or incomplete file.
Delete and re-download the model.

### iOS simulator model load failures

Large model/runtime combinations may fail or behave differently on simulator.
Test on a physical iOS device for reliable on-device inference behavior.

### Linux build fails with `libsecret` / `jsoncpp` errors

Install the Linux desktop prerequisites before running `flutter run -d linux` or `flutter build linux`.
On Debian/Ubuntu, the usual packages are:

```bash
sudo apt install libsecret-1-dev libjsoncpp-dev
```

Your distro may use a different runtime package name for `jsoncpp`.

### Linux notifications do not appear

Pocket LLM uses the Freedesktop notifications API on Linux.
You need a running desktop notification daemon/session for notifications to show.

### Linux secure storage falls back to local file storage

On Linux, `flutter_secure_storage` depends on the system keyring.
If the keyring is unavailable or locked, Pocket LLM automatically falls back to app-local storage so the app can still run.
Install and unlock a supported keyring if you want the platform-backed secure store.

## Privacy

- Inference runs on-device
- Conversations are stored locally as versioned JSON under the app support directory; settings and keys stay in secure storage
- No cloud inference backend is required for chat generation

## Credits

- [llama.cpp](https://github.com/ggerganov/llama.cpp) - High-performance LLM inference in C/C++.
- [llmfit](https://github.com/PradyX/llmfit) - LLM benchmarking tool.

## License

This project is licensed under **GNU GPL v3**.
See [LICENSE](LICENSE).
