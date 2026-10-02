import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/benchmark/data/comparison_set_store.dart';
import 'package:pocket_llm/features/benchmark/domain/comparison_set.dart';

void main() {
  late Directory tempDir;
  late File file;
  late ComparisonSetStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_sets_test');
    file = File(p.join(tempDir.path, 'benchmark', 'comparison_sets.json'));
    store = ComparisonSetStore(file);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ComparisonSet set({
    String id = 'set-1',
    String name = 'Small models',
    List<String> modelIds = const ['a', 'b'],
    List<String> prompts = const ['Say hi'],
    bool blind = false,
  }) {
    return ComparisonSet(
      id: id,
      name: name,
      modelIds: modelIds,
      prompts: prompts,
      blind: blind,
      createdAt: DateTime(2026, 10, 2, 12),
    );
  }

  List<File> backups() => tempDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((entry) => entry.path.contains('.corrupt-'))
      .toList();

  test('round-trips a saved set', () {
    expect(store.save([set(blind: true)]), isTrue);

    final loaded = store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'set-1');
    expect(loaded.single.name, 'Small models');
    expect(loaded.single.modelIds, ['a', 'b']);
    expect(loaded.single.prompts, ['Say hi']);
    expect(loaded.single.blind, isTrue);
    expect(loaded.single.createdAt, DateTime(2026, 10, 2, 12));
  });

  test('reads an empty file as no saved sets', () {
    expect(store.load(), isEmpty);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('');
    expect(store.load(), isEmpty);
  });

  test('skips entries that could never run a comparison', () {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'sets': [
          {
            'id': 'keep',
            'name': 'Keep me',
            'prompts': ['hi'],
            'modelIds': ['a', 'b'],
          },
          {
            'name': 'No id',
            'prompts': ['hi'],
            'modelIds': ['a'],
          },
          {
            'id': 'no-name',
            'prompts': ['hi'],
            'modelIds': ['a'],
          },
          {
            'id': 'no-prompt',
            'name': 'No prompt',
            'modelIds': ['a'],
          },
          {
            'id': 'no-models',
            'name': 'No models',
            'prompts': ['hi'],
          },
          'not-a-map',
        ],
      }),
    );

    final loaded = store.load();
    expect(loaded.map((entry) => entry.id), ['keep']);
  });

  test('clamps stored values to what a run accepts', () {
    store.save([
      set(
        name: 'x' * (ComparisonSet.maximumNameLength + 20),
        modelIds: ['a', 'b', 'c', 'd', 'e', 'f'],
        prompts: ['y' * (ComparisonSet.maximumPromptLength + 100), 'second'],
      ),
    ]);

    final loaded = store.load().single;
    expect(loaded.name.length, ComparisonSet.maximumNameLength);
    expect(loaded.modelIds, ['a', 'b', 'c', 'd']);
    expect(loaded.prompts.first.length, ComparisonSet.maximumPromptLength);
    expect(loaded.prompts, hasLength(2));
  });

  test('keeps at most the maximum number of sets on write', () {
    store.save([
      for (var index = 0; index < ComparisonSetStore.maximumSets + 5; index++)
        set(id: 'set-$index', name: 'Set $index'),
    ]);

    expect(store.load(), hasLength(ComparisonSetStore.maximumSets));
  });

  test('copies a damaged file aside before overwriting it', () {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{not json at all');

    expect(store.load(), isEmpty);
    expect(store.save([set()]), isTrue);
    expect(backups(), hasLength(1));
    expect(store.load(), hasLength(1));
  });

  test('treats a payload with no usable set as damaged', () {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'sets': [
          {'id': 'x'},
        ],
      }),
    );

    expect(store.load(), isEmpty);
    expect(store.save([set()]), isTrue);
    expect(backups(), hasLength(1));
  });

  test('leaves a file written by a newer build untouched', () {
    file.parent.createSync(recursive: true);
    final newer = jsonEncode({
      'version': ComparisonSetStore.currentVersion + 1,
      'sets': [
        {
          'id': 'future',
          'name': 'Future',
          'prompts': ['hi'],
          'modelIds': ['a'],
        },
      ],
    });
    file.writeAsStringSync(newer);

    expect(store.load(), isEmpty);
    expect(store.isReadOnly, isTrue);
    expect(store.save([set()]), isFalse);
    expect(file.readAsStringSync(), newer);
    expect(backups(), isEmpty);
  });
}
