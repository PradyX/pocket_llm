import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_vectors.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';

void main() {
  late Directory tempDir;
  late File file;
  late DocumentIndexStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_vectors_test');
    file = File(p.join(tempDir.path, 'documents', 'index.json'));
    store = DocumentIndexStore(file);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  IndexedDocument document({
    String id = 'doc-1',
    String name = 'notes.txt',
    String collectionId = defaultCollectionId,
    int chunkCount = 1,
  }) {
    return IndexedDocument(
      source: DocumentSource.fromFile(
        id: id,
        path: '/tmp/$name',
        name: name,
        sizeBytes: 40,
        modifiedAt: DateTime(2026, 3, 1),
        addedAt: DateTime(2026, 3, 2),
      ),
      collectionId: collectionId,
      chunks: [
        for (var index = 0; index < chunkCount; index++)
          DocumentChunk(
            index: index,
            text: 'chunk $index text',
            startOffset: index * 10,
            endOffset: index * 10 + 14,
          ),
      ],
      charCount: 14 * chunkCount,
      indexedAt: DateTime(2026, 3, 3),
      contentHash: 'hash-$id',
      embeddingModelId: 'bge-small-en-v1.5',
      embeddingDimensions: 3,
    );
  }

  DocumentVectors storedVectors(
    Map<int, List<double>> byChunk, {
    int dimensions = 3,
  }) {
    return DocumentVectors(
      dimensions: dimensions,
      chunkVectors: {
        for (final entry in byChunk.entries)
          entry.key: Float32List.fromList(entry.value),
      },
    );
  }

  group('vector persistence', () {
    test('round-trips vectors per document', () {
      final snapshot = DocumentIndexSnapshot(
        collections: [KnowledgeCollection.defaultCollection()],
        documents: [document(chunkCount: 2)],
        vectors: {
          'doc-1': storedVectors({
            0: [1, 0, 0],
            1: [0, 1, 0],
          }),
        },
      );

      expect(store.save(snapshot), isTrue);

      final restored = store.read()!;
      final stored = restored.vectorsFor('doc-1')!;
      expect(restored.vectorCount, 2);
      expect(stored.dimensions, 3);
      expect(stored.count, 2);
      expect(stored.vectorFor(1)!.toList(), [0.0, 1.0, 0.0]);
    });

    test('writes the current schema version and no vectors key when empty', () {
      store.save(
        DocumentIndexSnapshot(
          collections: [KnowledgeCollection.defaultCollection()],
          documents: [document()],
        ),
      );

      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(raw['version'], DocumentIndexStore.currentVersion);
      expect(
        raw.containsKey('vectors'),
        isFalse,
        reason: 'A lexical index stays exactly the size it was.',
      );
    });

    test('a version 2 file reads as a lexical index', () {
      final legacy = {
        'version': 2,
        'activeCollectionId': defaultCollectionId,
        'collections': [KnowledgeCollection.defaultCollection().toJson()],
        'documents': [document().toJson()],
      };
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(legacy));

      final restored = store.read()!;

      expect(restored.documents, hasLength(1));
      expect(restored.vectors, isEmpty);
      expect(restored.vectorCount, 0);
    });

    test('a vector entry without a document is dropped', () {
      final snapshot = DocumentIndexSnapshot(
        collections: [KnowledgeCollection.defaultCollection()],
        documents: [document()],
        vectors: {
          'doc-1': storedVectors({
            0: [1, 0, 0],
          }),
          'doc-gone': storedVectors({
            0: [1, 0, 0],
          }),
        },
      );

      store.save(snapshot);

      final restored = store.read()!;
      expect(restored.vectorsFor('doc-1'), isNotNull);
      expect(restored.vectorsFor('doc-gone'), isNull);
    });

    test('vectors for chunks the document no longer has are dropped', () {
      final snapshot = DocumentIndexSnapshot(
        collections: [KnowledgeCollection.defaultCollection()],
        documents: [document(chunkCount: 1)],
        vectors: {
          'doc-1': storedVectors({
            0: [1, 0, 0],
            7: [0, 0, 1],
          }),
        },
      );

      store.save(snapshot);

      final stored = store.read()!.vectorsFor('doc-1')!;
      expect(stored.count, 1);
      expect(stored.vectorFor(7), isNull);
    });

    test('a corrupt vectors payload does not cost the documents', () {
      store.save(
        DocumentIndexSnapshot(
          collections: [KnowledgeCollection.defaultCollection()],
          documents: [document()],
          vectors: {
            'doc-1': storedVectors({
              0: [1, 0, 0],
            }),
          },
        ),
      );

      // Break only the vectors half of the file.
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      raw['vectors'] = 'not a map';
      file.writeAsStringSync(jsonEncode(raw));

      final restored = store.read()!;

      expect(restored.documents, hasLength(1));
      expect(restored.vectorCount, 0);
      expect(store.isReadOnly, isFalse);
    });
    test('an empty document list still reads as a usable, empty index', () {
      store.save(
        DocumentIndexSnapshot(
          collections: [KnowledgeCollection.defaultCollection()],
          documents: [document()],
          vectors: {
            'doc-1': storedVectors({
              0: [1, 0, 0],
            }),
          },
        ),
      );
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      raw['documents'] = [];
      file.writeAsStringSync(jsonEncode(raw));

      final restored = store.read();

      // `documents: []` is still a usable payload, so it is not treated as
      // corruption: an empty index is a valid index, and the vectors that came
      // with it are dropped because no document is left to own them.
      expect(restored, isNotNull);
      expect(restored!.documents, isEmpty);
      expect(restored.vectorCount, 0);
    });
  });

  group('vector removal', () {
    test('removing a document removes its vectors', () {
      final snapshot = DocumentIndexSnapshot(
        collections: [KnowledgeCollection.defaultCollection()],
        documents: [document()],
        vectors: {
          'doc-1': storedVectors({
            0: [1, 0, 0],
          }),
        },
      );

      final without = snapshot.remove('doc-1');

      expect(without.documents, isEmpty);
      expect(without.vectors, isEmpty);
      expect(snapshot.vectorCount, 1, reason: 'The original is untouched.');
    });

    test('removing a collection removes the vectors of its documents', () {
      final snapshot = DocumentIndexSnapshot(
        collections: [
          KnowledgeCollection.defaultCollection(),
          KnowledgeCollection(
            id: 'col-work',
            name: 'Work',
            createdAt: DateTime(2026, 3, 1),
            updatedAt: DateTime(2026, 3, 1),
          ),
        ],
        documents: [
          document(),
          document(id: 'doc-2', name: 'work.txt', collectionId: 'col-work'),
        ],
        vectors: {
          'doc-1': storedVectors({
            0: [1, 0, 0],
          }),
          'doc-2': storedVectors({
            0: [0, 1, 0],
          }),
        },
      );

      final without = snapshot.removeCollection('col-work');

      expect(without.vectorsFor('doc-1'), isNotNull);
      expect(without.vectorsFor('doc-2'), isNull);

      expect(
        snapshot.removeCollection(KnowledgeCollection.defaultId).vectorCount,
        2,
        reason: 'The always-present collection cannot be removed.',
      );
    });

    test('storing null vectors forgets a document\'s vectors', () {
      final snapshot = DocumentIndexSnapshot(
        collections: [KnowledgeCollection.defaultCollection()],
        documents: [document()],
        vectors: {
          'doc-1': storedVectors({
            0: [1, 0, 0],
          }),
        },
      );

      expect(snapshot.withVectors('doc-1', null).vectorsFor('doc-1'), isNull);
      expect(snapshot.vectorCount, 1);
    });

    test('upserting a document keeps its vectors until they are replaced', () {
      final snapshot = DocumentIndexSnapshot(
        collections: [KnowledgeCollection.defaultCollection()],
        documents: [document()],
        vectors: {
          'doc-1': storedVectors({
            0: [1, 0, 0],
          }),
        },
      );

      final replaced = snapshot.upsert(document(chunkCount: 3));

      expect(
        replaced.vectorsFor('doc-1'),
        isNotNull,
        reason:
            'A metadata-only refresh keeps the vectors the chunks still have; '
            'the library decides when they are rebuilt.',
      );
      expect(replaced.vectorsFor('doc-1')!.count, 1);
    });
  });
}
