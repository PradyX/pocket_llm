import 'package:pocket_llm/features/documents/domain/document.dart';

/// One chunk returned by a retrieval query.
class DocumentSearchHit {
  const DocumentSearchHit({
    required this.documentId,
    required this.documentName,
    required this.chunk,
    required this.score,
    this.matchedTerms = const {},
  });

  final String documentId;

  /// File name shown in citations.
  final String documentName;

  final DocumentChunk chunk;

  /// Higher is better; scores are only comparable within a single query.
  final double score;

  /// Query terms this chunk matched, so a response can explain why a source
  /// was used instead of asking the user to trust it.
  final Set<String> matchedTerms;

  /// Stable id of the retrieved chunk, used to deduplicate prompt context and
  /// to point a citation at an exact place in the text.
  String get chunkId => chunk.idFor(documentId);

  /// Short label for citation lines, e.g. `notes.md · Setup`.
  String get citationLabel {
    final heading = chunk.heading?.trim();
    if (heading == null || heading.isEmpty) return documentName;
    return '$documentName · $heading';
  }
}

/// Read-only retrieval over the local document index.
///
/// A lexical (BM25) implementation ships first because it needs no model
/// download and runs offline; an embedding-backed implementation can replace it
/// without changing ingestion or prompt assembly.
abstract interface class DocumentRetriever {
  /// Number of documents currently indexed.
  int get documentCount;

  /// Number of retrievable chunks currently indexed.
  int get chunkCount;

  /// Number of retrievable chunks indexed for one knowledge collection.
  int chunkCountIn(String collectionId);

  /// Replaces the indexed corpus. Implementations must accept an empty list.
  void rebuild(List<IndexedDocument> documents);

  /// Returns the best matching chunks for [query], best first.
  ///
  /// When [collectionId] is set, only that knowledge collection is searched and
  /// ranking statistics are computed from it.
  List<DocumentSearchHit> search(
    String query, {
    int limit = 5,
    String? collectionId,
  });
}
