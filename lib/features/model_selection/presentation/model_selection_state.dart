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
  final Set<ModelCapability> selectedCapabilityFilters;
  final bool prioritizeDownloadedModels;
  final String searchQuery;
  final Map<String, DownloadProgress> downloadProgress;
  final String? error;
  final int? freeStorageBytes;
  final int? totalStorageBytes;

  ModelSelectionState({
    required this.models,
    this.selectedModelId,
    this.selectedCapabilityFilters = const {},
    this.prioritizeDownloadedModels = false,
    this.searchQuery = '',
    this.downloadProgress = const {},
    this.error,
    this.freeStorageBytes,
    this.totalStorageBytes,
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
    Set<ModelCapability>? selectedCapabilityFilters,
    bool? prioritizeDownloadedModels,
    String? searchQuery,
    Map<String, DownloadProgress>? downloadProgress,
    Object? error = _unset,
    Object? freeStorageBytes = _unset,
    Object? totalStorageBytes = _unset,
  }) {
    return ModelSelectionState(
      models: models ?? this.models,
      selectedModelId: selectedModelId == _unset
          ? this.selectedModelId
          : selectedModelId as String?,
      selectedCapabilityFilters:
          selectedCapabilityFilters ?? this.selectedCapabilityFilters,
      prioritizeDownloadedModels:
          prioritizeDownloadedModels ?? this.prioritizeDownloadedModels,
      searchQuery: searchQuery ?? this.searchQuery,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      error: error == _unset ? this.error : error as String?,
      freeStorageBytes: freeStorageBytes == _unset
          ? this.freeStorageBytes
          : freeStorageBytes as int?,
      totalStorageBytes: totalStorageBytes == _unset
          ? this.totalStorageBytes
          : totalStorageBytes as int?,
    );
  }
}
