import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/documents/application/document_embedding_models.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

void main() {
  late Directory tempDir;
  late String modelFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_embed_models');
    modelFile = p.join(tempDir.path, 'bge.gguf');
    await File(modelFile).writeAsString('not really a gguf');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  GgufMetadata metadata({
    String architecture = 'bert',
    int? embeddingLength = 384,
    int? contextLength = 512,
  }) {
    return GgufMetadata(
      architecture: architecture,
      name: 'bge',
      version: 3,
      kvCount: 1,
      tensorCount: 1,
      fileSizeBytes: 100,
      parameterCount: 33,
      quantization: 'Q8_0',
      embeddingLength: embeddingLength,
      contextLength: contextLength,
    );
  }

  LlmModel chatModel() => const LlmModel(
    id: 'qwen-2.5-0.5b',
    name: 'Qwen',
    parameterSize: '0.5B',
    description: 'chat',
  );

  LlmModel embeddingModel({
    String id = 'bge-small',
    bool isDownloaded = true,
    GgufMetadata? gguf,
    bool declaredCapability = true,
    String? externalPath,
  }) {
    return LlmModel(
      id: id,
      name: 'BGE Small',
      parameterSize: '33M',
      description: 'embeddings',
      capabilities: declaredCapability
          ? const [ModelCapability.embedding]
          : const [],
      isDownloaded: isDownloaded,
      localFileName: p.basename(modelFile),
      externalPath: externalPath,
      ggufMetadata: gguf ?? metadata(),
    );
  }

  DocumentEmbeddingModels resolverFor(
    List<LlmModel> models, {
    Map<String, String?>? paths,
  }) {
    return DocumentEmbeddingModels(
      models: models,
      resolvePath: (model) async => paths != null ? paths[model.id] : modelFile,
    );
  }

  group('what counts as an embedding model', () {
    test('a declared capability is enough', () {
      final resolver = resolverFor([
        chatModel(),
        embeddingModel(
          declaredCapability: true,
          gguf: metadata(architecture: 'qwen2'),
        ),
      ]);

      expect(resolver.embeddingModels.map((model) => model.id).toList(), [
        'bge-small',
      ]);
    });

    test('an imported encoder is recognised from its own metadata', () {
      final resolver = resolverFor([
        chatModel(),
        embeddingModel(declaredCapability: false, gguf: metadata()),
      ]);

      expect(
        resolver.embeddingModels.map((model) => model.id).toList(),
        ['bge-small'],
        reason:
            'A BERT file cannot generate text, so it must not be offered as a '
            'chat model just because nothing declared it.',
      );
    });

    test('a chat model is not offered for a collection', () {
      final resolver = resolverFor([chatModel(), embeddingModel()]);

      expect(
        resolver.embeddingModels.any((model) => model.isEmbeddingModel),
        isTrue,
      );
      expect(resolver.embeddingModels.length, 1);
    });

    test('only installed ones are listed as installed', () {
      final resolver = resolverFor([
        embeddingModel(id: 'installed', isDownloaded: true),
        embeddingModel(id: 'missing', isDownloaded: false),
      ]);

      expect(
        resolver.installedEmbeddingModels.map((model) => model.id).toList(),
        ['installed'],
      );
      expect(resolver.isInstalled('installed'), isTrue);
      expect(resolver.isInstalled('missing'), isFalse);
      expect(resolver.isInstalled(null), isFalse);
      expect(resolver.isInstalled('not-in-the-catalog'), isFalse);
    });
  });

  group('resolving a collection model', () {
    test('resolves the width and window the pipeline should use', () async {
      final resolver = resolverFor([embeddingModel()]);

      final ref = await resolver.resolve('bge-small');

      expect(ref, isNotNull);
      expect(ref!.id, 'bge-small');
      expect(ref.path, modelFile);
      expect(ref.dimensions, 384);
      expect(ref.maxInputTokens, 512);
      expect(ref.batchSize, 2);
    });

    test(
      'a wider window is capped, and the batch shrinks to pay for it',
      () async {
        final resolver = resolverFor([
          embeddingModel(
            gguf: metadata(contextLength: 8192, embeddingLength: 768),
          ),
        ]);

        final ref = await resolver.resolve('bge-small');

        expect(
          ref!.maxInputTokens,
          DocumentEmbeddingModels.maxWindowTokens,
          reason:
              'The KV cache a load costs is window × batch, so an 8k window '
              'cannot be taken literally.',
        );
        expect(ref.batchSize, 1);
      },
    );

    test('a model without a declared window uses the default', () async {
      final resolver = resolverFor([
        embeddingModel(
          gguf: metadata(contextLength: null, embeddingLength: null),
        ),
      ]);

      final ref = await resolver.resolve('bge-small');

      expect(ref!.maxInputTokens, 512);
      expect(ref.dimensions, isNull);
    });

    test('an unknown id resolves to null instead of guessing', () async {
      final resolver = resolverFor([embeddingModel()]);

      expect(await resolver.resolve(null), isNull);
      expect(await resolver.resolve(''), isNull);
      expect(await resolver.resolve('nope'), isNull);
    });

    test('a model whose file is gone resolves to null', () async {
      final resolver = resolverFor(
        [embeddingModel()],
        paths: {'bge-small': p.join(tempDir.path, 'deleted.gguf')},
      );

      expect(await resolver.resolve('bge-small'), isNull);
    });

    test('a model with no path at all resolves to null', () async {
      final resolver = resolverFor(
        [embeddingModel()],
        paths: {'bge-small': null},
      );

      expect(await resolver.resolve('bge-small'), isNull);
    });
  });
}
