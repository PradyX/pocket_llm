import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/utils/cancel_token.dart';
import 'package:pocket_llm/features/documents/application/document_library.dart';
import 'package:pocket_llm/features/documents/data/document_extraction_service.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_extraction.dart';

void main() {
  late Directory tempDir;
  late File indexFile;
  late DocumentIndexStore store;
  late DocumentLibrary library;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_library_test');
    indexFile = File(p.join(tempDir.path, 'index', 'index.json'));
    store = DocumentIndexStore(indexFile);
    library = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: store,
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

  test('ingests a text file and reloads it from disk', () async {
    final file = await writeFile(
      'notes.txt',
      'The docker engine keeps every image local.\n\n'
          'Unrelated notes about styling buttons.',
    );

    final result = await library.addDocument(path: file.path);

    expect(result.reusedIndex, isFalse);
    expect(result.summaryLabel, contains('indexed'));
    expect(result.document.source.name, 'notes.txt');
    expect(library.documents, hasLength(1));
    expect(library.chunkCount, greaterThan(0));

    final reloaded = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: DocumentIndexStore(indexFile),
    )..load();

    expect(reloaded.documents, hasLength(1));
    expect(reloaded.chunkCount, library.chunkCount);
    expect(reloaded.search('docker'), hasLength(1));
    expect(reloaded.search('docker').single.documentName, 'notes.txt');
  });

  test('keeps the original file untouched', () async {
    const content = 'Local files stay where they are.';
    final file = await writeFile('notes.txt', content);

    await library.addDocument(path: file.path);

    expect(file.readAsStringSync(), content);
    expect(DocumentIndexStore(indexFile).read()!.documents, hasLength(1));
  });

  test('reuses the stored index while the file looks unchanged', () async {
    const original = 'alpha beta gamma delta epsilon zeta value';
    final file = await writeFile('notes.txt', original);
    final modifiedAt = file.lastModifiedSync();

    await library.addDocument(path: file.path);

    // Same size, same timestamp, different bytes: the library must trust its
    // stored index rather than re-reading the file.
    await file.writeAsString(List.filled(original.length, 'x').join());
    file.setLastModifiedSync(modifiedAt);

    final result = await library.addDocument(path: file.path);

    expect(result.reusedIndex, isTrue);
    expect(result.summaryLabel, contains('up to date'));
    expect(library.search('alpha'), hasLength(1));
    expect(library.search('xxxx'), isEmpty);
    expect(library.documents, hasLength(1));
  });

  test('re-indexes a file whose text changed', () async {
    final file = await writeFile(
      'notes.txt',
      'The docker engine runs locally.',
    );

    await library.addDocument(path: file.path);
    expect(library.search('docker'), hasLength(1));

    await file.writeAsString('Kubernetes notes about clusters and nodes.');
    final result = await library.addDocument(path: file.path);

    expect(result.reusedIndex, isFalse);
    expect(library.documents, hasLength(1));
    expect(library.search('docker'), isEmpty);
    expect(library.search('kubernetes'), hasLength(1));
  });

  test(
    'refreshes only the file reference when the text did not change',
    () async {
      final file = await writeFile(
        'notes.txt',
        'Stable content for the index.',
      );
      final first = await library.addDocument(path: file.path);

      file.setLastModifiedSync(DateTime.now().add(const Duration(days: 1)));
      final result = await library.addDocument(path: file.path);

      expect(result.reusedIndex, isTrue);
      expect(
        result.document.source.modifiedAt.isAfter(
          first.document.source.modifiedAt,
        ),
        isTrue,
      );
      expect(result.document.chunks, first.document.chunks);
      expect(library.needsRefresh(result.document), isFalse);
    },
  );

  test('re-indexes when the stored pipeline version is older', () async {
    final file = await writeFile(
      'notes.txt',
      'Versioned pipeline content here.',
    );
    await library.addDocument(path: file.path);

    final stored = store.read()!;
    final document = stored.documents.single;
    store.save(
      stored.copyWith(
        documents: [
          IndexedDocument(
            source: document.source,
            chunks: document.chunks,
            charCount: document.charCount,
            indexedAt: document.indexedAt,
            contentHash: document.contentHash,
            chunking: document.chunking,
            chunkerVersion: document.chunkerVersion - 1,
            embeddingModelId: document.embeddingModelId,
          ),
        ],
      ),
    );

    library.load();
    expect(library.needsRefresh(library.documents.single), isTrue);

    final result = await library.addDocument(path: file.path);
    expect(result.reusedIndex, isFalse);
    expect(library.needsRefresh(library.documents.single), isFalse);
  });

  test('re-indexes when the stored chunking settings changed', () async {
    final file = await writeFile('notes.txt', 'Chunking settings under test.');
    await library.addDocument(path: file.path);

    store.save(
      store.read()!.copyWith(
        chunking: const DocumentChunkingConfig(
          targetTokens: 64,
          overlapTokens: 8,
        ),
      ),
    );

    final reloaded = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: DocumentIndexStore(indexFile),
    )..load();

    expect(reloaded.chunking.targetTokens, 64);
    expect(reloaded.needsRefresh(reloaded.documents.single), isTrue);

    final result = await reloaded.addDocument(path: file.path);
    expect(result.reusedIndex, isFalse);
    expect(result.document.chunking.targetTokens, 64);
    expect(reloaded.needsRefresh(reloaded.documents.single), isFalse);
  });

  test('removes a document without touching the file', () async {
    final file = await writeFile(
      'notes.txt',
      'Removable content stays on disk.',
    );
    final result = await library.addDocument(path: file.path);

    expect(library.removeDocument(result.document.id), isTrue);
    expect(library.documents, isEmpty);
    expect(library.search('removable'), isEmpty);
    expect(file.existsSync(), isTrue);
    expect(DocumentIndexStore(indexFile).read()!.documents, isEmpty);
    expect(library.removeDocument(result.document.id), isFalse);
  });

  test('refreshes a document by id through the library', () async {
    final file = await writeFile('notes.txt', 'First revision of the notes.');
    final result = await library.addDocument(path: file.path);

    await file.writeAsString('Second revision mentions zebras.');

    final refreshed = await library.refreshDocument(result.document.id);

    expect(refreshed.reusedIndex, isFalse);
    expect(library.search('zebras'), hasLength(1));
    expect(library.documents.single.id, result.document.id);
  });

  test('reports a file that disappeared', () async {
    final file = await writeFile(
      'notes.txt',
      'Temporary content for indexing.',
    );
    await library.addDocument(path: file.path);

    await file.delete();

    expect(library.needsRefresh(library.documents.single), isTrue);
    await expectLater(
      library.refreshDocument(library.documents.single.id),
      throwsA(
        isA<DocumentExtractionException>().having(
          (error) => error.message,
          'message',
          contains('no longer exists'),
        ),
      ),
    );
  });

  test('rejects a binary file without storing anything', () async {
    final file = File(p.join(tempDir.path, 'binary.txt'));
    await file.writeAsBytes(List.filled(128, 0x01));

    await expectLater(
      library.addDocument(path: file.path),
      throwsA(
        isA<DocumentExtractionException>().having(
          (error) => error.message,
          'message',
          contains('binary'),
        ),
      ),
    );

    expect(library.documents, isEmpty);
    expect(store.read(), isNull);
  });

  test('reports a path that does not exist', () async {
    await expectLater(
      library.addDocument(path: p.join(tempDir.path, 'missing.txt')),
      throwsA(
        isA<DocumentExtractionException>().having(
          (error) => error.message,
          'message',
          contains('no longer exists'),
        ),
      ),
    );
  });

  test('cancels ingestion without storing anything', () async {
    final file = await writeFile(
      'notes.txt',
      'Content that must not be indexed after cancelling.',
    );
    final token = CancelToken();

    await expectLater(
      library.addDocument(
        path: file.path,
        cancelToken: token,
        onProgress: (progress) {
          if (progress.stage == DocumentIngestStage.reading) token.cancel();
        },
      ),
      throwsA(isA<OperationCancelledException>()),
    );

    expect(token.isCancelled, isTrue);
    expect(library.documents, isEmpty);
    expect(store.read(), isNull);
  });

  test('cancels before touching the file at all', () async {
    final file = await writeFile('notes.txt', 'Unread content.');
    final token = CancelToken()..cancel();

    await expectLater(
      library.addDocument(path: file.path, cancelToken: token),
      throwsA(isA<OperationCancelledException>()),
    );

    expect(library.documents, isEmpty);
  });

  test('supports markdown and code files without a format argument', () async {
    final markdown = await writeFile('readme.md', '# Setup\n\nRun it locally.');
    final code = await writeFile('main.dart', 'void main() => run();');

    final markdownResult = await library.addDocument(path: markdown.path);
    final codeResult = await library.addDocument(path: code.path);

    expect(markdownResult.document.source.format, DocumentFormat.markdown);
    expect(codeResult.document.source.format, DocumentFormat.code);
    expect(library.documents, hasLength(2));
    expect(library.search('main'), isNotEmpty);
  });

  test('still works when the index file belongs to a newer build', () async {
    indexFile.parent.createSync(recursive: true);
    indexFile.writeAsStringSync('{"version": 99, "documents": []}');

    final readOnlyLibrary = DocumentLibrary(
      extractor: DocumentExtractionService(),
      store: DocumentIndexStore(indexFile),
    )..load();
    final file = await writeFile('notes.txt', 'In-memory only content.');

    final result = await readOnlyLibrary.addDocument(path: file.path);

    expect(readOnlyLibrary.isReadOnly, isTrue);
    expect(result.document.chunkCount, greaterThan(0));
    // Search keeps working from memory while the newer file stays untouched.
    expect(readOnlyLibrary.search('memory'), isNotEmpty);
    expect(indexFile.readAsStringSync(), '{"version": 99, "documents": []}');
  });
}
