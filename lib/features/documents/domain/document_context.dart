import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';

/// Retrieved local document text prepared for one request.
///
/// This is what retrieval produced, not a summary of it: [section] is rendered
/// from [hits] and nothing else, so a caller can always explain what the model
/// was given.
class DocumentContext {
  const DocumentContext({
    required this.section,
    required this.hits,
    required this.tokenCount,
  });

  /// Nothing retrieved: no documents, no usable query, or no budget.
  static const DocumentContext empty = DocumentContext(
    section: '',
    hits: [],
    tokenCount: 0,
  );

  /// Prompt section listing the retrieved chunks, or empty when nothing was
  /// retrieved.
  final String section;

  /// The chunks the section was built from, best first.
  final List<DocumentSearchHit> hits;

  /// Estimated tokens [section] costs.
  final int tokenCount;

  bool get isEmpty => hits.isEmpty && section.isEmpty;

  /// Number of chunks given to the model.
  int get chunkCount => hits.length;

  /// Bits of the section, for the UI and for diagnostics.
  String get summaryLabel => hits.isEmpty
      ? 'No local document chunks'
      : '$chunkCount local chunk${chunkCount == 1 ? '' : 's'}';
}
