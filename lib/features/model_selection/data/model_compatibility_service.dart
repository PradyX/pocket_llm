import 'dart:io';

import 'package:pocket_llm/core/services/device_profile_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/domain/model_compatibility.dart';

/// Result of evaluating one model against this device.
class ModelFitReport {
  const ModelFitReport({
    required this.device,
    required this.contextTokens,
    required this.fileSizeBytes,
    required this.projectorBytes,
    required this.hasLocalFile,
    required this.hasMetadata,
    required this.estimate,
  });

  final DeviceProfile device;

  /// Context size the estimate assumes.
  final int contextTokens;

  /// Model file size actually found on disk (0 when the file is missing).
  final int fileSizeBytes;

  /// Vision projector size on disk, 0 when the model has none.
  final int projectorBytes;

  /// Whether the model file exists on this device.
  final bool hasLocalFile;

  /// Whether GGUF metadata is available for this model.
  final bool hasMetadata;

  /// Memory estimate, or null when the file or its metadata is missing.
  final ModelMemoryEstimate? estimate;

  /// Whether the local file could be rated.
  bool get isRatable => estimate != null;

  /// True when the model's own context length is below the app default.
  bool get isContextLimited =>
      estimate != null && estimate!.contextTokens < contextTokens;
}

/// Estimates model memory requirements from the local file and device.
///
/// UI code stays free of file and platform details: it asks for a report and
/// renders [ModelFitReport].
class ModelCompatibilityService {
  ModelCompatibilityService({
    ModelStorageService? storageService,
    DeviceProfileService? deviceProfileService,
  }) : _storage = storageService ?? ModelStorageService(),
       _deviceProfiles = deviceProfileService ?? DeviceProfileService();

  /// Context size the app loads models with (matches the chat runtime).
  static const int desktopContextTokens = 4096;
  static const int mobileContextTokens = 2048;

  final ModelStorageService _storage;
  final DeviceProfileService _deviceProfiles;

  /// Context the runtime uses on this platform.
  static int get defaultContextTokens => (Platform.isAndroid || Platform.isIOS)
      ? mobileContextTokens
      : desktopContextTokens;

  Future<DeviceProfile> readDeviceProfile() => _deviceProfiles.collect();

  /// Builds a fit report for [model].
  ///
  /// Only models with a readable local file and GGUF metadata can be rated;
  /// for others the report carries [ModelFitReport.isRatable] `false` so the UI
  /// can ask the user to install the model first.
  Future<ModelFitReport> evaluate(
    LlmModel model, {
    DeviceProfile? device,
    int? contextTokens,
  }) async {
    final profile = device ?? await _deviceProfiles.collect();
    final targetContext = contextTokens ?? defaultContextTokens;

    final path = await _storage.resolveModelPath(model);
    final fileSize = await _fileSize(path);
    final projectorBytes = await _fileSize(
      model.supportsVision ? await _storage.resolveMmprojPath(model) : null,
    );
    final metadata = model.ggufMetadata;

    if (fileSize <= 0 || metadata == null) {
      return ModelFitReport(
        device: profile,
        contextTokens: targetContext,
        fileSizeBytes: fileSize,
        projectorBytes: projectorBytes,
        hasLocalFile: fileSize > 0,
        hasMetadata: metadata != null,
        estimate: null,
      );
    }

    // Never plan for more context than the model was trained for.
    final declared = metadata.contextLength;
    final context = declared != null && declared > 0 && declared < targetContext
        ? declared
        : targetContext;

    final estimate = ModelCompatibilityEstimator.estimate(
      metadata: metadata,
      contextTokens: context,
      fileSizeBytes: fileSize,
      projectorBytes: projectorBytes,
      totalMemoryBytes: profile.totalMemoryBytes,
      availableMemoryBytes: profile.availableMemoryBytes,
    );

    return ModelFitReport(
      device: profile,
      contextTokens: context,
      fileSizeBytes: fileSize,
      projectorBytes: projectorBytes,
      hasLocalFile: true,
      hasMetadata: true,
      estimate: estimate,
    );
  }

  Future<int> _fileSize(String? path) async {
    if (path == null || path.trim().isEmpty) return 0;
    try {
      final file = File(path);
      if (!await file.exists()) return 0;
      return await file.length();
    } catch (_) {
      return 0;
    }
  }
}
