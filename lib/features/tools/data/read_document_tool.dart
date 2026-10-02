import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Longest text handed to the model for one document, in characters.
///
/// A document can be a whole book; the tool reads what fits and says when it
/// stopped, so one call can never swallow the context window on its own.
const int maximumDocumentReadLength = 3000;

/// One document's text, ready for the model.
class LocalDocumentRead {
  const LocalDocumentRead({
    required this.name,
    required this.text,
    required this.truncated,
    required this.totalCharacters,
  });

  final String name;
  final String text;
  final bool truncated;

  /// Length of the whole document, so the model knows how much was left out.
  final int totalCharacters;
}

/// Finds a document by name and joins the chunks already indexed for it.
///
/// Matching is case-insensitive: an exact file name first, then a partial name
/// only when it is unique, so a model that wrote `infra` still finds `infra.md`
/// while an ambiguous `notes` is reported as not found rather than guessing.
/// Only documents the user added to the collection are ever considered.
LocalDocumentRead? readLocalDocument({
  required List<IndexedDocument> documents,
  required String documentName,
}) {
  final needle = documentName.trim().toLowerCase();
  if (needle.isEmpty) return null;

  IndexedDocument? match;
  for (final document in documents) {
    if (document.source.name.toLowerCase() == needle) {
      match = document;
      break;
    }
  }
  match ??= _uniquePartialMatch(documents, needle);
  if (match == null) return null;

  final text = _joinChunks(match);
  if (text.length <= maximumDocumentReadLength) {
    return LocalDocumentRead(
      name: match.source.name,
      text: text,
      truncated: false,
      totalCharacters: text.length,
    );
  }
  return LocalDocumentRead(
    name: match.source.name,
    text: '${text.substring(0, maximumDocumentReadLength)}…',
    truncated: true,
    totalCharacters: text.length,
  );
}

IndexedDocument? _uniquePartialMatch(
  List<IndexedDocument> documents,
  String needle,
) {
  IndexedDocument? found;
  for (final document in documents) {
    if (!document.source.name.toLowerCase().contains(needle)) continue;
    if (found != null) return null;
    found = document;
  }
  return found;
}

String _joinChunks(IndexedDocument document) {
  final parts = <String>[
    for (final chunk in document.chunks)
      if (chunk.text.trim().isNotEmpty) chunk.text.trim(),
  ];
  return parts.join('\n\n');
}

/// Tool: read one document the user added to the active collection.
ToolEntry buildReadDocumentTool({
  required Future<LocalDocumentRead?> Function(String documentName) read,
}) {
  return ToolEntry(
    definition: const ToolDefinition(
      name: 'read_document',
      description:
          'Reads the text of one document the user added to the active '
          'knowledge collection, so its details can be discussed. Read-only; '
          'a very long document is truncated.',
      risk: ToolRiskLevel.readOnly,
      timeout: Duration(seconds: 10),
      parameters: [
        ToolParameter(
          name: 'document',
          type: ToolParameterType.string,
          description:
              'Document name, exactly as shown by search_local_documents.',
          maxLength: 200,
        ),
      ],
    ),
    handler: (arguments) async {
      final name = arguments['document'] as String;
      final document = await read(name);

      if (document == null) {
        return 'No document named "$name" is in the active knowledge '
            'collection. Use search_local_documents to find the exact name.';
      }

      final buffer = StringBuffer()
        ..writeln('Document: ${document.name}')
        ..writeln()
        ..write(document.text);
      if (document.truncated) {
        buffer.write(
          '\n\n[Truncated after $maximumDocumentReadLength of '
          '${document.totalCharacters} characters.]',
        );
      }
      return buffer.toString().trimRight();
    },
  );
}
