import 'dart:convert';

import 'package:pocket_llm/features/documents/domain/document.dart';

/// Fingerprint of normalized document text, used to skip re-indexing when a
/// file's bytes changed without its text changing.
///
/// Two 32-bit FNV-1a passes with different seeds are combined into 16 hex
/// characters. The value only has to be stable across runs of this app, which
/// is exactly what a local cache key needs; it is not a security hash.
String documentContentHash(String text) {
  final bytes = utf8.encode(text);
  return '${_hex(_fnv1a(bytes, 0x811c9dc5))}${_hex(_fnv1a(bytes, 0x7f4a7c15))}';
}

int _fnv1a(List<int> bytes, int seed) {
  var hash = seed & 0xffffffff;
  for (final byte in bytes) {
    hash = (hash ^ (byte & 0xff)) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

String _hex(int value) => value.toRadixString(16).padLeft(8, '0');

/// Why [document] must be re-indexed under the current pipeline, or null when
/// its stored index is still usable.
///
/// Stored documents record how they were built (chunking settings, pipeline
/// version, retrieval backend), so a change in any of those is detectable
/// without re-reading the original file. Whether the *file* changed is checked
/// separately against its size and timestamp.
String? documentReindexReason(
  IndexedDocument document, {
  required DocumentChunkingConfig chunking,
  String? embeddingModelId,
  int? embeddingDimensions,
}) {
  if (document.chunkerVersion != documentChunkerVersion) {
    return 'the document pipeline changed';
  }
  if (!document.chunking.sameAs(chunking)) {
    return 'the chunking settings changed';
  }
  if (document.embeddingModelId != embeddingModelId) {
    return 'the retrieval backend changed';
  }
  if (embeddingModelId != null &&
      document.embeddingDimensions != embeddingDimensions) {
    return 'the embedding dimensions changed';
  }
  return null;
}
