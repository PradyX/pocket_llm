import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/documents/domain/document_vectors.dart';

void main() {
  Float32List vector(List<double> values) => Float32List.fromList(values);

  group('vector codec', () {
    test('a vector survives the round trip exactly', () {
      final original = Float32List.fromList([0.5, -1.25, 0, 3.5, 1e-8]);
      final decoded = decodeVector(encodeVector(original));

      expect(decoded, isNotNull);
      expect(decoded!.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(decoded[i], original[i]);
      }
    });

    test('decoding is byte-order pinned, not host order', () {
      // 1.0f as little-endian float32 is 0x0000803F; base64 of those four bytes
      // must decode to 1.0 no matter which machine reads it.
      final encoded = encodeVector(Float32List.fromList([1.0]));
      expect(encoded, 'AACAPw==');
      expect(decodeVector(encoded)!.first, 1.0);
    });

    test('payloads that are not vectors are rejected, not guessed at', () {
      expect(decodeVector(null), isNull);
      expect(decodeVector(''), isNull);
      expect(decodeVector('not base64 !!'), isNull);
      // Three bytes cannot be a whole float.
      expect(decodeVector('AAAA'), isNull);
      expect(decodeVector(42), isNull);
    });

    test('a width expectation rejects vectors from another model', () {
      final encoded = encodeVector(vector([1, 2, 3]));
      expect(decodeVector(encoded, dimensions: 3), isNotNull);
      expect(
        decodeVector(encoded, dimensions: 384),
        isNull,
        reason:
            'A vector from a different model must never be ranked against '
            'this index.',
      );
    });
  });

  group('DocumentVectors', () {
    test('round-trips through JSON with its dimensions', () {
      final stored = DocumentVectors(
        dimensions: 3,
        chunkVectors: {
          0: vector([1, 0, 0]),
          2: vector([0, 1, 0]),
        },
      );

      final restored = DocumentVectors.fromJson(stored.toJson());

      expect(restored, isNotNull);
      expect(restored!.dimensions, 3);
      expect(restored.count, 2);
      expect(restored.vectorFor(0), isNotNull);
      expect(restored.vectorFor(2), isNotNull);
      expect(restored.vectorFor(1), isNull);
    });

    test('one unreadable chunk keeps the rest instead of the whole set', () {
      final restored = DocumentVectors.fromJson({
        'dimensions': 3,
        'chunks': {
          '0': encodeVector(vector([1, 0, 0])),
          '1': 'garbage',
          '2': encodeVector(vector([0, 0, 1])),
          'three': encodeVector(vector([0, 1, 0])),
        },
      });

      expect(restored, isNotNull);
      expect(restored!.count, 2);
      expect(restored.vectorFor(0), isNotNull);
      expect(restored.vectorFor(2), isNotNull);
    });

    test('a wrong-width entry is dropped, not mixed in', () {
      final restored = DocumentVectors.fromJson({
        'dimensions': 3,
        'chunks': {
          '0': encodeVector(vector([1, 0, 0])),
          '1': encodeVector(vector([1, 0])),
        },
      });

      expect(restored!.count, 1);
      expect(restored.vectorFor(1), isNull);
    });

    test('a missing dimensions field is taken from the vectors themselves', () {
      final restored = DocumentVectors.fromJson({
        'chunks': {
          '0': encodeVector(vector([1, 0, 0, 0])),
        },
      });

      expect(restored, isNotNull);
      expect(restored!.dimensions, 4);
    });

    test(
      'nothing usable parses as null, so the document reads as unembedded',
      () {
        expect(DocumentVectors.fromJson(null), isNull);
        expect(DocumentVectors.fromJson({}), isNull);
        expect(DocumentVectors.fromJson({'dimensions': 3}), isNull);
        expect(
          DocumentVectors.fromJson({
            'dimensions': 3,
            'chunks': {'0': 'garbage'},
          }),
          isNull,
        );
      },
    );

    test('limitedTo drops vectors for chunks the document no longer has', () {
      final stored = DocumentVectors(
        dimensions: 2,
        chunkVectors: {
          0: vector([1, 0]),
          1: vector([0, 1]),
          5: vector([1, 1]),
        },
      );

      final limited = stored.limitedTo(2);

      expect(limited.count, 2);
      expect(limited.vectorFor(5), isNull);
      expect(
        stored.vectorFor(5),
        isNotNull,
        reason: 'The original value is not mutated by the narrowing.',
      );
    });
  });

  group('cosine similarity', () {
    test('equal normalized vectors score one', () {
      final a = vector([0.6, 0.8]);
      expect(cosineSimilarity(a, a), closeTo(1, 1e-6));
    });

    test('orthogonal vectors score zero and opposite ones score minus one', () {
      expect(
        cosineSimilarity(vector([1, 0]), vector([0, 1])),
        closeTo(0, 1e-6),
      );
      expect(
        cosineSimilarity(vector([1, 0]), vector([-1, 0])),
        closeTo(-1, 1e-6),
      );
    });

    test('unnormalized vectors are scaled, not misread', () {
      expect(
        cosineSimilarity(vector([2, 4]), vector([1, 2])),
        closeTo(1, 1e-6),
      );
    });

    test('a zero vector, an empty vector or a width mismatch scores zero', () {
      expect(cosineSimilarity(vector([0, 0]), vector([1, 1])), 0);
      expect(cosineSimilarity(Float32List(0), Float32List(0)), 0);
      expect(cosineSimilarity(vector([1, 0]), vector([1, 0, 0])), 0);
    });
  });
}
