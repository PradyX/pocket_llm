import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';

void main() {
  group('documentFormatForPath', () {
    test('recognizes text, markdown and PDF files', () {
      expect(documentFormatForPath('/tmp/notes.txt'), DocumentFormat.text);
      expect(documentFormatForPath('/tmp/notes.LOG'), DocumentFormat.text);
      expect(documentFormatForPath('/tmp/readme.md'), DocumentFormat.markdown);
      expect(documentFormatForPath('/tmp/paper.pdf'), DocumentFormat.pdf);
    });

    test('recognizes source files, including known build files', () {
      expect(documentFormatForPath('/tmp/main.dart'), DocumentFormat.code);
      expect(documentFormatForPath('/tmp/config.yaml'), DocumentFormat.code);
      expect(documentFormatForPath('/tmp/Dockerfile'), DocumentFormat.code);
      expect(documentFormatForPath('/srv/Makefile'), DocumentFormat.code);
    });

    test('falls back to other for unknown extensions', () {
      expect(documentFormatForPath('/tmp/archive.zip'), DocumentFormat.other);
      expect(documentFormatForPath('/tmp/noextension'), DocumentFormat.other);
    });
  });

  group('DocumentFormat', () {
    test('parses stored names and falls back safely', () {
      expect(DocumentFormat.tryParse('markdown'), DocumentFormat.markdown);
      expect(DocumentFormat.tryParse('nonsense'), DocumentFormat.other);
      expect(DocumentFormat.tryParse(null), DocumentFormat.other);
    });

    test('labels formats for errors and citations', () {
      expect(documentFormatLabel(DocumentFormat.pdf), 'PDF');
      expect(documentFormatLabel(DocumentFormat.code), 'source code');
    });
  });

  group('DocumentSource', () {
    DocumentSource source({int sizeBytes = 120}) => DocumentSource.fromFile(
      id: 'doc-1',
      path: '/tmp/notes.txt',
      name: 'notes.txt',
      sizeBytes: sizeBytes,
      modifiedAt: DateTime(2026, 3, 1),
      addedAt: DateTime(2026, 3, 2),
    );

    test('derives the format from the file name', () {
      expect(source().format, DocumentFormat.text);
    });

    test('detects a stale file by size or modification time', () {
      final stored = source();

      expect(
        stored.isStaleComparedTo(
          sizeBytes: 120,
          modifiedAt: DateTime(2026, 3, 1),
        ),
        isFalse,
      );
      expect(
        stored.isStaleComparedTo(
          sizeBytes: 121,
          modifiedAt: DateTime(2026, 3, 1),
        ),
        isTrue,
      );
      expect(
        stored.isStaleComparedTo(
          sizeBytes: 120,
          modifiedAt: DateTime(2026, 3, 2),
        ),
        isTrue,
      );
    });

    test('round-trips through JSON', () {
      final restored = DocumentSource.fromJson(source().toJson())!;

      expect(restored.id, 'doc-1');
      expect(restored.path, '/tmp/notes.txt');
      expect(restored.name, 'notes.txt');
      expect(restored.format, DocumentFormat.text);
      expect(restored.sizeBytes, 120);
      expect(restored.modifiedAt, DateTime(2026, 3, 1));
      expect(restored.addedAt, DateTime(2026, 3, 2));
    });

    test('rejects a payload without a usable path', () {
      expect(DocumentSource.fromJson(const {}), isNull);
      expect(DocumentSource.fromJson(const {'path': '  '}), isNull);
    });

    test('fills in defaults for partial payloads', () {
      final restored = DocumentSource.fromJson(const {
        'path': '/tmp/plain/notes.txt',
      })!;

      expect(restored.name, 'notes.txt');
      expect(restored.format, DocumentFormat.text);
      expect(restored.id, startsWith('doc-'));
    });
  });

  group('DocumentChunk', () {
    test('builds a stable chunk id per document', () {
      const chunk = DocumentChunk(
        index: 3,
        text: 'text',
        startOffset: 10,
        endOffset: 14,
      );

      expect(chunk.idFor('doc-1'), 'doc-1:3');
    });

    test('round-trips through JSON', () {
      const chunk = DocumentChunk(
        index: 1,
        text: 'Install the runtime.',
        startOffset: 5,
        endOffset: 26,
        heading: 'Setup',
      );

      final restored = DocumentChunk.fromJson(chunk.toJson())!;
      expect(restored.index, 1);
      expect(restored.text, 'Install the runtime.');
      expect(restored.startOffset, 5);
      expect(restored.endOffset, 26);
      expect(restored.heading, 'Setup');
    });

    test('drops entries without text', () {
      expect(DocumentChunk.fromJson(const {'index': 0}), isNull);
    });
  });

  group('DocumentChunkingConfig', () {
    test('normalizes out-of-range settings', () {
      final config = const DocumentChunkingConfig(
        targetTokens: 10,
        overlapTokens: 999,
        maxChunkTokens: 5,
      ).normalized();

      expect(config.targetTokens, 32);
      expect(config.overlapTokens, 16);
      expect(config.maxChunkTokens, 32);
    });

    test('compares settings field by field', () {
      const base = DocumentChunkingConfig();

      expect(base.sameAs(const DocumentChunkingConfig()), isTrue);
      expect(
        base.sameAs(const DocumentChunkingConfig(overlapTokens: 8)),
        isFalse,
      );
    });

    test('round-trips through JSON and falls back to defaults', () {
      const config = DocumentChunkingConfig(
        targetTokens: 200,
        overlapTokens: 20,
      );

      final restored = DocumentChunkingConfig.fromJson(config.toJson());
      expect(restored.sameAs(config), isTrue);
      expect(
        DocumentChunkingConfig.fromJson(
          null,
        ).sameAs(const DocumentChunkingConfig()),
        isTrue,
      );
    });
  });

  group('IndexedDocument', () {
    IndexedDocument document() => IndexedDocument(
      source: DocumentSource.fromFile(
        id: 'doc-1',
        path: '/tmp/notes.txt',
        name: 'notes.txt',
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

    test('records the pipeline defaults for index maintenance', () {
      final indexed = document();

      expect(indexed.chunkerVersion, documentChunkerVersion);
      expect(indexed.chunking.sameAs(const DocumentChunkingConfig()), isTrue);
      expect(indexed.embeddingModelId, isNull);
      expect(indexed.embeddingDimensions, isNull);
      expect(indexed.chunkCount, 1);
    });

    test('round-trips chunks and index metadata through JSON', () {
      final restored = IndexedDocument.fromJson(document().toJson())!;

      expect(restored.id, 'doc-1');
      expect(restored.source.name, 'notes.txt');
      expect(restored.chunkCount, 1);
      expect(restored.chunks.single.text, 'hello world');
      expect(restored.charCount, 11);
      expect(restored.indexedAt, DateTime(2026, 3, 3));
      expect(restored.contentHash, 'abc123');
      expect(restored.chunkerVersion, documentChunkerVersion);
    });

    test('keeps chunks when only the file reference changes', () {
      final original = document();
      final refreshed = original.withSource(
        DocumentSource.fromFile(
          id: 'doc-1',
          path: '/tmp/moved/notes.txt',
          name: 'notes.txt',
          sizeBytes: 40,
          modifiedAt: DateTime(2026, 3, 9),
          addedAt: DateTime(2026, 3, 2),
        ),
      );

      expect(refreshed.id, original.id);
      expect(refreshed.chunks, original.chunks);
      expect(refreshed.contentHash, original.contentHash);
      expect(refreshed.source.path, '/tmp/moved/notes.txt');
    });

    test('rejects a payload without a source', () {
      expect(IndexedDocument.fromJson(const {'charCount': 4}), isNull);
    });
  });
}
