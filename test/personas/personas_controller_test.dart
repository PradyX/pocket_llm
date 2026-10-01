import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/personas/application/personas_controller.dart';
import 'package:pocket_llm/features/personas/data/persona_store.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

void main() {
  late Directory tempDir;
  late File file;
  late PersonaStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_personas_ctrl');
    file = File(p.join(tempDir.path, 'personas', 'personas.json'));
    store = PersonaStore(file);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [personaStoreProvider.overrideWith((ref) async => store)],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Reads the notifier and waits for the stored selection to load.
  Future<PersonasNotifier> loaded(ProviderContainer container) async {
    final notifier = container.read(personasProvider.notifier);
    for (var attempt = 0; attempt < 50; attempt++) {
      if (container.read(personasProvider).isReady) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(personasProvider).isReady, isTrue);
    return notifier;
  }

  group('PersonasNotifier', () {
    test('starts on the built-ins with general as the default', () async {
      final container = buildContainer();
      await loaded(container);

      final state = container.read(personasProvider);
      expect(state.builtInPersonas, hasLength(5));
      expect(state.customPersonas, isEmpty);
      expect(state.defaultPersona.name, 'General');
      expect(state.errorMessage, isNull);
    });

    test(
      'resolves a conversation persona and falls back to the default',
      () async {
        final container = buildContainer();
        await loaded(container);

        final state = container.read(personasProvider);
        expect(state.resolve(BuiltInPersonas.conciseId).name, 'Concise');
        expect(state.resolve(null).name, 'General');
        expect(state.resolve('missing').name, 'General');
      },
    );

    test('keeps the default selection across sessions', () async {
      final container = buildContainer();
      final notifier = await loaded(container);
      expect(await notifier.selectDefault(BuiltInPersonas.conciseId), isTrue);

      final reopened = buildContainer();
      await loaded(reopened);
      expect(reopened.read(personasProvider).defaultPersona.name, 'Concise');
    });

    test('ignores unknown persona ids', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      expect(await notifier.selectDefault('missing'), isFalse);
      expect(
        container.read(personasProvider).defaultPersonaId,
        BuiltInPersonas.generalId,
      );
    });

    test('saves a custom persona and reloads it', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final saved = await notifier.savePersona(
        Persona.create(id: 'p-1', name: 'Reviewer').copyWith(
          systemPrompt: 'Review carefully.',
          inferenceProfileId: 'profile-1',
        ),
      );
      expect(saved, isNotNull);

      final reopened = buildContainer();
      await loaded(reopened);
      final state = reopened.read(personasProvider);
      expect(state.customPersonas, hasLength(1));
      expect(state.personaById('p-1')?.systemPrompt, 'Review carefully.');
      expect(state.personaById('p-1')?.inferenceProfileId, 'profile-1');
    });

    test('trims a pasted prompt before storing it', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final saved = await notifier.savePersona(
        Persona.create(name: 'Padded').copyWith(
          systemPrompt: 'x' * (PersonaLimits.maxSystemPromptCharacters + 200),
        ),
      );

      expect(
        saved?.systemPrompt.length,
        PersonaLimits.maxSystemPromptCharacters,
      );
    });

    test('refuses to edit or delete a built-in persona', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      expect(
        await notifier.savePersona(
          BuiltInPersonas.general.copyWith(name: 'Edited'),
        ),
        isNull,
      );
      expect(
        container.read(personasProvider).errorMessage,
        contains('read-only'),
      );

      notifier.clearError();
      expect(await notifier.deletePersona(BuiltInPersonas.codingId), isFalse);
      expect(
        container.read(personasProvider).errorMessage,
        contains('cannot be deleted'),
      );
      expect(container.read(personasProvider).builtInPersonas, hasLength(5));
    });

    test('duplicates a built-in into an editable copy', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final copy = await notifier.duplicatePersona(BuiltInPersonas.concise);

      expect(copy, isNotNull);
      expect(copy!.isBuiltIn, isFalse);
      expect(copy.name, 'Concise copy');
      expect(copy.systemPrompt, BuiltInPersonas.concise.systemPrompt);
      expect(container.read(personasProvider).customPersonas, hasLength(1));
    });

    test('deleting the default persona falls back to general', () async {
      final container = buildContainer();
      final notifier = await loaded(container);
      final saved = await notifier.savePersona(
        Persona.create(id: 'p-1', name: 'Temporary'),
      );
      await notifier.selectDefault(saved!.id);
      expect(container.read(personasProvider).defaultPersonaId, 'p-1');

      expect(await notifier.deletePersona('p-1'), isTrue);

      final state = container.read(personasProvider);
      expect(state.customPersonas, isEmpty);
      expect(state.defaultPersonaId, BuiltInPersonas.generalId);
      expect(state.defaultPersona.name, 'General');
    });

    test('reports personas written by a newer build as read-only', () async {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({'version': 99, 'personas': <Object>[]}),
      );

      final container = buildContainer();
      final notifier = await loaded(container);
      final state = container.read(personasProvider);

      expect(state.isReadOnly, isTrue);
      expect(state.errorMessage, contains('newer version'));

      final saved = await notifier.savePersona(
        Persona.create(id: 'p-1', name: 'Blocked'),
      );
      expect(saved, isNull);
      expect(
        container.read(personasProvider).errorMessage,
        contains('newer version'),
      );
    });
  });
}
