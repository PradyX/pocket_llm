import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/benchmark/application/model_comparison_controller.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';
import 'package:pocket_llm/features/benchmark/data/comparison_set_store.dart';
import 'package:pocket_llm/features/benchmark/domain/model_comparison_export.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

import 'scripted_comparison_runtime.dart';

void main() {
  // The export path writes to the platform clipboard channel.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ComparisonSetStore setStore;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'pocketllm_compare_harness',
    );
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

  test('runs the selected models and exposes every answer', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['first answer'],
        ['second answer'],
      ],
    );
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b'), model('c')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('b')
      ..toggleModel('a')
      ..setPrompt('Say hi');
    await controller.run();

    final state = container.read(modelComparisonControllerProvider);
    expect(state.stage, ComparisonStage.finished);
    // Runs follow the order the models were picked in.
    expect(runtime.loadedModelPaths, ['/models/b.gguf', '/models/a.gguf']);
    expect(state.results.map((result) => result.model.id), ['b', 'a']);
    expect(state.results.map((result) => result.outputText), [
      'first answer',
      'second answer',
    ]);
    expect(state.errorMessage, isNull);
    expect(state.runningModelName, isNull);
    expect(state.wasStopped, isFalse);
    expect(state.results, hasLength(2));
  });

  test('requires at least two selected models', () async {
    final runtime = ScriptedComparisonRuntime();
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller.toggleModel('a');
    await controller.run();

    final state = container.read(modelComparisonControllerProvider);
    expect(state.stage, ComparisonStage.idle);
    expect(state.errorMessage, contains('at least 2'));
    expect(runtime.loadedModelPaths, isEmpty);
  });

  test('keeps at most four selected models', () {
    final runtime = ScriptedComparisonRuntime();
    final container = containerFor(
      runtime: runtime,
      installedModels: [
        model('a'),
        model('b'),
        model('c'),
        model('d'),
        model('e'),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    for (final id in ['a', 'b', 'c', 'd', 'e']) {
      controller.toggleModel(id);
    }

    final state = container.read(modelComparisonControllerProvider);
    expect(state.selectedModelIds, ['a', 'b', 'c', 'd']);
    expect(state.isSelectionFull, isTrue);
  });

  test('stops the run and keeps the partial answer', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['partial'],
        ['never'],
      ],
    )..holdAtEnd = true;
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('a')
      ..toggleModel('b');
    final run = controller.run();
    await pumpUntil(() => runtime.isWaiting);

    controller.cancel();
    await run;

    final state = container.read(modelComparisonControllerProvider);
    expect(state.stage, ComparisonStage.finished);
    expect(state.wasStopped, isTrue);
    expect(state.results, hasLength(1));
    expect(state.results.single.outputText, 'partial');
    expect(runtime.loadedModelPaths, ['/models/a.gguf']);
  });

  test('reports a service failure as failed', () async {
    final runtime = ScriptedComparisonRuntime()..isGenerating = true;
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('a')
      ..toggleModel('b');
    await controller.run();

    final state = container.read(modelComparisonControllerProvider);
    expect(state.stage, ComparisonStage.failed);
    expect(state.errorMessage, contains('Stop the current answer'));
    expect(state.results, isEmpty);
  });

  test('clears results but keeps the chosen models and prompt', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['answer'],
        ['answer'],
      ],
    );
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setPrompt('Keep me');
    await controller.run();
    expect(
      container.read(modelComparisonControllerProvider).hasResults,
      isTrue,
    );

    controller.clear();

    final state = container.read(modelComparisonControllerProvider);
    expect(state.results, isEmpty);
    expect(state.stage, ComparisonStage.idle);
    expect(state.selectedModelIds, ['a', 'b']);
    expect(state.prompt, 'Keep me');
  });

  test(
    'builds an export from the finished run and copies each format',
    () async {
      final runtime = ScriptedComparisonRuntime(
        script: [
          ['first answer'],
          ['second answer'],
        ],
      );
      final container = containerFor(
        runtime: runtime,
        installedModels: [model('a'), model('b')],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        modelComparisonControllerProvider.notifier,
      );

      // Nothing to export before a run.
      expect(controller.buildExport(), isNull);
      expect(
        await controller.copyExportToClipboard(ComparisonExportFormat.json),
        isFalse,
      );

      controller
        ..toggleModel('a')
        ..toggleModel('b')
        ..setPrompt('Say hi');
      await controller.run();

      final export = controller.buildExport()!;
      expect(export.prompt, 'Say hi');
      expect(export.results, hasLength(2));
      expect(export.wasStopped, isFalse);
      expect(export.configuration.contextTokens, greaterThan(0));
      expect(
        export.configuration.temperature,
        ModelComparisonService.temperature,
      );

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
        await controller.copyExportToClipboard(ComparisonExportFormat.csv),
        isTrue,
      );
      expect(copied, contains('first answer'));
      expect(copied, startsWith(comparisonCsvColumns.join(',')));
    },
  );

  test('blind mode hides names until a model is revealed or picked', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['first answer'],
        ['second answer'],
      ],
    );
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setBlind(true);
    await controller.run();

    var state = container.read(modelComparisonControllerProvider);
    expect(state.blind, isTrue);
    expect(state.isBlindFor('a'), isTrue);
    expect(state.isBlindFor('b'), isTrue);
    expect(state.blindLabelFor('a'), 'Answer A');
    expect(state.blindLabelFor('b'), 'Answer B');
    expect(state.canChoosePreferred, isTrue);

    controller.revealModel('a');
    state = container.read(modelComparisonControllerProvider);
    expect(state.isBlindFor('a'), isFalse);
    expect(state.isBlindFor('b'), isTrue);

    // Picking an answer also names the model it came from.
    controller.choosePreferred('b');
    state = container.read(modelComparisonControllerProvider);
    expect(state.preferredModelId, 'b');
    expect(state.isBlindFor('b'), isFalse);

    controller.revealAll();
    state = container.read(modelComparisonControllerProvider);
    expect(state.revealedModelIds, {'a', 'b'});
  });

  test('a new run clears the revealed models and the preference', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['first answer'],
        ['second answer'],
        ['again'],
        ['again'],
      ],
    );
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setBlind(true);
    await controller.run();
    controller
      ..revealAll()
      ..choosePreferred('a');

    await controller.run();

    final state = container.read(modelComparisonControllerProvider);
    expect(state.revealedModelIds, isEmpty);
    expect(state.preferredModelId, isNull);
    expect(state.isBlindFor('a'), isTrue);
  });

  test('turning blind off reveals the answers again', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['first answer'],
        ['second answer'],
      ],
    );
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setBlind(true);
    await controller.run();
    controller.choosePreferred('a');

    controller.setBlind(false);

    final state = container.read(modelComparisonControllerProvider);
    expect(state.blind, isFalse);
    expect(state.isBlindFor('a'), isFalse);
    // A preference survives the switch, so revealing names never loses it.
    expect(state.preferredModelId, 'a');

    controller.clearPreferred();
    expect(
      container.read(modelComparisonControllerProvider).preferredModelId,
      isNull,
    );
  });

  test('preference needs at least two answers', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['partial'],
        ['never'],
      ],
    )..holdAtEnd = true;
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('a')
      ..toggleModel('b');
    final run = controller.run();
    await pumpUntil(() => runtime.isWaiting);
    controller.cancel();
    await run;

    final state = container.read(modelComparisonControllerProvider);
    expect(state.results, hasLength(1));
    expect(state.canChoosePreferred, isFalse);

    controller.choosePreferred('a');
    expect(
      container.read(modelComparisonControllerProvider).preferredModelId,
      isNull,
    );
  });

  test('the export records the blind flag and the preferred model', () async {
    final runtime = ScriptedComparisonRuntime(
      script: [
        ['first answer'],
        ['second answer'],
      ],
    );
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setBlind(true);
    await controller.run();
    controller.choosePreferred('b');

    final export = controller.buildExport()!;
    expect(export.blind, isTrue);
    expect(export.preferredModelId, 'b');
    expect(export.preferredAnswerLabel, 'Model b');
  });

  test('refuses an empty prompt', () async {
    final runtime = ScriptedComparisonRuntime();
    final container = containerFor(
      runtime: runtime,
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setPrompt('   ');
    await controller.run();

    final state = container.read(modelComparisonControllerProvider);
    expect(state.errorMessage, contains('Enter a prompt'));
    expect(runtime.loadedModelPaths, isEmpty);
  });
}
