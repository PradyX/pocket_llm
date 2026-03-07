import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

class DownloadProgress {
  final int received;
  final int total;

  DownloadProgress({required this.received, required this.total});

  double get progress => total > 0 ? received / total : 0;
}

class ModelSelectionState {
  final List<LlmModel> models;
  final String? selectedModelId;
  final Map<String, DownloadProgress> downloadProgress;
  final String? error;

  ModelSelectionState({
    required this.models,
    this.selectedModelId,
    this.downloadProgress = const {},
    this.error,
  });

  LlmModel? get selectedModel {
    if (selectedModelId == null) return null;
    try {
      return models.firstWhere((m) => m.id == selectedModelId);
    } catch (_) {
      return null;
    }
  }

  ModelSelectionState copyWith({
    List<LlmModel>? models,
    String? selectedModelId,
    Map<String, DownloadProgress>? downloadProgress,
    String? error,
  }) {
    return ModelSelectionState(
      models: models ?? this.models,
      selectedModelId: selectedModelId ?? this.selectedModelId,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      error: error,
    );
  }
}
