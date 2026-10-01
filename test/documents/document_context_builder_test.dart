import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/documents/application/document_context_builder.dart';
import 'package:pocket_llm/features/documents/data/lexical_document_retriever.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';

void main() {
  const builder = DocumentContextBuilder();

  DocumentSource sourceFor(String id, String name) => DocumentSource(
    id: id,
    path: '/tmp/$name',
    name: name,
    format: DocumentFormat.text,
    sizeBytes: 10,
    modifiedAt: DateTime(2026, 3, 1),
    addedAt: DateTime(2026, 3, 1),
  );

  IndexedDocument documentWith(
    String id,
    String name,
    List<String> texts, {
    String collectionId = defaultCollectionId,
  }) {
    return IndexedDocument(
      source: sourceFor(id, name),
      collectionId: collectionId,
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

  LexicalDocumentRetriever retrieverWith(List<IndexedDocument> documents) {
    final retriever = LexicalDocumentRetriever();
    retriever.rebuild(documents);
    return retriever;
  }

  LexicalDocumentRetriever dockerRetriever() => retrieverWith([
    documentWith('doc-1', 'infra.md', [
      'The docker engine keeps every image local.',
      'Unrelated styling notes about buttons.',
    ]),
    documentWith('doc-2', 'other.md', ['Docker containers and images again.']),
  ]);

  group('DocumentContextBuilder', () {
    test('returns nothing without a budget, a query or an index', () {
      final retriever = dockerRetriever();

      expect(
        builder
            .build(retriever: retriever, query: 'docker', tokenBudget: 0)
            .isEmpty,
        isTrue,
      );
      expect(
        builder
            .build(retriever: retriever, query: '   ', tokenBudget: 400)
            .isEmpty,
        isTrue,
      );
      expect(
        builder
            .build(
              retriever: retrieverWith(const []),
              query: 'docker',
              tokenBudget: 400,
            )
            .isEmpty,
        isTrue,
      );
    });

    test('lists retrieved chunks with contiguous citation markers', () {
      final context = builder.build(
        retriever: dockerRetriever(),
        query: 'docker',
        tokenBudget: 600,
      );

      expect(context.hits, hasLength(2));
      expect(context.section, contains(DocumentContextBuilder.instructions));
      expect(
        context.section,
        contains('[1] ${context.hits.first.citationLabel}'),
      );
      expect(
        context.section,
        contains('[2] ${context.hits.last.citationLabel}'),
      );
      expect(
        context.section,
        contains('docker engine keeps every image local'),
      );
      expect(context.tokenCount, lessThanOrEqualTo(600));
      expect(context.summaryLabel, '2 local chunks');
    });

    test('says so when documents exist but nothing matches', () {
      final context = builder.build(
        retriever: dockerRetriever(),
        query: 'quantum',
        tokenBudget: 400,
      );

      expect(context.hits, isEmpty);
      expect(context.section, contains(DocumentContextBuilder.noMatchNotice));
      expect(context.tokenCount, greaterThan(0));
      expect(context.summaryLabel, 'No local document chunks');
    });

    test('skips chunks that do not fit and renumbers the rest', () {
      final retriever = retrieverWith([
        documentWith('doc-1', 'big.md', [
          'docker ${'filler words ' * 60} docker docker',
        ]),
        documentWith('doc-2', 'small.md', ['docker note']),
      ]);

      final context = builder.build(
        retriever: retriever,
        query: 'docker',
        tokenBudget: 60,
      );

      expect(context.hits, hasLength(1));
      expect(context.hits.single.documentName, 'small.md');
      expect(context.section, contains('[1] small.md'));
      expect(context.section, isNot(contains('big.md')));
      expect(context.tokenCount, lessThanOrEqualTo(60));
    });

    test('sends nothing when even one chunk cannot fit', () {
      final context = builder.build(
        retriever: dockerRetriever(),
        query: 'docker',
        tokenBudget: 12,
      );

      expect(context.isEmpty, isTrue);
      expect(context.section, isEmpty);
    });

    test('retrieves from one collection at a time', () {
      final retriever = retrieverWith([
        documentWith('doc-1', 'work.md', [
          'docker deployment notes',
        ], collectionId: 'col-work'),
        documentWith('doc-2', 'home.md', [
          'docker recipes for dinner',
        ], collectionId: 'col-home'),
      ]);

      final work = builder.build(
        retriever: retriever,
        query: 'docker',
        tokenBudget: 400,
        collectionId: 'col-work',
      );
      expect(work.hits.single.documentName, 'work.md');
      expect(work.section, contains('work.md'));
      expect(work.section, isNot(contains('home.md')));

      // A collection without matching chunks contributes nothing at all.
      final missing = builder.build(
        retriever: retriever,
        query: 'docker',
        tokenBudget: 400,
        collectionId: 'col-missing',
      );
      expect(missing.isEmpty, isTrue);
      expect(missing.section, isEmpty);
    });

    test('never reports a chunk the retriever did not return', () {
      final context = builder.build(
        retriever: dockerRetriever(),
        query: 'styling',
        tokenBudget: 600,
      );

      expect(context.hits, hasLength(1));
      expect(context.section, contains('[1] infra.md'));
      expect(
        context.section,
        contains('Unrelated styling notes about buttons'),
      );
      // The instruction header mentions the markers, so check for a marker
      // block rather than the characters.
      expect(context.section, isNot(contains('\n[2] ')));
      expect(
        context.section,
        isNot(contains('Docker containers and images again')),
      );
    });
  });
}
