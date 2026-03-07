import 'package:dio/dio.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_state.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'model_selection_controller.g.dart';

@riverpod
class ModelSelectionController extends _$ModelSelectionController {
  late final ModelStorageService _storageService = ModelStorageService();
  final Map<String, CancelToken> _cancelTokens = {};

  @override
  ModelSelectionState build() {
    state = ModelSelectionState(
      models: LlmModel.availableModels,
      selectedModelId: null, // Start with no selection
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

    String? newSelectedId = state.selectedModelId;
    // If nothing is selected, try to pick the first downloaded one
    if (newSelectedId == null) {
      try {
        newSelectedId = updatedModels.firstWhere((m) => m.isDownloaded).id;
      } catch (_) {
        newSelectedId = null;
      }
    }

    state = state.copyWith(
      models: updatedModels,
      selectedModelId: newSelectedId,
    );
  }

  /// Select a specific model.
  void selectModel(LlmModel model) {
    if (model.isDownloaded) {
      state = state.copyWith(selectedModelId: model.id);
    }
  }

  Future<void> downloadModel(LlmModel model) async {
    if (model.downloadUrl == null || model.localFileName == null) return;

    // Initialize progress if it doesn't exist (to support resume)
    if (!state.downloadProgress.containsKey(model.id)) {
      state = state.copyWith(
        downloadProgress: {
          ...state.downloadProgress,
          model.id: DownloadProgress(received: 0, total: 0),
        },
      );
    }

    final cancelToken = CancelToken();
    _cancelTokens[model.id] = cancelToken;

    try {
      await _storageService.downloadModel(
        model.downloadUrl!,
        model.localFileName!,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          state = state.copyWith(
            downloadProgress: {
              ...state.downloadProgress,
              model.id: DownloadProgress(received: received, total: total),
            },
          );
        },
      );

      _cancelTokens.remove(model.id);

      // Download complete, update model status and remove progress
      final updatedModels = state.models
          .map((m) => m.id == model.id ? m.copyWith(isDownloaded: true) : m)
          .toList();

      final Map<String, DownloadProgress> updatedProgress = Map.of(
        state.downloadProgress,
      );
      updatedProgress.remove(model.id);

      state = state.copyWith(
        models: updatedModels,
        downloadProgress: updatedProgress,
        selectedModelId: state.selectedModelId ?? model.id,
      );
    } catch (e) {
      _cancelTokens.remove(model.id);

      if (e is DioException && CancelToken.isCancel(e)) {
        // Just return, keep progress in state so it shows as paused
        return;
      }

      // Remove progress on error and set error message
      final Map<String, DownloadProgress> updatedProgress = Map.of(
        state.downloadProgress,
      );
      updatedProgress.remove(model.id);
      state = state.copyWith(
        downloadProgress: updatedProgress,
        error: 'Failed to download ${model.name}: ${e.toString()}',
      );
    }
  }

  void pauseDownload(String modelId) {
    _cancelTokens[modelId]?.cancel();
    _cancelTokens.remove(modelId);
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  Future<void> deleteModel(LlmModel model) async {
    if (model.localFileName == null) return;

    try {
      await _storageService.deleteModel(model.localFileName!);

      // Update model status in state
      final updatedModels = state.models
          .map((m) => m.id == model.id ? m.copyWith(isDownloaded: false) : m)
          .toList();

      // If the deleted model was selected, clear selection
      String? newSelectedId = state.selectedModelId;
      if (newSelectedId == model.id) {
        newSelectedId = null;
        // Try to auto-select another downloaded model
        try {
          newSelectedId = updatedModels.firstWhere((m) => m.isDownloaded).id;
        } catch (_) {
          newSelectedId = null;
        }
      }

      state = state.copyWith(
        models: updatedModels,
        selectedModelId: newSelectedId,
      );
    } catch (e) {
      state = state.copyWith(
        error: 'Failed to delete ${model.name}: ${e.toString()}',
      );
    }
  }
}
