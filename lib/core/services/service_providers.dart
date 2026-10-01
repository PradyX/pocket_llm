import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/services/android_tool_executor_service.dart';
import 'package:pocket_llm/core/services/device_profile_service.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/services/platform_runtime_paths_service.dart';
import 'package:pocket_llm/features/model_selection/data/model_compatibility_service.dart';

final llmServiceProvider = Provider<LlmService>((ref) {
  final service = LlmService(
    platformRuntimePathsService: ref.read(platformRuntimePathsServiceProvider),
  );
  ref.onDispose(() {
    unawaited(service.unloadModel());
  });
  return service;
});

final modelStorageServiceProvider = Provider<ModelStorageService>((ref) {
  return ModelStorageService();
});

final platformRuntimePathsServiceProvider =
    Provider<PlatformRuntimePathsService>((ref) {
      return PlatformRuntimePathsService();
    });

final androidToolExecutorServiceProvider = Provider<AndroidToolExecutorService>(
  (ref) {
    return AndroidToolExecutorService();
  },
);

/// Collects local device information (OS, CPU, memory, storage).
final deviceProfileServiceProvider = Provider<DeviceProfileService>((ref) {
  return DeviceProfileService();
});

/// Cached device profile for the current session.
final deviceProfileProvider = FutureProvider<DeviceProfile>((ref) {
  return ref.watch(deviceProfileServiceProvider).collect();
});

/// Estimates whether a model fits on this device.
final modelCompatibilityServiceProvider = Provider<ModelCompatibilityService>((
  ref,
) {
  return ModelCompatibilityService(
    storageService: ref.watch(modelStorageServiceProvider),
    deviceProfileService: ref.watch(deviceProfileServiceProvider),
  );
});
