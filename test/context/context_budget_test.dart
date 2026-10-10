import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/context/application/context_budget_controller.dart';
import 'package:pocket_llm/features/context/data/context_budget_store.dart';
import 'package:pocket_llm/features/context/domain/context_budget.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';

void main() {
  group('ContextBudget', () {
    test('starts automatic and caps nothing', () {
      const budget = ContextBudget.auto;
      expect(budget.mode, ContextBudgetMode.auto);
      expect(budget.isManual, isFalse);
      expect(budget.windowCap, isNull);
    });

    test('ignores a stored cap while the mode is automatic', () {
      const budget = ContextBudget(maxContextTokens: 4096);
      expect(budget.windowCap, isNull);
      expect(budget.maxContextTokens, 4096);
    });

    test('honours the cap in manual mode', () {
      const budget = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 4096,
      );
      expect(budget.windowCap, 4096);
    });

    test('clamps a stored cap into the supported range', () {
      const tooSmall = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 1,
      );
      const tooLarge = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 999999,
      );
      expect(tooSmall.normalized().maxContextTokens, 512);
      expect(tooLarge.normalized().maxContextTokens, 32768);
    });

    test('round-trips through JSON', () {
      const budget = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 8192,
      );
      final restored = ContextBudget.fromJson(budget.toJson());
      expect(restored.mode, ContextBudgetMode.manual);
      expect(restored.maxContextTokens, 8192);
    });

    test('falls back to automatic for unusable stored values', () {
      expect(
        ContextBudget.fromJson(const {'mode': 'fast'}).mode,
        ContextBudgetMode.auto,
      );
      expect(ContextBudget.fromJson(const {}).mode, ContextBudgetMode.auto);
      expect(
        ContextBudget.fromJson(const {
          'mode': 'manual',
          'maxContextTokens': 'x',
        }).maxContextTokens,
        isNull,
      );
      // A cap stored as a string still reads, because a hand-edited file can
      // carry either shape.
      expect(
        ContextBudget.fromJson(const {
          'maxContextTokens': '4096',
        }).maxContextTokens,
        4096,
      );
    });

    test('copyWith can clear the cap', () {
      const budget = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 4096,
      );
      expect(
        budget.copyWith(clearMaxContextTokens: true).maxContextTokens,
        isNull,
      );
      expect(
        budget.copyWith(mode: ContextBudgetMode.auto).mode,
        ContextBudgetMode.auto,
      );
    });

    test('resolvePolicy in automatic mode matches the ungoverned policy', () {
      final expected = ContextPolicy.forModel(
        runtimeContextTokens: 4096,
        declaredContextTokens: 8192,
        reservedOutputTokens: 512,
      );
      final actual = ContextBudget.auto.resolvePolicy(
        runtimeContextTokens: 4096,
        declaredContextTokens: 8192,
        reservedOutputTokens: 512,
      );
      expect(actual.contextTokens, expected.contextTokens);
      expect(actual.reservedOutputTokens, expected.reservedOutputTokens);
      expect(actual.usableInputTokens, expected.usableInputTokens);
    });

    test('resolvePolicy lowers the window to the manual cap', () {
      const budget = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 1024,
      );
      final policy = budget.resolvePolicy(
        runtimeContextTokens: 8192,
        reservedOutputTokens: 512,
      );
      expect(policy.contextTokens, 1024);
      expect(policy.usableInputTokens, 1024 - 512 - 64);
    });

    test('a cap above the model still leaves the model in charge', () {
      const budget = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 16384,
      );
      final policy = budget.resolvePolicy(
        runtimeContextTokens: 8192,
        declaredContextTokens: 2048,
        reservedOutputTokens: 512,
      );
      expect(policy.contextTokens, 2048);
    });

    test('a cap above the runtime window cannot enlarge it', () {
      const budget = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 16384,
      );
      final policy = budget.resolvePolicy(
        runtimeContextTokens: 4096,
        reservedOutputTokens: 256,
      );
      expect(policy.contextTokens, 4096);
    });

    test('retrieval is still capped by the smaller manual window', () {
      const budget = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 1024,
      );
      final policy = budget.resolvePolicy(
        runtimeContextTokens: 8192,
        reservedOutputTokens: 256,
        retrievalTokens: ContextPolicy.defaultRetrievalTokens,
      );
      expect(policy.contextTokens, 1024);
      expect(policy.retrievalTokens, policy.maximumRetrievalTokens);
    });

    test('an unusable runtime window still resolves to the app fallback', () {
      const budget = ContextBudget(
        mode: ContextBudgetMode.manual,
        maxContextTokens: 8192,
      );
      expect(
        budget
            .resolvePolicy(runtimeContextTokens: 0, reservedOutputTokens: 256)
            .contextTokens,
        ContextPolicy.fallbackContextTokens,
      );
    });
  });

  group('describeContextBudget', () {
    test('reports the model maximum as the budget in automatic mode', () {
      final outcome = describeContextBudget(
        budget: ContextBudget.auto,
        runtimeContextTokens: 4096,
        declaredContextTokens: 8192,
        reservedOutputTokens: 512,
      );
      expect(outcome.budgetTokens, 4096);
      expect(outcome.modelMaximumTokens, 4096);
      expect(outcome.isCapped, isFalse);
      expect(outcome.capNote, isNull);
      expect(outcome.budgetLabel, '4.1K');
    });

    test('describes a manual cap that is honoured as asked', () {
      final outcome = describeContextBudget(
        budget: const ContextBudget(
          mode: ContextBudgetMode.manual,
          maxContextTokens: 2048,
        ),
        runtimeContextTokens: 8192,
        reservedOutputTokens: 512,
      );
      expect(outcome.budgetTokens, 2048);
      expect(outcome.modelMaximumTokens, 8192);
      expect(outcome.isCapped, isTrue);
      expect(outcome.cappedBy, isNull);
      expect(outcome.capNote, 'Limited to 2.0K tokens.');
    });

    test('says what lowered a cap the model refuses', () {
      final byModel = describeContextBudget(
        budget: const ContextBudget(
          mode: ContextBudgetMode.manual,
          maxContextTokens: 16384,
        ),
        runtimeContextTokens: 8192,
        declaredContextTokens: 2048,
        reservedOutputTokens: 512,
      );
      expect(byModel.budgetTokens, 2048);
      expect(
        byModel.capNote,
        "Asked for 16K tokens; The model's declared context allows 2.0K.",
      );

      final byPlatform = describeContextBudget(
        budget: const ContextBudget(
          mode: ContextBudgetMode.manual,
          maxContextTokens: 16384,
        ),
        runtimeContextTokens: 4096,
        reservedOutputTokens: 512,
      );
      expect(byPlatform.budgetTokens, 4096);
      expect(
        byPlatform.capNote,
        'Asked for 16K tokens; The platform window allows 4.1K.',
      );
    });
  });

  group('ContextBudgetStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pocketllm_budget');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    File budgetFile() => File('${tempDir.path}/context/budget.json');
    ContextBudgetStore store() => ContextBudgetStore(budgetFile());

    test('a missing file reads as automatic', () {
      final loaded = store().load();
      expect(loaded.mode, ContextBudgetMode.auto);
      expect(loaded.maxContextTokens, isNull);
      expect(store().isReadOnly, isFalse);
    });

    test('saves and loads a manual budget', () {
      final target = store();
      expect(
        target.save(
          const ContextBudget(
            mode: ContextBudgetMode.manual,
            maxContextTokens: 4096,
          ),
        ),
        isTrue,
      );

      final reloaded = store().load();
      expect(reloaded.mode, ContextBudgetMode.manual);
      expect(reloaded.maxContextTokens, 4096);

      final payload =
          jsonDecode(budgetFile().readAsStringSync()) as Map<String, dynamic>;
      expect(payload['version'], ContextBudgetStore.currentVersion);
    });

    test('an unreadable file is copied aside before it is rewritten', () {
      budgetFile().parent.createSync(recursive: true);
      budgetFile().writeAsStringSync('{not json');

      expect(store().load().mode, ContextBudgetMode.auto);
      expect(
        store().save(
          const ContextBudget(
            mode: ContextBudgetMode.manual,
            maxContextTokens: 2048,
          ),
        ),
        isTrue,
      );

      final backups = budgetFile().parent
          .listSync()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
      expect(store().load().maxContextTokens, 2048);
    });

    test('a file from a newer build is left alone and cannot be written', () {
      budgetFile().parent.createSync(recursive: true);
      budgetFile().writeAsStringSync(
        jsonEncode({
          'version': ContextBudgetStore.currentVersion + 1,
          'mode': 'manual',
          'maxContextTokens': 8192,
        }),
      );

      final newer = store();
      expect(newer.load().mode, ContextBudgetMode.auto);
      expect(newer.isReadOnly, isTrue);
      expect(newer.save(ContextBudget.auto), isFalse);
      // Untouched on disk.
      expect(
        (jsonDecode(budgetFile().readAsStringSync())
            as Map<String, dynamic>)['maxContextTokens'],
        8192,
      );
    });
  });

  group('ContextBudgetNotifier', () {
    late Directory tempDir;
    late File file;
    late ContextBudgetStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pocketllm_budget_ctl');
      file = File(p.join(tempDir.path, 'context', 'budget.json'));
      store = ContextBudgetStore(file);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    ProviderContainer buildContainer() {
      final container = ProviderContainer(
        overrides: [
          contextBudgetStoreProvider.overrideWith((ref) async => store),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    /// Reads the notifier and waits for the stored budget to load.
    Future<ContextBudgetNotifier> loaded(ProviderContainer container) async {
      final notifier = container.read(contextBudgetProvider.notifier);
      for (var attempt = 0; attempt < 50; attempt++) {
        if (container.read(contextBudgetProvider).isReady) break;
        await Future<void>.delayed(Duration.zero);
      }
      expect(container.read(contextBudgetProvider).isReady, isTrue);
      return notifier;
    }

    test('starts automatic on a fresh device', () async {
      final container = buildContainer();
      await loaded(container);

      final state = container.read(contextBudgetProvider);
      expect(state.budget.mode, ContextBudgetMode.auto);
      expect(state.budget.maxContextTokens, isNull);
      expect(state.errorMessage, isNull);
      expect(state.isReadOnly, isFalse);
    });

    test('switching to manual stores a starting cap and persists it', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      expect(await notifier.setMode(ContextBudgetMode.manual), isTrue);
      final stored = container.read(contextBudgetProvider).budget;
      expect(stored.mode, ContextBudgetMode.manual);
      expect(
        stored.maxContextTokens,
        ContextBudgetNotifier.defaultManualContextTokens,
      );
      expect(store.load().maxContextTokens, stored.maxContextTokens);

      expect(await notifier.setMaxContextTokens(8192), isTrue);
      expect(store.load().maxContextTokens, 8192);
      final written = jsonDecode(file.readAsStringSync()) as Map;
      expect(written['version'], ContextBudgetStore.currentVersion);
      expect(written['mode'], 'manual');
      expect(written['maxContextTokens'], 8192);
    });

    test('a stored budget is read back on the next start', () async {
      ContextBudgetStore(file).save(
        const ContextBudget(
          mode: ContextBudgetMode.manual,
          maxContextTokens: 4096,
        ),
      );
      final container = buildContainer();
      await loaded(container);

      final state = container.read(contextBudgetProvider);
      expect(state.budget.mode, ContextBudgetMode.manual);
      expect(state.budget.maxContextTokens, 4096);
    });

    test('resetting to automatic clears the stored cap', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      await notifier.setMode(ContextBudgetMode.manual);
      await notifier.setMaxContextTokens(4096);
      expect(await notifier.resetToAuto(), isTrue);
      expect(
        container.read(contextBudgetProvider).budget.mode,
        ContextBudgetMode.auto,
      );
      expect(store.load().maxContextTokens, isNull);
    });

    test('a read-only store refuses a change and explains why', () async {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': ContextBudgetStore.currentVersion + 1,
          'mode': 'manual',
          'maxContextTokens': 8192,
        }),
      );
      final container = buildContainer();
      final notifier = await loaded(container);

      expect(container.read(contextBudgetProvider).isReadOnly, isTrue);
      expect(
        container.read(contextBudgetProvider).errorMessage,
        contains('newer version'),
      );
      expect(await notifier.setMode(ContextBudgetMode.manual), isFalse);
      final state = container.read(contextBudgetProvider);
      expect(state.budget.mode, ContextBudgetMode.auto);
      expect(state.budget.maxContextTokens, isNull);
      expect(state.errorMessage, contains('newer version'));
    });
  });
}
