import 'dart:async';

import 'package:pocket_llm/features/agents/application/agent_loop_service.dart';

/// Agent runtime the tests drive, so the loop can be observed without a model.
class ScriptedAgentRuntime implements AgentRuntime {
  ScriptedAgentRuntime({
    this.script = const [],
    this.failingModelPaths = const [],
  });

  /// Text emitted by each successive [generate] call.
  final List<String> script;

  /// Model files whose load fails.
  final List<String> failingModelPaths;

  /// When true, a scripted stream stays open after its text until [release] (or
  /// [cancel]) is called, which is how a real generation ends.
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
    final text = call < script.length ? script[call] : '';
    if (text.isNotEmpty) yield text;
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
}

/// Waits until [condition] holds, so an async loop can be observed mid-flight.
Future<void> pumpAgentUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('condition was never met');
}
