import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/services/device_profile_service.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';
import 'package:pocket_llm/features/model_selection/data/model_compatibility_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

import 'scripted_comparison_runtime.dart';

void main() {
  LlmModel model(String id, {bool downloaded = true}) => LlmModel(
    id: id,
    name: 'Model $id',
    parameterSize: '1B',
    description: 'test model',
    isDownloaded: downloaded,
  );

  ModelComparisonService serviceFor(
    ScriptedComparisonRuntime runtime, {
    Future<DeviceProfile> Function()? readDeviceProfile,
    Future<int?> Function()? readResidentMemoryBytes,
  }) {
    return ModelComparisonService(
      runtime: runtime,
      resolveModelPath: (model) async => '/models/${model.id}.gguf',
      isFileReady: (path) async => path != null,
      readDeviceProfile: readDeviceProfile,
      readResidentMemoryBytes: readResidentMemoryBytes,
    );
  }

  test('runs models in order with one shared prompt and window', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['Hello'],
        ['Hi', ' there'],
        ['Hey'],
      ],
    );
    final service = serviceFor(runtime);

    final results = await service
        .compare(models: [model('a'), model('b'), model('c')], prompt: 'Say hi')
        .toList();

    expect(runtime.loadedModelPaths, [
      '/models/a.gguf',
      '/models/b.gguf',
      '/models/c.gguf',
    ]);
    final expectedContext = ModelCompatibilityService.defaultContextTokens;
    expect(runtime.loadedContextTokens, everyElement(expectedContext));
    expect(runtime.prompts, hasLength(3));
    expect(runtime.prompts.toSet(), hasLength(1));
    final expectedBudget = ModelComparisonService.outputTokensFor(
      requested: ModelComparisonService.defaultMaxTokens,
      contextTokens: expectedContext,
    );
    expect(runtime.requestedMaxTokens, everyElement(expectedBudget));
    expect(results.map((result) => result.model.id), ['a', 'b', 'c']);
    expect(results.map((result) => result.outputText), [
      'Hello',
      'Hi there',
      'Hey',
    ]);
    expect(results.every((result) => result.isSuccess), isTrue);
    expect(results.map((result) => result.generatedTokens), [1, 2, 1]);
    expect(results.first.ttftMs, isNotNull);
  });

  test(
    'loads the next model only after the previous answer finished',
    () async {
      final runtime = ScriptedComparisonRuntime(
        script: [
          ['one'],
          ['two'],
        ],
      )..holdAtEnd = true;
      final service = serviceFor(runtime);

      final run = service
          .compare(models: [model('a'), model('b')], prompt: 'p')
          .toList();
      await pumpUntil(() => runtime.isWaiting);
      expect(runtime.loadedModelPaths, ['/models/a.gguf']);
      expect(runtime.generateCalls, 1);

      runtime.release();
      await pumpUntil(() => runtime.loadedModelPaths.length == 2);
      runtime.release();

      final results = await run;
      expect(results, hasLength(2));
      expect(results.map((result) => result.outputText), ['one', 'two']);
    },
  );

  test('reports a model that fails to load and keeps going', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['first'],
        ['third'],
      ],
    )..failingModelPaths.add('/models/b.gguf');
    final service = serviceFor(runtime);

    final results = await service
        .compare(models: [model('a'), model('b'), model('c')], prompt: 'p')
        .toList();

    expect(results, hasLength(3));
    expect(results[0].isSuccess, isTrue);
    expect(results[1].isSuccess, isFalse);
    expect(results[1].errorMessage, 'the model failed to load');
    expect(results[2].isSuccess, isTrue);
    expect(results[2].outputText, 'third');
  });

  test(
    'keeps the partial answer of a stopped model and skips the rest',
    () async {
      final runtime = ScriptedComparisonRuntime(
        script: [
          ['partial answer'],
          ['never'],
        ],
      )..holdAtEnd = true;
      final service = serviceFor(runtime);

      final run = service
          .compare(models: [model('a'), model('b')], prompt: 'p')
          .toList();
      await pumpUntil(() => runtime.isWaiting);

      service.cancel();
      final results = await run;

      expect(runtime.cancelled, isTrue);
      expect(runtime.loadedModelPaths, ['/models/a.gguf']);
      expect(results, hasLength(1));
      expect(results.single.outputText, 'partial answer');
      expect(results.single.isSuccess, isTrue);
    },
  );

  test('rejects fewer than two or more than four models', () async {
    final runtime = ScriptedComparisonRuntime();
    final service = serviceFor(runtime);

    await expectLater(
      service.compare(models: [model('a')], prompt: 'p'),
      emitsError(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('between 2 and 4'),
        ),
      ),
    );
    await expectLater(
      service.compare(
        models: [model('a'), model('b'), model('c'), model('d'), model('e')],
        prompt: 'p',
      ),
      emitsError(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('between 2 and 4'),
        ),
      ),
    );
    expect(runtime.loadedModelPaths, isEmpty);
  });

  test('rejects an empty prompt', () async {
    final runtime = ScriptedComparisonRuntime();
    final service = serviceFor(runtime);

    await expectLater(
      service.compare(models: [model('a'), model('b')], prompt: '   '),
      emitsError(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Enter a prompt'),
        ),
      ),
    );
    expect(runtime.loadedModelPaths, isEmpty);
  });

  test('refuses to run while the shared engine is busy', () async {
    final runtime = ScriptedComparisonRuntime()..isGenerating = true;
    final service = serviceFor(runtime);

    await expectLater(
      service.compare(models: [model('a'), model('b')], prompt: 'p'),
      emitsError(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Stop the current answer'),
        ),
      ),
    );
    expect(runtime.loadedModelPaths, isEmpty);
  });

  test('does not load a model that is not downloaded', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['only'],
      ],
    );
    final service = serviceFor(runtime);

    final results = await service
        .compare(
          models: [model('a', downloaded: false), model('b')],
          prompt: 'p',
        )
        .toList();

    expect(results.first.isSuccess, isFalse);
    expect(results.first.errorMessage, contains('not downloaded'));
    expect(results[1].isSuccess, isTrue);
    expect(runtime.loadedModelPaths, ['/models/b.gguf']);
  });

  test('reports a model file that cannot be resolved', () async {
    final runtime = ScriptedComparisonRuntime();
    final service = ModelComparisonService(
      runtime: runtime,
      resolveModelPath: (model) async =>
          model.id == 'a' ? null : '/models/${model.id}.gguf',
      isFileReady: (path) async => path != null,
    );

    final results = await service
        .compare(models: [model('a'), model('b')], prompt: 'p')
        .toList();

    expect(results.first.isSuccess, isFalse);
    expect(results.first.errorMessage, contains('missing or incomplete'));
    expect(runtime.loadedModelPaths, ['/models/b.gguf']);
  });

  test('clamps the output budget to the window', () {
    expect(
      ModelComparisonService.outputTokensFor(
        requested: 256,
        contextTokens: 4096,
      ),
      256,
    );
    expect(
      ModelComparisonService.outputTokensFor(
        requested: 4096,
        contextTokens: 1024,
      ),
      256,
    );
    expect(
      ModelComparisonService.outputTokensFor(requested: 8, contextTokens: 4096),
      64,
    );
  });

  test('captures the device and memory numbers when supplied', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['answer'],
      ],
    );
    final service = serviceFor(
      runtime,
      readDeviceProfile: () async => const DeviceProfile(
        operatingSystem: 'TestOS',
        operatingSystemVersion: '1',
        architecture: 'arm64',
        cpuCores: 8,
        totalMemoryBytes: 8 * 1024 * 1024 * 1024,
      ),
      readResidentMemoryBytes: () async => 1234,
    );

    final results = await service
        .compare(models: [model('a'), model('b')], prompt: 'p')
        .toList();

    expect(results.first.peakMemoryBytes, 1234);
    expect(results.first.deviceSummary, isNotNull);
    expect(results.first.deviceCpuCores, 8);
    expect(results.first.deviceMemoryBytes, 8 * 1024 * 1024 * 1024);
    expect(results.first.contextTokens, 4096);
    expect(results.first.threads, 4);
    expect(results.first.backend, 'Test backend');
  });
}
