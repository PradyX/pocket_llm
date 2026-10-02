import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/benchmark/application/model_comparison_controller.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';
import 'package:pocket_llm/features/benchmark/data/comparison_set_store.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

import 'scripted_comparison_runtime.dart';

void main() {
  late Directory tempDir;
  late File setFile;
  late ComparisonSetStore setStore;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_sets_ctrl');
    setFile = File(p.join(tempDir.path, 'benchmark', 'comparison_sets.json'));
    setStore = ComparisonSetStore(setFile);
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
    ComparisonSetStore? store,
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
        comparisonSetStoreProvider.overrideWith(
          (ref) async => store ?? setStore,
        ),
      ],
    );
  }

  /// Waits for the controller's one-time read of the stored sets.
  Future<void> settleSets(ProviderContainer container) async {
    container.read(modelComparisonControllerProvider.notifier);
    await container.read(comparisonSetStoreProvider.future);
    await Future<void>.delayed(Duration.zero);
  }

  ModelComparisonController controllerOf(ProviderContainer container) =>
      container.read(modelComparisonControllerProvider.notifier);

  ModelComparisonState stateOf(ProviderContainer container) =>
      container.read(modelComparisonControllerProvider);

  test('saves the current models, prompt and blind switch', () async {
    final container = containerFor(
      runtime: ScriptedComparisonRuntime(),
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = controllerOf(container);
    await settleSets(container);

    controller
      ..toggleModel('b')
      ..toggleModel('a')
      ..setPrompt('Say hi')
      ..setBlind(true);
    final saved = await controller.saveCurrentAsSet('  Morning check  ');

    expect(saved, isTrue);
    final state = stateOf(container);
    expect(state.savedSets, hasLength(1));
    expect(state.savedSets.single.name, 'Morning check');
    expect(state.savedSets.single.modelIds, ['b', 'a']);
    expect(state.savedSets.single.prompts, ['Say hi']);
    expect(state.savedSets.single.blind, isTrue);
    expect(state.notice, contains('Morning check'));
    expect(setStore.load(), hasLength(1));
  });

  test('saving the same name replaces that set', () async {
    final container = containerFor(
      runtime: ScriptedComparisonRuntime(),
      installedModels: [model('a'), model('b'), model('c')],
    );
    addTearDown(container.dispose);
    final controller = controllerOf(container);
    await settleSets(container);

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setPrompt('First prompt');
    await controller.saveCurrentAsSet('Daily');
    final createdAt = stateOf(container).savedSets.single.createdAt;

    controller.clear();
    controller
      ..toggleModel('b')
      ..toggleModel('c')
      ..setPrompt('Second prompt');
    await controller.saveCurrentAsSet('daily');

    final state = stateOf(container);
    expect(state.savedSets, hasLength(1));
    expect(state.savedSets.single.prompts, ['Second prompt']);
    expect(state.savedSets.single.modelIds, ['a', 'c']);
    expect(state.savedSets.single.createdAt, createdAt);
    expect(setStore.load().single.prompts, ['Second prompt']);
  });

  test('refuses to save without enough models or a prompt', () async {
    final container = containerFor(
      runtime: ScriptedComparisonRuntime(),
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = controllerOf(container);
    await settleSets(container);

    controller.toggleModel('a');
    expect(await controller.saveCurrentAsSet('Too few'), isFalse);
    expect(stateOf(container).errorMessage, contains('at least 2 models'));

    controller.toggleModel('b');
    controller.setPrompt('   ');
    expect(await controller.saveCurrentAsSet('No prompt'), isFalse);
    expect(stateOf(container).errorMessage, contains('Enter a prompt'));

    expect(await controller.saveCurrentAsSet('   '), isFalse);
    expect(stateOf(container).errorMessage, contains('name'));
    expect(stateOf(container).savedSets, isEmpty);
  });

  test('loads a saved set back into the tab', () async {
    final container = containerFor(
      runtime: ScriptedComparisonRuntime(),
      installedModels: [model('a'), model('b'), model('c')],
    );
    addTearDown(container.dispose);
    final controller = controllerOf(container);
    await settleSets(container);

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setPrompt('Saved prompt')
      ..setBlind(true);
    await controller.saveCurrentAsSet('Daily');
    final id = stateOf(container).savedSets.single.id;

    controller.clear();
    controller
      ..setPrompt('Something else')
      ..setBlind(false);
    controller.applySet(id);

    final state = stateOf(container);
    expect(state.prompt, 'Saved prompt');
    expect(state.selectedModelIds, ['a', 'b']);
    expect(state.blind, isTrue);
    expect(state.results, isEmpty);
    expect(state.notice, contains('Daily'));
    expect(state.errorMessage, isNull);
  });

  test('loading a set reports models that are no longer installed', () async {
    final container = containerFor(
      runtime: ScriptedComparisonRuntime(),
      installedModels: [model('a'), model('b'), model('c')],
    );
    addTearDown(container.dispose);
    final controller = controllerOf(container);
    await settleSets(container);

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..toggleModel('c')
      ..setPrompt('Saved prompt');
    await controller.saveCurrentAsSet('Daily');
    final id = stateOf(container).savedSets.single.id;
    container.dispose();

    final redeployed = containerFor(
      runtime: ScriptedComparisonRuntime(),
      installedModels: [model('a'), model('c')],
    );
    addTearDown(redeployed.dispose);
    await settleSets(redeployed);
    controllerOf(redeployed).applySet(id);

    final state = stateOf(redeployed);
    expect(state.selectedModelIds, ['a', 'c']);
    expect(state.notice, contains('1 of 3'));
  });

  test('deletes a saved set and persists the removal', () async {
    final container = containerFor(
      runtime: ScriptedComparisonRuntime(),
      installedModels: [model('a'), model('b')],
    );
    addTearDown(container.dispose);
    final controller = controllerOf(container);
    await settleSets(container);

    controller
      ..toggleModel('a')
      ..toggleModel('b')
      ..setPrompt('Saved prompt');
    await controller.saveCurrentAsSet('Daily');
    final id = stateOf(container).savedSets.single.id;

    expect(await controller.deleteSet(id), isTrue);
    expect(stateOf(container).savedSets, isEmpty);
    expect(stateOf(container).notice, contains('Daily'));
    expect(setStore.load(), isEmpty);
  });

  test(
    'reports a store written by a newer build instead of changing it',
    () async {
      setFile.parent.createSync(recursive: true);
      setFile.writeAsStringSync('{"version": 99, "sets": []}');

      final container = containerFor(
        runtime: ScriptedComparisonRuntime(),
        installedModels: [model('a'), model('b')],
      );
      addTearDown(container.dispose);
      final controller = controllerOf(container);
      await settleSets(container);

      expect(stateOf(container).savedSetsReady, isTrue);
      expect(stateOf(container).savedSetsReadOnly, isTrue);

      controller
        ..toggleModel('a')
        ..toggleModel('b')
        ..setPrompt('Saved prompt');
      expect(await controller.saveCurrentAsSet('Daily'), isFalse);
      expect(stateOf(container).errorMessage, contains('newer version'));
    },
  );
}
