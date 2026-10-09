import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/inference/inference_engine.dart';
import 'package:pocket_llm/core/services/native_runtime_layout.dart';
import 'package:pocket_llm/core/services/platform_runtime_paths_service.dart';
import 'package:pocket_llm/core/utils/logger.dart';

/// The bundled llama.cpp engine, seen by the rest of the app through
/// [InferenceEngine].
///
/// This is the only place that owns `llama_cpp_dart` types: native parameters,
/// the engine, its session and its media handles all stop here. Features depend
/// on [InferenceEngine] instead, which is what keeps a runtime swap from
/// reaching into chat, voice, documents or benchmarks.
class LlmService implements InferenceEngine {
  static const _defaultTemperature = 0.8;
  static const _defaultTopP = 0.95;
  static const _defaultTopK = 40;

  final PlatformRuntimePathsService? _platformRuntimePathsService;

  LlamaEngine? _llama;
  EngineSession? _session;
  StreamIterator<GenerationEvent>? _generation;
  String? _libraryPath;
  int _nPredict = -1;
  String? _loadedModelPath;
  bool _isGenerating = false;
  bool _stopRequested = false;
  int _configuredNCtx = 0;
  int _configuredNBatch = 0;
  int _configuredThreads = 0;
  int _configuredThreadsBatch = 0;
  int _configuredGpuLayers = 0;
  bool _configuredOffloadKqv = false;
  double _configuredTemperature = _defaultTemperature;
  double _configuredTopP = _defaultTopP;
  int _configuredTopK = _defaultTopK;
  String? _configuredMmprojPath;
  bool _libraryConfigured = false;

  /// Whether the bundled multimodal runtime was found on this build.
  ///
  /// Sticky: it describes the build, not the model currently loaded, so it
  /// survives an unload.
  bool? _multimodalRuntimeAvailable;

  /// True when the runtime's native code is linked into the app instead of
  /// being opened from a library shipped beside it. The platform rule lives in
  /// [NativeRuntimeLayout] so the embedding engine answers it the same way.
  static bool get _usesLinkedFramework =>
      NativeRuntimeLayout.isLinkedIntoProcess;

  LlmService({PlatformRuntimePathsService? platformRuntimePathsService})
    : _platformRuntimePathsService = platformRuntimePathsService;

  @override
  bool get isLoaded => _llama != null;

  @override
  bool get isGenerating => _isGenerating;

  @override
  bool get isStopRequested => _stopRequested;

  @override
  String? get loadedModelPath => _loadedModelPath;

  /// What this runtime can do on this device.
  ///
  /// Image and audio input are reported from whether the bundled multimodal
  /// runtime was found, which is resolved when the runtime is first
  /// configured: they read false until the first load on a build that does
  /// bundle it. Use them to explain an unavailable feature, not to hide one.
  @override
  InferenceCapabilities get capabilities {
    final multimodal = _multimodalRuntimeAvailable ?? false;
    return InferenceCapabilities(
      streaming: true,
      cancellation: true,
      gpuOffload: supportsGpuOffload,
      vision: multimodal,
      audio: multimodal,
      // The runtime can produce embeddings, but no method on the seam asks
      // for one and the knowledge index is lexical, so nothing here can offer
      // it yet. See `InferenceEngine`'s note on the section 17 evaluation.
      embeddings: false,
    );
  }

  /// Effective runtime configuration of the loaded model.
  ///
  /// These reflect what the engine was actually started with (including the
  /// defaults this service applies), so diagnostics and benchmark records can
  /// describe a run instead of guessing.
  @override
  InferenceRuntimeInfo get runtimeInfo {
    return InferenceRuntimeInfo(
      isLoaded: isLoaded,
      modelPath: _loadedModelPath,
      projectorPath: _configuredMmprojPath,
      backend: _runtimeBackend,
      contextTokens: _configuredNCtx,
      batchTokens: _configuredNBatch,
      threads: _configuredThreads,
      threadsBatch: _configuredThreadsBatch,
      gpuLayers: _configuredGpuLayers,
      offloadKqv: _configuredOffloadKqv,
    );
  }

  /// Best-effort label for the compute backend of the loaded model.
  ///
  /// Metal is the only GPU path the bundled runtime uses; everything else is
  /// reported as CPU when no layers are offloaded.
  String get _runtimeBackend {
    if (!isLoaded) return 'unknown';
    if (Platform.isMacOS || Platform.isIOS) return 'Metal';
    return _configuredGpuLayers > 0 ? 'GPU offload' : 'CPU';
  }

  /// Threads the runtime uses when a request does not specify them.
  ///
  /// Shared with the inference-profile resolver so a profile that overrides
  /// nothing reproduces the runtime's own defaults.
  static int defaultComputeThreads({required bool isMobile}) {
    final cpuCount = Platform.numberOfProcessors;
    return math.max(2, math.min(isMobile ? 4 : 8, cpuCount));
  }

  /// GPU layers the runtime uses when a request does not specify them.
  static int defaultGpuLayers({required bool isVisionLoad}) {
    if (Platform.isAndroid) return 0;
    return isVisionLoad ? 24 : 32;
  }

  /// Whether the KV cache is kept on the GPU when a request does not say.
  static bool defaultOffloadKqv({required bool isMobile}) => !isMobile;

  /// True when this platform can offload layers to the GPU at all.
  static bool get supportsGpuOffload => !Platform.isAndroid;

  @override
  Future<void> loadModel(InferenceLoadRequest request) async {
    final modelPath = request.modelPath;
    final normalizedMmprojPath = _normalizedProjectorPath(
      request.projectorPath,
    );
    AppLogger.debug('[LlmService] Loading model: $modelPath');
    AppLogger.debug('[LlmService] Vision projector: $normalizedMmprojPath');

    await _ensureLibraryConfigured(
      requiresMultimodal: normalizedMmprojPath != null,
    );

    final isMobile = Platform.isAndroid || Platform.isIOS;
    final defaultThreads = defaultComputeThreads(isMobile: isMobile);
    final resolvedNCtx = request.contextTokens ?? (isMobile ? 1024 : 2048);

    validateGgufFile(modelPath, label: 'Model');
    if (normalizedMmprojPath != null) {
      validateGgufFile(normalizedMmprojPath, label: 'Vision projector');
    }

    if (_llama != null) {
      await unloadModel();
    }

    _stopRequested = false;
    _isGenerating = false;

    final isVisionLoad = normalizedMmprojPath != null;
    final modelParams = ModelParams(
      path: modelPath,
      gpuLayers:
          request.gpuLayers ?? defaultGpuLayers(isVisionLoad: isVisionLoad),
    );
    final resolvedNBatch = math.min(request.batchTokens ?? 512, resolvedNCtx);
    final contextParams = ContextParams(
      nCtx: resolvedNCtx,
      nBatch: resolvedNBatch,
      nUbatch: resolvedNBatch,
      nThreads: request.threads ?? defaultThreads,
      nThreadsBatch: request.threadsBatch ?? defaultThreads,
      offloadKqv: request.offloadKqv ?? defaultOffloadKqv(isMobile: isMobile),
    );
    _nPredict = request.maxTokens ?? -1;
    _configuredThreads = contextParams.nThreads;
    _configuredThreadsBatch = contextParams.nThreadsBatch;
    _configuredGpuLayers = modelParams.gpuLayers;
    _configuredOffloadKqv = contextParams.offloadKqv;
    final samplerParams = SamplerParams(
      temperature: request.temperature ?? _defaultTemperature,
      topP: request.topP ?? _defaultTopP,
      topK: request.topK ?? _defaultTopK,
    );

    try {
      AppLogger.debug(
        '[LlmService] Native library: '
        '${_usesLinkedFramework ? '<process>' : _libraryPath}',
      );
      final multimodalParams = normalizedMmprojPath == null
          ? null
          : MultimodalParams(
              mmprojPath: normalizedMmprojPath,
              mediaMarker: '<image>',
            );
      _llama = _usesLinkedFramework
          ? await LlamaEngine.spawnFromProcess(
              modelParams: modelParams,
              contextParams: contextParams,
              multimodalParams: multimodalParams,
            )
          : await LlamaEngine.spawn(
              libraryPath: _libraryPath ?? LlamaLibrary.defaultFileName(),
              modelParams: modelParams,
              contextParams: contextParams,
              multimodalParams: multimodalParams,
            );
      _session = await _llama!.createSession();
    } catch (e, stack) {
      await unloadModel();
      AppLogger.error('[LlmService] Initialization failed', e, stack);
      final details = e.toString().toLowerCase();
      if (details.contains('unknown') ||
          details.contains('unsupported') ||
          details.contains('architecture')) {
        throw Exception(
          'Model format is not supported by current llama runtime. '
          'Try another GGUF model or update llama_cpp_dart.',
        );
      }
      throw Exception(
        'Failed to initialize model. The file may be corrupted or unsupported. '
        'Please re-download and try again.',
      );
    }
    _loadedModelPath = modelPath;
    _configuredNCtx = contextParams.nCtx;
    _configuredNBatch = contextParams.nBatch;
    _configuredTemperature = samplerParams.temperature;
    _configuredTopP = samplerParams.topP;
    _configuredTopK = samplerParams.topK;
    _configuredMmprojPath = normalizedMmprojPath;
  }

  @override
  Future<void> unloadModel() async {
    await _generation?.cancel();
    _generation = null;
    await _session?.dispose();
    _session = null;
    await _llama?.dispose();
    _llama = null;
    _loadedModelPath = null;
    _isGenerating = false;
    _stopRequested = false;
    _configuredNCtx = 0;
    _configuredNBatch = 0;
    _configuredThreads = 0;
    _configuredThreadsBatch = 0;
    _configuredGpuLayers = 0;
    _configuredOffloadKqv = false;
    _configuredTemperature = _defaultTemperature;
    _configuredTopP = _defaultTopP;
    _configuredTopK = _defaultTopK;
    _configuredMmprojPath = null;
  }

  @override
  Future<void> ensureModelLoaded(InferenceLoadRequest request) async {
    final resolvedTemperature = request.temperature ?? _defaultTemperature;
    final resolvedTopP = request.topP ?? _defaultTopP;
    final resolvedTopK = request.topK ?? _defaultTopK;
    final normalizedMmprojPath = _normalizedProjectorPath(
      request.projectorPath,
    );

    // Every setting a profile can control forces a reload, otherwise switching
    // profiles would silently keep the previous configuration.
    final requiresReloadForConfig =
        (request.contextTokens != null &&
            request.contextTokens != _configuredNCtx) ||
        (request.batchTokens != null &&
            request.batchTokens != _configuredNBatch) ||
        (request.threads != null && request.threads != _configuredThreads) ||
        (request.threadsBatch != null &&
            request.threadsBatch != _configuredThreadsBatch) ||
        (request.gpuLayers != null &&
            request.gpuLayers != _configuredGpuLayers) ||
        (request.offloadKqv != null &&
            request.offloadKqv != _configuredOffloadKqv) ||
        (resolvedTopK != _configuredTopK) ||
        (resolvedTemperature - _configuredTemperature).abs() > 0.001 ||
        (resolvedTopP - _configuredTopP).abs() > 0.001 ||
        normalizedMmprojPath != _configuredMmprojPath;
    if (isLoaded &&
        _loadedModelPath == request.modelPath &&
        !requiresReloadForConfig) {
      _nPredict = request.maxTokens ?? _nPredict;
      return;
    }

    await loadModel(request);
  }

  @override
  Stream<String> generateResponse(String prompt, {int? maxTokens}) =>
      _generate(prompt, maxTokens: maxTokens);

  @override
  Stream<String> generateVisionResponse(
    String prompt, {
    required List<String> imagePaths,
    int? maxTokens,
  }) {
    if (imagePaths.isEmpty) {
      throw Exception('No image supplied for vision generation.');
    }
    final media = imagePaths
        .map((path) {
          if (!File(path).existsSync()) {
            throw Exception('Attached image could not be found.');
          }
          return LlamaMedia.imageFile(path);
        })
        .toList(growable: false);
    return _generate(prompt, maxTokens: maxTokens, media: media);
  }

  /// Streams a response about one local audio clip.
  ///
  /// The clip is decoded by the bundled multimodal runtime, which reads wav,
  /// mp3 and flac through miniaudio, so the bytes never leave the device and
  /// no Dart-side decoder is involved. The prompt must contain the media
  /// marker the engine was started with, exactly as the image path does.
  @override
  Stream<String> generateAudioResponse(
    String prompt, {
    required String audioPath,
    int? maxTokens,
  }) {
    if (!File(audioPath).existsSync()) {
      throw Exception('Attached audio could not be found.');
    }
    return _generate(
      prompt,
      maxTokens: maxTokens,
      media: [LlamaMedia.audioFile(audioPath)],
    );
  }

  Stream<String> _generate(
    String prompt, {
    int? maxTokens,
    List<LlamaMedia> media = const [],
  }) async* {
    final session = _session;
    if (session == null) throw Exception('Model not loaded');
    if (_isGenerating) throw StateError('Generation already in progress');
    _stopRequested = false;
    _isGenerating = true;
    try {
      await session.clear();
      if (_stopRequested) return;
      final generation = StreamIterator(
        session.generate(
          prompt: prompt,
          addSpecial: true,
          media: media,
          sampler: SamplerParams(
            temperature: _configuredTemperature,
            topP: _configuredTopP,
            topK: _configuredTopK,
          ),
          // The new API requires a non-negative limit; context capacity still
          // bounds requests that previously used nPredict = -1.
          maxTokens:
              maxTokens ?? (_nPredict >= 0 ? _nPredict : _configuredNCtx),
        ),
      );
      _generation = generation;
      while (!_stopRequested && await generation.moveNext()) {
        final event = generation.current;
        if (_stopRequested) break;
        if (event is TokenEvent && event.text.isNotEmpty) yield event.text;
      }
    } finally {
      await _generation?.cancel();
      _generation = null;
      _isGenerating = false;
    }
  }

  @override
  void cancel() {
    if (!_isGenerating) return;
    _stopRequested = true;
    unawaited(_generation?.cancel());
  }

  /// Trims a projector path, treating blank text as "no projector".
  static String? _normalizedProjectorPath(String? projectorPath) {
    if (projectorPath == null || projectorPath.trim().isEmpty) return null;
    return projectorPath.trim();
  }

  Future<void> _ensureLibraryConfigured({
    required bool requiresMultimodal,
  }) async {
    if (_libraryConfigured &&
        (!requiresMultimodal || _multimodalRuntimeAvailable == true)) {
      return;
    }

    if (_usesLinkedFramework) {
      // Nothing to resolve: the framework was linked by Xcode, so the only
      // question is whether this build's image carries the multimodal half.
      _multimodalRuntimeAvailable = _hasLinkedMultimodalRuntime();
      _libraryConfigured = true;
      AppLogger.debug(
        '[LlmService] Linked runtime carries multimodal: '
        '$_multimodalRuntimeAvailable',
      );
      if (requiresMultimodal && _multimodalRuntimeAvailable != true) {
        throw Exception(
          'Image and audio runtime is not bundled on this build. Reinstall the app or use a supported build.',
        );
      }
      return;
    }

    final preferredPath = await _resolveMultimodalLibraryPath();
    AppLogger.debug('[LlmService] Preferred library path: $preferredPath');
    // Recorded here because this is where the build is inspected; the result
    // answers [InferenceCapabilities.vision] and `.audio` for the session.
    _multimodalRuntimeAvailable =
        preferredPath != null && preferredPath.trim().isNotEmpty;
    if (preferredPath != null && preferredPath.trim().isNotEmpty) {
      AppLogger.debug(
        '[LlmService] Setting native library path to: $preferredPath',
      );
      _libraryPath = p.join(
        p.dirname(preferredPath),
        NativeRuntimeLayout.sharedLibraryFileName,
      );
      _libraryConfigured = true;
      return;
    }

    if (requiresMultimodal) {
      throw Exception(
        'Image and audio runtime is not bundled on this build. Reinstall the app or use a supported build.',
      );
    }

    _libraryConfigured = true;
  }

  /// Whether the linked-in runtime carries the multimodal (mtmd) half.
  ///
  /// [InferenceCapabilities.vision] and `.audio` are answered from this. The
  /// framework ships llama.cpp, its ggml backends and libmtmd in a single
  /// image, so the question is whether a known mtmd entry point resolves in
  /// this process. A real lookup is used rather than a hard-coded `true`, so a
  /// build that ships a text-only runtime reports the truth.
  static bool _hasLinkedMultimodalRuntime() {
    try {
      DynamicLibrary.process().lookup<NativeFunction<Void Function()>>(
        'mtmd_context_params_default',
      );
      return true;
    } on ArgumentError {
      return false;
    } on UnsupportedError {
      return false;
    }
  }

  Future<String?> _resolveMultimodalLibraryPath() async {
    final overridePath = Platform.environment['POCKET_LLM_MTMD_PATH'];
    if (overridePath != null && overridePath.trim().isNotEmpty) {
      final overrideFile = File(overridePath.trim());
      if (overrideFile.existsSync()) {
        return overrideFile.path;
      }
    }

    if (Platform.isAndroid) {
      final nativeLibraryDir = await _platformRuntimePathsService
          ?.getAndroidNativeLibraryDir();
      if (nativeLibraryDir != null && nativeLibraryDir.trim().isNotEmpty) {
        final candidate = p.join(nativeLibraryDir, 'libmtmd.so');
        if (File(candidate).existsSync()) {
          return candidate;
        }
      }
      return null;
    }

    if (Platform.isIOS || Platform.isMacOS) {
      final frameworksDir = await _platformRuntimePathsService
          ?.getAppleFrameworksDir();
      if (frameworksDir == null || frameworksDir.trim().isEmpty) {
        return null;
      }

      final candidate = p.join(frameworksDir, 'libmtmd.dylib');
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    if (Platform.isLinux) {
      final executable = File(Platform.resolvedExecutable);
      final candidates = <String>{
        p.join(executable.parent.path, 'libmtmd.so'),
        p.join(executable.parent.path, 'lib', 'libmtmd.so'),
        p.join(executable.parent.parent.path, 'lib', 'libmtmd.so'),
      };

      for (final candidate in candidates) {
        if (File(candidate).existsSync()) {
          return candidate;
        }
      }
    }

    return null;
  }

  /// Rejects a file that is not a GGUF at all before a runtime is asked to
  /// open it, so the user gets a sentence instead of a native error.
  ///
  /// Shared with the embedding service: both load models the same way, and a
  /// half-downloaded file has to fail in both.
  static void validateGgufFile(String filePath, {required String label}) {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw Exception('$label file not found at $filePath');
    }

    if (file.lengthSync() < 4) {
      throw Exception(
        '$label file appears invalid or incomplete. Please re-download it.',
      );
    }

    final header = file.openSync(mode: FileMode.read);
    try {
      final magic = header.readSync(4);
      if (magic.length != 4 ||
          magic[0] != 0x47 ||
          magic[1] != 0x47 ||
          magic[2] != 0x55 ||
          magic[3] != 0x46) {
        throw Exception(
          'Invalid GGUF file for $label. Please delete and re-download it.',
        );
      }
    } finally {
      header.closeSync();
    }
  }
}
