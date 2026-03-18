import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/core/services/platform_runtime_paths_service.dart';

final llmServiceProvider = Provider<LlmService>((ref) {
  final service = LlmService();
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
