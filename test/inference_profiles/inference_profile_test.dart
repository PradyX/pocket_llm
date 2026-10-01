import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';

void main() {
  InferenceProfile sample() => InferenceProfile(
    id: 'p-1',
    name: 'Phone chat',
    description: 'Small context for long sessions',
    createdAt: DateTime(2026, 1, 2),
    updatedAt: DateTime(2026, 1, 3),
    contextTokens: 2048,
    batchTokens: 256,
    threads: 4,
    threadsBatch: 2,
    gpuLayers: 0,
    offloadKqv: false,
    temperature: 0.4,
    topP: 0.8,
    topK: 20,
    maxOutputTokens: 256,
  );

  group('InferenceProfile', () {
    test('round-trips through JSON', () {
      final restored = InferenceProfile.fromJson(sample().toJson())!;

      expect(restored.id, 'p-1');
      expect(restored.name, 'Phone chat');
      expect(restored.description, 'Small context for long sessions');
      expect(restored.contextTokens, 2048);
      expect(restored.batchTokens, 256);
      expect(restored.threads, 4);
      expect(restored.threadsBatch, 2);
      expect(restored.gpuLayers, 0);
      expect(restored.offloadKqv, isFalse);
      expect(restored.temperature, 0.4);
      expect(restored.topP, 0.8);
      expect(restored.topK, 20);
      expect(restored.maxOutputTokens, 256);
      expect(restored.createdAt, DateTime(2026, 1, 2));
      expect(restored.isBuiltIn, isFalse);
    });

    test('keeps unset fields null so app defaults stay in charge', () {
      final restored = InferenceProfile.fromJson({
        'id': 'p-2',
        'name': 'Minimal',
        'contextTokens': 4096,
      })!;

      expect(restored.contextTokens, 4096);
      expect(restored.threads, isNull);
      expect(restored.gpuLayers, isNull);
      expect(restored.temperature, isNull);
      expect(restored.maxOutputTokens, isNull);
      expect(restored.isAllDefaults, isFalse);
    });

    test('rejects entries without a usable id', () {
      expect(InferenceProfile.fromJson(const {}), isNull);
      expect(InferenceProfile.fromJson(const {'id': '   '}), isNull);
      expect(InferenceProfile.fromJson(const {'id': 7}), isNull);
    });

    test('clamps stored values into their allowed ranges', () {
      final restored = InferenceProfile.fromJson({
        'id': 'p-3',
        'name': 'Hand edited',
        'contextTokens': 999999,
        'batchTokens': -20,
        'threads': 500,
        'gpuLayers': -5,
        'temperature': 9.5,
        'topP': 0.0,
        'topK': 0,
        'maxOutputTokens': 100000,
      })!;

      expect(restored.contextTokens, InferenceProfileLimits.maxContextTokens);
      expect(restored.batchTokens, InferenceProfileLimits.minBatchTokens);
      expect(restored.threads, InferenceProfileLimits.maxThreads);
      expect(restored.gpuLayers, InferenceProfileLimits.minGpuLayers);
      expect(restored.temperature, InferenceProfileLimits.maxTemperature);
      expect(restored.topP, InferenceProfileLimits.minTopP);
      expect(restored.topK, InferenceProfileLimits.minTopK);
      expect(restored.maxOutputTokens, InferenceProfileLimits.maxOutputTokens);
    });

    test('reads numeric strings and doubles that arrive as ints', () {
      final restored = InferenceProfile.fromJson({
        'id': 'p-4',
        'name': 'Coerced',
        'contextTokens': '2048',
        'temperature': 1,
        'topP': 1,
      })!;

      expect(restored.contextTokens, 2048);
      expect(restored.temperature, 1.0);
      expect(restored.topP, 1.0);
    });

    test('falls back to a placeholder name and keeps timestamps sane', () {
      final restored = InferenceProfile.fromJson({
        'id': 'p-5',
        'name': '  ',
        'createdAt': 'not a date',
      })!;

      expect(restored.name, InferenceProfile.defaultProfileName);
      expect(restored.updatedAt, restored.createdAt);
    });

    test('create trims the name and generates an id', () {
      final first = InferenceProfile.create(name: '  Coding  ');
      final second = InferenceProfile.create(name: 'Coding');

      expect(first.name, 'Coding');
      expect(first.isBuiltIn, isFalse);
      expect(first.id, isNotEmpty);
      expect(first.id, isNot(second.id));
    });

    test('copyWith can set and clear single overrides', () {
      final base = sample();
      final cleared = base.copyWith(
        clearContextTokens: true,
        clearGpuLayers: true,
        threads: 8,
      );

      expect(cleared.contextTokens, isNull);
      expect(cleared.gpuLayers, isNull);
      expect(cleared.threads, 8);
      expect(cleared.offloadKqv, isFalse);
      expect(cleared.name, 'Phone chat');
      expect(cleared.createdAt, base.createdAt);
    });

    test('duplicate keeps the settings but renames and re-ids', () {
      final copy = sample().duplicate();

      expect(copy.id, isNot('p-1'));
      expect(copy.name, 'Phone chat copy');
      expect(copy.contextTokens, 2048);
      expect(copy.temperature, 0.4);
      expect(copy.isBuiltIn, isFalse);
    });

    test('summary labels list only what is overridden', () {
      expect(BuiltInProfiles.balanced.summaryLabel, 'App defaults');
      expect(sample().summaryLabel, contains('2.0K ctx'));
      expect(sample().summaryLabel, contains('4 threads'));
      expect(sample().summaryLabel, contains('CPU only'));
      expect(sample().summaryLabel, contains('KV on CPU'));
      expect(sample().summaryLabel, contains('temp 0.40'));
      expect(sample().summaryLabel, contains('256 max output'));
    });
  });

  group('BuiltInProfiles', () {
    test('ships a balanced default, a saver and a performance profile', () {
      expect(BuiltInProfiles.all(), hasLength(3));
      expect(BuiltInProfiles.all().first.id, BuiltInProfiles.balancedId);
      for (final profile in BuiltInProfiles.all()) {
        expect(profile.isBuiltIn, isTrue);
        expect(profile.name, isNotEmpty);
      }
    });

    test('the default profile changes nothing at all', () {
      expect(BuiltInProfiles.balanced.isAllDefaults, isTrue);
      expect(BuiltInProfiles.byId()[BuiltInProfiles.balancedId], isNotNull);
    });

    test('battery saver stays small and on the CPU', () {
      final saver = BuiltInProfiles.batterySaver;
      expect(saver.contextTokens, 1024);
      expect(saver.threads, 2);
      expect(saver.gpuLayers, 0);
      expect(saver.offloadKqv, isFalse);
      expect(saver.maxOutputTokens, 256);
    });

    test('maximum performance offloads every layer and answers longer', () {
      final performance = BuiltInProfiles.maximumPerformance;
      expect(performance.contextTokens, greaterThan(4096));
      expect(performance.gpuLayers, 200);
      expect(performance.offloadKqv, isTrue);
      expect(performance.maxOutputTokens, 1024);
    });
  });
}
