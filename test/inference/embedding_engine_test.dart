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
