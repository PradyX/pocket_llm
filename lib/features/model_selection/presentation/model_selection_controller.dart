import 'package:dio/dio.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_state.dart';
import 'package:pocket_llm/storage/secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'model_selection_controller.g.dart';

@riverpod
class ModelSelectionController extends _$ModelSelectionController {
  static const _customModelsStorageKey = 'custom_models_v1';

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
    final customModels = await _loadCustomModels();
    final combinedModels = [...LlmModel.availableModels, ...customModels];

    final updatedModels = await Future.wait(
      combinedModels.map((model) async {
        final fileName = model.localFileName;
        if (fileName == null || fileName.isEmpty) return model;
        final isDownloaded = await _storageService.isModelDownloaded(fileName);
        return model.copyWith(isDownloaded: isDownloaded);
      }),
    );

    String? newSelectedId = state.selectedModelId;
    if (newSelectedId != null &&
        !updatedModels.any((m) => m.id == newSelectedId)) {
      newSelectedId = null;
    }
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
      await _persistCustomModels(updatedModels);
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
        error: 'Failed to download ${model.name}: ${_friendlyDownloadError(e)}',
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

  Future<void> addCustomModel({
    required String downloadUrl,
    required String name,
    required String parameterSize,
    String? description,
  }) async {
    final normalizedUrl = downloadUrl.trim();
    final uri = Uri.tryParse(normalizedUrl);
    final normalizedName = name.trim();
    final normalizedSize = parameterSize.trim().toUpperCase();

    if (normalizedUrl.isEmpty ||
        uri == null ||
        !uri.hasAbsolutePath ||
        !(uri.scheme == 'http' || uri.scheme == 'https')) {
      state = state.copyWith(
        error: 'Please provide a valid direct model link (http/https).',
      );
      return;
    }

    if (normalizedName.isEmpty) {
      state = state.copyWith(error: 'Model name is required.');
      return;
    }

    if (!_isValidParameterSize(normalizedSize)) {
      state = state.copyWith(
        error: 'Parameter size is required (format: 1.5B, 800M, 360M).',
      );
      return;
    }

    final localFileName = _deriveLocalFileName(uri);
    if (state.models.any(
      (m) =>
          m.downloadUrl == normalizedUrl ||
          (m.localFileName != null && m.localFileName == localFileName),
    )) {
      state = state.copyWith(error: 'This model link is already in your list.');
      return;
    }

    final resolvedName = normalizedName;
    final resolvedParamSize = normalizedSize;
    final resolvedDescription = (description ?? '').trim().isNotEmpty
        ? description!.trim()
        : 'User-added model from custom download link.';
    final id =
        'custom-${_slugify(resolvedName)}-${DateTime.now().millisecondsSinceEpoch}';

    final isDownloaded = await _storageService.isModelDownloaded(localFileName);
    final model = LlmModel(
      id: id,
      name: resolvedName,
      parameterSize: resolvedParamSize,
      description: resolvedDescription,
      downloadUrl: normalizedUrl,
      localFileName: localFileName,
      isDownloaded: isDownloaded,
      isCustom: true,
    );

    final updatedModels = [...state.models, model];
    state = state.copyWith(models: updatedModels, error: null);
    await _persistCustomModels(updatedModels);
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
      await _persistCustomModels(updatedModels);
    } catch (e) {
      state = state.copyWith(
        error: 'Failed to delete ${model.name}: ${_friendlyDownloadError(e)}',
      );
    }
  }

  Future<List<LlmModel>> _loadCustomModels() async {
    try {
      final data = await SecureStorage.instance.read(_customModelsStorageKey);
      final raw = data?['models'];
      if (raw is! List) return const [];

      final models = <LlmModel>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final model = LlmModel.fromJson(Map<String, dynamic>.from(entry));
        if (model.downloadUrl == null ||
            model.downloadUrl!.trim().isEmpty ||
            model.localFileName == null ||
            model.localFileName!.trim().isEmpty) {
          continue;
        }
        models.add(model.copyWith(isCustom: true));
      }
      return models;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistCustomModels(List<LlmModel> models) async {
    final encoded = models
        .where((m) => m.isCustom)
        .map((m) => m.toJson())
        .toList();
    await SecureStorage.instance.write(
      key: _customModelsStorageKey,
      value: {'models': encoded},
    );
  }

  String _friendlyDownloadError(Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 401 || code == 403) {
        return 'HTTP $code from host. Link may be private or blocked. Use a public direct .gguf URL.';
      }
      if (code == 404) {
        return 'Model file not found (404). Verify the URL and filename.';
      }
      if (code != null) {
        return 'Network request failed (HTTP $code).';
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return 'Connection timed out. Check network and retry.';
      }
      return error.message ?? 'Unexpected network error.';
    }
    return error.toString();
  }

  String _deriveLocalFileName(Uri uri) {
    final lastSegment = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last
        : '';
    final fileName = lastSegment.isEmpty
        ? 'custom-${DateTime.now().millisecondsSinceEpoch}.gguf'
        : lastSegment;
    return fileName.toLowerCase().endsWith('.gguf')
        ? fileName
        : '$fileName.gguf';
  }

  String _slugify(String text) {
    final slug = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'model' : slug;
  }

  bool _isValidParameterSize(String value) {
    return RegExp(r'^[0-9]*\.?[0-9]+\s*[KMBT]$').hasMatch(value);
  }
}
