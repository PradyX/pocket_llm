import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

class LlmService {
  static const _defaultTemperature = 0.8;
  static const _defaultTopP = 0.95;
  static const _defaultTopK = 40;

  Llama? _llama;
  String? _loadedModelPath;
  bool _isGenerating = false;
  bool _stopRequested = false;
  int _configuredNCtx = 0;
  int _configuredNBatch = 0;
  double _configuredTemperature = _defaultTemperature;
  double _configuredTopP = _defaultTopP;
  int _configuredTopK = _defaultTopK;

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
  }) async {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final cpuCount = Platform.numberOfProcessors;
    final defaultThreads = math.max(2, math.min(isMobile ? 4 : 8, cpuCount));
    final resolvedNCtx = nCtx ?? (isMobile ? 1024 : 2048);
    final modelFile = File(modelPath);

    if (!modelFile.existsSync()) {
      throw Exception('Model file not found at $modelPath');
    }

    final modelSize = modelFile.lengthSync();
    if (modelSize < 4) {
      throw Exception(
        'Model file appears invalid/incomplete. Please delete and re-download it.',
      );
    }

    final header = modelFile.openSync(mode: FileMode.read);
    try {
      final magic = header.readSync(4);
      if (magic.length != 4 ||
          magic[0] != 0x47 ||
          magic[1] != 0x47 ||
          magic[2] != 0x55 ||
          magic[3] != 0x46) {
        throw Exception(
          'Invalid GGUF file. Please delete and re-download the model.',
        );
      }
    } finally {
      header.closeSync();
    }

    if (_llama != null) {
      await unloadModel();
    }

    _stopRequested = false;
    _isGenerating = false;

    final modelParams = ModelParams();
    modelParams.nGpuLayers = nGpuLayers ?? (isMobile ? 0 : 99);

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
    // Unlimited unless caller explicitly wants a cap.
    contextParams.nPredict = nPredict ?? -1;

    final samplerParams = SamplerParams();
    if (temperature != null) samplerParams.temp = temperature;
    if (topP != null) samplerParams.topP = topP;
    if (topK != null) samplerParams.topK = topK;

    try {
      // llama_cpp_dart uses Llama class as the main entry point
      _llama = Llama(
        modelPath,
        modelParams,
        contextParams,
        samplerParams,
        false, // verbose
      );
    } catch (e) {
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
  }) async {
    final resolvedTemperature = temperature ?? _defaultTemperature;
    final resolvedTopP = topP ?? _defaultTopP;
    final resolvedTopK = topK ?? _defaultTopK;

    final requiresReloadForConfig =
        (nCtx != null && nCtx != _configuredNCtx) ||
        (nBatch != null && nBatch != _configuredNBatch) ||
        (resolvedTopK != _configuredTopK) ||
        (resolvedTemperature - _configuredTemperature).abs() > 0.001 ||
        (resolvedTopP - _configuredTopP).abs() > 0.001;
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

    // Clear previous context as we send the full history in the prompt
    llama.clear();
    // setPrompt prepares the model for generation
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

        // Cooperative yielding keeps Flutter responsive on slower phones.
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
}
