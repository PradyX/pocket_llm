import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

class LocalBenchmarkResult {
  final LlmModel model;
  final int latencyMs;
  final double tokensPerSecond;
  final int generatedTokens;
  final String outputText;
  final String? errorMessage;

  const LocalBenchmarkResult({
    required this.model,
    required this.latencyMs,
    required this.tokensPerSecond,
    required this.generatedTokens,
    required this.outputText,
    this.errorMessage,
  });

  bool get isSuccess => errorMessage == null;

  String get responsePreview {
    final normalized = outputText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 160) return normalized;
    return '${normalized.substring(0, 157)}...';
  }
}
