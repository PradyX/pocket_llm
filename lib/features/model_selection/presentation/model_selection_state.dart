import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

class DownloadProgress {
  final int received;
  final int total;

  DownloadProgress({required this.received, required this.total});

  double get progress => total > 0 ? received / total : 0;
}

class ModelSelectionState {
  static const _unset = Object();

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
    Object? selectedModelId = _unset,
    Map<String, DownloadProgress>? downloadProgress,
    Object? error = _unset,
  }) {
    return ModelSelectionState(
      models: models ?? this.models,
      selectedModelId: selectedModelId == _unset
          ? this.selectedModelId
          : selectedModelId as String?,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      error: error == _unset ? this.error : error as String?,
    );
  }
}
