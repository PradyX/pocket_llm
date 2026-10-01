import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

/// One local benchmark run for one model.
///
/// Only [latencyMs], [tokensPerSecond] and [generatedTokens] are exact
/// wall-clock measurements of the generated text. The Phase 3 metrics are
/// filled in where the runtime can report them:
///
/// * [ttftMs] — measured from the start of generation to the first token.
/// * [promptTokensEstimated] / [promptTokensPerSecond] — the bundled runtime
///   does not expose a tokenizer through its isolate API, so prompt tokens are
///   approximated and flagged with [isPromptRateEstimated].
/// * [peakMemoryBytes] — peak resident memory where the OS reports it
///   (`VmHWM` on Linux/Android), otherwise a sample taken after generation
///   (macOS), otherwise null.
class LocalBenchmarkResult {
  final LlmModel model;
  final int latencyMs;
  final double tokensPerSecond;
  final int generatedTokens;
  final String outputText;
  final String? errorMessage;

  /// Time to first token in milliseconds.
  final int? ttftMs;

  /// Prompt tokens, approximated (see [isPromptRateEstimated]).
  final int? promptTokensEstimated;

  /// Prompt processing rate: estimated prompt tokens over time to first token.
  final double? promptTokensPerSecond;

  /// Context size the model was loaded with.
  final int? contextTokens;

  /// Threads the runtime used for generation.
  final int? threads;

  /// Layers offloaded to the GPU, 0 when running on CPU.
  final int? gpuLayers;

  /// Whether the runtime kept the KV cache on the GPU.
  final bool? offloadKqv;

  /// Best-effort backend label (`Metal`, `GPU offload`, `CPU`).
  final String? backend;

  /// Peak (or sampled) resident memory of the app process.
  final int? peakMemoryBytes;

  /// Snapshot of the device the run happened on.
  final String? deviceSummary;
  final int? deviceCpuCores;
  final int? deviceMemoryBytes;

  const LocalBenchmarkResult({
    required this.model,
    required this.latencyMs,
    required this.tokensPerSecond,
    required this.generatedTokens,
    required this.outputText,
    this.errorMessage,
    this.ttftMs,
    this.promptTokensEstimated,
    this.promptTokensPerSecond,
    this.contextTokens,
    this.threads,
    this.gpuLayers,
    this.offloadKqv,
    this.backend,
    this.peakMemoryBytes,
    this.deviceSummary,
    this.deviceCpuCores,
    this.deviceMemoryBytes,
  });

  bool get isSuccess => errorMessage == null;

  /// True when the prompt rate comes from an approximated token count.
  bool get isPromptRateEstimated => promptTokensPerSecond != null;

  /// True when the OS could only sample memory instead of reporting a peak.
  bool get isMemorySampled => peakMemoryBytes != null;

  String get responsePreview {
    final normalized = outputText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 160) return normalized;
    return '${normalized.substring(0, 157)}...';
  }
}
