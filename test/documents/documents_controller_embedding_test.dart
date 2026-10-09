import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/inference/embedding_engine.dart';
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/features/documents/application/document_embedding_models.dart';
import 'package:pocket_llm/features/documents/application/document_library.dart';
import 'package:pocket_llm/features/documents/application/documents_controller.dart';
import 'package:pocket_llm/features/documents/data/document_extraction_service.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

/// Two axes: `docker` along x, `garden` along y.
class _FakeEmbeddingEngine implements EmbeddingEngine {
  bool _loaded = false;
  String? _modelId;

  @override
  bool get isLoaded => _loaded;

  @override
  String? get loadedModelId => _loaded ? _modelId : null;

  @override
  int? get dimensions => _loaded ? 2 : null;

  @override
  Future<void> load(EmbeddingLoadRequest request) async {
    _loaded = true;
    _modelId = request.modelId;
  }

  @override
  Future<void> unload() async {
    _loaded = false;
    _modelId = null;
  }

  @override
  Future<List<Float32List>> embed(
    List<String> texts, {
    CancelToken? cancelToken,
  }) async {
    return [for (final text in texts) Float32List.fromList(_vectorFor(text))];
  }

  List<double> _vectorFor(String text) {
    final lower = text.toLowerCase();
    final x = lower.contains('docker') ? 1.0 : 0.0;
    final y = lower.contains('garden') ? 1.0 : 0.0;
    if (x == 0 && y == 0) return const [0.5, 0.5];
    final total = x + y;
    return [x / total, y / total];
  }
}

void main() {
  const installedId = 'bge-small';
  const missingId = 'bge-large';

  late Directory tempDir;
  late File indexFile;
  late File modelFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_ctrl_embed');
    indexFile = File(p.join(tempDir.path, 'documents', 'index.json'));
    modelFile = File(p.join(tempDir.path, 'bge.gguf'));
    await modelFile.writeAsString('model bytes');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<File> writeFile(String name, String content) async {
    final file = File(p.join(tempDir.path, name));
    await file.writeAsString(content);
    return file;
  }

  LlmModel model(String id, String name, {required bool isDownloaded}) {
    return LlmModel(
      id: id,
      name: name,
      parameterSize: '33M',
      description: 'embeddings',
      capabilities: const [ModelCapability.embedding],
      isDownloaded: isDownloaded,
    );
  }

  DocumentLibrary buildLibrary() {
    final library = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: DocumentIndexStore(indexFile),
      embeddingEngine: _FakeEmbeddingEngine(),
    );
    library.load();
    return library;
  }

  ProviderContainer buildContainer({DocumentLibrary? library}) {
    final container = ProviderContainer(
      overrides: [
        documentLibraryProvider.overrideWith(
          (ref) async => library ?? buildLibrary(),
        ),
        documentEmbeddingModelsProvider.overrideWith(
          (ref) => DocumentEmbeddingModels(
            models: [
              model(installedId, 'BGE Small', isDownloaded: true),
              model(missingId, 'BGE Large', isDownloaded: false),
            ],
            resolvePath: (candidate) async =>
                candidate.id == installedId ? modelFile.path : null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<DocumentsNotifier> loaded(ProviderContainer container) async {
    final notifier = container.read(documentsProvider.notifier);
    for (var attempt = 0; attempt < 50; attempt++) {
      if (container.read(documentsProvider).isReady) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(documentsProvider).isReady, isTrue);
    return notifier;
  }

  DocumentsState state(ProviderContainer container) =>
      container.read(documentsProvider);

  test('publishes the embedding models, installed first', () async {
    final container = buildContainer();
    await loaded(container);

    final options = state(container).embeddingModels;

    expect(options.map((option) => option.id).toList(), [
      installedId,
      missingId,
    ]);
    expect(options.first.isInstalled, isTrue);
    expect(options.last.isInstalled, isFalse);
    expect(state(container).installedEmbeddingModels, hasLength(1));
  });

  test('refuses a model that is not installed, with somewhere to go', () async {
    final container = buildContainer();
    final notifier = await loaded(container);
    await notifier.addDocument((await writeFile('a.txt', 'docker notes')).path);

    await notifier.setCollectionEmbeddingModel(
      state(container).activeCollectionId,
      missingId,
    );

    final current = state(container);
    expect(
      current.activeEmbeddingModelId,
      isNull,
      reason: 'A collection must not point at a model it cannot load.',
    );
    expect(current.errorMessage, contains('not installed'));
    expect(current.errorMessage, contains('Models screen'));
  });

  test('switching to embeddings then re-indexing builds the vectors', () async {
    final container = buildContainer();
    final notifier = await loaded(container);
    final file = await writeFile('a.txt', 'docker notes about images');
    await notifier.addDocument(file.path);

    expect(state(container).vectorCount, 0);

    await notifier.setCollectionEmbeddingModel(
      state(container).activeCollectionId,
      installedId,
    );

    final switched = state(container);
    expect(switched.activeEmbeddingModelId, installedId);
    expect(switched.statusMessage, contains('embeddings'));
    expect(
      switched.vectorCount,
      0,
      reason: 'Switching does not re-embed on its own.',
    );
    expect(
      switched.documents.single.embeddingModelId,
      isNull,
      reason: 'The stored document still describes the index that exists.',
    );

    await notifier.refreshOutdated();

    final reindexed = state(container);
    expect(reindexed.vectorCount, greaterThan(0));
    expect(reindexed.vectorCount, reindexed.chunkCount);
    expect(
      reindexed.documents.single.embeddingModelId,
      installedId,
      reason: 'The document records the model that built its vectors.',
    );
  });

  test('the preview finds chunks by meaning once vectors exist', () async {
    final container = buildContainer();
    final notifier = await loaded(container);
    await notifier.addDocument(
      (await writeFile('a.txt', 'The docker engine keeps images local.')).path,
    );
    await notifier.setCollectionEmbeddingModel(
      state(container).activeCollectionId,
      installedId,
    );
    await notifier.refreshOutdated();

    // No word of this query appears in the document.
    await notifier.search('containers');

    final hits = state(container).searchResults;
    expect(hits, isNotEmpty);
    expect(hits.first.documentName, 'a.txt');
  });

  test('switching back to terms stops using the vectors', () async {
    final container = buildContainer();
    final notifier = await loaded(container);
    await notifier.addDocument(
      (await writeFile('a.txt', 'The docker engine keeps images local.')).path,
    );
    final collectionId = state(container).activeCollectionId;
    await notifier.setCollectionEmbeddingModel(collectionId, installedId);
    await notifier.refreshOutdated();
    expect(state(container).vectorCount, greaterThan(0));

    await notifier.setCollectionEmbeddingModel(collectionId, null);

    final current = state(container);
    expect(current.activeEmbeddingModelId, isNull);
    expect(
      current.vectorCount,
      0,
      reason: 'A collection searching by terms is not answered by vectors.',
    );
    expect(current.statusMessage, contains('by terms'));
  });
}
