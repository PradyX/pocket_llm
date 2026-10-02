import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/documents/data/lexical_document_retriever.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/document_search_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

void main() {
  IndexedDocument documentWith(String id, String name, List<String> texts) {
    return IndexedDocument(
      source: DocumentSource(
        id: id,
        path: '/tmp/$name',
        name: name,
        format: DocumentFormat.text,
        sizeBytes: 10,
        modifiedAt: DateTime(2026, 3, 1),
        addedAt: DateTime(2026, 3, 1),
      ),
      collectionId: defaultCollectionId,
      chunks: [
        for (var index = 0; index < texts.length; index++)
          DocumentChunk(
            index: index,
            text: texts[index],
            startOffset: 0,
            endOffset: texts[index].length,
            heading: index == 0 ? 'Setup' : null,
          ),
      ],
      charCount: texts.fold(0, (sum, text) => sum + text.length),
      indexedAt: DateTime(2026, 3, 1),
      contentHash: 'hash-$id',
    );
  }

  LexicalDocumentRetriever dockerRetriever() {
    final retriever = LexicalDocumentRetriever();
    retriever.rebuild([
      documentWith('doc-1', 'infra.md', [
        'The docker engine keeps every image local.',
        'Unrelated styling notes about buttons.',
      ]),
      documentWith('doc-2', 'other.md', ['Docker containers and images.']),
    ]);
    return retriever;
  }

  group('searchLocalDocuments', () {
    test('returns excerpts with their document label', () {
      final matches = searchLocalDocuments(
        retriever: dockerRetriever(),
        query: 'docker',
        collectionId: defaultCollectionId,
      );

      expect(matches, isNotEmpty);
      final infra = matches.firstWhere(
        (match) => match.documentName == 'infra.md',
      );
      expect(infra.heading, 'Setup');
      expect(infra.label, 'infra.md · Setup');
      expect(infra.text, contains('docker'));
    });

    test(
      'respects the asked-for limit and returns nothing without a match',
      () {
        final limited = searchLocalDocuments(
          retriever: dockerRetriever(),
          query: 'docker',
          collectionId: defaultCollectionId,
          limit: 1,
        );
        expect(limited, hasLength(1));

        expect(
          searchLocalDocuments(
            retriever: dockerRetriever(),
            query: 'unfindable',
            collectionId: defaultCollectionId,
          ),
          isEmpty,
        );
      },
    );

    test('never hands the model an unbounded chunk', () {
      final retriever = LexicalDocumentRetriever();
      retriever.rebuild([
        documentWith('doc-1', 'long.md', [
          'docker ${'word ' * maximumDocumentExcerptLength}',
        ]),
      ]);

      final matches = searchLocalDocuments(
        retriever: retriever,
        query: 'docker',
        collectionId: defaultCollectionId,
      );

      expect(matches, hasLength(1));
      expect(matches.single.text, endsWith('…'));
      expect(
        matches.single.text.length,
        lessThanOrEqualTo(maximumDocumentExcerptLength + 1),
      );
    });
  });

  group('search_local_documents tool', () {
    test('is read-only and reports what it found', () async {
      final entry = buildDocumentSearchTool(
        search: (query, limit) async => const [
          LocalDocumentMatch(
            documentName: 'infra.md',
            heading: 'Setup',
            text: 'The docker engine keeps every image local.',
          ),
        ],
      );
      expect(entry.definition.risk, ToolRiskLevel.readOnly);

      final registry = ToolRegistry(
        tools: [entry],
        platform: ToolPlatform.macOS,
      );
      final result = await registry.execute(
        const ToolCall(
          toolName: 'search_local_documents',
          arguments: {'query': 'docker'},
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, contains('1 local document excerpt'));
      expect(result.output, contains('[1] infra.md · Setup'));
      expect(result.output, contains('docker engine'));
    });

    test('explains when nothing matches or nothing is indexed', () async {
      final registry = ToolRegistry(
        tools: [
          buildDocumentSearchTool(search: (query, limit) async => const []),
        ],
        platform: ToolPlatform.macOS,
      );

      final result = await registry.execute(
        const ToolCall(
          toolName: 'search_local_documents',
          arguments: {'query': 'docker'},
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, contains('No local document excerpts matched'));
    });
  });
}
