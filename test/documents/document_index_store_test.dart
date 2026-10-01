import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';

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

  IndexedDocument document({String id = 'doc-1', String name = 'notes.txt'}) {
    return IndexedDocument(
      source: DocumentSource.fromFile(
        id: id,
        path: '/tmp/$name',
        name: name,
        sizeBytes: 40,
        modifiedAt: DateTime(2026, 3, 1),
        addedAt: DateTime(2026, 3, 2),
      ),
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

    test('round-trips documents and chunking settings', () {
      expect(
        store.save(
          const DocumentIndexSnapshot(
            chunking: DocumentChunkingConfig(
              targetTokens: 200,
              overlapTokens: 20,
            ),
          ).upsert(document()),
        ),
        isTrue,
      );

      final reloaded = DocumentIndexStore(file).read()!;
      expect(reloaded.documents, hasLength(1));
      expect(reloaded.documents.single.source.name, 'notes.txt');
      expect(reloaded.documents.single.chunks.single.text, 'hello world');
      expect(reloaded.chunkCount, 1);
      expect(reloaded.chunking.targetTokens, 200);
      expect(reloaded.chunking.overlapTokens, 20);
    });

    test('writes a versioned payload', () {
      store.save(DocumentIndexSnapshot.empty.upsert(document()));

      final payload =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(payload['version'], DocumentIndexStore.currentVersion);
      expect(payload['chunking'], isA<Map<String, dynamic>>());
      expect(payload['documents'], hasLength(1));
    });

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
