import 'package:flutter_base_app/core/services/model_storage_service.dart';
import 'package:flutter_base_app/features/model_selection/domain/llm_model.dart';
import 'package:flutter_base_app/features/model_selection/presentation/model_selection_state.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'model_selection_controller.g.dart';

@riverpod
class ModelSelectionController extends _$ModelSelectionController {
  late final ModelStorageService _storageService = ModelStorageService();

  @override
  ModelSelectionState build() {
    state = ModelSelectionState(
      models: LlmModel.availableModels,
      selectedModelId: LlmModel.availableModels.first.id,
    );
    _init();
    return state;
  }

  Future<void> _init() async {
    final updatedModels = await Future.wait(
      state.models.map((model) async {
        final isDownloaded = await _storageService.isModelDownloaded(
          model.localFileName!,
        );
        return model.copyWith(isDownloaded: isDownloaded);
      }),
    );
    state = state.copyWith(models: updatedModels);
  }

  /// Select a specific model.
  void selectModel(LlmModel model) {
    if (model.isDownloaded) {
      state = state.copyWith(selectedModelId: model.id);
    }
  }

  Future<void> downloadModel(LlmModel model) async {
    if (model.downloadUrl == null || model.localFileName == null) return;

    // Initialize progress at 0
    state = state.copyWith(
      downloadProgress: {...state.downloadProgress, model.id: 0.0},
    );

    try {
      await _storageService.downloadModel(
        model.downloadUrl!,
        model.localFileName!,
        onProgress: (received, total) {
          if (total != -1) {
            final progress = received / total;
            state = state.copyWith(
              downloadProgress: {...state.downloadProgress, model.id: progress},
            );
          }
        },
      );

      // Download complete, update model status and remove progress
      final updatedModels = state.models
          .map((m) => m.id == model.id ? m.copyWith(isDownloaded: true) : m)
          .toList();

      final Map<String, double> updatedProgress = Map.of(
        state.downloadProgress,
      );
      updatedProgress.remove(model.id);

      state = state.copyWith(
        models: updatedModels,
        downloadProgress: updatedProgress,
      );
    } catch (e) {
      // Remove progress on error
      final Map<String, double> updatedProgress = Map.of(
        state.downloadProgress,
      );
      updatedProgress.remove(model.id);
      state = state.copyWith(downloadProgress: updatedProgress);
    }
  }
}
