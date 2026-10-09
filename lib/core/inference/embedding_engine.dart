import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocket_llm/core/utils/cancel_token.dart';

/// What to load, and the window one input may use.
///
/// The window is part of the request because it shapes the context the runtime
/// is started with: an embedding model reads a fixed number of tokens per text,
/// and an input longer than that has to be bounded before it is handed to the
/// runtime.
class EmbeddingLoadRequest {
  const EmbeddingLoadRequest({
    required this.modelId,
    required this.modelPath,
    this.dimensions,
    this.maxInputTokens = 512,
    this.batchSize = 4,
    this.threads,
  });

  /// Stable id of the model, recorded in the knowledge index.
  ///
  /// This is the value stored with every document a collection embeds, so a
  /// different model is detected as a change instead of silently mixing two
  /// vector spaces in one index.
  final String modelId;

  /// Absolute path of the embedding model's GGUF file.
  final String modelPath;

  /// Expected width of one vector, or null to accept what the model produces.
  ///
  /// When set, a model that answers with a different width fails the load
  /// rather than filling the index with vectors the stored dimensions
  /// contradict.
  final int? dimensions;

  /// Tokens one input may use. Longer inputs are bounded before embedding.
  final int maxInputTokens;

  /// Texts embedded in one pass. Also the number of sequences the runtime is
  /// started with, so it drives the memory a batch costs.
  final int batchSize;

  /// Compute threads, or null for the runtime's own default.
  final int? threads;
}

/// Turns text into vectors on this device.
///
/// This is the second half of local retrieval, next to `InferenceEngine`: chat
/// needs a context that generates, embeddings need one that pools hidden
/// states, and a runtime started for one of them cannot serve the other. Keeping
/// them apart is what lets a small embedding model and a chat model be resident
/// without either interfering with the other.
///
/// Nothing here downloads anything: a caller that wants vectors names a model
/// already on disk. See `EmbeddingCapability`-style reporting on the concrete
/// service for whether the build can embed at all.
abstract interface class EmbeddingEngine {
  /// True while an embedding model is resident.
  bool get isLoaded;

  /// Id of the resident model as given to [load], or null when nothing is
  /// loaded.
  String? get loadedModelId;

  /// Width of the vectors this model produces, or null while it is not known.
  int? get dimensions;

  /// Loads [request]'s model, replacing anything already resident.
  Future<void> load(EmbeddingLoadRequest request);

  /// Releases the resident model. Safe to call when nothing is loaded.
  Future<void> unload();

  /// One vector per text of [texts], in the same order.
  ///
  /// Vectors are L2-normalized, so a cosine similarity is a dot product and a
  /// stored index never has to renormalize. Inputs are bounded to the loaded
  /// model's window; the text itself is never modified by the caller.
  ///
  /// Throws when no model is loaded. [cancelToken] is checked between batches,
  /// which is the granularity the runtime allows.
  Future<List<Float32List>> embed(
    List<String> texts, {
    CancelToken? cancelToken,
  });
}

/// Cosine similarity between two vectors of equal width.
///
/// Both operands are expected to be L2-normalized (which is how the engine
/// returns them), so this is the dot product; the fallback keeps the function
/// honest for vectors that were normalized elsewhere.
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
