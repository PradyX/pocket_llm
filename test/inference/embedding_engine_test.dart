import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/inference/embedding_engine.dart';
import 'package:pocket_llm/core/services/local_embedding_service.dart';
import 'package:pocket_llm/core/services/service_providers.dart';

void main() {
  group('EmbeddingEngine contract', () {
    test('the local service is honest before a model loads', () {
      final EmbeddingEngine engine = LocalEmbeddingService();

      expect(engine.isLoaded, isFalse);
      expect(engine.loadedModelId, isNull);
      expect(
        engine.dimensions,
        isNull,
        reason: 'A width comes from a model that answered, not from a guess.',
      );
    });

    test(
      'embedding without a model fails instead of returning vectors',
      () async {
        final engine = LocalEmbeddingService();

        await expectLater(
          engine.embed(const ['hello']),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('No embedding model is loaded'),
            ),
          ),
        );
      },
    );

    test('releasing an idle engine is safe', () async {
      final engine = LocalEmbeddingService();

      await engine.unload();
      await engine.unload();

      expect(engine.isLoaded, isFalse);
    });

    test('a batch is sized for every sequence it may carry', () {
      // One sequence per text, each using a whole window, and one batched
      // decode holding all of them: sizing nBatch for a single text is rejected
      // by the runtime the moment two chunks arrive in one batch.
      final plan = LocalEmbeddingService.planFor(
        maxInputTokens: 512,
        batchSize: 4,
      );

      expect(plan.window, 512);
      expect(plan.sequences, 4);
      expect(plan.batchTokens, 512 * 4);
      expect(
        plan.batchTokens,
        greaterThan(plan.window),
        reason: 'A batch holds more than the window of one sequence.',
      );
    });

    test('a nonsense window or batch is clamped, not trusted', () {
      final tiny = LocalEmbeddingService.planFor(
        maxInputTokens: 0,
        batchSize: 0,
      );
      expect(tiny.window, greaterThanOrEqualTo(32));
      expect(tiny.sequences, 1);
      expect(tiny.batchTokens, tiny.window);

      final negative = LocalEmbeddingService.planFor(
        maxInputTokens: -100,
        batchSize: -3,
      );
      expect(negative.window, greaterThanOrEqualTo(32));
      expect(negative.sequences, 1);
      expect(negative.batchTokens, greaterThan(0));
    });

    test('the engine is one shared instance behind the provider', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final engine = container.read(embeddingEngineProvider);
      expect(engine, isA<LocalEmbeddingService>());
      expect(
        container.read(embeddingEngineProvider),
        same(engine),
        reason:
            'One embedding model resident means one engine, not one per '
            'caller.',
      );
      expect(
        engine,
        isNot(same(container.read(inferenceEngineProvider))),
        reason:
            'Chat and embeddings cannot share a native context, so they must '
            'not share an engine.',
      );
    });
  });
}
