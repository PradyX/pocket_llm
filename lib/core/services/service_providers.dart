import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/inference/embedding_engine.dart';
import 'package:pocket_llm/core/inference/inference_engine.dart';
import 'package:pocket_llm/core/services/android_tool_executor_service.dart';
import 'package:pocket_llm/core/services/device_profile_service.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/local_embedding_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/services/platform_runtime_paths_service.dart';
import 'package:pocket_llm/core/services/process_memory_probe.dart';
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

/// The local inference engine as features see it.
///
/// Features depend on this interface rather than on [LlmService], so replacing
/// the llama.cpp binding is a change behind this provider instead of a change
/// in every feature. It hands out the same single engine, which is what keeps
/// one model resident across chat, voice, documents, comparison and agents.
final inferenceEngineProvider = Provider<InferenceEngine>((ref) {
  return ref.watch(llmServiceProvider);
});

final localEmbeddingServiceProvider = Provider<LocalEmbeddingService>((ref) {
  final service = LocalEmbeddingService(
    platformRuntimePathsService: ref.read(platformRuntimePathsServiceProvider),
  );
  ref.onDispose(() {
    unawaited(service.unload());
  });
  return service;
});

/// The local embedding engine as features see it.
///
/// Deliberately not the chat engine: an embedding context is created with
/// embeddings enabled and a pooling type, which a generating context cannot
/// also be. This engine loads a small embedding model on demand and releases it
/// when the work that needed it is done.
final embeddingEngineProvider = Provider<EmbeddingEngine>((ref) {
  return ref.watch(localEmbeddingServiceProvider);
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

/// Reads this process's memory use for benchmark records.
final processMemoryProbeProvider = Provider<ProcessMemoryProbe>((ref) {
  return ProcessMemoryProbe();
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
