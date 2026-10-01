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
- **Inference profiles (Roadmap Phase 5)**: named runtime configurations that any model can reuse.
  - A profile only overrides what it sets — context size, prompt batch size, threads, GPU layers, KV-cache placement, sampling and maximum answer length. Everything else keeps the app or runtime default for the device, so a profile cannot go stale as platform defaults change.
  - Three built-ins ship with the app: `Balanced` (changes nothing and is the default), `Battery Saver` (1024 context, 2 threads, CPU only, short answers) and `Maximum Performance` (8192 context, full GPU offload, longer answers). Built-ins are read-only; duplicating one creates an editable copy.
  - Custom profiles are stored in a versioned file (`inference_profiles/profiles.json`, schema v1) under the app support directory. Stored values are clamped to safe ranges on read and on write, a payload that cannot be read is copied to `.corrupt-<time>` before any rewrite, and a file written by a newer build is left untouched and shown as read-only instead of being downgraded.
  - New **Inference Profiles** screen (drawer → Inference Profiles): lists built-ins and custom profiles, shows what the active profile resolves to on this device, and explains anything the platform had to drop — GPU offload on Android, contexts above the model's declared limit, or answers capped so half the window stays free for the prompt.
  - The chat runtime builds every request through the profile resolver, so the token budget, the context window the model is loaded with and the recorded prompt stats always describe the same configuration. Changing the active profile reloads the model with the new settings, and the loading status names the profile in use.
  - Runtime defaults (threads, GPU layers, KV offload) are now defined once in `LlmService` and shared with the resolver, and a change to threads or offload triggers the reload check that previously only covered context size, batch size and sampling.
- **Personas (Roadmap Phase 5)**: a persona is a reusable system prompt that a conversation adopts.
  - Five built-ins ship with the app: `General` (keeps the app default prompt), `Coding`, `Research`, `Creative` and `Concise`. Built-ins are read-only; duplicating one creates an editable custom persona.
  - Persona text is trimmed and length-limited (a pasted prompt cannot swallow the context window), and the editor shows what the prompt costs in tokens on this device.
  - Each conversation records the persona it chats with, so switching voice never touches message history and conversations saved before personas existed simply use the current default.
  - A persona can prefer a model and an inference profile. Choosing a persona that prefers an installed model switches to it and says so in a message; when a persona pins a profile, that profile takes over for that conversation, otherwise the app-wide active profile applies.
  - On Android the structured tool-calling contract is appended to the persona prompt instead of replacing it, so tool calls keep working with a custom voice.
  - Personas are stored in a versioned file (`personas/personas.json`, schema v1) with the same guarantees as profiles: clamped values, a `.corrupt-<time>` backup before any rewrite, and read-only handling of files written by a newer build. Both stores now share one versioned-document implementation.
  - A persona (or every persona) can be exported to the clipboard as versioned JSON and imported back as an editable custom copy: an import can never shadow a shipped built-in, and an id that already exists locally gets a fresh one, so importing never overwrites local work.
  - New **Personas** screen (drawer → Personas) with built-in and custom sections, set-default, duplicate, edit and delete; the chat header shows the active persona and switches it in place, and new chats record the current default persona.
- **Local documents and retrieval (Roadmap Phase 6A)**: local files can now be read, searched and cited, fully offline.
  - Text, markdown and source-code files are read where they live; Pocket LLM never copies, moves or edits the original. Everything derived from a file lives in its own versioned store (`documents/index.json`, schema v1).
  - Extraction, chunking, ranking and storage stay separate, so a format parser, an embedding backend or a different store can be swapped in without rewriting the rest of the pipeline.
  - Chunking is heading-aware (ATX and setext): paragraphs are packed up to a token target, oversized blocks are split on sentence and line boundaries before a hard cut, and a little of the previous chunk is repeated so a sentence crossing a boundary stays retrievable. Every chunk records the character offsets it came from, so a citation can point at the original text.
  - Retrieval is lexical (BM25) for now: no extra model download, fully offline, deterministic, and every hit reports which query terms it matched instead of asking the user to trust the ranking.
  - Each stored document records the chunking settings, the pipeline version and the retrieval backend it was built with, plus a content fingerprint. A file is re-read only when its size or timestamp changed, re-chunked only when its text actually changed or that metadata drifted, and a file that merely moved keeps its existing chunks.
  - New **Documents** screen (drawer → Documents): add files through the system picker, see every document with its format, chunk count, size and index date, re-index one document or every file that changed on disk, and remove a document — removing drops only what Pocket LLM derived, never the file itself.
  - Indexing shows its stage with a progress bar and can be cancelled; a cancelled or failed file stores nothing and says so, and errors name the file and the reason. Files whose bytes do not look like text are rejected with an actionable message instead of being indexed as garbage.
  - The same screen previews retrieval: a query shows the chunks it would match, with the matched terms and the chunk text, so what the model would be given is visible before asking anything. Retrieval never invents a source.
  - Chat requests now retrieve for the newest question before the prompt is assembled: the best whole chunks are fitted into a retrieval budget that never takes more than a third of the input, appended to the system prompt and charged before any history, so an old conversation can never push the current question's documents out of the window.
  - The model is told to use the chunks it was given and cite them as `[1]`, `[2]`; assistant messages record which chunks were sent with those same markers, and the answer shows them as citation chips. The chip opens the chunk as it is now and states when a document is no longer indexed, instead of pretending a source still exists.
  - Chunk text is deliberately not copied into conversations: a citation points back at the local index, so a re-indexed document is never quoted from a stale copy. Conversations saved before citations existed load with no sources.
  - Retrieval is best-effort: an index that cannot be opened is treated as "no documents", so local documents can never break a chat request.
  - PDF files are recognized but not extractable yet: no maintained pure-Dart extractor is bundled, so attaching one explains the limitation and suggests converting to text or markdown. A PDF extractor is a drop-in addition to the extraction service.
- **Knowledge collections (Roadmap Phase 6B)**: documents are now grouped into named collections, so work, research and personal material can be indexed and searched separately.
  - A collection owns its chunking settings, retrieval backend and index version, and holds only what Pocket LLM derived from its files — never the files themselves. Removing a collection is therefore always safe for the originals.
  - Retrieval searches one collection at a time and computes its ranking statistics from that collection alone, so a term that is common in one collection cannot weaken its score in another, and unrelated material cannot influence an answer.
  - The index store moves to schema v2. Files written by the previous version are migrated on read into an always-present collection that keeps the stored chunking settings; nothing is dropped, and the file is only rewritten in the new shape when something changes.
  - A partially written or hand-edited index is repaired rather than discarded: the always-present collection is recreated if missing, a selection that points at no collection falls back to it, and a document whose collection is gone is moved there instead of disappearing from the app.
  - Collections are created, renamed and removed on the **Documents** screen, which shows one collection at a time: the picker lists each collection with its own document and changed-file counts, and the retrieval preview always describes the collection on screen.
  - Chat retrieval searches the active collection only. A collection with nothing indexed adds no retrieval budget and no prompt section, so the selected collection is also how document grounding is turned off — there is no separate global switch to keep in sync.
  - The active collection is stored with the index and survives restarts; removing a collection returns the selection to the always-present one.
- **Multimodal attachments (Roadmap Phase 7)**: a message can now carry several images instead of one.
  - Up to four images attach to a single turn, each with its own thumbnail, an individual remove button and a Clear all action, so a local model can be asked to compare pictures. A turn with images still needs a question, and switching to a model without multimodality clears the pending images instead of sending something the model cannot read.
  - Prompt assembly writes one `<image>` marker per attached image in attachment order and passes the same order to the runtime; formats without multimodality still ignore images rather than embedding markers the model would read as text.
  - Assistant turns render every image of the message, not just the first, and regenerating a turn resends all of its images. Editing and resending stays available only for messages without attachments, because an edit cannot reproduce them.
  - Attachments are stored per conversation under the message id; same-named images get a suffix instead of overwriting each other, so attaching `photo.jpg` twice keeps both files.
  - Multi-select uses the platform's multi-image picker where it exists and falls back to one image at a time elsewhere, so adding images works the same way on every platform.

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
