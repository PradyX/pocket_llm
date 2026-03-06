import 'package:flutter_base_app/features/model_selection/domain/llm_model.dart';

class ModelSelectionState {
  final List<LlmModel> models;
  final String selectedModelId;
  final Map<String, double> downloadProgress;

  ModelSelectionState({
    required this.models,
    required this.selectedModelId,
    this.downloadProgress = const {},
  });

  LlmModel get selectedModel =>
      models.firstWhere((m) => m.id == selectedModelId);

  ModelSelectionState copyWith({
    List<LlmModel>? models,
    String? selectedModelId,
    Map<String, double>? downloadProgress,
  }) {
    return ModelSelectionState(
      models: models ?? this.models,
      selectedModelId: selectedModelId ?? this.selectedModelId,
      downloadProgress: downloadProgress ?? this.downloadProgress,
    );
  }
}
