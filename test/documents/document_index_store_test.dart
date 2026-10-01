import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/knowledge_collection.dart';

void main() {
  late Directory tempDir;
  late File file;
  late DocumentIndexStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_index_test');
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
      chunks: const [
        DocumentChunk(
          index: 0,
          text: 'hello world',
          startOffset: 0,
          endOffset: 11,
        ),
      ],
      charCount: 11,
      indexedAt: DateTime(2026, 3, 3),
      contentHash: 'abc123',
    );
  }

  group('DocumentIndexStore', () {
    test('reads an empty index when nothing has been stored', () {
      expect(store.read(), isNull);
      expect(store.exists, isFalse);
      expect(store.isReadOnly, isFalse);
    });

    test('round-trips collections, documents and chunking settings', () {
      final collection = KnowledgeCollection(
        id: 'col-notes',
        name: 'Notes',
        createdAt: DateTime(2026, 3, 1),
        updatedAt: DateTime(2026, 3, 2),
        chunking: const DocumentChunkingConfig(
          targetTokens: 200,
          overlapTokens: 20,
        ),
      );

      expect(
        store.save(
          DocumentIndexSnapshot(collections: [collection])
              .upsert(document(collectionId: 'col-notes'))
              .copyWith(activeCollectionId: 'col-notes'),
        ),
        isTrue,
      );

      final reloaded = DocumentIndexStore(file).read()!;
      expect(reloaded.documents, hasLength(1));
      expect(reloaded.documents.single.source.name, 'notes.txt');
      expect(reloaded.documents.single.chunks.single.text, 'hello world');
      expect(reloaded.documents.single.collectionId, 'col-notes');
      expect(reloaded.chunkCount, 1);
      expect(reloaded.activeCollectionId, 'col-notes');
      expect(reloaded.collectionById('col-notes')!.name, 'Notes');
      expect(reloaded.collectionById('col-notes')!.chunking.targetTokens, 200);
      expect(reloaded.collectionById('col-notes')!.chunking.overlapTokens, 20);
      expect(reloaded.collectionById(defaultCollectionId), isNotNull);
    });

    test('writes a versioned payload', () {
      store.save(DocumentIndexSnapshot.empty.upsert(document()));

      final payload =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(payload['version'], DocumentIndexStore.currentVersion);
      expect(payload['collections'], hasLength(1));
      expect(payload['activeCollectionId'], defaultCollectionId);
      expect(payload['documents'], hasLength(1));
      expect(payload.containsKey('chunking'), isFalse);
    });

    test('migrates a version 1 payload into the default collection', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'chunking': {
            'targetTokens': 120,
            'overlapTokens': 12,
            'maxChunkTokens': 240,
          },
          'documents': [document().toJson()..remove('collectionId')],
        }),
      );

      final migrated = store.read()!;
      expect(migrated.collections, hasLength(1));
      expect(migrated.collections.single.id, defaultCollectionId);
      expect(migrated.collections.single.chunking.targetTokens, 120);
      expect(migrated.activeCollectionId, defaultCollectionId);
      expect(migrated.documents.single.collectionId, defaultCollectionId);
      expect(migrated.documents.single.chunks, hasLength(1));

      // Reading alone never rewrites the stored file.
      final before =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(before['version'], 1);

      store.save(migrated);
      final after = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(after['version'], DocumentIndexStore.currentVersion);
      expect(after['collections'], hasLength(1));
      expect(after['documents'], hasLength(1));
    });

    test('repairs missing collections and orphaned documents', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': DocumentIndexStore.currentVersion,
          'activeCollectionId': 'col-missing',
          'collections': <Map<String, dynamic>>[],
          'documents': [document(collectionId: 'col-missing').toJson()],
        }),
      );

      final repaired = store.read()!;
      expect(repaired.collections.single.id, defaultCollectionId);
      expect(repaired.activeCollectionId, defaultCollectionId);
      expect(repaired.documents.single.collectionId, defaultCollectionId);
    });

    test('skips unusable stored collections and keeps the default one', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': DocumentIndexStore.currentVersion,
          'collections': [
            <String, dynamic>{},
            {'id': '', 'name': 'No id'},
            {'id': 'col-a', 'name': 'Alpha'},
            {'id': 'col-a', 'name': 'Duplicate'},
          ],
          'documents': <Map<String, dynamic>>[],
        }),
      );

      final stored = store.read()!;
      expect(stored.collections.map((collection) => collection.id), [
        defaultCollectionId,
        'col-a',
      ]);
      expect(stored.collectionById('col-a')!.name, 'Alpha');
    });

    test(
      'removes a collection with its documents but never the default one',
      () {
        final snapshot = DocumentIndexSnapshot(
          collections: [
            KnowledgeCollection.defaultCollection(now: DateTime(2026, 3, 1)),
            KnowledgeCollection.create(
              id: 'col-research',
              name: 'Research',
              now: DateTime(2026, 3, 2),
            ),
          ],
          activeCollectionId: 'col-research',
          documents: [document(collectionId: 'col-research')],
        );

        final removed = snapshot.removeCollection('col-research');
        expect(removed.collections, hasLength(1));
        expect(removed.collections.single.id, defaultCollectionId);
        expect(removed.documents, isEmpty);
        expect(removed.activeCollectionId, defaultCollectionId);

        // The always-present collection cannot be removed, so its documents are
        // never silently dropped.
        expect(
          snapshot.removeCollection(defaultCollectionId).documents,
          snapshot.documents,
        );
      },
    );

    test('upserts and removes documents by id', () {
      final snapshot = DocumentIndexSnapshot.empty
          .upsert(document())
          .upsert(document(id: 'doc-2', name: 'other.md'))
          .upsert(document());

      expect(snapshot.documents, hasLength(2));
      expect(snapshot.documentById('doc-2')!.source.name, 'other.md');
      expect(snapshot.remove('doc-1').documents, hasLength(1));
      expect(snapshot.remove('doc-1').documentById('doc-1'), isNull);
    });

    test('drops stored documents without chunks', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': DocumentIndexStore.currentVersion,
          'documents': [
            {
              'source': document().source.toJson(),
              'chunks': <Map<String, dynamic>>[],
              'charCount': 0,
              'indexedAt': DateTime(2026, 3, 3).toIso8601String(),
              'contentHash': 'empty',
            },
          ],
        }),
      );

      expect(store.read()!.documents, isEmpty);
    });

    test('recovers from an unreadable payload and preserves it', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('not json at all');

      expect(store.read(), isNull);
      store.save(DocumentIndexSnapshot.empty);

      final backups = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
      expect(backups.single.readAsStringSync(), 'not json at all');
    });

    test('treats a payload where no document parses as unreadable', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': DocumentIndexStore.currentVersion,
          'documents': [
            <String, dynamic>{},
            {'source': <String, dynamic>{}},
          ],
        }),
      );

      expect(store.read(), isNull);
      store.save(DocumentIndexSnapshot.empty);

      final backups = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
    });

    test('never downgrades a file written by a newer build', () {
      file.parent.createSync(recursive: true);
      const newer = '{"version": 99, "documents": []}';
      file.writeAsStringSync(newer);

      expect(store.read(), isNull);
      expect(store.isReadOnly, isTrue);
      expect(store.save(DocumentIndexSnapshot.empty), isFalse);
      expect(file.readAsStringSync(), newer);
    });

    test('deletes the stored index', () {
      store.save(DocumentIndexSnapshot.empty.upsert(document()));
      expect(store.exists, isTrue);

      expect(store.delete(), isTrue);
      expect(store.exists, isFalse);
      expect(store.read(), isNull);
    });
  });
}
