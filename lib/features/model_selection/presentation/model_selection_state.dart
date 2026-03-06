import 'package:flutter_base_app/features/model_selection/domain/llm_model.dart';

class ModelSelectionState {
  final List<LlmModel> models;
  final String selectedModelId;
  final Map<String, double> downloadProgress;
  final String? error;

  ModelSelectionState({
    required this.models,
    required this.selectedModelId,
    this.downloadProgress = const {},
    this.error,
  });

  LlmModel get selectedModel =>
      models.firstWhere((m) => m.id == selectedModelId);

  ModelSelectionState copyWith({
    List<LlmModel>? models,
    String? selectedModelId,
    Map<String, double>? downloadProgress,
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
