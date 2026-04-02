import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/services/platform_runtime_paths_service.dart';

class LlmService {
  static const _defaultTemperature = 0.8;
  static const _defaultTopP = 0.95;
  static const _defaultTopK = 40;

  final PlatformRuntimePathsService? _platformRuntimePathsService;

  Llama? _llama;
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
    print('[LlmService] Loading model: $modelPath');
    print('[LlmService] Vision projector: $normalizedMmprojPath');

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

    final modelParams = ModelParams();
    final isVisionLoad = normalizedMmprojPath != null;
    final defaultGpuLayers = Platform.isIOS
        ? 32
        : Platform.isAndroid
        ? 0
        // Cap GPU layers for vision on desktop to avoid Metal buffer overflow.
        : isVisionLoad
        ? 24
        : 32;
    modelParams.nGpuLayers = nGpuLayers ?? defaultGpuLayers;

    final contextParams = ContextParams();
    contextParams.nCtx = resolvedNCtx;
    if (nBatch != null) {
      final resolvedNBatch = math.min(nBatch, resolvedNCtx);
      contextParams.nBatch = resolvedNBatch;
      contextParams.nUbatch = resolvedNBatch;
    }
    contextParams.nThreads = nThreads ?? defaultThreads;
    contextParams.nThreadsBatch = nThreadsBatch ?? defaultThreads;
    contextParams.offloadKqv = offloadKqv ?? !isMobile;
    contextParams.nPredict = nPredict ?? -1;

    final samplerParams = SamplerParams();
    if (temperature != null) samplerParams.temp = temperature;
    if (topP != null) samplerParams.topP = topP;
    if (topK != null) samplerParams.topK = topK;

    try {
      final file = File(modelPath);
      print('[LlmService] File exists: ${file.existsSync()}');
      if (file.existsSync()) {
        final len = file.lengthSync();
        print('[LlmService] File size: $len bytes');
        if (len >= 64) {
          final header = file.openSync().readSync(64);
          final hex = header
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(' ');
          print('[LlmService] File header (64B): $hex');
        }
      }
      print('[LlmService] Llama.libraryPath: ${Llama.libraryPath}');
      print('[LlmService] ModelParams: nGpuLayers=${modelParams.nGpuLayers}');
      print(
        '[LlmService] ContextParams: nCtx=${contextParams.nCtx}, nBatch=${contextParams.nBatch}, nThreads=${contextParams.nThreads}',
      );
      print('[LlmService] Initializing Llama instance...');
      _llama = Llama(
        modelPath,
        modelParams: modelParams,
        contextParams: contextParams,
        samplerParams: samplerParams,
        verbose: false,
        mmprojPath: normalizedMmprojPath,
      );
      print('[LlmService] Llama initialized successfully.');
    } catch (e, stack) {
      print('[LlmService] Initialization failed: $e');
      print('[LlmService] Stack trace: $stack');
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
    _configuredTemperature = samplerParams.temp;
    _configuredTopP = samplerParams.topP;
    _configuredTopK = samplerParams.topK;
    _configuredMmprojPath = normalizedMmprojPath;
  }

  Future<void> unloadModel() async {
    _llama?.dispose();
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

  Stream<String> generateResponse(String prompt, {int? maxTokens}) async* {
    if (_llama == null) {
      throw Exception('Model not loaded');
    }

    _stopRequested = false;
    _isGenerating = true;
    var generatedTokenCount = 0;

    final llama = _llama!;
    llama.clear();
    llama.setPrompt(prompt);

    try {
      while (true) {
        if (_stopRequested) break;

        final (token, isDone, contextLimitReached) = llama.getNextWithStatus();
        if (token.isNotEmpty) {
          yield token;
          generatedTokenCount++;
        }

        if (maxTokens != null && generatedTokenCount >= maxTokens) break;
        if (isDone || contextLimitReached) break;

        if (generatedTokenCount % 8 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      _isGenerating = false;
    }
  }

  Stream<String> generateVisionResponse(
    String prompt, {
    required List<String> imagePaths,
    int? maxTokens,
  }) async* {
    if (_llama == null) {
      throw Exception('Model not loaded');
    }
    if (imagePaths.isEmpty) {
      throw Exception('No image supplied for vision generation.');
    }

    final inputs = imagePaths
        .map((path) {
          final file = File(path);
          if (!file.existsSync()) {
            throw Exception('Attached image could not be found.');
          }
          return LlamaImage.fromFile(file);
        })
        .toList(growable: false);

    _stopRequested = false;
    _isGenerating = true;
    var generatedTokenCount = 0;

    try {
      await for (final token in _llama!.generateWithMedia(
        prompt,
        inputs: inputs,
      )) {
        if (_stopRequested) break;

        if (token.isNotEmpty) {
          yield token;
          generatedTokenCount++;
        }

        if (maxTokens != null && generatedTokenCount >= maxTokens) {
          _stopRequested = true;
          break;
        }

        if (generatedTokenCount % 8 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      _isGenerating = false;
    }
  }

  void stopGeneration() {
    if (!_isGenerating) return;
    _stopRequested = true;
  }

  Future<void> _ensureLibraryConfigured({required bool requiresVision}) async {
    if (_libraryConfigured) return;

    final preferredPath = await _resolveMultimodalLibraryPath();
    print('[LlmService] Preferred library path: $preferredPath');
    if (preferredPath != null && preferredPath.trim().isNotEmpty) {
      print('[LlmService] Setting Llama.libraryPath to: $preferredPath');
      Llama.libraryPath = preferredPath;
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
