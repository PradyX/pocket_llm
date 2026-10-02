import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/benchmark/application/model_comparison_controller.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';
import 'package:pocket_llm/features/benchmark/data/comparison_set_store.dart';
import 'package:pocket_llm/features/benchmark/domain/comparison_set.dart';
import 'package:pocket_llm/features/benchmark/domain/model_comparison_export.dart';
import 'package:pocket_llm/features/benchmark/domain/prompt_suite.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

import 'scripted_comparison_runtime.dart';

void main() {
  // The suite export path writes to the platform clipboard channel.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ComparisonSetStore setStore;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_suite_test');
    setStore = ComparisonSetStore(
      File(p.join(tempDir.path, 'benchmark', 'comparison_sets.json')),
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  LlmModel model(String id) => LlmModel(
    id: id,
    name: 'Model $id',
    parameterSize: '1B',
    description: 'test model',
    isDownloaded: true,
  );

  ProviderContainer containerFor({
    required ScriptedComparisonRuntime runtime,
    required List<LlmModel> installedModels,
  }) {
    return ProviderContainer(
      overrides: [
        installedComparisonModelsProvider.overrideWithValue(installedModels),
        modelComparisonServiceProvider.overrideWithValue(
          ModelComparisonService(
            runtime: runtime,
            resolveModelPath: (model) async => '/models/${model.id}.gguf',
            isFileReady: (path) async => path != null,
          ),
        ),
        comparisonSetStoreProvider.overrideWith((ref) async => setStore),
      ],
    );
  }

  Future<ModelComparisonController> controllerOf(
    ProviderContainer container,
  ) async {
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );
    await container.read(comparisonSetStoreProvider.future);
    await Future<void>.delayed(Duration.zero);
    return controller;
  }

  ModelComparisonState stateOf(ProviderContainer container) =>
      container.read(modelComparisonControllerProvider);

  test('runs every prompt across the selected models, in order', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['a1'],
        ['b1'],
        ['a2'],
        ['b2'],
      ],
    );
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = await controllerOf(container);

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setPrompt('First question')
      ..addSuitePrompt('Second question');
    await controller.runSuite();

    final state = stateOf(container);
    expect(state.stage, ComparisonStage.finished);
    expect(state.suiteRuns, hasLength(2));
    expect(state.suiteRuns.map((run) => run.prompt), [
      'First question',
      'Second question',
    ]);
    expect(state.suiteRuns.every((run) => run.results.length == 2), isTrue);
    expect(state.suiteRuns.first.results.first.outputText, 'a1');
    expect(state.suiteRuns.last.results.last.outputText, 'b2');
    // Each prompt loads the same models again, in the same order.
    expect(runtime.loadedModelPaths, [
      '/models/a.gguf',
      '/models/b.gguf',
      '/models/a.gguf',
      '/models/b.gguf',
    ]);
    expect(state.suiteRunningPrompt, isNull);
    expect(state.wasStopped, isFalse);
    expect(state.errorMessage, isNull);
  });

  test('needs two prompts and two models', () async {
    final runtime = ScriptedComparisonRuntime();
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = await controllerOf(container);

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setPrompt('Only one');
    await controller.runSuite();
    expect(stateOf(container).errorMessage, contains('at least one more'));

    controller
      ..setPrompt('First')
      ..addSuitePrompt('Second')
      ..toggleModel('a');
    await controller.runSuite();
    expect(stateOf(container).errorMessage, contains('at least 2'));
    expect(runtime.loadedModelPaths, isEmpty);
  });

  test(
    'stopping a suite keeps its answers and marks the rest skipped',
    () async {
      final runtime = ScriptedComparisonRuntime(
        script: [
          ['only answer'],
          ['never'],
          ['never'],
          ['never'],
        ],
      )..holdAtEnd = true;
      final container = containerFor(
        runtime: runtime,
        installedModels: [model('a'), model('b')],
      );
      addTearDown(container.dispose);
      final controller = await controllerOf(container);

      controller
        ..toggleModel('a')
        ..toggleModel('b')
        ..setPrompt('First question')
        ..addSuitePrompt('Second question');
      final running = controller.runSuite();
      await pumpUntil(() => runtime.isWaiting);

      controller.cancel();
      await running;

      final state = stateOf(container);
      expect(state.stage, ComparisonStage.finished);
      expect(state.wasStopped, isTrue);
      expect(state.suiteRuns, hasLength(2));
      expect(state.suiteRuns.first.wasStopped, isTrue);
      expect(state.suiteRuns.first.results, hasLength(1));
      expect(state.suiteRuns.first.results.single.outputText, 'only answer');
      expect(state.suiteRuns.last.wasSkipped, isTrue);
      expect(state.suiteRuns.last.results, isEmpty);
    },
  );

  test('exports the whole suite as one versioned payload', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['a1'],
        ['b1'],
        ['a2'],
        ['b2'],
      ],
    );
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = await controllerOf(container);

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setPrompt('First question')
      ..addSuitePrompt('Second question')
      ..setBlind(true);
    await controller.runSuite();

    final export = controller.buildSuiteExport()!;
    expect(export.runs, hasLength(2));
    expect(export.modelCount, 2);
    expect(export.answerCount, 4);
    expect(export.failureCount, 0);
    expect(export.blind, isTrue);

    // The clipboard is a platform channel; capture what would be written.
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    expect(
      await controller.copySuiteExportToClipboard(ComparisonExportFormat.json),
      isTrue,
    );
    final payload = jsonDecode(copied!) as Map<String, dynamic>;
    expect(payload['format'], promptSuiteExportFormat);
    expect(payload['schemaVersion'], promptSuiteExportSchemaVersion);
    expect(payload['promptCount'], 2);
    expect(payload['runs'], hasLength(2));
    expect(
      ((payload['runs'] as List).last as Map<String, dynamic>)['prompt'],
      'Second question',
    );
  });

  test('a saved set carries the suite prompts back into the tab', () async {
    final runtime = ScriptedComparisonRuntime();
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = await controllerOf(container);

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setPrompt('First question')
      ..addSuitePrompt('Second question')
      ..addSuitePrompt('Third question');
    await controller.saveCurrentAsSet('Daily suite');
    final id = stateOf(container).savedSets.single.id;
    expect(stateOf(container).savedSets.single.prompts, hasLength(3));

    controller
      ..removeSuitePrompt(1)
      ..removeSuitePrompt(0);
    expect(stateOf(container).suitePrompts, isEmpty);

    controller.applySet(id);
    final state = stateOf(container);
    expect(state.prompt, 'First question');
    expect(state.suitePrompts, ['Second question', 'Third question']);
    expect(state.activePrompts, hasLength(3));
  });

  test('removing and editing suite prompts keeps the order', () async {
    final runtime = ScriptedComparisonRuntime();
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = await controllerOf(container);

    controller
      ..setPrompt('Main')
      ..addSuitePrompt('Second')
      ..addSuitePrompt('Third');
    controller.updateSuitePrompt(0, 'Second edited');
    controller.removeSuitePrompt(1);

    final state = stateOf(container);
    expect(state.suitePrompts, ['Second edited']);
    expect(state.activePrompts, ['Main', 'Second edited']);
  });

  test('a suite is capped at the maximum number of prompts', () async {
    final runtime = ScriptedComparisonRuntime();
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = await controllerOf(container);

    controller.setPrompt('Main');
    for (var index = 0; index < ComparisonSet.maximumPrompts + 3; index++) {
      controller.addSuitePrompt('Prompt $index');
    }

    final state = stateOf(container);
    expect(state.activePrompts, hasLength(ComparisonSet.maximumPrompts));
    expect(state.errorMessage, contains('at most'));
  });
}
