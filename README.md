<p align="center">
  <img src="assets/icons/pocketllm_new.png" width="120" alt="Pocket LLM Logo">
</p>

# Pocket LLM

Pocket LLM is a **privacy-first mobile AI assistant that runs entirely on your device**.  
It enables **on-device Local Language Model (LLM) inference using GGUF models** with `llama_cpp_dart`, allowing you to chat with AI **without sending your data to external servers**.

Unlike most AI apps that rely on cloud APIs, **Pocket LLM performs all inference locally on your phone**. Your prompts, conversations, and models remain **fully under your control**, making it suitable for users who value **privacy, offline capability, and ownership of their data**.

The app is designed as a **mobile-first local AI runtime**, providing a smooth chat experience with model downloads, streaming responses, and per-model chat memory — all running directly **on-device**.

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
- Live token streaming in chat with `Thinking...` + progressive output
- Stop generation anytime
- Per-model chat memory (switching models keeps separate threads)
- Regenerate assistant reply + Edit & Resend user prompts
- Generation stats per assistant message (`tok/s`, elapsed time, token count)
- Markdown-like code fence rendering + one-tap copy for code blocks
- Adaptive generation mode for mobile performance tuning
- Sampling presets: `Precise`, `Balanced`, `Creative`
- Advanced override for `temperature` and `top-p`
- Built-in model catalog + custom model links
- Chunked/resumable downloads with progress + pause
- Local notification when a model download completes

### Model Management

- Built-in model list (Qwen, Qwen Coder, Llama 3.2, SmolLM2, Gemma, Phi, TinyLlama)
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
- Last 5 messages are sent as prompt context to keep runtime stable
- GGUF signature checks to reject invalid/corrupt downloads

## Tech Stack

- Flutter + Material 3
- Riverpod (`flutter_riverpod`, `riverpod_annotation`)
- `llama_cpp_dart` for local LLM runtime
- Dio for model downloads (chunked + resumable)
- `flutter_secure_storage` for persisted app data
- `flutter_local_notifications` for download-complete notifications
- GoRouter for navigation
- Firebase Core + Crashlytics

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
└── firebase_initializer.dart
```

## Getting Started

### Prerequisites

- Flutter SDK `^3.10.8`
- Android Studio / Xcode toolchain

### Setup

```bash
# 1) Install dependencies
flutter pub get

# 2) Ensure env file exists (required by startup)
cp .env.example .env

# 3) Run app
flutter run
```

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

## Troubleshooting

### `HTTP 401/403` while downloading model

Your link is likely private/protected or not a direct public GGUF file.
Use a public direct URL ending with `.gguf`.

### `Prompt token count exceeds batch capacity`

Your prompt/context is too large for current runtime settings.
The app already limits history context, but very long prompts can still overflow.
Use shorter prompts or a larger-capability model/runtime config.

### `Failed to initialize model`

Usually indicates unsupported/corrupt GGUF or incomplete file.
Delete and re-download the model.

### iOS simulator model load failures

Large model/runtime combinations may fail or behave differently on simulator.
Test on a physical iOS device for reliable on-device inference behavior.

## Privacy

- Inference runs on-device
- Chat threads and settings are persisted locally via secure storage
- No cloud inference backend is required for chat generation

## License

This project is licensed under **GNU GPL v3**.
See [LICENSE](LICENSE).
