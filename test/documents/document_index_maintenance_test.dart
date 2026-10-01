import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_index_maintenance.dart';

void main() {
  IndexedDocument document({
    int chunkerVersion = documentChunkerVersion,
    DocumentChunkingConfig chunking = const DocumentChunkingConfig(),
    String? embeddingModelId,
    int? embeddingDimensions,
  }) {
    return IndexedDocument(
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
      chunking: chunking,
      chunkerVersion: chunkerVersion,
      embeddingModelId: embeddingModelId,
      embeddingDimensions: embeddingDimensions,
    );
  }

  group('documentContentHash', () {
    test('is stable for the same text', () {
      expect(
        documentContentHash('hello world'),
        documentContentHash('hello world'),
      );
    });

    test('is 16 hex characters and changes with the text', () {
      final hash = documentContentHash('hello world');

      expect(hash, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(documentContentHash('hello worlds'), isNot(hash));
      expect(documentContentHash(''), isNot(hash));
    });
  });

  group('documentReindexReason', () {
    test('returns null when the stored index still applies', () {
      expect(
        documentReindexReason(
          document(),
          chunking: const DocumentChunkingConfig(),
          embeddingModelId: null,
        ),
        isNull,
      );
    });

    test('reports an older pipeline version', () {
      expect(
        documentReindexReason(
          document(chunkerVersion: documentChunkerVersion - 1),
          chunking: const DocumentChunkingConfig(),
        ),
        'the document pipeline changed',
      );
    });

    test('reports changed chunking settings', () {
      expect(
        documentReindexReason(
          document(),
          chunking: const DocumentChunkingConfig(targetTokens: 128),
        ),
        'the chunking settings changed',
      );
    });

    test('reports a changed retrieval backend', () {
      expect(
        documentReindexReason(
          document(embeddingModelId: 'model-a', embeddingDimensions: 384),
          chunking: const DocumentChunkingConfig(),
          embeddingModelId: 'model-b',
          embeddingDimensions: 384,
        ),
        'the retrieval backend changed',
      );
    });

    test('reports changed embedding dimensions for an embedding backend', () {
      expect(
        documentReindexReason(
          document(embeddingModelId: 'model-a', embeddingDimensions: 384),
          chunking: const DocumentChunkingConfig(),
          embeddingModelId: 'model-a',
          embeddingDimensions: 768,
        ),
        'the embedding dimensions changed',
      );
    });

    test('does not require a width when the caller has no expectation', () {
      expect(
        documentReindexReason(
          document(embeddingModelId: 'model-a', embeddingDimensions: 384),
          chunking: const DocumentChunkingConfig(),
          embeddingModelId: 'model-a',
        ),
        isNull,
      );
    });

    test('ignores dimensions for lexical indexes', () {
      expect(
        documentReindexReason(
          document(embeddingDimensions: 384),
          chunking: const DocumentChunkingConfig(),
          embeddingDimensions: 768,
        ),
        isNull,
      );
    });
  });
}
