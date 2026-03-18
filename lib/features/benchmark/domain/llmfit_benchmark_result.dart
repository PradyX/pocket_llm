class LlmfitBenchmarkResult {
  final String output;
  final int? exitCode;
  final String? errorMessage;
  final List<String> command;

  const LlmfitBenchmarkResult({
    required this.output,
    required this.command,
    this.exitCode,
    this.errorMessage,
  });

  bool get isSuccess =>
      errorMessage == null && (exitCode == null || exitCode == 0);
}
