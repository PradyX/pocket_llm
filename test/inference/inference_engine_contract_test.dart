import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/inference/inference_engine.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/features/agents/application/agent_loop_service.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';
import 'package:pocket_llm/features/voice/data/speech_to_text_service.dart';

/// An engine that is not llama.cpp at all.
///
/// Its whole purpose is to show that features run on the interface: if any of
/// them needed the concrete service, it could not be driven from here.
class _FakeInferenceEngine implements InferenceEngine {
  InferenceLoadRequest? lastLoadRequest;
  int cancelCalls = 0;

  @override
  bool isLoaded = false;

  @override
  bool isGenerating = false;

  @override
  bool isStopRequested = false;

  @override
  String? loadedModelPath;

  @override
  InferenceRuntimeInfo runtimeInfo = InferenceRuntimeInfo.unloaded;

  @override
  InferenceCapabilities capabilities = const InferenceCapabilities(
    streaming: true,
    cancellation: true,
    gpuOffload: false,
    vision: false,
    audio: false,
    embeddings: false,
  );

  @override
  Future<void> loadModel(InferenceLoadRequest request) async {
    lastLoadRequest = request;
    isLoaded = true;
    loadedModelPath = request.modelPath;
    runtimeInfo = InferenceRuntimeInfo(
      isLoaded: true,
      modelPath: request.modelPath,
      projectorPath: request.projectorPath,
      backend: 'Fake backend',
      contextTokens: request.contextTokens ?? 2048,
      batchTokens: request.batchTokens ?? 512,
      threads: request.threads ?? 4,
      threadsBatch: request.threadsBatch ?? 4,
      gpuLayers: request.gpuLayers ?? 0,
      offloadKqv: request.offloadKqv ?? false,
    );
  }

  @override
  Future<void> ensureModelLoaded(InferenceLoadRequest request) =>
      loadModel(request);

  @override
  Future<void> unloadModel() async {
    isLoaded = false;
    loadedModelPath = null;
    runtimeInfo = InferenceRuntimeInfo.unloaded;
  }

  @override
  Stream<String> generateResponse(String prompt, {int? maxTokens}) =>
      Stream.fromIterable(const ['fake ', 'answer']);

  @override
  Stream<String> generateVisionResponse(
    String prompt, {
    required List<String> imagePaths,
    int? maxTokens,
  }) => Stream.fromIterable(const ['fake ', 'picture']);

  @override
  Stream<String> generateAudioResponse(
    String prompt, {
    required String audioPath,
    int? maxTokens,
  }) => Stream.fromIterable(const ['fake ', 'transcript']);

  @override
  void cancel() {
    cancelCalls++;
    isStopRequested = true;
  }
}

void main() {
  group('InferenceEngine contract', () {
    test('LlmService is the engine, and is honest before a model loads', () {
      final InferenceEngine engine = LlmService();

      expect(engine.isLoaded, isFalse);
      expect(engine.isGenerating, isFalse);
      expect(engine.loadedModelPath, isNull);

      // Nothing resident means nothing to report, not invented numbers.
      expect(engine.runtimeInfo.isLoaded, isFalse);
      expect(engine.runtimeInfo.modelPath, isNull);
      expect(engine.runtimeInfo.backend, 'unknown');
      expect(engine.runtimeInfo.contextTokens, 0);
      expect(engine.runtimeInfo.threads, 0);
      expect(engine.runtimeInfo.gpuLayers, 0);
      expect(engine.runtimeInfo.offloadKqv, isFalse);

      // Capabilities describe the build: streaming and cancellation always,
      // embeddings never, GPU offload where the platform allows it.
      expect(engine.capabilities.streaming, isTrue);
      expect(engine.capabilities.cancellation, isTrue);
      expect(engine.capabilities.embeddings, isFalse);
      expect(
        engine.capabilities.gpuOffload,
        equals(LlmService.supportsGpuOffload),
      );
    });

    test('cancelling an idle engine is a no-op, not a stopped run', () {
      final engine = LlmService();

      engine.cancel();

      expect(engine.isGenerating, isFalse);
      expect(
        engine.isStopRequested,
        isFalse,
        reason:
            'The stop flag belongs to a run: an idle engine must not look as '
            'if the user stopped something.',
      );
    });

    test('an engine is only ever one shared instance behind the provider', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final engine = container.read(inferenceEngineProvider);
      expect(engine, isA<LlmService>());
      expect(
        container.read(inferenceEngineProvider),
        same(engine),
        reason: 'One resident model means one engine, not one per feature.',
      );
    });
  });

  group('features run on the interface', () {
    test('the agent runtime loads, generates and cancels through it', () async {
      final fake = _FakeInferenceEngine();
      final runtime = LlmAgentRuntime(fake);

      await runtime.load(modelPath: '/models/a.gguf', contextTokens: 2048);
      expect(fake.lastLoadRequest?.modelPath, '/models/a.gguf');
      expect(fake.lastLoadRequest?.contextTokens, 2048);
      expect(
        fake.lastLoadRequest?.temperature,
        AgentLoopService.temperature,
        reason: 'An agent keeps its own deterministic sampler.',
      );

      expect(await runtime.generate('hello', maxTokens: 8).toList(), [
        'fake ',
        'answer',
      ]);

      runtime.cancel();
      expect(fake.cancelCalls, 1);
    });

    test('the comparison runtime projects the engine runtime info', () async {
      final fake = _FakeInferenceEngine();
      final runtime = LlmComparisonRuntime(fake);

      await runtime.load(modelPath: '/models/b.gguf', contextTokens: 4096);

      expect(runtime.configuredContextSize, 4096);
      expect(runtime.configuredThreads, 4);
      expect(runtime.configuredGpuLayers, 0);
      expect(runtime.configuredOffloadKqv, isFalse);
      expect(runtime.runtimeBackend, 'Fake backend');

      runtime.cancel();
      expect(fake.cancelCalls, 1);
    });

    test('the speech runtime loads a projector and transcribes', () async {
      final fake = _FakeInferenceEngine();
      final runtime = LlmSpeechRuntime(fake);

      await runtime.load(
        modelPath: '/models/speech.gguf',
        projectorPath: '/models/mmproj.gguf',
        contextTokens: 2048,
      );

      expect(fake.lastLoadRequest?.projectorPath, '/models/mmproj.gguf');
      expect(fake.lastLoadRequest?.temperature, 0);
      expect(
        await runtime
            .transcribe('transcribe', audioPath: '/clips/a.wav', maxTokens: 32)
            .toList(),
        ['fake ', 'transcript'],
      );
    });
  });

  group('runtime coupling', () {
    test('only the engine adapter imports the llama.cpp binding', () async {
      final offenders = <String>[];
      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final contents = await entity.readAsString();
        if (contents.contains('package:llama_cpp_dart/')) {
          offenders.add(entity.path.replaceAll(r'\', '/'));
        }
      }

      expect(
        offenders,
        ['lib/core/services/llm_service.dart'],
        reason:
            'A second feature importing the binding would tie that feature to '
            'one runtime and make the swap unsafe.',
      );
    });
  });
}
