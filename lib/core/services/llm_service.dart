import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/services/platform_runtime_paths_service.dart';
import 'package:pocket_llm/core/utils/logger.dart';

class LlmService {
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
  double _configuredTemperature = _defaultTemperature;
  double _configuredTopP = _defaultTopP;
  int _configuredTopK = _defaultTopK;
  String? _configuredMmprojPath;
  bool _libraryConfigured = false;

  LlmService({PlatformRuntimePathsService? platformRuntimePathsService})
    : _platformRuntimePathsService = platformRuntimePathsService;

  bool get isLoaded => _llama != null;
  bool get isGenerating => _isGenerating;
  bool get isStopRequested => _stopRequested;
  String? get loadedModelPath => _loadedModelPath;

  Future<void> loadModel(
    String modelPath, {
    int? nGpuLayers,
    int? nCtx,
    int? nBatch,
    int? nThreads,
    int? nThreadsBatch,
    bool? offloadKqv,
    int? nPredict,
    double? temperature,
    double? topP,
    int? topK,
    String? mmprojPath,
  }) async {
    final normalizedMmprojPath =
        mmprojPath != null && mmprojPath.trim().isNotEmpty
        ? mmprojPath.trim()
        : null;
    AppLogger.debug('[LlmService] Loading model: $modelPath');
    AppLogger.debug('[LlmService] Vision projector: $normalizedMmprojPath');

    await _ensureLibraryConfigured(
      requiresVision: normalizedMmprojPath != null,
    );

    final isMobile = Platform.isAndroid || Platform.isIOS;
    final cpuCount = Platform.numberOfProcessors;
    final defaultThreads = math.max(2, math.min(isMobile ? 4 : 8, cpuCount));
    final resolvedNCtx = nCtx ?? (isMobile ? 1024 : 2048);

    _validateGgufFile(modelPath, label: 'Model');
    if (normalizedMmprojPath != null) {
      _validateGgufFile(normalizedMmprojPath, label: 'Vision projector');
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
          nGpuLayers ??
          (Platform.isAndroid
              ? 0
              : isVisionLoad
              ? 24
              : 32),
    );
    final resolvedNBatch = math.min(nBatch ?? 512, resolvedNCtx);
    final contextParams = ContextParams(
      nCtx: resolvedNCtx,
      nBatch: resolvedNBatch,
      nUbatch: resolvedNBatch,
      nThreads: nThreads ?? defaultThreads,
      nThreadsBatch: nThreadsBatch ?? defaultThreads,
      offloadKqv: offloadKqv ?? !isMobile,
    );
    _nPredict = nPredict ?? -1;
    final samplerParams = SamplerParams(
      temperature: temperature ?? _defaultTemperature,
      topP: topP ?? _defaultTopP,
      topK: topK ?? _defaultTopK,
    );

    try {
      AppLogger.debug('[LlmService] Native library: $_libraryPath');
      _llama = await LlamaEngine.spawn(
        libraryPath: _libraryPath ?? LlamaLibrary.defaultFileName(),
        modelParams: modelParams,
        contextParams: contextParams,
        multimodalParams: normalizedMmprojPath == null
            ? null
            : MultimodalParams(
                mmprojPath: normalizedMmprojPath,
                mediaMarker: '<image>',
              ),
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
    _configuredTemperature = _defaultTemperature;
    _configuredTopP = _defaultTopP;
    _configuredTopK = _defaultTopK;
    _configuredMmprojPath = null;
  }

  Future<void> ensureModelLoaded(
    String modelPath, {
    int? nGpuLayers,
    int? nCtx,
    int? nBatch,
    int? nThreads,
    int? nThreadsBatch,
    bool? offloadKqv,
    int? nPredict,
    double? temperature,
    double? topP,
    int? topK,
    String? mmprojPath,
  }) async {
    final resolvedTemperature = temperature ?? _defaultTemperature;
    final resolvedTopP = topP ?? _defaultTopP;
    final resolvedTopK = topK ?? _defaultTopK;
    final normalizedMmprojPath =
        mmprojPath != null && mmprojPath.trim().isNotEmpty
        ? mmprojPath.trim()
        : null;

    final requiresReloadForConfig =
        (nCtx != null && nCtx != _configuredNCtx) ||
        (nBatch != null && nBatch != _configuredNBatch) ||
        (resolvedTopK != _configuredTopK) ||
        (resolvedTemperature - _configuredTemperature).abs() > 0.001 ||
        (resolvedTopP - _configuredTopP).abs() > 0.001 ||
        normalizedMmprojPath != _configuredMmprojPath;
    if (isLoaded && _loadedModelPath == modelPath && !requiresReloadForConfig) {
      _nPredict = nPredict ?? _nPredict;
      return;
    }

    await loadModel(
      modelPath,
      nGpuLayers: nGpuLayers,
      nCtx: nCtx,
      nBatch: nBatch,
      nThreads: nThreads,
      nThreadsBatch: nThreadsBatch,
      offloadKqv: offloadKqv,
      nPredict: nPredict,
      temperature: temperature,
      topP: topP,
      topK: topK,
      mmprojPath: normalizedMmprojPath,
    );
  }

  Stream<String> generateResponse(String prompt, {int? maxTokens}) =>
      _generate(prompt, maxTokens: maxTokens);

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

  void stopGeneration() {
    if (!_isGenerating) return;
    _stopRequested = true;
    unawaited(_generation?.cancel());
  }

  Future<void> _ensureLibraryConfigured({required bool requiresVision}) async {
    if (_libraryConfigured && (!requiresVision || _libraryPath != null)) return;

    final preferredPath = await _resolveMultimodalLibraryPath();
    AppLogger.debug('[LlmService] Preferred library path: $preferredPath');
    if (preferredPath != null && preferredPath.trim().isNotEmpty) {
      AppLogger.debug(
        '[LlmService] Setting native library path to: $preferredPath',
      );
      _libraryPath = p.join(
        p.dirname(preferredPath),
        Platform.isIOS || Platform.isMacOS ? 'libllama.dylib' : 'libllama.so',
      );
      _libraryConfigured = true;
      return;
    }

    if (requiresVision) {
      throw Exception(
        'Vision runtime is not bundled on this build. Reinstall the app or use a supported build.',
      );
    }

    _libraryConfigured = true;
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

  void _validateGgufFile(String filePath, {required String label}) {
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
