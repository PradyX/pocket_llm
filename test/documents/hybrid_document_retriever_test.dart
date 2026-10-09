import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/documents/data/hybrid_document_retriever.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_vectors.dart';

void main() {
  DocumentSource sourceFor(String id, String name) => DocumentSource(
    id: id,
    path: '/tmp/$name',
    name: name,
    format: DocumentFormat.text,
    sizeBytes: 10,
    modifiedAt: DateTime(2026, 3, 1),
    addedAt: DateTime(2026, 3, 1),
  );

  IndexedDocument documentWith(
    String id,
    String name,
    List<String> texts, {
    String collectionId = defaultCollectionId,
  }) {
    return IndexedDocument(
      source: sourceFor(id, name),
      collectionId: collectionId,
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

  DocumentVectors vectors(Map<int, List<double>> byChunk) {
    final dimensions = byChunk.values.first.length;
    return DocumentVectors(
      dimensions: dimensions,
      chunkVectors: {
        for (final entry in byChunk.entries)
          entry.key: Float32List.fromList(entry.value),
      },
    );
  }

  /// `docker` and `gardening` are two directions of one plane, so a query
  /// vector points at them.
  final dockerAxis = Float32List.fromList([1, 0]);
  final gardenAxis = Float32List.fromList([0, 1]);

  /// Between the two, so both chunks score above zero and the *ordering*
  /// matters rather than the floor.
  final tiltedAxis = Float32List.fromList([0.8, 0.6]);

  late HybridDocumentRetriever retriever;
  late IndexedDocument dockerDoc;
  late IndexedDocument gardenDoc;

  setUp(() {
    retriever = HybridDocumentRetriever();
    dockerDoc = documentWith('doc-1', 'docker.md', [
      'The docker engine keeps every image local.',
    ]);
    gardenDoc = documentWith('doc-2', 'garden.md', [
      'Tomatoes need sun and water.',
    ]);
  });

  group('without vectors', () {
    test('ranks exactly like lexical search', () {
      retriever.rebuild([dockerDoc, gardenDoc]);

      final hits = retriever.search('docker');
      final lexicalOnly = HybridDocumentRetriever()
        ..rebuild([dockerDoc, gardenDoc]);

      expect(hits, hasLength(1));
      expect(hits.single.documentName, 'docker.md');
      expect(
        hits.single.score,
        lexicalOnly.search('docker').single.score,
        reason: 'Fusion must not change a ranking it took no part in.',
      );
      expect(hits.single.matchedTerms, contains('docker'));
      expect(retriever.vectorCountIn(defaultCollectionId), 0);
    });

    test('a query vector without stored vectors changes nothing', () {
      retriever.rebuild([dockerDoc, gardenDoc]);

      final hits = retriever.search('docker', queryVector: dockerAxis);

      expect(hits, hasLength(1));
      expect(hits.single.documentName, 'docker.md');
    });
  });

  group('with stored vectors', () {
    setUp(() {
      retriever.rebuild(
        [dockerDoc, gardenDoc],
        vectors: {
          'doc-1': vectors({
            0: [1, 0],
          }),
          'doc-2': vectors({
            0: [0, 1],
          }),
        },
      );
    });

    test('counts the vectors it can rank, per collection', () {
      expect(retriever.vectorCountIn(defaultCollectionId), 2);
      expect(retriever.vectorCountIn('collection-other'), 0);
    });

    test('finds a chunk no query term appears in', () {
      // No shared word with either chunk, so only the vector channel can
      // answer — which is the point of adding one.
      final hits = retriever.search(
        'kubernetes orchestration',
        queryVector: dockerAxis,
      );

      expect(hits, isNotEmpty);
      expect(hits.first.documentName, 'docker.md');
      expect(hits.first.matchedTerms, isEmpty);
    });

    test('keeps the lexical hit first and adds the semantic one after it', () {
      final hits = retriever.search('docker', queryVector: tiltedAxis);

      expect(hits.map((hit) => hit.documentName).toList(), [
        'docker.md',
        'garden.md',
      ]);
      expect(
        hits.first.matchedTerms,
        contains('docker'),
        reason: 'A chunk both channels found keeps its lexical explanation.',
      );
    });

    test('a chunk both channels rank highly beats a single-channel winner', () {
      final first = documentWith('doc-1', 'first.md', ['alpha beta']);
      final second = documentWith('doc-2', 'second.md', ['alpha gamma']);
      final third = documentWith('doc-3', 'third.md', ['beta delta']);

      // Lexical: first, second. Vector: second, third. The chunk both channels
      // know about has to win.
      retriever.rebuild(
        [first, second, third],
        vectors: {
          'doc-1': vectors({
            0: [0, 1],
          }),
          'doc-2': vectors({
            0: [1, 0],
          }),
          'doc-3': vectors({
            0: [0.9, 0.1],
          }),
        },
      );

      final hits = retriever.search('alpha', queryVector: dockerAxis);

      expect(hits.first.documentName, 'second.md');
    });

    test('searches only the requested collection', () {
      final other = documentWith('doc-3', 'other.md', [
        'docker',
      ], collectionId: 'collection-work');
      retriever.rebuild(
        [dockerDoc, gardenDoc, other],
        vectors: {
          'doc-1': vectors({
            0: [1, 0],
          }),
          'doc-2': vectors({
            0: [0, 1],
          }),
          'doc-3': vectors({
            0: [1, 0],
          }),
        },
      );

      final hits = retriever.search(
        'kubernetes',
        collectionId: 'collection-work',
        queryVector: dockerAxis,
      );

      expect(hits, hasLength(1));
      expect(hits.single.documentName, 'other.md');
    });

    test('ignores a vector whose width does not match the stored set', () {
      // A two-wide vector in a three-wide document cannot be compared with a
      // three-wide query, so it is skipped rather than scored.
      retriever.rebuild(
        [dockerDoc],
        vectors: {
          'doc-1': DocumentVectors(
            dimensions: 3,
            chunkVectors: {
              0: Float32List.fromList([1, 0]),
            },
          ),
        },
      );

      expect(retriever.search('kubernetes', queryVector: dockerAxis), isEmpty);
    });

    test('respects the limit and stays deterministic across calls', () {
      retriever.rebuild(
        [
          documentWith('doc-1', 'a.md', ['alpha']),
          documentWith('doc-2', 'b.md', ['alpha']),
          documentWith('doc-3', 'c.md', ['alpha']),
        ],
        vectors: {
          'doc-1': vectors({
            0: [1, 0],
          }),
          'doc-2': vectors({
            0: [0.9, 0.1],
          }),
          'doc-3': vectors({
            0: [0.8, 0.2],
          }),
        },
      );

      final firstRun = retriever.search(
        'alpha',
        limit: 2,
        queryVector: dockerAxis,
      );
      final secondRun = retriever.search(
        'alpha',
        limit: 2,
        queryVector: dockerAxis,
      );

      expect(firstRun, hasLength(2));
      expect(
        firstRun.map((hit) => hit.chunkId).toList(),
        secondRun.map((hit) => hit.chunkId).toList(),
      );
    });

    test('a rebuilt index drops vectors it no longer has', () {
      // A lexical re-index (no vectors passed) must not leave the previous
      // document's vectors rankable.
      retriever.rebuild([dockerDoc, gardenDoc]);

      expect(retriever.vectorCountIn(defaultCollectionId), 0);
      expect(retriever.search('kubernetes', queryVector: dockerAxis), isEmpty);
    });

    test('an orthogonal chunk is not offered as a source', () {
      final hits = retriever.search('zzzz', queryVector: gardenAxis);

      // The garden chunk is the nearest vector and is returned; the docker one
      // sits at cosine zero, which means it has nothing in common with the
      // question and must not be cited for it.
      expect(hits, hasLength(1));
      expect(hits.single.documentName, 'garden.md');
    });
  });
}
