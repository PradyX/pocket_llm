import 'dart:math' as math;

import 'package:pocket_llm/core/settings/inference_settings_provider.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';

/// What the runtime will be started with for one request.
///
/// Device settings a profile does not override stay `null`, which tells the
/// runtime to keep its own platform- and load-type-aware default. That keeps
/// this class free of duplicated default tables: there is exactly one place
/// that decides what "threads" or "GPU layers" mean on a device.
class ResolvedInferenceConfig {
  const ResolvedInferenceConfig({
    required this.profileId,
    required this.profileName,
    required this.contextTokens,
    required this.batchTokens,
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.maxOutputTokens,
    this.threads,
    this.threadsBatch,
    this.gpuLayers,
    this.offloadKqv,
    this.notes = const [],
  });

  final String profileId;
  final String profileName;

  final int contextTokens;
  final int batchTokens;

  /// null = runtime default.
  final int? threads;
  final int? threadsBatch;
  final int? gpuLayers;
  final bool? offloadKqv;

  final double temperature;
  final double topP;
  final int topK;
  final int maxOutputTokens;

  /// What the resolver had to reduce or ignore, in plain language.
  ///
  /// Empty when the profile was applied exactly as written.
  final List<String> notes;

  /// `4.1K ctx · 8 threads · GPU 32 layers · temp 0.70`.
  String get summaryLabel {
    final parts = <String>[
      '${formatTokens(contextTokens)} ctx',
      threads == null ? 'default threads' : '$threads threads',
      gpuLayers == null
          ? 'default offload'
          : (gpuLayers! > 0 ? 'GPU $gpuLayers layers' : 'CPU only'),
      'temp ${temperature.toStringAsFixed(2)}',
    ];
    return parts.join(' · ');
  }

  /// One line describing the answer reservation.
  String get outputLabel =>
      '${formatTokens(maxOutputTokens)} tokens reserved for the answer';
}

/// Applies a profile on top of the app settings and the platform limits.
///
/// Rules, in order:
///
/// 1. A profile only overrides what it sets; everything else keeps the app or
///    runtime default for this platform.
/// 2. The context window is capped by the model's declared limit, which a
///    profile must never exceed.
/// 3. Answers are capped so at least half the window stays available for the
///    prompt, matching the budget the prompt builder uses.
/// 4. Settings a platform cannot use (GPU offload on Android) are dropped and
///    reported in [ResolvedInferenceConfig.notes] instead of failing silently.
class InferenceProfileResolver {
  const InferenceProfileResolver({
    required this.platformContextTokens,
    required this.supportsGpuOffload,
  });

  /// Context the app uses when a profile does not set one.
  final int platformContextTokens;

  /// False on platforms that run on the CPU only (Android).
  final bool supportsGpuOffload;

  /// Top-k used when a profile does not set one (the app's long-standing value).
  static const int defaultTopK = 40;

  ResolvedInferenceConfig resolve({
    required InferenceProfile profile,
    required InferenceSettingsState settings,
    int? declaredContextTokens,
  }) {
    final notes = <String>[];

    var contextTokens = profile.contextTokens ?? platformContextTokens;
    final declared = declaredContextTokens;
    if (declared != null && declared > 0 && declared < contextTokens) {
      notes.add(
        'Context uses the model limit of ${formatTokens(declared)} tokens.',
      );
      contextTokens = declared;
    }

    final requestedOutput = profile.maxOutputTokens ?? settings.maxTokens;
    final outputCeiling = math.max(
      ContextPolicy.minimumReservedOutputTokens,
      contextTokens ~/ 2,
    );
    var maxOutputTokens = math.max(
      ContextPolicy.minimumReservedOutputTokens,
      requestedOutput,
    );
    if (maxOutputTokens > outputCeiling) {
      notes.add(
        'Answers limited to ${formatTokens(outputCeiling)} tokens so half the '
        'window stays free for the prompt.',
      );
      maxOutputTokens = outputCeiling;
    }

    var gpuLayers = profile.gpuLayers;
    var offloadKqv = profile.offloadKqv;
    if (!supportsGpuOffload) {
      final askedForGpu =
          (gpuLayers != null && gpuLayers > 0) || offloadKqv == true;
      if (askedForGpu) {
        notes.add(
          'This platform runs on CPU, so GPU layers and KV offload are '
          'ignored.',
        );
        gpuLayers = 0;
        offloadKqv = false;
      }
    }
    if (gpuLayers != null && gpuLayers <= 0) {
      // A profile that asks for no GPU layers must also keep the cache on CPU.
      offloadKqv = false;
    }

    final sampling = settings.resolvedSampling;
    final temperature = profile.temperature ?? sampling.temperature;
    final topP = profile.topP ?? sampling.topP;
    if (settings.advancedSamplingOverride &&
        (profile.temperature != null || profile.topP != null)) {
      notes.add(
        'Sampling uses this profile instead of the custom values in Settings.',
      );
    }

    return ResolvedInferenceConfig(
      profileId: profile.id,
      profileName: profile.name,
      contextTokens: contextTokens,
      batchTokens: math.min(
        math.max(
          profile.batchTokens ?? contextTokens,
          InferenceProfileLimits.minBatchTokens,
        ),
        contextTokens,
      ),
      threads: profile.threads,
      threadsBatch: profile.threadsBatch,
      gpuLayers: gpuLayers,
      offloadKqv: offloadKqv,
      temperature: temperature,
      topP: topP,
      topK: profile.topK ?? defaultTopK,
      maxOutputTokens: maxOutputTokens,
      notes: notes,
    );
  }
}
