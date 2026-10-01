import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/model_compatibility.dart';

GgufMetadata _metadata({
  int? layers = 4,
  int? embedding = 128,
  int? contextLength = 4096,
  String architecture = 'llama',
  Map<String, num> scalars = const {},
  int fileSizeBytes = 0,
}) {
  return GgufMetadata(
    architecture: architecture,
    name: 'Test',
    version: 3,
    kvCount: 10,
    tensorCount: 4,
    fileSizeBytes: fileSizeBytes,
    parameterCount: 1000000,
    quantization: 'Q4_K_M',
    contextLength: contextLength,
    embeddingLength: embedding,
    blockCount: layers,
    numericScalars: scalars,
  );
}

void main() {
  group('KV cache estimation', () {
    test('uses head counts and key length from GGUF metadata', () {
      final metadata = _metadata(
        scalars: const {
          'llama.attention.head_count': 8,
          'llama.attention.head_count_kv': 2,
          'llama.attention.key_length': 16,
        },
      );

      // 4 layers × 2 KV heads × 16 head dim × 2 (K and V) × 2 bytes × 4096.
      expect(
        ModelCompatibilityEstimator.kvCacheBytes(metadata, 4096),
        4 * 2 * 16 * 2 * 2 * 4096,
      );
    });

    test('falls back to a 128-dimension head when metadata is sparse', () {
      final metadata = _metadata(scalars: const {});

      // 4 layers × 1 KV head × 128 head dim × 2 × 2 bytes × 4096.
      expect(
        ModelCompatibilityEstimator.kvCacheBytes(metadata, 4096),
        4 * 1 * 128 * 2 * 2 * 4096,
      );
    });

    test('returns 0 when the architecture cannot be estimated', () {
      expect(
        ModelCompatibilityEstimator.kvCacheBytes(_metadata(layers: null), 4096),
        0,
      );
      expect(ModelCompatibilityEstimator.kvCacheBytes(_metadata(), 0), 0);
    });

    test('scales with context size', () {
      final small = ModelCompatibilityEstimator.kvCacheBytes(_metadata(), 2048);
      final large = ModelCompatibilityEstimator.kvCacheBytes(_metadata(), 4096);
      expect(large, small * 2);
    });
  });

  group('memory budget', () {
    test('prefers free memory and falls back to a fraction of total', () {
      expect(
        ModelCompatibilityEstimator.memoryBudget(
          totalMemoryBytes: 10000,
          availableMemoryBytes: 4000,
        ),
        4000,
      );
      expect(
        ModelCompatibilityEstimator.memoryBudget(totalMemoryBytes: 10000),
        6000,
      );
      expect(ModelCompatibilityEstimator.memoryBudget(), isNull);
    });

    test('never plans to use almost all physical memory', () {
      expect(
        ModelCompatibilityEstimator.memoryBudget(
          totalMemoryBytes: 10000,
          availableMemoryBytes: 9900,
        ),
        8500,
      );
    });
  });

  group('compatibility rating', () {
    test('maps headroom ratios to descriptive states', () {
      expect(
        ModelCompatibilityEstimator.ratingFor(600, 1000),
        ModelCompatibilityRating.recommended,
      );
      expect(
        ModelCompatibilityEstimator.ratingFor(800, 1000),
        ModelCompatibilityRating.shouldRun,
      );
      expect(
        ModelCompatibilityEstimator.ratingFor(900, 1000),
        ModelCompatibilityRating.mayBeSlow,
      );
      expect(
        ModelCompatibilityEstimator.ratingFor(1200, 1000),
        ModelCompatibilityRating.memoryRisk,
      );
      expect(
        ModelCompatibilityEstimator.ratingFor(2000, 1000),
        ModelCompatibilityRating.notRecommended,
      );
    });

    test('reports no rating without device memory', () {
      expect(ModelCompatibilityEstimator.ratingFor(500, null), isNull);
      expect(ModelCompatibilityEstimator.ratingFor(0, 1000), isNull);
    });
  });

  group('memory estimate', () {
    test('sums weights, KV cache, projector and runtime overhead', () {
      const weights = 100 * 1024 * 1024;
      const projector = 50 * 1024 * 1024;
      final estimate = ModelCompatibilityEstimator.estimate(
        metadata: _metadata(fileSizeBytes: weights),
        contextTokens: 4096,
        fileSizeBytes: weights,
        projectorBytes: projector,
        totalMemoryBytes: 8 * 1024 * 1024 * 1024,
        availableMemoryBytes: 4 * 1024 * 1024 * 1024,
      );

      final expectedOverhead =
          ModelCompatibilityEstimator.runtimeOverheadBaseBytes +
          (weights * ModelCompatibilityEstimator.runtimeOverheadWeightsFraction)
              .round();

      expect(estimate.weightsBytes, weights);
      expect(
        estimate.kvCacheBytes,
        ModelCompatibilityEstimator.kvCacheBytes(_metadata(), 4096),
      );
      expect(estimate.runtimeOverheadBytes, expectedOverhead);
      expect(estimate.projectorBytes, projector);
      expect(
        estimate.requiredBytes,
        weights + estimate.kvCacheBytes + expectedOverhead + projector,
      );
      expect(estimate.budgetBytes, 4 * 1024 * 1024 * 1024);
      expect(estimate.rating, ModelCompatibilityRating.recommended);
      expect(estimate.explain(), contains(contains('Vision projector')));
    });

    test('falls back to metadata file size when no path is known', () {
      const weights = 33 * 1024 * 1024;
      final estimate = ModelCompatibilityEstimator.estimate(
        metadata: _metadata(fileSizeBytes: weights),
        contextTokens: 2048,
        fileSizeBytes: 0,
      );

      expect(estimate.weightsBytes, weights);
      expect(estimate.budgetBytes, isNull);
      expect(estimate.rating, isNull);
      expect(estimate.headroomRatio, isNull);
    });

    test('large models on small devices are flagged as a memory risk', () {
      final estimate = ModelCompatibilityEstimator.estimate(
        metadata: _metadata(contextLength: 32768),
        contextTokens: 32768,
        fileSizeBytes: 9 * 1024 * 1024 * 1024,
        totalMemoryBytes: 8 * 1024 * 1024 * 1024,
        availableMemoryBytes: 4 * 1024 * 1024 * 1024,
      );

      expect(estimate.rating, ModelCompatibilityRating.notRecommended);
      expect(estimate.headroomRatio, greaterThan(1.3));
    });

    test('formats bytes for the breakdown UI', () {
      expect(ModelMemoryEstimate.formatBytes(0), '0 B');
      expect(ModelMemoryEstimate.formatBytes(512), '512 B');
      expect(ModelMemoryEstimate.formatBytes(2048), '2.0 KB');
      expect(ModelMemoryEstimate.formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(ModelMemoryEstimate.formatBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
    });
  });
}
