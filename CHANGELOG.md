# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- **Conversation & data architecture (Roadmap Phase 1)**: conversations are now independent from models.
  - Create, rename, delete, search and pin multiple local conversations.
  - Switch the active model inside a conversation without losing or duplicating history.
  - Every assistant message records the model that generated it, plus per-message generation stats.
  - Export/import conversations as versioned JSON (clipboard flow, no new dependencies).
  - Automatic migration of existing per-model chat threads into conversations on upgrade; the legacy secure-storage entry (`model_chat_threads_v1`) is kept as a backup.
  - Conversations are persisted in a versioned file store (`conversations/index.json` plus one file per conversation) under the app support directory.
- **Model management (Roadmap Phase 2)**: models can now be added from the device or from Hugging Face.
  - Import a local `.gguf` file: Pocket LLM reads the GGUF metadata first, then copies it into app storage (`Copy to app`) or, on desktop, references it where it already lives (`Keep in place`).
  - Imported models are tracked as *managed* (the app owns the file, so removing the model deletes the copy) or *external* (the app only references the path; the original file is never deleted or moved).
  - Duplicate detection warns before importing when the same file is already referenced or a same-named file exists in app storage, and an import never overwrites an existing model file.
  - GGUF metadata inspector: architecture, parameter count, quantization, context length, embedding size, layers, tokenizer, special tokens, chat template and vision/projector information, read from the file itself instead of the file name.
  - New Model Details screen, reachable from any model in the model list, showing source/storage information and the parsed GGUF metadata.
  - Hugging Face repository browser: paste `author/repository` or a `huggingface.co` link to list GGUF quantization variants with sizes, then download the selected one through the existing resumable downloader (paired `mmproj` projectors are downloaded too).
  - Imported and repository models persist through the existing custom-model storage with versioned JSON metadata; models saved before Phase 2 keep working.
- **Hardware intelligence (Roadmap Phase 3)**: the app now knows the device, whether a model fits, and how fast it actually ran.
  - Local device profile: OS and version, CPU architecture, core count, physical and available memory, and free/total storage. Collected on demand, never uploaded.
    - Linux and Android read `/proc/meminfo`; macOS uses `sysctl` plus `vm_stat`; platforms without a reader (currently iOS) report memory as unknown instead of guessing.
  - Model compatibility rating: `Recommended`, `Should Run`, `May Be Slow`, `Memory Risk` and `Not Recommended`, derived from the model file size, its GGUF architecture metadata and the device memory budget.
  - Memory estimate breakdown so the logic is visible rather than a black box: model weights, KV cache for the context actually used, vision projector weights and runtime overhead. The formula lives in `ModelCompatibilityEstimator` and is unit tested.
  - Model Details shows the device summary, the rating and the estimate breakdown, with an explicit reminder that these are estimates, not guarantees of performance.
  - Model list cards show the rating and required memory once their details are expanded, and the model screen shows the device summary next to storage usage.
  - The chat runtime and the estimator share one context-size constant, so a rating always describes the context the model is really loaded with.
  - Benchmark records capture the runtime configuration (context size, quantization, backend, thread count, GPU layers, KV offload), time to first token, prompt-processing rate and memory use, plus a device snapshot, so runs from different releases can be compared honestly.
    - Peak memory comes from `VmHWM` on Linux and Android; macOS has no high-water mark available to Dart, so the value is sampled after the run and labelled as such. Platforms without a probe store `null`.
    - The prompt-processing rate is marked as an estimate: the bundled runtime exposes no tokenizer through its isolate API, so prompt tokens are approximated from prompt length.
  - Benchmark history is now versioned storage (schema v2). Existing v1 history is read as-is and upgraded on the next write, and a history file that cannot be parsed is copied to `history.json.corrupt-<time>` instead of being overwritten.
  - The Benchmark screen saves every run (including failures) and lists the saved history with a clear action; Model Details shows the latest measured run for the model next to its estimate.
  - Imported and externally referenced models can be benchmarked now as well, not just managed downloads.
- **Context & session management (Roadmap Phase 4)**: prompts are now assembled against a token budget instead of fixed character limits.
  - `ContextPolicy` describes the budget of one request: the effective context window, the tokens reserved for the answer, a safety margin and a per-message truncation threshold. The window is capped by the model's declared GGUF context length when that is smaller than the platform default, and the answer reservation is clamped so at least half the window stays available for input.
  - `ConversationContextBuilder` assembles model input deterministically: the system prompt is always preserved and charged first, output tokens are reserved before any history is considered, the newest turn is always kept, and older turns are added newest-first until the budget runs out. Older turns that no longer fit are dropped (sliding context); summarisation is not enabled yet.
  - A message longer than the per-message threshold keeps its head and tail with the middle elided, because instructions sit at the start of a prompt and the question at the end.
  - Attached images are charged against the budget, so an image turn is budgeted rather than free.
  - Token counts are estimates (`ceil(characters / 4)` plus per-message overhead) and documented as such: the bundled runtime exposes no tokenizer through its isolate API, so the estimator deliberately stays conservative.
  - The chat screen shows a context usage readout above the composer: used versus available input tokens, a progress bar, and the window and answer reservation, plus an explicit note when older or shortened messages were trimmed to fit. Prompt assembly is no longer silent about what it left out.
  - Assistant messages store the estimated prompt tokens and the context window they ran with, and the per-message stats line shows input tokens next to the output count.

### Fixed
- **Image turns could exceed the context window (Roadmap Phase 4)**: the previous history trimming charged image overhead for older messages but not for the newest turn, so a large image message could be sent with a prompt longer than the window the runtime was started with. Attachment overhead is now part of the single-turn budget as well.

## [1.5.0] - 2026-03-24

### Added
- **Vision Model Support**: Support for multimodal models using `mmproj` projectors. Chat with images on supported hardware.
- **On-device Benchmarking**: Integrated the `llmfit` tool for measuring inference speeds (`tok/s`) directly in the app.
- **Model Search & Filtering**: New search bar in the model selection page to easily find models by name or metadata.
- **macOS Native Support**: Fully functional desktop build with unified navigation and performance optimizations.
- **About Page**: New dedicated About section in the navigation drawer featuring project info and sponsorship links.
- **Hugging Face Feature Detection**: Automatically detect and display model capabilities (Vision, Chat Template, etc.) from Hugging Face metadata.
- **Dynamic Model Discovery**: Automatically discovers and caches downloaded GGUF files for instant selection.
- **New Models**: Added support for the latest Qwen 2.5, DeepSeek R1, Gemma 2, and SmolLM2 variants.

### Fixed
- **Android Initialization Regression**: Resolved an issue where missing multimodal libraries prevented standard model loading.
- **Library Path Resolution**: Improved native library path resolution on Android for better compatibility with split `.so` files.
- **Message History Optimization**: Context window now correctly compresses long messages to maintain stable performance.

## [1.0.0] - 2026-03-07

### Added
- **iOS Native Support**: Full integration of llama.cpp using Metal GPU acceleration for physical devices and CPU-only support for simulators.
- **Max Output Tokens Slider**: New setting in LLM Inference to control response length (up to 2048 tokens).
- **New LLM Models**: Added support for DeepSeek-R1 (1.5B, 7B, 14B, 32B), Qwen2.5-Coder-7B-Instruct, and other modern variants.
- **Visual Refresh**: Updated app branding with a new logo and added a screenshots showcase to the project documentation.
- **Context Expansion**: Increased default context window (nCtx) to 2048 for better long-conversation memory.

### Fixed
- **Response Truncation**: Fixed a bug where chat responses were prematurely stopping at 256 tokens on mobile devices.
- **Default maxTokens**: Increased from 256 to 512 for a better out-of-the-box experience.
- **iOS Simulator Linker Errors**: Resolved issues related to Accelerate/BLAS framework mismatches in simulator builds.
- **Settings Persistence**: Hardened the internal settings logic to prevent Null type errors when loading user preferences.
- **Metal Performance**: Optimized GPU offloading specifically for iOS hardware.
