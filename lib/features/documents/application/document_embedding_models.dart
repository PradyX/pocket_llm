import 'dart:io';
import 'dart:math' as math;

import 'package:pocket_llm/features/documents/domain/embedding_model_ref.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

/// Resolves the embedding model a collection pins to something loadable.
///
/// The document pipeline is deliberately ignorant of the model catalog: this is
/// the one place that knows an embedding model is an `LlmModel`, so indexing,
/// the question path and the screen all agree on what "installed" means. It
/// never downloads anything — a model that is not on disk resolves to null and
/// the caller says so.
class DocumentEmbeddingModels {
  const DocumentEmbeddingModels({
    required this.models,
    required this.resolvePath,
  });

  /// Every model the app knows about, installed or not.
  final List<LlmModel> models;

  /// Resolves a model's main file, or null when it has none.
  final Future<String?> Function(LlmModel model) resolvePath;

  /// Widest window an embedding model is loaded with.
  ///
  /// A wider window is not free: the runtime keeps a KV cache of
  /// `window × sequences` for the batch, so this bounds what one load costs
  /// (roughly `window × batch × layers` worth of cache).
  static const int maxWindowTokens = 1024;

  /// Token slots one batch may occupy, which is what decides the batch size.
  static const int _batchTokenBudget = 1024;

  /// Models that can turn text into vectors, catalog order.
  List<LlmModel> get embeddingModels =>
      models.where((model) => model.isEmbeddingModel).toList(growable: false);

  /// Embedding models whose file is on this device.
  List<LlmModel> get installedEmbeddingModels =>
      embeddingModels.where((model) => model.isDownloaded).toList();

  LlmModel? modelById(String? embeddingModelId) {
    final id = embeddingModelId?.trim();
    if (id == null || id.isEmpty) return null;
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// True when [embeddingModelId] names a model this device can load now.
  bool isInstalled(String? embeddingModelId) {
    final model = modelById(embeddingModelId);
    if (model == null) return false;
    if (model.isDownloaded) return true;
    // An external reference is "installed" when its file is still where the
    // user keeps it, which the download flag alone cannot answer.
    return model.isExternal;
  }

  /// The loadable model behind a collection's `embeddingModelId`, or null when
  /// no such model is installed.
  Future<EmbeddingModelRef?> resolve(String? embeddingModelId) async {
    final model = modelById(embeddingModelId);
    if (model == null) return null;
    final path = await resolvePath(model);
    if (path == null || path.trim().isEmpty) return null;
    if (!File(path).existsSync()) return null;

    final metadata = model.ggufMetadata;
    final declaredWindow = metadata?.contextLength;
    final window = declaredWindow == null || declaredWindow <= 0
        ? 512
        : declaredWindow.clamp(64, maxWindowTokens);
    return EmbeddingModelRef(
      id: model.id,
      path: path,
      dimensions: metadata?.embeddingLength,
      maxInputTokens: window,
      batchSize: math.max(1, math.min(4, _batchTokenBudget ~/ window)),
    );
  }
}
