import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/settings/inference_settings_provider.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile_resolver.dart';

void main() {
  const desktopContext = 4096;
  const resolver = InferenceProfileResolver(
    platformContextTokens: desktopContext,
    supportsGpuOffload: true,
  );
  const mobileResolver = InferenceProfileResolver(
    platformContextTokens: 2048,
    supportsGpuOffload: false,
  );

  InferenceProfile profile({
    int? contextTokens,
    int? batchTokens,
    int? threads,
    int? threadsBatch,
    int? gpuLayers,
    bool? offloadKqv,
    double? temperature,
    double? topP,
    int? topK,
    int? maxOutputTokens,
  }) {
    return InferenceProfile(
      id: 'p-1',
      name: 'Test profile',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      contextTokens: contextTokens,
      batchTokens: batchTokens,
      threads: threads,
      threadsBatch: threadsBatch,
      gpuLayers: gpuLayers,
      offloadKqv: offloadKqv,
      temperature: temperature,
      topP: topP,
      topK: topK,
      maxOutputTokens: maxOutputTokens,
    );
  }

  group('InferenceProfileResolver', () {
    test('a profile that overrides nothing reproduces the app defaults', () {
      final resolved = resolver.resolve(
        profile: BuiltInProfiles.balanced,
        settings: const InferenceSettingsState(),
      );

      expect(resolved.contextTokens, desktopContext);
      expect(resolved.batchTokens, desktopContext);
      expect(resolved.threads, isNull);
      expect(resolved.threadsBatch, isNull);
      expect(resolved.gpuLayers, isNull);
      expect(resolved.offloadKqv, isNull);
      expect(resolved.temperature, 0.7);
      expect(resolved.topP, 0.9);
      expect(resolved.topK, 40);
      expect(resolved.maxOutputTokens, 512);
      expect(resolved.notes, isEmpty);
      expect(resolved.profileName, 'Balanced');
    });

    test('applies every value a profile sets', () {
      final resolved = resolver.resolve(
        profile: profile(
          contextTokens: 8192,
          batchTokens: 1024,
          threads: 6,
          threadsBatch: 8,
          gpuLayers: 40,
          offloadKqv: true,
          temperature: 0.2,
          topP: 0.5,
          topK: 10,
          maxOutputTokens: 1024,
        ),
        settings: const InferenceSettingsState(),
      );

      expect(resolved.contextTokens, 8192);
      expect(resolved.batchTokens, 1024);
      expect(resolved.threads, 6);
      expect(resolved.threadsBatch, 8);
      expect(resolved.gpuLayers, 40);
      expect(resolved.offloadKqv, isTrue);
      expect(resolved.temperature, 0.2);
      expect(resolved.topP, 0.5);
      expect(resolved.topK, 10);
      expect(resolved.maxOutputTokens, 1024);
    });

    test('falls back to the app sampling and output settings', () {
      final resolved = resolver.resolve(
        profile: profile(threads: 4),
        settings: const InferenceSettingsState(
          adaptiveMode: true,
          samplingPreset: SamplingPreset.creative,
          maxTokens: 256,
        ),
      );

      expect(resolved.temperature, 1.1);
      expect(resolved.topP, 0.98);
      expect(resolved.maxOutputTokens, 256);
      expect(resolved.threads, 4);
      expect(resolved.threadsBatch, isNull);
    });

    test('honours the custom sampling override in the app settings', () {
      final resolved = resolver.resolve(
        profile: BuiltInProfiles.balanced,
        settings: const InferenceSettingsState(
          advancedSamplingOverride: true,
          customTemperature: 0.25,
          customTopP: 0.6,
        ),
      );

      expect(resolved.temperature, 0.25);
      expect(resolved.topP, 0.6);
    });

    test('explains when a profile outranks the custom sampling settings', () {
      final resolved = resolver.resolve(
        profile: profile(temperature: 0.4),
        settings: const InferenceSettingsState(
          advancedSamplingOverride: true,
          customTemperature: 0.25,
        ),
      );

      expect(resolved.temperature, 0.4);
      expect(
        resolved.notes.join(' '),
        contains('instead of the custom values in Settings'),
      );
    });

    test('never exceeds the context the model declares', () {
      final resolved = resolver.resolve(
        profile: profile(contextTokens: 8192),
        settings: const InferenceSettingsState(),
        declaredContextTokens: 2048,
      );

      expect(resolved.contextTokens, 2048);
      expect(resolved.batchTokens, 2048);
      expect(resolved.notes.join(' '), contains('model limit'));
    });

    test('leaves a generous model declaration alone', () {
      final resolved = resolver.resolve(
        profile: profile(contextTokens: 8192),
        settings: const InferenceSettingsState(),
        declaredContextTokens: 131072,
      );

      expect(resolved.contextTokens, 8192);
      expect(resolved.notes, isEmpty);
    });

    test('keeps answers within half of the window', () {
      final resolved = resolver.resolve(
        profile: profile(contextTokens: 1024, maxOutputTokens: 4096),
        settings: const InferenceSettingsState(),
      );

      expect(resolved.contextTokens, 1024);
      expect(resolved.maxOutputTokens, 512);
      expect(resolved.notes.join(' '), contains('half the window'));
    });

    test('caps the batch size at the context window', () {
      final resolved = resolver.resolve(
        profile: profile(contextTokens: 512, batchTokens: 8192),
        settings: const InferenceSettingsState(),
      );

      expect(resolved.batchTokens, 512);
    });

    test('drops GPU offload on a CPU-only platform and explains why', () {
      final resolved = mobileResolver.resolve(
        profile: profile(gpuLayers: 40, offloadKqv: true),
        settings: const InferenceSettingsState(),
      );

      expect(resolved.gpuLayers, 0);
      expect(resolved.offloadKqv, isFalse);
      expect(resolved.notes.join(' '), contains('runs on CPU'));
    });

    test('does not warn when a profile already asks for the CPU', () {
      final resolved = mobileResolver.resolve(
        profile: BuiltInProfiles.batterySaver,
        settings: const InferenceSettingsState(),
      );

      expect(resolved.gpuLayers, 0);
      expect(resolved.offloadKqv, isFalse);
      expect(resolved.notes, isEmpty);
    });

    test('keeps the KV cache on the CPU when no layers are offloaded', () {
      final resolved = resolver.resolve(
        profile: profile(gpuLayers: 0, offloadKqv: true),
        settings: const InferenceSettingsState(),
      );

      expect(resolved.gpuLayers, 0);
      expect(resolved.offloadKqv, isFalse);
    });

    test('maximum performance fits a phone window', () {
      final resolved = mobileResolver.resolve(
        profile: BuiltInProfiles.maximumPerformance,
        settings: const InferenceSettingsState(),
      );

      expect(resolved.contextTokens, 8192);
      expect(resolved.maxOutputTokens, 1024);
      expect(resolved.gpuLayers, 0);
      expect(resolved.notes.join(' '), contains('runs on CPU'));
    });

    test('describes the resolved configuration for the UI', () {
      final resolved = resolver.resolve(
        profile: profile(
          contextTokens: 4096,
          threads: 8,
          gpuLayers: 32,
          temperature: 0.7,
        ),
        settings: const InferenceSettingsState(),
      );

      expect(
        resolved.summaryLabel,
        '4.1K ctx · 8 threads · GPU 32 layers · temp 0.70',
      );
      expect(resolved.outputLabel, '512 tokens reserved for the answer');
    });
  });
}
