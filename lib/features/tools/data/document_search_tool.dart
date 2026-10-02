import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Longest excerpt of one chunk handed to the model, in characters.
///
/// Chunks are already token-sized for retrieval; this is a second guard so a
/// tool answer can never swallow the context window on its own.
const int maximumDocumentExcerptLength = 800;

/// One local document excerpt found for a query.
class LocalDocumentMatch {
  const LocalDocumentMatch({
    required this.documentName,
    required this.text,
    this.heading,
  });

  final String documentName;
  final String? heading;
  final String text;

  /// `notes.md · Setup`.
  String get label {
    final section = heading?.trim();
    if (section == null || section.isEmpty) return documentName;
    return '$documentName · $section';
  }
}

/// Searches one knowledge collection the user selected and returns excerpts.
///
/// Read-only: files are only searched where they already live; nothing is
/// written back and no file outside the indexed selection is touched.
List<LocalDocumentMatch> searchLocalDocuments({
  required DocumentRetriever retriever,
  required String query,
  required String collectionId,
  int limit = 3,
}) {
  final hits = retriever.search(
    query,
    limit: limit,
    collectionId: collectionId,
  );
  return [
    for (final hit in hits)
      LocalDocumentMatch(
        documentName: hit.documentName,
        heading: hit.chunk.heading,
        text: _excerpt(hit),
      ),
  ];
}

String _excerpt(DocumentSearchHit hit) {
  final text = hit.chunk.text.trim();
  if (text.length <= maximumDocumentExcerptLength) return text;
  return '${text.substring(0, maximumDocumentExcerptLength)}…';
}

/// Tool: search the user's indexed local documents.
ToolEntry buildDocumentSearchTool({
  required Future<List<LocalDocumentMatch>> Function(String query, int limit)
  search,
}) {
  return ToolEntry(
    definition: const ToolDefinition(
      name: 'search_local_documents',
      description:
          "Searches the local documents the user added to the active "
          'knowledge collection and returns the best matching excerpts with '
          'their file names. Read-only and offline.',
      risk: ToolRiskLevel.readOnly,
      timeout: Duration(seconds: 10),
      parameters: [
        ToolParameter(
          name: 'query',
          type: ToolParameterType.string,
          description: 'Words to look for in the documents.',
          maxLength: 200,
        ),
        ToolParameter(
          name: 'limit',
          type: ToolParameterType.integer,
          description: 'How many excerpts to return.',
          required: false,
          minimum: 1,
          maximum: 5,
        ),
      ],
    ),
    handler: (arguments) async {
      final query = arguments['query'] as String;
      final limit = arguments['limit'] as int? ?? 3;
      final matches = await search(query, limit);

      if (matches.isEmpty) {
        return 'No local document excerpts matched "$query". The user can add '
            'documents on the Documents screen.';
      }

      final buffer = StringBuffer()
        ..writeln(
          matches.length == 1
              ? '1 local document excerpt matched "$query":'
              : '${matches.length} local document excerpts matched "$query":',
        );
      for (var index = 0; index < matches.length; index++) {
        final match = matches[index];
        buffer
          ..writeln('[${index + 1}] ${match.label}')
          ..writeln(match.text);
      }
      return buffer.toString().trimRight();
    },
  );
}
