import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pocket_llm/core/inference/inference_engine.dart';
import 'package:pocket_llm/core/services/device_profile_service.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_service.dart';
import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/model_selection/data/model_compatibility_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

/// The engine operations a comparison needs.
///
/// Kept behind an interface so the comparison path can be tested without
/// loading a GGUF model: tests supply a fake runtime, the app supplies
/// [LlmComparisonRuntime].
abstract class ComparisonRuntime {
  /// True while the shared engine is already generating something else.
  bool get isGenerating;

  /// Loads [modelPath] with the comparison's own sampler settings.
  Future<void> load({required String modelPath, required int contextTokens});

  /// Streams the answer to [prompt].
  Stream<String> generate(String prompt, {required int maxTokens});

  /// Asks the running generation to stop; text produced so far is kept.
  void cancel();

  /// Context size the runtime actually loaded, when it reports one.
  int? get configuredContextSize;

  /// Threads the runtime used for generation.
  int? get configuredThreads;

  /// Layers offloaded to the GPU, 0 when running on CPU.
  int? get configuredGpuLayers;

  /// Whether the runtime kept the KV cache on the GPU.
  bool? get configuredOffloadKqv;

  /// Best-effort backend label (`Metal`, `GPU offload`, `CPU`).
  String? get runtimeBackend;
}

/// Runs comparisons on the app's shared local engine.
///
/// Pocket LLM keeps one model in memory at a time, so loading the next model
/// of a run releases the previous one. Keeping comparison on the shared engine
/// is what makes that guarantee hold across chat, voice and benchmarking: a
/// separate engine would leave two models resident.
class LlmComparisonRuntime implements ComparisonRuntime {
  LlmComparisonRuntime(this._engine);

  final InferenceEngine _engine;

  @override
  bool get isGenerating => _engine.isGenerating;

  @override
  Future<void> load({required String modelPath, required int contextTokens}) {
    return _engine.ensureModelLoaded(
      InferenceLoadRequest(
        modelPath: modelPath,
        contextTokens: contextTokens,
        batchTokens: contextTokens,
        // Low, fixed sampling: answers should differ because the models differ,
        // not because one run sampled more creatively than another.
        temperature: ModelComparisonService.temperature,
        topP: ModelComparisonService.topP,
        topK: ModelComparisonService.topK,
      ),
    );
  }

  @override
  Stream<String> generate(String prompt, {required int maxTokens}) {
    return _engine.generateResponse(prompt, maxTokens: maxTokens);
  }

  @override
  void cancel() => _engine.cancel();

  @override
  int? get configuredContextSize => _engine.runtimeInfo.contextTokens;

  @override
  int? get configuredThreads => _engine.runtimeInfo.threads;

  @override
  int? get configuredGpuLayers => _engine.runtimeInfo.gpuLayers;

  @override
  bool? get configuredOffloadKqv => _engine.runtimeInfo.offloadKqv;

  @override
  String? get runtimeBackend => _engine.runtimeInfo.backend;
}

/// Comparison over the app's shared local engine.
final modelComparisonServiceProvider = Provider<ModelComparisonService>((ref) {
  final storage = ref.watch(modelStorageServiceProvider);
  final deviceProfileService = ref.watch(deviceProfileServiceProvider);
  final memoryProbe = ref.watch(processMemoryProbeProvider);

  return ModelComparisonService(
    runtime: LlmComparisonRuntime(ref.watch(inferenceEngineProvider)),
    resolveModelPath: storage.resolveModelPath,
    isFileReady: storage.isModelPathDownloaded,
    readDeviceProfile: deviceProfileService.collect,
    readResidentMemoryBytes: memoryProbe.readResidentMemoryBytes,
  );
});

/// Sends one prompt to several installed models and reports what each did.
///
/// Models run **sequentially**: each one is loaded, answers, and is released
/// before the next is loaded, so comparing large models cannot exhaust phone
/// memory. Parallel execution, if it ever comes, has to be hardware-gated,
/// because two resident models is exactly what this app avoids.
///
/// Every model gets the same prompt, the same context window and the same
/// output budget, which is what makes answers and rates comparable. A model
/// that fails is reported as a failed result and does not stop the run.
class ModelComparisonService {
  ModelComparisonService({
    required ComparisonRuntime runtime,
    required this.resolveModelPath,
    required this.isFileReady,
    this.readDeviceProfile,
    this.readResidentMemoryBytes,
  }) : _runtime = runtime;

  /// Instruction shared by every model in a run.
  static const String systemPrompt = 'You are a helpful and concise assistant.';

  /// Sampler settings shared by every model.
  static const double temperature = 0.2;
  static const double topP = 0.8;
  static const int topK = 40;

  /// Output budget reserved for each model.
  static const int defaultMaxTokens = 256;

  /// Fewest models a comparison is meaningful with.
  static const int minimumModels = 2;

  /// Most models one run accepts: each load costs time and memory.
  static const int maximumModels = 4;

  final ComparisonRuntime _runtime;

  /// Absolute path of a model's main GGUF file.
  final Future<String?> Function(LlmModel model) resolveModelPath;

  /// Whether a model file exists, is complete and carries GGUF bytes.
  final Future<bool> Function(String? path) isFileReady;

  /// Device snapshot for the result cards, when the app supplies one.
  final Future<DeviceProfile> Function()? readDeviceProfile;

  /// Resident memory sample taken after a model, when the OS reports it.
  final Future<int?> Function()? readResidentMemoryBytes;

  bool _cancelled = false;

  /// Runs [models] in the given order, yielding each result as it completes.
  ///
  /// The stream yields exactly one result per model, failed ones included, so
  /// the UI can show the responses independently. A cancelled run yields the
  /// partial answer of the model that was generating and then ends, leaving
  /// the remaining models unloaded.
  Stream<LocalBenchmarkResult> compare({
    required List<LlmModel> models,
    required String prompt,
    int maxTokens = defaultMaxTokens,
  }) async* {
    final trimmedPrompt = prompt.trim();
    if (models.length < minimumModels || models.length > maximumModels) {
      throw Exception(
        'Choose between $minimumModels and $maximumModels models to compare.',
      );
    }
    if (trimmedPrompt.isEmpty) {
      throw Exception('Enter a prompt to send to every model.');
    }
    if (_runtime.isGenerating) {
      throw Exception('Stop the current answer before comparing models.');
    }

    _cancelled = false;
    final contextTokens = ModelCompatibilityService.defaultContextTokens;
    final outputTokens = outputTokensFor(
      requested: maxTokens,
      contextTokens: contextTokens,
    );

    for (final model in models) {
      yield await _compareModel(
        model: model,
        prompt: trimmedPrompt,
        contextTokens: contextTokens,
        maxTokens: outputTokens,
      );
      // A stop ends the run after the model that was generating.
      if (_cancelled) return;
    }
  }

  /// Stops the generating model; the run ends after its partial answer.
  void cancel() {
    _cancelled = true;
    _runtime.cancel();
  }

  /// Output budget shared by every model.
  ///
  /// The requested number of tokens, but never more than a quarter of the
  /// window: a long answer must not crowd out the prompt it is answering.
  static int outputTokensFor({
    required int requested,
    required int contextTokens,
  }) {
    final ceiling = math.max(64, contextTokens ~/ 4);
    return requested.clamp(64, ceiling);
  }

  Future<LocalBenchmarkResult> _compareModel({
    required LlmModel model,
    required String prompt,
    required int contextTokens,
    required int maxTokens,
  }) async {
    if (!model.isDownloaded) {
      return _failedResult(model, 'Model is not downloaded on this device.');
    }

    // Managed downloads and imported/external references both resolve here.
    final modelPath = await resolveModelPath(model);
    if (modelPath == null ||
        modelPath.trim().isEmpty ||
        !await isFileReady(modelPath)) {
      return _failedResult(
        model,
        'Model file is missing or incomplete on this device.',
      );
    }

    final responseBuffer = StringBuffer();
    var generatedTokenCount = 0;
    var promptTokens = 0;
    int? ttftMs;
    String? errorMessage;
    final stopwatch = Stopwatch()..start();

    try {
      await _runtime.load(modelPath: modelPath, contextTokens: contextTokens);

      final promptBundle = buildModelChatPrompt(
        [LlmPromptMessage.user(prompt)],
        systemPrompt: systemPrompt,
        promptFormatId: model.promptFormatId,
      );
      promptTokens = BenchmarkService.estimatePromptTokens(promptBundle.prompt);
      final stopToken = modelStopToken(model.promptFormatId);

      await for (final token in _runtime.generate(
        promptBundle.prompt,
        maxTokens: maxTokens,
      )) {
        final cleanToken = token.replaceAll(stopToken, '');
        if (cleanToken.isNotEmpty) {
          ttftMs ??= stopwatch.elapsedMilliseconds;
          responseBuffer.write(cleanToken);
          generatedTokenCount++;
        }

        if (token.contains(stopToken)) {
          break;
        }
      }
      stopwatch.stop();

      // A stop can surface as a runtime error; the words decoded before it are
      // still worth keeping, so a cancelled model is not reported as failed.
      // (Reaching here without an error is the normal path.)
    } catch (error) {
      stopwatch.stop();
      if (!_cancelled) errorMessage = _messageOf(error);
    }

    if (errorMessage != null) {
      return _failedResult(model, errorMessage);
    }

    final elapsedMs = stopwatch.elapsedMilliseconds;
    final elapsedSeconds = elapsedMs / 1000.0;
    final tokensPerSecond = elapsedSeconds > 0
        ? generatedTokenCount / elapsedSeconds
        : 0.0;
    final outputText = buildFinalResponseText(responseBuffer.toString());

    final promptTokensPerSecond = ttftMs != null && ttftMs > 0
        ? promptTokens / (ttftMs / 1000.0)
        : null;
    final device = await readDeviceProfile?.call();
    final peakMemoryBytes = await readResidentMemoryBytes?.call();

    return LocalBenchmarkResult(
      model: model,
      latencyMs: elapsedMs,
      tokensPerSecond: tokensPerSecond,
      generatedTokens: generatedTokenCount,
      outputText: outputText,
      ttftMs: ttftMs,
      promptTokensEstimated: promptTokens > 0 ? promptTokens : null,
      promptTokensPerSecond: promptTokensPerSecond,
      contextTokens: _runtime.configuredContextSize,
      threads: _runtime.configuredThreads,
      gpuLayers: _runtime.configuredGpuLayers,
      offloadKqv: _runtime.configuredOffloadKqv,
      backend: _runtime.runtimeBackend,
      peakMemoryBytes: peakMemoryBytes,
      deviceSummary: device?.summaryLabel,
      deviceCpuCores: device?.cpuCores,
      deviceMemoryBytes: device?.totalMemoryBytes,
    );
  }

  static LocalBenchmarkResult _failedResult(LlmModel model, String message) {
    return LocalBenchmarkResult(
      model: model,
      latencyMs: 0,
      tokensPerSecond: 0,
      generatedTokens: 0,
      outputText: '',
      errorMessage: message,
    );
  }

  /// `Exception: something` reads badly in the UI, so the prefix is dropped.
  static String _messageOf(Object error) {
    const prefix = 'Exception: ';
    final text = error.toString();
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }
}
