import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Vectors one document's chunks were embedded into.
///
/// Derived data, stored with the document's index and never with the original
/// file: removing a document or a collection forgets these vectors, and the file
/// the user pointed at is untouched. Each vector is kept next to the chunk
/// position it belongs to, so a stored index can be read back without the model
/// that produced it.
class DocumentVectors {
  DocumentVectors({
    required this.dimensions,
    required Map<int, Float32List> chunkVectors,
  }) : chunkVectors = Map.unmodifiable(chunkVectors);

  /// Width of every vector here, so a mismatch is detectable without decoding.
  final int dimensions;

  /// Chunk position inside the document -> vector.
  final Map<int, Float32List> chunkVectors;

  int get count => chunkVectors.length;

  bool get isEmpty => chunkVectors.isEmpty;

  Float32List? vectorFor(int chunkIndex) => chunkVectors[chunkIndex];

  /// Vectors of the chunks the document still has.
  ///
  /// A re-chunked document can keep vectors for positions that no longer exist;
  /// this drops them instead of letting a stale vector answer for new text.
  DocumentVectors limitedTo(int chunkCount) {
    if (chunkVectors.keys.every((index) => index < chunkCount)) return this;
    return DocumentVectors(
      dimensions: dimensions,
      chunkVectors: {
        for (final entry in chunkVectors.entries)
          if (entry.key < chunkCount) entry.key: entry.value,
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'dimensions': dimensions,
    'chunks': {
      for (final entry in chunkVectors.entries)
        '${entry.key}': encodeVector(entry.value),
    },
  };

  /// Reads stored vectors, or null when nothing usable is there.
  ///
  /// Tolerance is per entry: a payload with one unreadable chunk keeps the rest,
  /// and only a payload with no usable vector at all is reported as missing —
  /// which the library treats as "this document needs re-indexing" rather than
  /// as data loss.
  static DocumentVectors? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);

    final declaredDimensions = (map['dimensions'] as num?)?.toInt();
    final rawChunks = map['chunks'];
    if (rawChunks is! Map) return null;

    final decoded = <int, Float32List>{};
    var dimensions = declaredDimensions;
    for (final entry in rawChunks.entries) {
      final index = int.tryParse('${entry.key}');
      if (index == null || index < 0) continue;
      final vector = decodeVector(entry.value, dimensions: dimensions);
      if (vector == null) continue;
      dimensions ??= vector.length;
      if (vector.length != dimensions) continue;
      decoded[index] = vector;
    }

    if (decoded.isEmpty || dimensions == null || dimensions <= 0) return null;
    return DocumentVectors(dimensions: dimensions, chunkVectors: decoded);
  }
}

/// Base64 of a vector's little-endian float32 values.
///
/// The byte order is pinned rather than taken from the host, because an index
/// carried to another device (backup and restore) must decode to the same
/// numbers.
String encodeVector(Float32List vector) {
  final bytes = ByteData(vector.length * 4);
  for (var i = 0; i < vector.length; i++) {
    bytes.setFloat32(i * 4, vector[i], Endian.little);
  }
  return base64Encode(bytes.buffer.asUint8List());
}

/// Decodes [encoded], or null when it is not a vector payload.
///
/// When [dimensions] is given, a payload of any other width is rejected: a
/// vector from a different model must never be ranked against this one's.
Float32List? decodeVector(Object? encoded, {int? dimensions}) {
  if (encoded is! String || encoded.isEmpty) return null;
  final List<int> bytes;
  try {
    bytes = base64Decode(encoded);
  } catch (_) {
    return null;
  }
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final length = bytes.length ~/ 4;
  if (dimensions != null && length != dimensions) return null;

  final view = ByteData.sublistView(Uint8List.fromList(bytes));
  final vector = Float32List(length);
  for (var i = 0; i < length; i++) {
    vector[i] = view.getFloat32(i * 4, Endian.little);
  }
  return vector;
}

/// Cosine similarity between two vectors of equal width.
///
/// Stored vectors are L2-normalized, which is how the embedding engine returns
/// them, so in practice this is a dot product. The scaling is kept because the
/// cost is one pass and it makes the function correct for a vector that was
/// normalized somewhere else.
double cosineSimilarity(Float32List a, Float32List b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return 0;
  final scale = math.sqrt(normA) * math.sqrt(normB);
  if (scale == 0) return 0;
  return dot / scale;
}
