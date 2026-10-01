import 'dart:math' as math;

import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';

final RegExp _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);
final RegExp _camelBoundary = RegExp(
  r'(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])',
);

/// Splits [text] into the lowercase terms retrieval works with.
///
/// Words break on anything that is not a letter or a digit, and camelCase
/// boundaries break too, so `requestContextBuilder` is found by a search for
/// `context`. Terms shorter than two characters are dropped as noise.
List<String> retrievalTokens(String text) {
  final tokens = <String>[];
  for (final match in _wordPattern.allMatches(text)) {
    for (final part in match.group(0)!.split(_camelBoundary)) {
      final token = part.toLowerCase();
      if (token.length >= 2) tokens.add(token);
    }
  }
  return tokens;
}

/// Ranks local chunks with Okapi BM25.
///
/// Lexical retrieval is deliberate for the first release: it needs no extra
/// model download, works fully offline, and gives deterministic hits that can
/// report which query terms matched. The [DocumentRetriever] seam means an
/// embedding backend can be added later without touching ingestion, storage or
/// prompt assembly.
///
/// Statistics are computed per search over the chunks actually being searched,
/// so a term that is common in one knowledge collection does not weaken its
/// score in another.
class LexicalDocumentRetriever implements DocumentRetriever {
  LexicalDocumentRetriever({this.k1 = 1.2, this.b = 0.75});

  /// Term-frequency saturation.
  final double k1;

  /// Length-normalization strength.
  final double b;

  final List<_IndexedChunk> _chunks = [];
  final Set<String> _documentIds = {};

  @override
  int get documentCount => _documentIds.length;

  @override
  int get chunkCount => _chunks.length;

  @override
  int chunkCountIn(String collectionId) =>
      _chunks.where((chunk) => chunk.collectionId == collectionId).length;

  @override
  void rebuild(List<IndexedDocument> documents) {
    _chunks.clear();
    _documentIds.clear();

    for (final document in documents) {
      for (final chunk in document.chunks) {
        final terms = retrievalTokens(chunk.text);
        if (terms.isEmpty) continue;

        final frequencies = <String, int>{};
        for (final term in terms) {
          frequencies[term] = (frequencies[term] ?? 0) + 1;
        }

        _chunks.add(
          _IndexedChunk(
            collectionId: document.collectionId,
            documentId: document.id,
            documentName: document.source.name,
            chunk: chunk,
            frequencies: frequencies,
            length: terms.length,
          ),
        );
        _documentIds.add(document.id);
      }
    }
  }

  @override
  List<DocumentSearchHit> search(
    String query, {
    int limit = 5,
    String? collectionId,
  }) {
    if (limit <= 0 || _chunks.isEmpty) return const [];
    final terms = retrievalTokens(query).toSet();
    if (terms.isEmpty) return const [];

    final candidates = collectionId == null
        ? _chunks
        : _chunks
              .where((chunk) => chunk.collectionId == collectionId)
              .toList(growable: false);
    if (candidates.isEmpty) return const [];

    final documentFrequency = <String, int>{};
    var totalLength = 0;
    for (final entry in candidates) {
      totalLength += entry.length;
      for (final term in terms) {
        if (entry.frequencies.containsKey(term)) {
          documentFrequency[term] = (documentFrequency[term] ?? 0) + 1;
        }
      }
    }
    final averageLength = totalLength / candidates.length;

    final scored = <DocumentSearchHit>[];
    for (final entry in candidates) {
      var score = 0.0;
      final matched = <String>{};
      for (final term in terms) {
        final frequency = entry.frequencies[term];
        if (frequency == null) continue;
        matched.add(term);
        final normalization =
            frequency + k1 * (1 - b + b * entry.length / averageLength);
        score +=
            _idf(term, documentFrequency, candidates.length) *
            (frequency * (k1 + 1)) /
            normalization;
      }
      if (score <= 0) continue;

      scored.add(
        DocumentSearchHit(
          documentId: entry.documentId,
          documentName: entry.documentName,
          chunk: entry.chunk,
          score: score,
          matchedTerms: matched,
        ),
      );
    }

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      // Stable ordering keeps repeated queries and tests deterministic.
      final byDocument = a.documentId.compareTo(b.documentId);
      if (byDocument != 0) return byDocument;
      return a.chunk.index.compareTo(b.chunk.index);
    });

    return scored.length <= limit ? scored : scored.sublist(0, limit);
  }

  static double _idf(
    String term,
    Map<String, int> documentFrequency,
    int documentCount,
  ) {
    final frequency = documentFrequency[term] ?? 0;
    return math.log(1 + (documentCount - frequency + 0.5) / (frequency + 0.5));
  }
}

class _IndexedChunk {
  const _IndexedChunk({
    required this.collectionId,
    required this.documentId,
    required this.documentName,
    required this.chunk,
    required this.frequencies,
    required this.length,
  });

  final String collectionId;
  final String documentId;
  final String documentName;
  final DocumentChunk chunk;
  final Map<String, int> frequencies;
  final int length;
}
