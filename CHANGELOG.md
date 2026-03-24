# Changelog

All notable changes to this project will be documented in this file.

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
- **Font & Icon Assets**: Fixed missing `CupertinoIcons` in release builds and optimized font tree-shaking.
- **Library Path Resolution**: Improved native library path resolution on Android for better compatibility with split `.so` files.
- **Message History Optimization**: Context window now correctly compresses long messages to maintain stable performance.

### Changed
- **Credits Update**: Properly credited `llama.cpp` and `llmfit` in the documentation.
- **Drawer Organization**: Reorganized navigation drawer for better accessibility of core features.

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
