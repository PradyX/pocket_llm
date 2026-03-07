# Changelog

All notable changes to the PocketLlama project will be documented in this file.

## [1.1.0] - 2026-03-07

### Added
- **iOS Native Support**: Full integration of `llama.cpp` using Metal GPU acceleration for physical devices and CPU-only support for simulators.
- **Max Output Tokens Slider**: New setting in LLM Inference to control response length (up to 2048 tokens).
- **New LLM Models**: Added support for DeepSeek-R1 (1.5B, 7B, 14B, 32B), Qwen2.5-Coder-7B-Instruct, and other modern variants.
- **Visual Refresh**: Updated app branding with a new logo and added a screenshots showcase to the project documentation.
- **Context Expansion**: Increased default context window (`nCtx`) to 2048 for better long-conversation memory.

### Fixed
- **Response Truncation**: Fixed a bug where chat responses were prematurely stopping at 256 tokens on mobile devices.
- **iOS Simulator Linker Errors**: Resolved issues related to Accelerate/BLAS framework mismatches in simulator builds.
- **Settings Persistence**: Hardened the internal settings logic to prevent `Null` type errors when loading user preferences.
- **Metal Performance**: Optimized GPU offloading specifically for iOS hardware.

### Changed
- Default `maxTokens` increased from 256 to 512 for a better out-of-the-box experience.
- Refactored project architecture to follow a cleaner MVVM and feature-based structure.
- Updated `README.md` with comprehensive build instructions for both Android and iOS.
