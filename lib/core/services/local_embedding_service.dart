import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:pocket_llm/core/inference/embedding_engine.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/native_runtime_layout.dart';
import 'package:pocket_llm/core/services/platform_runtime_paths_service.dart';
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/core/utils/logger.dart';

/// The bundled llama.cpp runtime, loaded a second time for embeddings.
///
/// Chat and embeddings cannot share one engine: an embedding context is
/// spawned with `ContextParams(embeddings: true)`, and the pool it uses is
/// fixed when the context is created. The chat context is therefore left
/// untouched, and this service owns its own engine, its own small model and its
/// own lifetime — it is loaded when documents are indexed or queried and
/// released when that work is done, so two models are never resident for
/// longer than the operation needs.
///
/// This is the only other place that owns `llama_cpp_dart` types. Everything
/// above it depends on `EmbeddingEngine`.
class LocalEmbeddingService implements EmbeddingEngine {
  LocalEmbeddingService({
    PlatformRuntimePathsService? platformRuntimePathsService,
  }) : _platformRuntimePathsService = platformRuntimePathsService;

  /// Characters per token assumed when an input is bounded, i.e. deliberately
  /// pessimistic:
  /// the app's `TokenEstimator` counts four characters per token, but dense
  /// text (code, tables, CJK) packs more tokens into the same characters. Being
  /// wrong here only means embedding slightly less of a long chunk, while being
  /// optimistic means a decode error, so the margin is taken.
  static const int _charactersPerToken = 3;

  /// Special tokens added around an input, reserved from the window.
  static const int _specialTokenAllowance = 2;

  final PlatformRuntimePathsService? _platformRuntimePathsService;

  LlamaEngine? _engine;
  String? _modelId;
  int? _dimensions;
  int _maxInputTokens = 512;
  int _batchSize = 4;

  @override
  bool get isLoaded => _engine != null;

  @override
  String? get loadedModelId => _engine == null ? null : _modelId;

  @override
  int? get dimensions => _engine == null ? null : _dimensions;

  @override
  Future<void> load(EmbeddingLoadRequest request) async {
    final modelPath = request.modelPath;
    AppLogger.debug(
      '[LocalEmbeddingService] Loading embedding model: $modelPath',
    );
    LlmService.validateGgufFile(modelPath, label: 'Embedding model');

    await unload();

    final isMobile = Platform.isAndroid || Platform.isIOS;
    final threads =
        request.threads ?? LlmService.defaultComputeThreads(isMobile: isMobile);
    final window = math.max(32, request.maxInputTokens);
    final batchSize = math.max(1, request.batchSize);

    final contextParams = ContextParams(
      nCtx: window,
      nBatch: window,
      nUbatch: window,
      // One sequence per text in a batch, so a batch is a single decode.
      nSeqMax: batchSize,
      nThreads: threads,
      nThreadsBatch: threads,
      // Pooled embeddings are the whole point: a mean over the model's hidden
      // states, which is what a retrieval vector is.
      poolingType: PoolingType.mean,
      embeddings: true,
    );
    final modelParams = ModelParams(
      path: modelPath,
      gpuLayers: LlmService.defaultGpuLayers(isVisionLoad: false),
    );

    try {
      _engine = NativeRuntimeLayout.isLinkedIntoProcess
          ? await LlamaEngine.spawnFromProcess(
              modelParams: modelParams,
              contextParams: contextParams,
            )
          : await LlamaEngine.spawn(
              libraryPath:
                  await _resolveLibraryPath() ?? LlamaLibrary.defaultFileName(),
              modelParams: modelParams,
              contextParams: contextParams,
            );
    } catch (error, stack) {
      await unload();
      AppLogger.error(
        '[LocalEmbeddingService] Initialization failed',
        error,
        stack,
      );
      throw Exception(
        'The embedding model could not be loaded. The file may be corrupted, '
        'unsupported by this runtime, or not an embedding model. '
        'Re-download it or pick another one.',
      );
    }

    _modelId = request.modelId;
    _dimensions = request.dimensions;
    _maxInputTokens = window;
    _batchSize = batchSize;
    AppLogger.debug(
      '[LocalEmbeddingService] Ready: ${request.modelId}, '
      'window $window tokens, batch $batchSize.',
    );
  }

  @override
  Future<void> unload() async {
    final engine = _engine;
    _engine = null;
    _modelId = null;
    _dimensions = null;
    _maxInputTokens = 512;
    _batchSize = 4;
    if (engine == null) return;
    try {
      await engine.dispose();
    } catch (error, stack) {
      AppLogger.error(
        '[LocalEmbeddingService] Could not release',
        error,
        stack,
      );
    }
  }

  @override
  Future<List<Float32List>> embed(
    List<String> texts, {
    CancelToken? cancelToken,
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw Exception('No embedding model is loaded.');
    }
    if (texts.isEmpty) return const <Float32List>[];

    final vectors = <Float32List>[];
    for (var start = 0; start < texts.length; start += _batchSize) {
      cancelToken?.throwIfCancelled();
      final end = math.min(start + _batchSize, texts.length);
      final batch = <String>[
        for (var i = start; i < end; i++) _boundedInput(texts[i]),
      ];

      final List<EmbeddingResult> results;
      try {
        results = await engine.embedBatch(batch);
      } catch (error, stack) {
        AppLogger.error(
          '[LocalEmbeddingService] Embedding failed',
          error,
          stack,
        );
        throw Exception(
          'A vector could not be computed for part of this document. '
          'Try a smaller document or another embedding model.',
        );
      }
      for (final result in results) {
        vectors.add(_vectorFrom(result));
      }
      cancelToken?.throwIfCancelled();
    }
    return vectors;
  }

  /// The pooled, L2-normalized vector of one result.
  ///
  /// A model that answers per token instead of pooled is averaged here rather
  /// than rejected, so an embedding model whose pooling type this build does
  /// not know still produces a usable retrieval vector.
  Float32List _vectorFrom(EmbeddingResult result) {
    final expected = _dimensions;
    if (expected != null && result.nEmbd != expected) {
      throw Exception(
        'The embedding model produced ${result.nEmbd}-dimensional vectors but '
        'this index was built for $expected. Re-index with the model that '
        'matches the collection.',
      );
    }
    if (result.vector.isEmpty) {
      throw Exception('The embedding model returned an empty vector.');
    }

    final vector = result.pooled
        ? _copyOf(result.vector)
        : _meanPooled(result.vector, result.nEmbd, result.nTokens);
    _dimensions ??= result.nEmbd;
    if (!result.normalized) _normalizeInPlace(vector);
    return vector;
  }

  /// Averages the per-token rows of an unpooled result into one vector.
  static Float32List _meanPooled(Float32List rows, int nEmbd, int nTokens) {
    final pooled = Float32List(nEmbd);
    if (nEmbd <= 0 || nTokens <= 0) return pooled;
    var counted = 0;
    for (var token = 0; token < nTokens; token++) {
      final offset = token * nEmbd;
      if (offset + nEmbd > rows.length) break;
      for (var i = 0; i < nEmbd; i++) {
        pooled[i] += rows[offset + i];
      }
      counted++;
    }
    if (counted == 0) return pooled;
    for (var i = 0; i < nEmbd; i++) {
      pooled[i] /= counted;
    }
    return pooled;
  }

  static void _normalizeInPlace(Float32List vector) {
    var sum = 0.0;
    for (final value in vector) {
      sum += value * value;
    }
    if (sum <= 0) return;
    final scale = math.sqrt(sum);
    for (var i = 0; i < vector.length; i++) {
      vector[i] /= scale;
    }
  }

  static Float32List _copyOf(Float32List source) {
    final copy = Float32List(source.length);
    copy.setRange(0, source.length, source);
    return copy;
  }

  /// Bounds one input to the model's window.
  ///
  /// The runtime's tokenizer lives inside its isolate, so the window is applied
  /// to characters with a pessimistic ratio. Only the text handed to the model
  /// is shortened; the chunk a citation points at is untouched.
  String _boundedInput(String text) {
    final maxCharacters =
        math.max(1, _maxInputTokens - _specialTokenAllowance) *
        _charactersPerToken;
    if (text.length <= maxCharacters) return text;
    return text.substring(0, maxCharacters);
  }

  Future<String?> _resolveLibraryPath() async {
    final androidNativeLibraryDir = await _platformRuntimePathsService
        ?.getAndroidNativeLibraryDir();
    final appleFrameworksDir = await _platformRuntimePathsService
        ?.getAppleFrameworksDir();
    return NativeRuntimeLayout.resolveSharedLibraryPath(
      androidNativeLibraryDir: androidNativeLibraryDir,
      appleFrameworksDir: appleFrameworksDir,
      resolvedExecutable: Platform.resolvedExecutable,
    );
  }
}
