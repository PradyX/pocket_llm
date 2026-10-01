import 'package:pocket_llm/features/conversations/domain/context_policy.dart'
    show TokenEstimator;
import 'package:pocket_llm/features/documents/domain/document_context.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';

/// Turns retrieved local chunks into a prompt section with citation markers.
///
/// Everything in the section comes from the retriever, so a citation can never
/// describe a document that was not really used. The builder fits as many whole
/// chunks as the budget allows — a chunk is never cut in half, because half a
/// paragraph reads like the whole one and would be quoted as if it were.
class DocumentContextBuilder {
  const DocumentContextBuilder();

  /// Chunks retrieved per request before the budget is applied.
  static const int candidateLimit = 6;

  /// Instructions prepended to the section, charged against the budget.
  static const String instructions =
      'Local documents from this device are listed below. Use them when they '
      'help, cite them as [1], [2] and so on, and say when they do not contain '
      'the answer instead of guessing.';

  /// Charged for the instruction header so it cannot be dropped by the budget.
  static const int _headerTokens = 24;

  /// Per-chunk overhead: the marker line with the file name and heading.
  static const int _blockOverheadTokens = 12;

  /// Message used when documents exist but none matched, so the model does not
  /// quietly answer as if it had consulted them.
  static const String noMatchNotice =
      'No local document chunk matched this question.';

  /// Retrieves for [query] within [tokenBudget] tokens.
  ///
  /// Returns [DocumentContext.empty] when there is nothing to retrieve or no
  /// budget for it.
  DocumentContext build({
    required DocumentRetriever retriever,
    required String query,
    required int tokenBudget,
  }) {
    if (tokenBudget <= 0 || query.trim().isEmpty) return DocumentContext.empty;
    if (retriever.chunkCount == 0) return DocumentContext.empty;

    final candidates = retriever.search(query, limit: candidateLimit);
    if (candidates.isEmpty) {
      final section = '$instructions\n\n$noMatchNotice';
      return DocumentContext(
        section: section,
        hits: const [],
        tokenCount: TokenEstimator.estimateText(section),
      );
    }

    final used = <DocumentSearchHit>[];
    final blocks = <String>[];
    var usedTokens = _headerTokens;

    for (final hit in candidates) {
      final block = _format(hit, used.length + 1);
      final cost = TokenEstimator.estimateText(block) + _blockOverheadTokens;
      // Skip a chunk that does not fit; a later, smaller one may still.
      if (usedTokens + cost > tokenBudget) continue;
      usedTokens += cost;
      used.add(hit);
      blocks.add(block);
    }

    if (used.isEmpty) return DocumentContext.empty;

    final section = '$instructions\n\n${blocks.join('\n\n')}';
    return DocumentContext(
      section: section,
      hits: List.unmodifiable(used),
      tokenCount: usedTokens,
    );
  }

  /// `[1] notes.md · Setup` followed by the chunk text.
  static String _format(DocumentSearchHit hit, int marker) {
    return '[$marker] ${hit.citationLabel}\n${hit.chunk.text.trim()}';
  }
}
