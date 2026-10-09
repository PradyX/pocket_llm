/// An embedding model that is installed on this device.
///
/// The document pipeline never searches the model list itself: the caller that
/// knows which models are installed resolves one of these and hands it over, so
/// indexing stays testable without a catalog and the library cannot download
/// anything by accident.
///
/// [id] is the value stored on a `KnowledgeCollection` and recorded on every
/// document it indexed, so a different model is a detectable change rather than
/// a silent mix of two vector spaces.
class EmbeddingModelRef {
  const EmbeddingModelRef({
    required this.id,
    required this.path,
    this.dimensions,
    this.maxInputTokens = 512,
    this.batchSize = 4,
    this.threads,
  });

  /// Stable id of the model, e.g. `bge-small-en-v1.5-q8`.
  final String id;

  /// Absolute path of the model's GGUF file.
  final String path;

  /// Expected width of one vector, or null to accept what the model produces.
  ///
  /// Read from the model's own GGUF metadata where possible: it is what makes a
  /// vector built by another model detectable before it is mixed into an index.
  final int? dimensions;

  /// Tokens one text may use; longer text is bounded by the engine.
  final int maxInputTokens;

  /// Texts embedded in one pass.
  final int batchSize;

  /// Compute threads, or null for the runtime default.
  final int? threads;

  bool sameAs(EmbeddingModelRef other) => id == other.id && path == other.path;

  @override
  String toString() => 'EmbeddingModelRef($id, $path)';
}
