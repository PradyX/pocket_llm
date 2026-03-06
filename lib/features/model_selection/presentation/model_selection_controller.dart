import 'package:flutter_base_app/features/model_selection/domain/llm_model.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'model_selection_controller.g.dart';

@riverpod
class ModelSelectionController extends _$ModelSelectionController {
  @override
  LlmModel build() {
    // Default to the first available model.
    return LlmModel.availableModels.first;
  }

  /// Select a specific model.
  void selectModel(LlmModel model) {
    state = model;
  }
}
