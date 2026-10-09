import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/inference/embedding_engine.dart';
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/features/documents/application/document_library.dart';
import 'package:pocket_llm/features/documents/data/document_extraction_service.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/domain/document_extraction.dart';
import 'package:pocket_llm/features/documents/domain/document_vectors.dart';
import 'package:pocket_llm/features/documents/domain/embedding_model_ref.dart';

/// An embedding engine with two axes, so a test can state which document a
/// question is close to without running a model.
class _FakeEmbeddingEngine implements EmbeddingEngine {
  final int vectorDimensions = 2;
  bool failOnEmbed = false;

  EmbeddingLoadRequest? lastLoad;
  int loadCount = 0;
  int embedCalls = 0;
  final List<String> embeddedTexts = [];

  bool _loaded = false;
  String? _modelId;

  @override
  bool get isLoaded => _loaded;

  @override
  String? get loadedModelId => _loaded ? _modelId : null;

  @override
  int? get dimensions => _loaded ? vectorDimensions : null;

  @override
  Future<void> load(EmbeddingLoadRequest request) async {
    lastLoad = request;
    loadCount++;
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
    if (failOnEmbed) throw Exception('the model refused to answer');
    embedCalls++;
    cancelToken?.throwIfCancelled();
    embeddedTexts.addAll(texts);
    return [for (final text in texts) _vectorFor(text)];
  }

  /// `docker` points along x, `garden` along y, everything else in between.
  Float32List _vectorFor(String text) {
    final lower = text.toLowerCase();
    final x = lower.contains('docker') ? 1.0 : 0.0;
    final y = lower.contains('garden') ? 1.0 : 0.0;
    if (x == 0 && y == 0) return Float32List.fromList([0.5, 0.5]);
    final length = x + y;
    return Float32List.fromList([x / length, y / length]);
  }
}

void main() {
  const modelId = 'fake-embed';
  const model = EmbeddingModelRef(id: modelId, path: '/models/fake.gguf');

  late Directory tempDir;
  late File indexFile;
  late _FakeEmbeddingEngine engine;
  late DocumentLibrary library;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_embed_test');
    indexFile = File(p.join(tempDir.path, 'documents', 'index.json'));
    engine = _FakeEmbeddingEngine();
    library = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: DocumentIndexStore(indexFile),
      embeddingEngine: engine,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeFile(String name, String content) async {
    final file = File(p.join(tempDir.path, name));
    await file.writeAsString(content);
    return file;
  }

  /// Text long enough to be sliced into more than one chunk: the chunker packs
  /// to a ~300-token target, and a one-chunk document would not prove that every
  /// chunk gets its own vector.
  String longText(String keyword) {
    final paragraph =
        'This section is about $keyword. '
        'It keeps every image local and works with no network at all. ';
    return List.generate(
      10,
      (index) => 'Section $index\n\n${paragraph * 6}',
    ).join('\n\n');
  }

  /// A collection that answers from embeddings.
  String embeddedCollection() {
    final collection = library.createCollection(
      'Work',
      embeddingModelId: modelId,
    )!;
    return collection.id;
  }

  Future<DocumentIngestResult> ingest(
    File file, {
    String? collectionId,
    CancelToken? cancelToken,
  }) {
    return library.addDocument(
      path: file.path,
      collectionId: collectionId,
      embeddingModel: model,
      cancelToken: cancelToken,
    );
  }

  group('indexing with an embedding model', () {
    test('stores a vector per chunk and finds them by meaning', () async {
      final collectionId = embeddedCollection();
      final file = await writeFile('notes.txt', longText('docker'));

      final result = await ingest(file, collectionId: collectionId);

      expect(result.document.embeddingModelId, modelId);
      expect(result.document.embeddingDimensions, 2);
      expect(result.document.chunkCount, greaterThan(1));
      expect(
        library.vectorsFor(result.document.id)!.count,
        result.document.chunkCount,
        reason: 'Every chunk needs a vector, or a question can miss one.',
      );
      expect(library.vectorCountIn(collectionId), result.document.chunkCount);

      // No word of the question appears in the file, so only the vector
      // channel can answer it.
      final hits = library.search(
        'containers',
        collectionId: collectionId,
        queryVector: Float32List.fromList([1, 0]),
      );

      expect(hits, isNotEmpty);
      expect(hits.first.documentId, result.document.id);
    });

    test('loads the model once and reuses it for later documents', () async {
      final collectionId = embeddedCollection();
      await ingest(
        await writeFile('a.txt', 'docker notes'),
        collectionId: collectionId,
      );
      await ingest(
        await writeFile('b.txt', 'docker more notes'),
        collectionId: collectionId,
      );

      expect(engine.loadCount, 1);
      expect(engine.lastLoad?.modelId, modelId);
      expect(engine.lastLoad?.modelPath, '/models/fake.gguf');
      expect(library.loadedEmbeddingModelId, modelId);

      await library.releaseEmbeddingModel();

      expect(library.loadedEmbeddingModelId, isNull);
      expect(engine.isLoaded, isFalse);
    });

    test('the vectors survive a reload from disk', () async {
      final collectionId = embeddedCollection();
      final file = await writeFile('notes.txt', 'docker notes about images');

      final result = await ingest(file, collectionId: collectionId);

      final reloaded = DocumentLibrary(
        extractor: DocumentExtractionService(),
        store: DocumentIndexStore(indexFile),
        embeddingEngine: _FakeEmbeddingEngine(),
      )..load();

      final stored = reloaded.vectorsFor(result.document.id);
      expect(stored, isNotNull);
      expect(stored!.dimensions, 2);
      expect(stored.count, result.document.chunkCount);
      expect(reloaded.vectorCountIn(collectionId), result.document.chunkCount);
      expect(
        reloaded
            .search(
              'containers',
              collectionId: collectionId,
              queryVector: Float32List.fromList([1, 0]),
            )
            .first
            .documentId,
        result.document.id,
      );
    });

    test(
      'refuses to index when the collection model is not installed',
      () async {
        final collectionId = embeddedCollection();
        final file = await writeFile('notes.txt', 'docker notes');

        await expectLater(
          library.addDocument(path: file.path, collectionId: collectionId),
          throwsA(
            isA<DocumentExtractionException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('Work'),
                contains('embedding model is not installed'),
              ),
            ),
          ),
        );

        expect(library.documents, isEmpty);
        expect(library.vectorsFor('missing'), isNull);
      },
    );

    test('a failed embedding stores nothing at all', () async {
      final collectionId = embeddedCollection();
      engine.failOnEmbed = true;
      final file = await writeFile('notes.txt', 'docker notes');

      await expectLater(
        ingest(file, collectionId: collectionId),
        throwsA(isA<DocumentExtractionException>()),
      );

      expect(
        library.documents,
        isEmpty,
        reason:
            'A half-embedded document would be answered from partial search '
            'results.',
      );
      expect(library.vectorCountIn(collectionId), 0);
    });

    test('cancelling during embedding stores nothing', () async {
      final collectionId = embeddedCollection();
      final token = CancelToken();
      final file = await writeFile('notes.txt', 'docker notes');

      final pending = library.addDocument(
        path: file.path,
        collectionId: collectionId,
        embeddingModel: model,
        cancelToken: token,
        onProgress: (progress) {
          if (progress.stage == DocumentIngestStage.embedding) token.cancel();
        },
      );

      await expectLater(pending, throwsA(isA<OperationCancelledException>()));
      expect(library.documents, isEmpty);
      expect(library.vectorCountIn(collectionId), 0);
    });

    test('a lexical collection stores no vectors', () async {
      final collectionId = embeddedCollection();
      final lexicalFile = await writeFile('lexical.txt', 'docker notes');

      // Indexed into the always-present collection, which is lexical.
      await library.addDocument(path: lexicalFile.path);

      expect(library.vectorCountIn(collectionId), 0);
      expect(library.vectorsFor(library.documents.single.id), isNull);
    });
  });

  group('changing a collection backend', () {
    test(
      'marks indexed documents stale instead of re-embedding silently',
      () async {
        final file = await writeFile('notes.txt', 'docker notes');
        await library.addDocument(path: file.path);
        final documentId = library.documents.single.id;
        final collectionId = library.activeCollectionId;

        expect(
          library.setCollectionEmbeddingModel(collectionId, modelId),
          isTrue,
        );

        final document = library.documentById(documentId)!;
        expect(library.needsRefresh(document), isTrue);
        expect(library.vectorCountIn(collectionId), 0);

        // Re-indexing with the model that the collection now pins embeds it.
        await library.refreshDocument(documentId, embeddingModel: model);

        expect(library.vectorCountIn(collectionId), greaterThan(0));
        expect(
          library.needsRefresh(library.documentById(documentId)!),
          isFalse,
        );
      },
    );

    test('switching back to lexical search rebuilds without vectors', () async {
      final collectionId = embeddedCollection();
      final file = await writeFile('notes.txt', 'docker notes');
      final result = await ingest(file, collectionId: collectionId);
      expect(library.vectorCountIn(collectionId), greaterThan(0));

      expect(library.setCollectionEmbeddingModel(collectionId, null), isTrue);
      expect(
        library.vectorCountIn(collectionId),
        0,
        reason: 'A lexical collection must not be answered by vectors.',
      );

      await library.refreshDocument(result.document.id);

      expect(library.vectorsFor(result.document.id), isNull);
      expect(
        library.needsRefresh(library.documentById(result.document.id)!),
        isFalse,
      );
    });

    test('a document whose vectors were lost is reported stale', () async {
      final collectionId = embeddedCollection();
      final file = await writeFile('notes.txt', 'docker notes about images');
      final result = await ingest(file, collectionId: collectionId);

      // A stored index whose vectors went missing: the file and the chunking
      // are fine, but there is nothing to answer a question with.
      final store = DocumentIndexStore(indexFile);
      final snapshot = store.read()!;
      store.save(snapshot.withVectors(result.document.id, null));

      final reloaded = DocumentLibrary(
        extractor: DocumentExtractionService(),
        store: DocumentIndexStore(indexFile),
        embeddingEngine: engine,
      )..load();

      final document = reloaded.documentById(result.document.id)!;
      expect(reloaded.needsRefresh(document), isTrue);

      await reloaded.refreshDocument(result.document.id, embeddingModel: model);

      expect(
        reloaded.needsRefresh(reloaded.documentById(result.document.id)!),
        isFalse,
      );
      expect(reloaded.vectorCountIn(collectionId), greaterThan(0));
    });

    test('a partial vector set is repaired on refresh', () async {
      final collectionId = embeddedCollection();
      final file = await writeFile('notes.txt', longText('docker'));
      final result = await ingest(file, collectionId: collectionId);
      expect(result.document.chunkCount, greaterThan(1));

      final store = DocumentIndexStore(indexFile);
      final snapshot = store.read()!;
      final stored = snapshot.vectorsFor(result.document.id)!;
      final firstEntry = stored.chunkVectors.entries.first;
      store.save(
        snapshot.withVectors(
          result.document.id,
          // Keep one vector only, as a file left behind by an interrupted run
          // would: too few for the chunks that are there.
          DocumentVectors(
            dimensions: stored.dimensions,
            chunkVectors: {firstEntry.key: firstEntry.value},
          ),
        ),
      );

      final reloaded = DocumentLibrary(
        extractor: DocumentExtractionService(),
        store: DocumentIndexStore(indexFile),
        embeddingEngine: engine,
      )..load();

      expect(
        reloaded.needsRefresh(reloaded.documentById(result.document.id)!),
        isTrue,
      );

      await reloaded.refreshDocument(result.document.id, embeddingModel: model);

      expect(
        reloaded.vectorsFor(result.document.id)!.count,
        reloaded.documentById(result.document.id)!.chunkCount,
      );
      expect(
        reloaded.needsRefresh(reloaded.documentById(result.document.id)!),
        isFalse,
      );
      expect(reloaded.vectorCountIn(collectionId), greaterThan(1));
    });
  });

  group('question embedding', () {
    test('returns a vector for the collection model', () async {
      final vector = await library.embedQuery('docker', model: model);

      expect(vector, isNotNull);
      expect(vector!.length, 2);
      expect(library.loadedEmbeddingModelId, modelId);
    });

    test('returns null instead of failing the turn', () async {
      engine.failOnEmbed = true;

      expect(await library.embedQuery('docker', model: model), isNull);
    });

    test('returns null when there is no embedding engine at all', () async {
      final withoutEngine = DocumentLibrary(
        extractor: DocumentExtractionService(),
        store: DocumentIndexStore(
          File(p.join(tempDir.path, 'other', 'index.json')),
        ),
      );

      expect(await withoutEngine.embedQuery('docker', model: model), isNull);
    });
  });
}
