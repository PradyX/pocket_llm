import 'dart:typed_data';

import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_vectors.dart';

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
  ///
  /// The number means whatever the retriever that produced it ranks by: a BM25
  /// weight, a cosine similarity, or — when lexical and vector hits are fused —
  /// a reciprocal rank sum, which is a small number near zero by design. Read it
  /// as an ordering, never as a quality percentage.
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
/// download and runs offline; an embedding-backed implementation ranks the same
/// corpus by vector similarity without changing ingestion or prompt assembly.
///
/// A vector backend needs something no retriever can produce by itself: the
/// *query* has to be embedded by the same model that embedded the chunks, and
/// only the caller owns a model. That is why [search] accepts a query vector
/// ([queryVector]) and [rebuild] accepts stored vectors — a lexical-only
/// implementation simply ignores both.
abstract interface class DocumentRetriever {
  /// Number of documents currently indexed.
  int get documentCount;

  /// Number of retrievable chunks currently indexed.
  int get chunkCount;

  /// Number of retrievable chunks indexed for one knowledge collection.
  int chunkCountIn(String collectionId);

  /// Replaces the indexed corpus. Implementations must accept an empty list.
  ///
  /// [vectors] are the stored vectors of those documents, keyed by document id;
  /// a retriever without a vector backend ignores them.
  void rebuild(
    List<IndexedDocument> documents, {
    Map<String, DocumentVectors> vectors = const {},
  });

  /// Returns the best matching chunks for [query], best first.
  ///
  /// When [collectionId] is set, only that knowledge collection is searched and
  /// ranking statistics are computed from it.
  ///
  /// [queryVector] is the embedded [query], when the caller has one: a vector
  /// backend cannot search without it, and a backend that needs it returns
  /// nothing rather than guessing.
  List<DocumentSearchHit> search(
    String query, {
    int limit = 5,
    String? collectionId,
    Float32List? queryVector,
  });

  /// Number of stored vectors this retriever can rank for [collectionId].
  ///
  /// Zero means the collection is answered lexically: either it never asked for
  /// embeddings or its vectors are not readable.
  int vectorCountIn(String collectionId);
}
