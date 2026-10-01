import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';

/// How well a model is expected to fit on this device.
///
/// Ratings are descriptive, never guarantees: they are derived from the model's
/// own GGUF metadata, the file size on disk and the device's memory budget.
enum ModelCompatibilityRating {
  recommended(
    'Recommended',
    'Fits with room to spare for a long conversation.',
  ),
  shouldRun('Should Run', 'Fits in memory; expect moderate speed.'),
  mayBeSlow(
    'May Be Slow',
    'Tight fit — expect reduced speed or memory pressure.',
  ),
  memoryRisk(
    'Memory Risk',
    'Likely to run out of memory. Try a smaller quantization or context.',
  ),
  notRecommended(
    'Not Recommended',
    'Larger than this device can hold. Pick a smaller model.',
  );

  const ModelCompatibilityRating(this.label, this.explanation);

  final String label;
  final String explanation;
}

/// Memory estimate for one model on one device.
///
/// The breakdown is intentionally explicit so the UI can show where the
/// estimate comes from instead of presenting a black box.
class ModelMemoryEstimate {
  const ModelMemoryEstimate({
    required this.weightsBytes,
    required this.kvCacheBytes,
    required this.runtimeOverheadBytes,
    required this.projectorBytes,
    required this.contextTokens,
    required this.budgetBytes,
    required this.totalMemoryBytes,
  });

  /// Approximate weight memory: the GGUF file size on disk.
  final int weightsBytes;

  /// KV cache for [contextTokens] at the current context size.
  final int kvCacheBytes;

  /// Runtime buffers and graph overhead reserved by the inference engine.
  final int runtimeOverheadBytes;

  /// Vision projector (mmproj) weights, when the model uses one.
  final int projectorBytes;

  /// Context size the estimate was calculated for.
  final int contextTokens;

  /// Memory the app can expect to use on this device, or null when the
  /// platform does not expose memory information.
  final int? budgetBytes;

  /// Physical memory of the device, when known.
  final int? totalMemoryBytes;

  int get requiredBytes =>
      weightsBytes + kvCacheBytes + runtimeOverheadBytes + projectorBytes;

  /// Required memory as a fraction of the available budget.
  double? get headroomRatio {
    final budget = budgetBytes;
    if (budget == null || budget <= 0) return null;
    return requiredBytes / budget;
  }

  /// Rating for this estimate, or null when the device memory is unknown.
  ModelCompatibilityRating? get rating =>
      ModelCompatibilityEstimator.ratingFor(requiredBytes, budgetBytes);

  /// Human-readable lines documenting the estimate for the UI.
  List<String> explain() {
    final lines = <String>[
      'Model file: ${formatBytes(weightsBytes)}',
      if (kvCacheBytes > 0)
        'KV cache at $contextTokens tokens: ${formatBytes(kvCacheBytes)}',
      if (projectorBytes > 0)
        'Vision projector: ${formatBytes(projectorBytes)}',
      'Runtime overhead: ${formatBytes(runtimeOverheadBytes)}',
      if (budgetBytes != null)
        'Budget on this device: ${formatBytes(budgetBytes!)}',
    ];
    return lines;
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Estimates whether a model fits on a device.
///
/// The calculation is deliberately simple, documented and testable:
///
/// ```text
/// required = weights + KV cache + runtime overhead + projector
/// weights   = GGUF file size on disk
/// KV cache  = layers × KV heads × head dim × 2 (K and V) × 2 bytes × context
/// overhead  = 320 MiB + 5% of the weights
/// budget    = available memory, else 60% of physical memory (capped at 85%)
/// ```
///
/// KV cache details come from the GGUF metadata when the model publishes them
/// (`<arch>.attention.head_count_kv`, `key_length`, `value_length`) and fall
/// back to the embedding size divided by a 128-dimension head.
class ModelCompatibilityEstimator {
  const ModelCompatibilityEstimator._();

  /// f16 KV cache, the default for the bundled runtime.
  static const int kvBytesPerElement = 2;

  /// Fixed runtime buffers (graph, samplers, scratch) reserved by the engine.
  static const int runtimeOverheadBaseBytes = 320 * 1024 * 1024;

  /// Extra overhead proportional to the weights (temporary buffers).
  static const double runtimeOverheadWeightsFraction = 0.05;

  /// Head dimension assumed when the GGUF file does not describe one.
  static const int fallbackHeadDim = 128;

  /// Fraction of physical memory used as the budget when the platform does not
  /// report free memory (mobile OSes never let an app use all of it).
  static const double fallbackBudgetFractionOfTotal = 0.6;

  /// Hard ceiling: the app should never plan to use almost all physical RAM.
  static const double maxBudgetFractionOfTotal = 0.85;

  /// Rating thresholds, as required memory / budget.
  static const double recommendedMaxRatio = 0.6;
  static const double shouldRunMaxRatio = 0.85;
  static const double mayBeSlowMaxRatio = 1.0;
  static const double memoryRiskMaxRatio = 1.3;

  /// Builds the estimate for [metadata] running with [contextTokens] context.
  ///
  /// [fileSizeBytes] is the GGUF file size; [projectorBytes] is the mmproj file
  /// size when the model uses vision. Memory is only rated when the device
  /// reports [totalMemoryBytes] or [availableMemoryBytes].
  static ModelMemoryEstimate estimate({
    required GgufMetadata metadata,
    required int contextTokens,
    required int fileSizeBytes,
    int projectorBytes = 0,
    int? totalMemoryBytes,
    int? availableMemoryBytes,
  }) {
    final weights = fileSizeBytes > 0 ? fileSizeBytes : metadata.fileSizeBytes;
    final kvCache = kvCacheBytes(metadata, contextTokens);
    final overhead =
        runtimeOverheadBaseBytes +
        (weights * runtimeOverheadWeightsFraction).round();
    final budget = memoryBudget(
      totalMemoryBytes: totalMemoryBytes,
      availableMemoryBytes: availableMemoryBytes,
    );

    return ModelMemoryEstimate(
      weightsBytes: weights,
      kvCacheBytes: kvCache,
      runtimeOverheadBytes: overhead,
      projectorBytes: projectorBytes < 0 ? 0 : projectorBytes,
      contextTokens: contextTokens,
      budgetBytes: budget,
      totalMemoryBytes: totalMemoryBytes,
    );
  }

  /// KV cache size in bytes for [contextTokens] tokens.
  ///
  /// Returns 0 when the metadata does not describe the architecture well
  /// enough to estimate it, so callers can show "unknown" instead of a wrong
  /// number.
  static int kvCacheBytes(GgufMetadata metadata, int contextTokens) {
    if (contextTokens <= 0) return 0;
    final layers = metadata.blockCount ?? 0;
    if (layers <= 0) return 0;

    final architecture = metadata.architecture;
    final scalars = metadata.numericScalars;
    final headCount = _scalarInt(
      scalars,
      _archKey(architecture, 'attention.head_count'),
    );
    final kvHeads =
        _scalarInt(
          scalars,
          _archKey(architecture, 'attention.head_count_kv'),
        ) ??
        headCount;
    final keyLength = _scalarInt(
      scalars,
      _archKey(architecture, 'attention.key_length'),
    );
    final valueLength = _scalarInt(
      scalars,
      _archKey(architecture, 'attention.value_length'),
    );

    final embedding = metadata.embeddingLength;
    final headDim =
        keyLength ??
        valueLength ??
        (headCount != null && headCount > 0 && embedding != null
            ? (embedding / headCount).round()
            : fallbackHeadDim);
    if (headDim <= 0) return 0;

    final kvHeadCount =
        kvHeads ??
        (embedding != null && embedding > 0
            ? (embedding / headDim).round()
            : 0);
    if (kvHeadCount <= 0) return 0;

    final bytes =
        BigInt.from(layers) *
        BigInt.from(kvHeadCount) *
        BigInt.from(headDim) *
        BigInt.two * // one K tensor and one V tensor per layer
        BigInt.from(kvBytesPerElement) *
        BigInt.from(contextTokens);
    final maxInt = BigInt.from(1) << 62;
    if (bytes > maxInt) return maxInt.toInt();
    return bytes.toInt();
  }

  /// Memory the app can plan to use, or null when memory is unknown.
  static int? memoryBudget({int? totalMemoryBytes, int? availableMemoryBytes}) {
    final total = totalMemoryBytes;
    final available = availableMemoryBytes;

    var budget = available;
    if (budget == null || budget <= 0) {
      if (total == null || total <= 0) return null;
      budget = (total * fallbackBudgetFractionOfTotal).round();
    }
    if (total != null && total > 0) {
      final ceiling = (total * maxBudgetFractionOfTotal).round();
      if (budget > ceiling) budget = ceiling;
    }
    return budget <= 0 ? null : budget;
  }

  /// Rating for a [requiredBytes] estimate against [budgetBytes].
  static ModelCompatibilityRating? ratingFor(
    int requiredBytes,
    int? budgetBytes,
  ) {
    if (budgetBytes == null || budgetBytes <= 0 || requiredBytes <= 0) {
      return null;
    }
    final ratio = requiredBytes / budgetBytes;
    if (ratio <= recommendedMaxRatio) {
      return ModelCompatibilityRating.recommended;
    }
    if (ratio <= shouldRunMaxRatio) {
      return ModelCompatibilityRating.shouldRun;
    }
    if (ratio <= mayBeSlowMaxRatio) {
      return ModelCompatibilityRating.mayBeSlow;
    }
    if (ratio <= memoryRiskMaxRatio) {
      return ModelCompatibilityRating.memoryRisk;
    }
    return ModelCompatibilityRating.notRecommended;
  }

  static String _archKey(String architecture, String suffix) {
    return architecture.isEmpty ? suffix : '$architecture.$suffix';
  }

  static int? _scalarInt(Map<String, num> scalars, String key) {
    final value = scalars[key];
    if (value == null) return null;
    final rounded = value.round();
    return rounded > 0 ? rounded : null;
  }
}
