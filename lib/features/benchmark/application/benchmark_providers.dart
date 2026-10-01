import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_history.dart';

/// Benchmark history file, opened once per session.
///
/// The benchmark screen appends runs and Model Details reads the latest run
/// for a model, so both share this provider.
final benchmarkHistoryProvider = FutureProvider<BenchmarkHistory>((ref) {
  return BenchmarkHistory.open();
});
