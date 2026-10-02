import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/read_document_tool.dart';
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
          ),
      ],
      charCount: texts.fold(0, (sum, text) => sum + text.length),
      indexedAt: DateTime(2026, 3, 1),
      contentHash: 'hash-$id',
    );
  }

  final library = [
    documentWith('doc-1', 'infra.md', [
      'The docker engine keeps every image local.',
      'Backups run nightly.',
    ]),
    documentWith('doc-2', 'notes-a.md', ['Planning notes for week one.']),
    documentWith('doc-3', 'notes-b.md', ['Planning notes for week two.']),
  ];

  group('readLocalDocument', () {
    test('joins the indexed chunks of an exact name match', () {
      final read = readLocalDocument(
        documents: library,
        documentName: 'infra.md',
      );

      expect(read, isNotNull);
      expect(read!.name, 'infra.md');
      expect(
        read.text,
        'The docker engine keeps every image local.\n\nBackups run nightly.',
      );
      expect(read.truncated, isFalse);
      expect(read.totalCharacters, read.text.length);
    });

    test('matches an exact name without case', () {
      final read = readLocalDocument(
        documents: library,
        documentName: 'INFRA.MD',
      );

      expect(read!.name, 'infra.md');
    });

    test('matches a unique partial name', () {
      final read = readLocalDocument(documents: library, documentName: 'infra');

      expect(read!.name, 'infra.md');
    });

    test('refuses an ambiguous or unknown name instead of guessing', () {
      expect(
        readLocalDocument(documents: library, documentName: 'notes'),
        isNull,
      );
      expect(
        readLocalDocument(documents: library, documentName: 'missing.md'),
        isNull,
      );
      expect(
        readLocalDocument(documents: library, documentName: '   '),
        isNull,
      );
    });

    test('skips blank chunks and truncates a very long document', () {
      final long = documentWith('doc-4', 'long.md', [
        '   ',
        'x' * (maximumDocumentReadLength + 500),
      ]);
      final read = readLocalDocument(
        documents: [long],
        documentName: 'long.md',
      );

      expect(read, isNotNull);
      expect(read!.truncated, isTrue);
      expect(read.text, endsWith('…'));
      expect(read.text.length, maximumDocumentReadLength + 1);
      expect(read.totalCharacters, maximumDocumentReadLength + 500);
    });
  });

  group('read_document tool', () {
    test('is read-only and returns the document text', () async {
      final entry = buildReadDocumentTool(
        read: (documentName) async => LocalDocumentRead(
          name: 'infra.md',
          text: 'The docker engine keeps every image local.',
          truncated: false,
          totalCharacters: 42,
        ),
      );
      expect(entry.definition.risk, ToolRiskLevel.readOnly);

      final registry = ToolRegistry(
        tools: [entry],
        platform: ToolPlatform.macOS,
      );
      final result = await registry.execute(
        const ToolCall(
          toolName: 'read_document',
          arguments: {'document': 'infra.md'},
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, startsWith('Document: infra.md'));
      expect(result.output, contains('docker engine'));
      expect(result.output, isNot(contains('Truncated')));
    });

    test('points at search when the document is not there', () async {
      final registry = ToolRegistry(
        tools: [buildReadDocumentTool(read: (documentName) async => null)],
        platform: ToolPlatform.macOS,
      );

      final result = await registry.execute(
        const ToolCall(
          toolName: 'read_document',
          arguments: {'document': 'missing.md'},
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, contains('No document named "missing.md"'));
      expect(result.output, contains('search_local_documents'));
    });

    test('says how much of a long document fits', () async {
      final registry = ToolRegistry(
        tools: [
          buildReadDocumentTool(
            read: (documentName) async => LocalDocumentRead(
              name: 'book.md',
              text: 'page one …',
              truncated: true,
              totalCharacters: 9000,
            ),
          ),
        ],
        platform: ToolPlatform.macOS,
      );

      final result = await registry.execute(
        const ToolCall(
          toolName: 'read_document',
          arguments: {'document': 'book.md'},
        ),
      );

      expect(
        result.output,
        contains('Truncated after $maximumDocumentReadLength'),
      );
      expect(result.output, contains('9000'));
    });
  });
}
