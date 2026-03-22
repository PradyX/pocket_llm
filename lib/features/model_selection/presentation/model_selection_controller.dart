import 'dart:async';

import 'package:dio/dio.dart';
import 'package:pocket_llm/core/services/hugging_face_model_capability_service.dart';
import 'package:pocket_llm/core/services/local_notification_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/services/storage_info_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_state.dart';
import 'package:pocket_llm/storage/secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'model_selection_controller.g.dart';

class _ModelDownloadAsset {
  final String url;
  final String fileName;

  const _ModelDownloadAsset({required this.url, required this.fileName});
}

@riverpod
class ModelSelectionController extends _$ModelSelectionController {
  static const _customModelsStorageKey = 'custom_models_v1';
  static const _downloadSafetyBytes = 128 * 1024 * 1024;

  late final ModelStorageService _storageService = ModelStorageService();
  late final StorageInfoService _storageInfoService = StorageInfoService();
  late final LocalNotificationService _notificationService =
      LocalNotificationService.instance;
  late final HuggingFaceModelCapabilityService _capabilityService =
      HuggingFaceModelCapabilityService();
  final Map<String, CancelToken> _cancelTokens = {};

  @override
  ModelSelectionState build() {
    state = ModelSelectionState(
      models: LlmModel.availableModels,
      selectedModelId: null,
    );
    unawaited(_init());
    return state;
  }

  Future<void> _init() async {
    final customModels = await _loadCustomModels();
    final combinedModels = [...LlmModel.availableModels, ...customModels];

    final updatedModels = await Future.wait(
      combinedModels.map((model) async {
        final isDownloaded = await _isModelBundleDownloaded(model);
        return model.copyWith(isDownloaded: isDownloaded);
      }),
    );
    final modelsWithCachedCapabilities = await _applyCachedCapabilities(
      updatedModels,
    );

    String? newSelectedId = state.selectedModelId;
    if (newSelectedId != null &&
        !modelsWithCachedCapabilities.any((m) => m.id == newSelectedId)) {
      newSelectedId = null;
    }
    if (newSelectedId == null) {
      try {
        newSelectedId = modelsWithCachedCapabilities
            .firstWhere((m) => m.isDownloaded)
            .id;
      } catch (_) {
        newSelectedId = null;
      }
    }

    state = state.copyWith(
      models: modelsWithCachedCapabilities,
      selectedModelId: newSelectedId,
    );
    await _refreshStorageInfo();
    unawaited(_refreshModelCapabilities(modelsWithCachedCapabilities));
  }

  void selectModel(LlmModel model) {
    if (model.isDownloaded) {
      state = state.copyWith(selectedModelId: model.id);
    }
  }

  void toggleCapabilityFilter(ModelCapability capability) {
    final updatedFilters = Set<ModelCapability>.from(
      state.selectedCapabilityFilters,
    );

    if (!updatedFilters.add(capability)) {
      updatedFilters.remove(capability);
    }

    state = state.copyWith(selectedCapabilityFilters: updatedFilters);
  }

  void clearCapabilityFilters() {
    if (state.selectedCapabilityFilters.isEmpty) return;
    state = state.copyWith(selectedCapabilityFilters: <ModelCapability>{});
  }

  Future<void> downloadModel(LlmModel model) async {
    final assets = _downloadAssetsForModel(model);
    if (assets.isEmpty) return;

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
      final storageInfo = await _refreshStorageInfo();
      final remoteSizes = await Future.wait(
        assets.map(
          (asset) => _storageService.getRemoteFileSize(
            asset.url,
            cancelToken: cancelToken,
          ),
        ),
      );
      final existingSizes = await Future.wait(
        assets.map((asset) => _storageService.getLocalFileSize(asset.fileName)),
      );

      final totalRemoteBytes = remoteSizes.whereType<int>().fold<int>(
        0,
        (sum, size) => sum + size,
      );
      final remainingBytes = List.generate(assets.length, (index) {
        final remoteSize = remoteSizes[index];
        if (remoteSize == null) return 0;
        final existingSize = existingSizes[index];
        return remoteSize > existingSize ? remoteSize - existingSize : 0;
      }).fold<int>(0, (sum, size) => sum + size);

      if (storageInfo != null && remainingBytes > 0) {
        final requiredBytes = remainingBytes + _downloadSafetyBytes;
        if (storageInfo.freeBytes < requiredBytes) {
          _cancelTokens.remove(model.id);
          final updatedProgress = Map<String, DownloadProgress>.from(
            state.downloadProgress,
          )..remove(model.id);
          state = state.copyWith(
            downloadProgress: updatedProgress,
            error:
                'Not enough free storage for ${model.name}. '
                'Need ${_formatBytes(requiredBytes)} (including safety buffer), '
                'free ${_formatBytes(storageInfo.freeBytes)}.',
          );
          return;
        }
      }

      var completedBytes = List.generate(assets.length, (index) {
        final remoteSize = remoteSizes[index];
        final existingSize = existingSizes[index];
        if (remoteSize == null) return 0;
        return existingSize > remoteSize ? remoteSize : existingSize;
      }).fold<int>(0, (sum, size) => sum + size);

      if (completedBytes > 0) {
        state = state.copyWith(
          downloadProgress: {
            ...state.downloadProgress,
            model.id: DownloadProgress(
              received: completedBytes,
              total: totalRemoteBytes > 0 ? totalRemoteBytes : completedBytes,
            ),
          },
        );
      }

      for (var index = 0; index < assets.length; index++) {
        final asset = assets[index];
        final knownRemoteSize = remoteSizes[index];
        final currentLocalSize = await _storageService.getLocalFileSize(
          asset.fileName,
        );
        final isAlreadyComplete =
            knownRemoteSize != null &&
            currentLocalSize >= knownRemoteSize &&
            await _storageService.isModelDownloaded(asset.fileName);
        if (isAlreadyComplete) {
          continue;
        }

        final completedBeforeAsset = completedBytes;
        await _storageService.downloadModel(
          asset.url,
          asset.fileName,
          cancelToken: cancelToken,
          onProgress: (received, total) {
            final resolvedTotal = totalRemoteBytes > 0
                ? totalRemoteBytes
                : completedBeforeAsset + total;
            final resolvedReceived = completedBeforeAsset + received;
            final safeTotal = resolvedTotal > 0
                ? resolvedTotal
                : resolvedReceived;
            state = state.copyWith(
              downloadProgress: {
                ...state.downloadProgress,
                model.id: DownloadProgress(
                  received: resolvedReceived,
                  total: safeTotal,
                ),
              },
            );
          },
        );

        completedBytes +=
            knownRemoteSize ??
            await _storageService.getLocalFileSize(asset.fileName);
      }

      _cancelTokens.remove(model.id);

      final isDownloaded = await _isModelBundleDownloaded(model);
      final updatedModels = state.models
          .map(
            (m) =>
                m.id == model.id ? m.copyWith(isDownloaded: isDownloaded) : m,
          )
          .toList();

      final updatedProgress = Map<String, DownloadProgress>.from(
        state.downloadProgress,
      )..remove(model.id);

      state = state.copyWith(
        models: updatedModels,
        downloadProgress: updatedProgress,
        selectedModelId:
            state.selectedModelId ?? (isDownloaded ? model.id : null),
      );
      await _persistCustomModels(updatedModels);
      await _refreshStorageInfo();
      try {
        await _notificationService.showModelDownloadComplete(model.name);
      } catch (_) {
        // Notification failures should not affect download success.
      }
    } catch (e) {
      _cancelTokens.remove(model.id);

      if (e is DioException && CancelToken.isCancel(e)) {
        return;
      }

      final updatedProgress = Map<String, DownloadProgress>.from(
        state.downloadProgress,
      )..remove(model.id);
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
    List<ModelCapability> capabilities = const [],
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

    if (!uri.path.toLowerCase().endsWith('.gguf')) {
      state = state.copyWith(
        error:
            'This app supports GGUF only. Please provide a direct .gguf file URL.',
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

    final resolvedDescription = (description ?? '').trim().isNotEmpty
        ? description!.trim()
        : 'User-added model from custom download link.';
    final id =
        'custom-${_slugify(normalizedName)}-${DateTime.now().millisecondsSinceEpoch}';

    final isDownloaded = await _storageService.isModelDownloaded(localFileName);
    final model = LlmModel(
      id: id,
      name: normalizedName,
      parameterSize: normalizedSize,
      description: resolvedDescription,
      capabilities: capabilities,
      downloadUrl: normalizedUrl,
      localFileName: localFileName,
      isDownloaded: isDownloaded,
      isCustom: true,
    );

    final updatedModels = [...state.models, model];
    state = state.copyWith(models: updatedModels, error: null);
    await _persistCustomModels(updatedModels);
    if (_capabilityService.canResolveFromUrl(model.downloadUrl)) {
      unawaited(_refreshModelCapabilities([model]));
    }
  }

  Future<void> deleteModel(LlmModel model) async {
    final assets = _downloadAssetsForModel(model);
    if (assets.isEmpty) return;

    try {
      await Future.wait(
        assets.map((asset) => _storageService.deleteModel(asset.fileName)),
      );

      final updatedModels = state.models
          .map((m) => m.id == model.id ? m.copyWith(isDownloaded: false) : m)
          .toList();

      String? newSelectedId = state.selectedModelId;
      if (newSelectedId == model.id) {
        newSelectedId = null;
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
      await _refreshStorageInfo();
    } catch (e) {
      state = state.copyWith(
        error: 'Failed to delete ${model.name}: ${_friendlyDownloadError(e)}',
      );
    }
  }

  Future<void> refreshStorageInfo() async {
    await _refreshStorageInfo();
  }

  Future<List<LlmModel>> _applyCachedCapabilities(List<LlmModel> models) async {
    final cachedCapabilities = await _capabilityService.readCachedCapabilities(
      models,
    );
    if (cachedCapabilities.isEmpty) return models;
    return _mergeCapabilitiesIntoModels(models, cachedCapabilities);
  }

  Future<void> _refreshModelCapabilities(List<LlmModel> models) async {
    final resolvedCapabilities = await _capabilityService.refreshCapabilities(
      models,
    );
    if (resolvedCapabilities.isEmpty) return;

    final updatedModels = _mergeCapabilitiesIntoModels(
      state.models,
      resolvedCapabilities,
    );
    if (_sameModelCapabilities(state.models, updatedModels)) return;

    state = state.copyWith(models: updatedModels);
    await _persistCustomModels(updatedModels);
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

  List<LlmModel> _mergeCapabilitiesIntoModels(
    List<LlmModel> models,
    Map<String, List<ModelCapability>> capabilitiesByModelId,
  ) {
    return models
        .map((model) {
          final incomingCapabilities = capabilitiesByModelId[model.id];
          if (incomingCapabilities == null) return model;

          final mergedCapabilities = _mergeCapabilities(
            model.capabilities,
            incomingCapabilities,
          );
          if (_sameCapabilities(model.capabilities, mergedCapabilities)) {
            return model;
          }

          return model.copyWith(capabilities: mergedCapabilities);
        })
        .toList(growable: false);
  }

  List<ModelCapability> _mergeCapabilities(
    List<ModelCapability> current,
    List<ModelCapability> incoming,
  ) {
    final merged = <ModelCapability>{...current, ...incoming};
    return ModelCapability.values
        .where(merged.contains)
        .toList(growable: false);
  }

  bool _sameModelCapabilities(List<LlmModel> current, List<LlmModel> updated) {
    if (current.length != updated.length) return false;

    for (var index = 0; index < current.length; index++) {
      if (!_sameCapabilities(
        current[index].capabilities,
        updated[index].capabilities,
      )) {
        return false;
      }
    }

    return true;
  }

  bool _sameCapabilities(
    List<ModelCapability> first,
    List<ModelCapability> second,
  ) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  List<_ModelDownloadAsset> _downloadAssetsForModel(LlmModel model) {
    final assets = <_ModelDownloadAsset>[];
    if (model.downloadUrl != null &&
        model.downloadUrl!.trim().isNotEmpty &&
        model.localFileName != null &&
        model.localFileName!.trim().isNotEmpty) {
      assets.add(
        _ModelDownloadAsset(
          url: model.downloadUrl!.trim(),
          fileName: model.localFileName!.trim(),
        ),
      );
    }
    if (model.supportsVision &&
        model.mmprojDownloadUrl != null &&
        model.mmprojDownloadUrl!.trim().isNotEmpty &&
        model.mmprojLocalFileName != null &&
        model.mmprojLocalFileName!.trim().isNotEmpty) {
      assets.add(
        _ModelDownloadAsset(
          url: model.mmprojDownloadUrl!.trim(),
          fileName: model.mmprojLocalFileName!.trim(),
        ),
      );
    }
    return assets;
  }

  Future<bool> _isModelBundleDownloaded(LlmModel model) async {
    final assets = _downloadAssetsForModel(model);
    if (assets.isEmpty) return false;

    for (final asset in assets) {
      if (!await _storageService.isModelDownloaded(asset.fileName)) {
        return false;
      }
    }
    return true;
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

  Future<StorageInfo?> _refreshStorageInfo() async {
    final info = await _storageInfoService.getStorageInfo();
    state = state.copyWith(
      freeStorageBytes: info?.freeBytes,
      totalStorageBytes: info?.totalBytes,
    );
    return info;
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
