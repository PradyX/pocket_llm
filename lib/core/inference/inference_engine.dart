import 'dart:async';

/// Runtime-neutral contract for local inference.
///
/// Everything above this seam — chat, documents, voice, comparison,
/// benchmarks and agents — talks to [InferenceEngine] instead of to a binding,
/// so the llama.cpp runtime can be replaced without rewriting those features.
/// [LlmService] is the only implementation today and owns every
/// `llama_cpp_dart` type; a second implementation can be swapped in behind this
/// interface without touching a feature module.
///
/// Deliberately absent. Each was re-checked against the pinned runtime's own
/// API while Road Map 1 section 17 was evaluated (2026-10-08):
///
/// * `tokenize` — the binding does have a `Tokenizer`, but it needs the
///   model's vocabulary, which lives inside the runtime isolate and cannot be
///   reached from here, so token counts stay `TokenEstimator` estimates. Both
///   the pinned `0.9.0-dev.10` and the `0.9.0-dev.12` candidate tokenize only
///   inside the isolate: this is a binding gap, not a missing feature here,
///   and it closes with a real count the day one of them exposes it.
/// * `getMetadata` — deliberately not here: this app reads GGUF metadata with
///   its own reader, which is authoritative and answers before any model is
///   loaded, so routing the question through a resident runtime would be a
///   detour.
/// * `embeddings` — the binding does expose `LlamaEngine.embed`, so the
///   runtime could answer; what is missing is an engine that offers it and a
///   consumer that wants it (the knowledge index is lexical by design).
///   [InferenceCapabilities.embeddings] therefore stays false: a capability
///   flag describes what can be asked for through this seam.
abstract interface class InferenceEngine {
  /// True while a model is resident in memory.
  bool get isLoaded;

  /// True while a generation is streaming.
  bool get isGenerating;

  /// True when the running generation was asked to stop.
  bool get isStopRequested;

  /// Absolute path of the resident model, or null when nothing is loaded.
  String? get loadedModelPath;

  /// What this engine can do on this device and build.
  InferenceCapabilities get capabilities;

  /// How the resident model is actually configured.
  ///
  /// These are the values the engine was started with, so diagnostics and
  /// benchmark records describe a run instead of guessing at it.
  InferenceRuntimeInfo get runtimeInfo;

  /// Loads [request]'s model, replacing any resident model.
  Future<void> loadModel(InferenceLoadRequest request);

  /// Loads only when [request] differs from the resident configuration.
  ///
  /// Switching a profile or a context size therefore reloads, while an
  /// unchanged request keeps the model in memory.
  Future<void> ensureModelLoaded(InferenceLoadRequest request);

  /// Releases the resident model and cancels any running generation.
  Future<void> unloadModel();

  /// Streams one text completion for [prompt].
  Stream<String> generateResponse(String prompt, {int? maxTokens});

  /// Streams one completion about the local images at [imagePaths].
  ///
  /// Exists only when [InferenceCapabilities.vision] is true; otherwise the
  /// implementation reports why it cannot run.
  Stream<String> generateVisionResponse(
    String prompt, {
    required List<String> imagePaths,
    int? maxTokens,
  });

  /// Streams one completion about the local audio clip at [audioPath].
  ///
  /// Exists only when [InferenceCapabilities.audio] is true.
  Stream<String> generateAudioResponse(
    String prompt, {
    required String audioPath,
    int? maxTokens,
  });

  /// Asks the running generation to stop; text produced so far is kept.
  void cancel();
}

/// One model load, described without any runtime-specific type.
///
/// A request object keeps this contract stable as runtimes gain options: a new
/// runtime knob becomes a field here instead of another named parameter every
/// caller has to thread through.
///
/// Null means "let the engine decide" — the engine applies its platform
/// defaults for that setting — except [maxTokens], which falls back to the
/// context capacity.
class InferenceLoadRequest {
  const InferenceLoadRequest({
    required this.modelPath,
    this.projectorPath,
    this.gpuLayers,
    this.contextTokens,
    this.batchTokens,
    this.threads,
    this.threadsBatch,
    this.offloadKqv,
    this.maxTokens,
    this.temperature,
    this.topP,
    this.topK,
  });

  /// Absolute path of the GGUF model file.
  final String modelPath;

  /// Absolute path of the multimodal projector, when the load should be able
  /// to read images or audio.
  final String? projectorPath;

  /// Layers offloaded to the GPU.
  final int? gpuLayers;

  /// Context window in tokens.
  final int? contextTokens;

  /// Batch size used while filling the context.
  final int? batchTokens;

  /// Threads used for generation.
  final int? threads;

  /// Threads used while filling the context.
  final int? threadsBatch;

  /// Whether the KV cache is kept on the GPU.
  final bool? offloadKqv;

  /// Default generation limit for this load.
  final int? maxTokens;

  final double? temperature;
  final double? topP;
  final int? topK;
}

/// What an engine can do here, as opposed to what some other runtime could do.
///
/// This is the checklist a runtime swap has to answer, so it is declared by the
/// engine rather than probed by feature code. Capabilities can differ per
/// platform, per build and per engine: nothing above this seam may assume them.
class InferenceCapabilities {
  const InferenceCapabilities({
    required this.streaming,
    required this.cancellation,
    required this.gpuOffload,
    required this.vision,
    required this.audio,
    required this.embeddings,
  });

  /// Token-by-token streaming instead of whole answers.
  final bool streaming;

  /// Stopping a generation that is already running.
  final bool cancellation;

  /// Offloading layers to the GPU on this platform.
  final bool gpuOffload;

  /// Image input, which needs a bundled multimodal runtime.
  final bool vision;

  /// Audio input, which needs the same bundled runtime.
  final bool audio;

  /// Embedding vectors. False today: the binding can produce them, but no
  /// implementation of this interface offers them and nothing asks.
  final bool embeddings;
}

/// How the resident model is configured, or [unloaded] when nothing is loaded.
class InferenceRuntimeInfo {
  const InferenceRuntimeInfo({
    required this.isLoaded,
    required this.modelPath,
    required this.projectorPath,
    required this.backend,
    required this.contextTokens,
    required this.batchTokens,
    required this.threads,
    required this.threadsBatch,
    required this.gpuLayers,
    required this.offloadKqv,
  });

  /// The engine with no model resident.
  static const InferenceRuntimeInfo unloaded = InferenceRuntimeInfo(
    isLoaded: false,
    modelPath: null,
    projectorPath: null,
    backend: 'unknown',
    contextTokens: 0,
    batchTokens: 0,
    threads: 0,
    threadsBatch: 0,
    gpuLayers: 0,
    offloadKqv: false,
  );

  final bool isLoaded;
  final String? modelPath;
  final String? projectorPath;

  /// Best-effort compute backend label: `Metal`, `GPU offload`, `CPU` or
  /// `unknown`. Kept as text because benchmark records already store it.
  final String backend;

  final int contextTokens;
  final int batchTokens;
  final int threads;
  final int threadsBatch;
  final int gpuLayers;
  final bool offloadKqv;
}
