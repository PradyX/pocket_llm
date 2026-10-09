import 'dart:typed_data';

import 'package:pocket_llm/features/documents/data/lexical_document_retriever.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';
import 'package:pocket_llm/features/documents/domain/document_vectors.dart';

/// Retrieval over the local index, lexical first and semantic when it can be.
///
/// The two channels answer different questions — which chunks contain the
/// query's terms, and which chunks mean the same thing — so their scores live on
/// incomparable scales. They are therefore fused by reciprocal rank rather than
/// by a weighted sum: a chunk both channels rank highly rises, a chunk only one
/// of them knows about still surfaces, and no per-model weight has to be tuned
/// or stored. [rankConstant] is the usual 60, which only decides how much the
/// first few ranks matter relative to the tail.
///
/// When a collection has no stored vectors, or the caller has no query vector
/// (the embedding model is not installed, or embedding failed), the result is
/// exactly the lexical ranking this retriever delegates to. That is deliberate:
/// retrieval is best-effort, and a missing model must not make a collection
/// answer with nothing.
class HybridDocumentRetriever implements DocumentRetriever {
  HybridDocumentRetriever({
    LexicalDocumentRetriever? lexical,
    this.rankConstant = 60,
  }) : _lexical = lexical ?? LexicalDocumentRetriever();

  final LexicalDocumentRetriever _lexical;

  /// Reciprocal-rank-fusion constant.
  final int rankConstant;

  /// Extra candidates each channel returns before fusion, as a multiple of the
  /// requested limit, so a strong hit ranked low by one channel is not cut off
  /// before the other channel can lift it.
  static const int _candidateFactor = 3;

  /// Chunks that have a stored vector, keyed by chunk id.
  final Map<String, _VectorChunk> _vectorChunks = {};

  @override
  int get documentCount => _lexical.documentCount;

  @override
  int get chunkCount => _lexical.chunkCount;

  @override
  int chunkCountIn(String collectionId) => _lexical.chunkCountIn(collectionId);

  @override
  int vectorCountIn(String collectionId) => _vectorChunks.values
      .where((entry) => entry.collectionId == collectionId)
      .length;

  @override
  void rebuild(
    List<IndexedDocument> documents, {
    Map<String, DocumentVectors> vectors = const {},
  }) {
    _lexical.rebuild(documents);
    _vectorChunks.clear();

    for (final document in documents) {
      final stored = vectors[document.id];
      if (stored == null || stored.isEmpty) continue;
      for (final chunk in document.chunks) {
        final vector = stored.vectorFor(chunk.index);
        if (vector == null || vector.isEmpty) continue;
        // A vector from another model would be measuring something else, so a
        // width that does not match this document's own vectors is skipped
        // rather than ranked.
        if (vector.length != stored.dimensions) continue;
        _vectorChunks[chunk.idFor(document.id)] = _VectorChunk(
          collectionId: document.collectionId,
          documentId: document.id,
          documentName: document.source.name,
          chunk: chunk,
          vector: vector,
        );
      }
    }
  }

  @override
  List<DocumentSearchHit> search(
    String query, {
    int limit = 5,
    String? collectionId,
    Float32List? queryVector,
  }) {
    final lexicalHits = _lexical.search(
      query,
      limit: limit * _candidateFactor,
      collectionId: collectionId,
    );
    if (queryVector == null || queryVector.isEmpty) {
      return _take(lexicalHits, limit);
    }

    final vectorHits = _vectorSearch(
      queryVector,
      limit: limit * _candidateFactor,
      collectionId: collectionId,
    );
    if (vectorHits.isEmpty) return _take(lexicalHits, limit);
    if (lexicalHits.isEmpty) return _take(vectorHits, limit);

    return _take(_fuse(lexicalHits, vectorHits), limit);
  }

  static List<DocumentSearchHit> _take(
    List<DocumentSearchHit> hits,
    int limit,
  ) {
    if (limit <= 0) return const [];
    if (hits.length <= limit) return hits;
    return hits.sublist(0, limit);
  }

  /// Cosine ranking over the stored vectors of the searched collection.
  List<DocumentSearchHit> _vectorSearch(
    Float32List queryVector, {
    required int limit,
    String? collectionId,
  }) {
    if (limit <= 0 || _vectorChunks.isEmpty) return const [];

    final scored = <DocumentSearchHit>[];
    for (final entry in _vectorChunks.values) {
      if (collectionId != null && entry.collectionId != collectionId) continue;
      if (entry.vector.length != queryVector.length) continue;
      final score = cosineSimilarity(queryVector, entry.vector);
      // Zero is orthogonal and negative points away: neither is a source for
      // this question. Only the floor is fixed here — how *high* a score has to
      // be before a chunk is useful depends on the model, so that judgement
      // stays with the caller that chose it.
      if (score <= 0) continue;
      scored.add(
        DocumentSearchHit(
          documentId: entry.documentId,
          documentName: entry.documentName,
          chunk: entry.chunk,
          score: score,
        ),
      );
    }
    if (scored.isEmpty) return const [];

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byDocument = a.documentId.compareTo(b.documentId);
      if (byDocument != 0) return byDocument;
      return a.chunk.index.compareTo(b.chunk.index);
    });

    return scored.length <= limit ? scored : scored.sublist(0, limit);
  }

  /// Merges both rankings, best first, by summed reciprocal rank.
  List<DocumentSearchHit> _fuse(
    List<DocumentSearchHit> lexicalHits,
    List<DocumentSearchHit> vectorHits,
  ) {
    final fused = <String, _FusedHit>{};

    for (var rank = 0; rank < lexicalHits.length; rank++) {
      final hit = lexicalHits[rank];
      fused
          .putIfAbsent(hit.chunkId, () => _FusedHit(hit))
          .addRank(
            1 / (rankConstant + rank + 1),
            matchedTerms: hit.matchedTerms,
          );
    }
    for (var rank = 0; rank < vectorHits.length; rank++) {
      final hit = vectorHits[rank];
      fused
          .putIfAbsent(hit.chunkId, () => _FusedHit(hit))
          .addRank(
            1 / (rankConstant + rank + 1),
            matchedTerms: hit.matchedTerms,
          );
    }

    final hits = fused.values.toList(growable: false);
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byDocument = a.hit.documentId.compareTo(b.hit.documentId);
      if (byDocument != 0) return byDocument;
      return a.hit.chunk.index.compareTo(b.hit.chunk.index);
    });
    return [
      for (final entry in hits)
        DocumentSearchHit(
          documentId: entry.hit.documentId,
          documentName: entry.hit.documentName,
          chunk: entry.hit.chunk,
          score: entry.score,
          matchedTerms: entry.matchedTerms,
        ),
    ];
  }
}

/// One chunk that can be ranked by vector similarity.
class _VectorChunk {
  const _VectorChunk({
    required this.collectionId,
    required this.documentId,
    required this.documentName,
    required this.chunk,
    required this.vector,
  });

  final String collectionId;
  final String documentId;
  final String documentName;
  final DocumentChunk chunk;
  final Float32List vector;
}

/// A hit being accumulated across the channels that found it.
class _FusedHit {
  _FusedHit(this.hit) : matchedTerms = hit.matchedTerms;

  final DocumentSearchHit hit;
  double score = 0;
  Set<String> matchedTerms;

  void addRank(double value, {Set<String>? matchedTerms}) {
    score += value;
    if (matchedTerms != null && matchedTerms.isNotEmpty) {
      this.matchedTerms = matchedTerms;
    }
  }
}
