import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';

/// Comparison runtime the tests drive, so sequencing, streaming, stopping and
/// failures can be observed without a model on disk.
class ScriptedComparisonRuntime implements ComparisonRuntime {
  ScriptedComparisonRuntime({this.script = const []});

  /// Tokens emitted by each successive [generate] call.
  final List<List<String>> script;

  /// Model files whose load fails.
  final List<String> failingModelPaths = [];

  /// When true, a scripted stream stays open after its tokens until [release]
  /// (or [cancel]) is called, which is how a real generation ends.
  bool holdAtEnd = false;

  final List<String> loadedModelPaths = [];
  final List<int> loadedContextTokens = [];
  final List<String> prompts = [];
  final List<int> requestedMaxTokens = [];
  int generateCalls = 0;
  bool cancelled = false;

  Completer<void>? _gate;

  /// True while a held stream is waiting to be released.
  bool get isWaiting => _gate != null && !_gate!.isCompleted;

  @override
  bool isGenerating = false;

  @override
  Future<void> load({
    required String modelPath,
    required int contextTokens,
  }) async {
    if (failingModelPaths.contains(modelPath)) {
      throw Exception('the model failed to load');
    }
    loadedModelPaths.add(modelPath);
    loadedContextTokens.add(contextTokens);
  }

  @override
  Stream<String> generate(String prompt, {required int maxTokens}) async* {
    final call = generateCalls++;
    prompts.add(prompt);
    requestedMaxTokens.add(maxTokens);
    final tokens = call < script.length ? script[call] : const <String>[];
    for (final token in tokens) {
      yield token;
    }
    if (holdAtEnd) {
      _gate = Completer<void>();
      await _gate!.future;
      _gate = null;
    }
  }

  @override
  void cancel() {
    cancelled = true;
    release();
  }

  /// Lets a held stream finish without marking the run cancelled.
  void release() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  int? get configuredContextSize => 4096;

  @override
  int? get configuredThreads => 4;

  @override
  int? get configuredGpuLayers => 0;

  @override
  bool? get configuredOffloadKqv => false;

  @override
  String? get runtimeBackend => 'Test backend';
}

/// Waits until [condition] holds, so an async run can be observed mid-flight.
Future<void> pumpUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was never met');
}
