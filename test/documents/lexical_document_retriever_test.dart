import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/documents/data/lexical_document_retriever.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';

void main() {
  DocumentSource sourceFor(String id, String name) => DocumentSource(
    id: id,
    path: '/tmp/$name',
    name: name,
    format: DocumentFormat.text,
    sizeBytes: 10,
    modifiedAt: DateTime(2026, 3, 1),
    addedAt: DateTime(2026, 3, 1),
  );

  IndexedDocument documentWith(String id, String name, List<String> texts) {
    return IndexedDocument(
      source: sourceFor(id, name),
      chunks: [
        for (var index = 0; index < texts.length; index++)
          DocumentChunk(
            index: index,
            text: texts[index],
            startOffset: 0,
            endOffset: texts[index].length,
          ),
      ],
      charCount: texts.fold(0, (sum, text) => sum + text.length),
      indexedAt: DateTime(2026, 3, 1),
      contentHash: 'hash-$id',
    );
  }

  group('retrievalTokens', () {
    test('lowercases words and drops single characters', () {
      expect(retrievalTokens('The Quick a fox'), ['the', 'quick', 'fox']);
    });

    test('splits identifiers at camelCase boundaries', () {
      expect(retrievalTokens('requestContextBuilder'), [
        'request',
        'context',
        'builder',
      ]);
      expect(retrievalTokens('parseHTTPResponse'), [
        'parse',
        'http',
        'response',
      ]);
    });
  });

  group('LexicalDocumentRetriever', () {
    late LexicalDocumentRetriever retriever;

    setUp(() {
      retriever = LexicalDocumentRetriever();
    });

    test('returns nothing while the corpus is empty', () {
      expect(retriever.documentCount, 0);
      expect(retriever.chunkCount, 0);
      expect(retriever.search('docker'), isEmpty);
    });

    test('finds the chunk that mentions the query term', () {
      retriever.rebuild([
        documentWith('doc-1', 'infra.md', [
          'The docker engine keeps every image local.',
          'Unrelated notes about styling buttons.',
        ]),
        documentWith('doc-2', 'style.md', ['Colors and spacing for the app.']),
      ]);

      final hits = retriever.search('docker');

      expect(hits, hasLength(1));
      expect(hits.single.documentId, 'doc-1');
      expect(hits.single.documentName, 'infra.md');
      expect(hits.single.chunkId, 'doc-1:0');
      expect(hits.single.matchedTerms, {'docker'});
      expect(hits.single.score, greaterThan(0));
    });

    test('returns nothing for terms that appear nowhere', () {
      retriever.rebuild([
        documentWith('doc-1', 'infra.md', ['local files only']),
      ]);

      expect(retriever.search('quantum'), isEmpty);
      expect(retriever.search('!!!'), isEmpty);
    });

    test('ranks rarer terms and their chunks first', () {
      retriever.rebuild([
        documentWith('doc-1', 'infra.md', [
          'common words appear everywhere here',
          'the zebra stands alone in this paragraph',
        ]),
        documentWith('doc-2', 'other.md', [
          'common words appear everywhere too',
        ]),
      ]);

      final hits = retriever.search('common zebra');

      expect(hits, isNotEmpty);
      expect(hits.first.chunk.index, 1);
      expect(hits.first.matchedTerms, {'zebra'});
      expect(hits.where((hit) => hit.documentId == 'doc-2'), isNotEmpty);
    });

    test('matches identifiers by their word parts', () {
      retriever.rebuild([
        documentWith('doc-1', 'main.dart', [
          'final requestContextBuilder = 1;',
        ]),
      ]);

      final hits = retriever.search('context');

      expect(hits, hasLength(1));
      expect(hits.single.matchedTerms, {'context'});
    });

    test('honors the result limit', () {
      retriever.rebuild([
        documentWith('doc-1', 'many.md', [
          'target appears in the first chunk',
          'target appears in the second chunk',
          'target appears in the third chunk',
        ]),
      ]);

      expect(retriever.search('target'), hasLength(3));
      expect(retriever.search('target', limit: 2), hasLength(2));
      expect(retriever.search('target', limit: 0), isEmpty);
    });

    test('reports the indexed size and replaces the corpus on rebuild', () {
      retriever.rebuild([
        documentWith('doc-1', 'infra.md', ['docker images']),
        documentWith('doc-2', 'other.md', ['docker containers', 'spacing']),
      ]);

      expect(retriever.documentCount, 2);
      expect(retriever.chunkCount, 3);

      retriever.rebuild([
        documentWith('doc-3', 'new.md', ['kubernetes notes']),
      ]);

      expect(retriever.documentCount, 1);
      expect(retriever.chunkCount, 1);
      expect(retriever.search('docker'), isEmpty);
      expect(retriever.search('kubernetes'), hasLength(1));

      retriever.rebuild([]);
      expect(retriever.chunkCount, 0);
      expect(retriever.search('kubernetes'), isEmpty);
    });

    test('matches shared terms across chunks with deterministic ordering', () {
      retriever.rebuild([
        documentWith('doc-b', 'b.md', ['shared term']),
        documentWith('doc-a', 'a.md', ['shared term']),
      ]);

      final first = retriever.search('shared');
      final second = retriever.search('shared');

      expect(first.map((hit) => hit.chunkId), second.map((hit) => hit.chunkId));
      expect(first, hasLength(2));
    });
  });
}
