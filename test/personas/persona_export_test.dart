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
    tempDir = await Directory.systemTemp.createTemp('pocketllm_persona_export');
    file = File(p.join(tempDir.path, 'personas', 'personas.json'));
    store = PersonaStore(file);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ProviderContainer buildContainer([PersonaStore? personaStore]) {
    final container = ProviderContainer(
      overrides: [
        personaStoreProvider.overrideWith((ref) async => personaStore ?? store),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<PersonasNotifier> loaded(ProviderContainer container) async {
    final notifier = container.read(personasProvider.notifier);
    for (var attempt = 0; attempt < 50; attempt++) {
      if (container.read(personasProvider).isReady) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(personasProvider).isReady, isTrue);
    return notifier;
  }

  Persona custom({String id = 'p-1', String name = 'Reviewer'}) {
    return Persona.create(
      id: id,
      name: name,
      description: 'Strict but kind',
      systemPrompt: 'Review code carefully.',
      defaultModelId: 'm-1',
      inferenceProfileId: 'profile-1',
    );
  }

  Map<String, dynamic> payloadOf(String json) =>
      jsonDecode(json) as Map<String, dynamic>;

  group('persona export', () {
    test('exports every persona with a format marker and version', () async {
      final container = buildContainer();
      final notifier = await loaded(container);
      await notifier.savePersona(custom());

      final payload = payloadOf(notifier.exportJson());

      expect(payload['format'], personaExportFormat);
      expect(payload['schemaVersion'], personaExportSchemaVersion);
      expect(payload['exportedAt'], isA<String>());
      final personas = payload['personas'] as List<dynamic>;
      // Five built-ins plus the custom persona.
      expect(personas, hasLength(6));
      expect(
        personas.map((entry) => (entry as Map<String, dynamic>)['name']),
        contains('Reviewer'),
      );
    });

    test('exports a single persona, including a built-in', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final payload = payloadOf(
        notifier.exportJson(personaId: BuiltInPersonas.conciseId),
      );

      final personas = payload['personas'] as List<dynamic>;
      expect(personas, hasLength(1));
      expect((personas.single as Map<String, dynamic>)['name'], 'Concise');
      expect(notifier.exportJson(personaId: 'missing'), isNotNull);
      expect(
        (payloadOf(notifier.exportJson(personaId: 'missing'))['personas']
                as List<dynamic>)
            .isEmpty,
        isTrue,
      );
    });

    test('round-trips a persona through export and import', () async {
      final source = buildContainer();
      final sourceNotifier = await loaded(source);
      final saved = await sourceNotifier.savePersona(custom());
      final exported = sourceNotifier.exportJson(personaId: saved!.id);

      // A separate store: the same id is free on a device that never saw it.
      final targetFile = File(
        p.join(tempDir.path, 'second_device', 'personas.json'),
      );
      final target = buildContainer(PersonaStore(targetFile));
      final targetNotifier = await loaded(target);
      final imported = await targetNotifier.importJson(exported);

      expect(imported, hasLength(1));
      expect(imported.single.id, 'p-1');
      expect(imported.single.name, 'Reviewer');
      expect(imported.single.systemPrompt, 'Review code carefully.');
      expect(imported.single.defaultModelId, 'm-1');
      expect(imported.single.inferenceProfileId, 'profile-1');
      expect(imported.single.isBuiltIn, isFalse);
      expect(target.read(personasProvider).customPersonas, hasLength(1));
      expect(target.read(personasProvider).builtInPersonas, hasLength(5));
    });

    test('imports a built-in as an editable custom copy', () async {
      final source = buildContainer();
      final sourceNotifier = await loaded(source);
      final exported = sourceNotifier.exportJson(
        personaId: BuiltInPersonas.creativeId,
      );

      final target = buildContainer();
      final targetNotifier = await loaded(target);
      final imported = await targetNotifier.importJson(exported);

      expect(imported.single.isBuiltIn, isFalse);
      expect(imported.single.name, 'Creative');
      expect(
        imported.single.systemPrompt,
        BuiltInPersonas.creative.systemPrompt,
      );
      expect(target.read(personasProvider).customPersonas, hasLength(1));
    });

    test('re-importing assigns fresh ids instead of overwriting', () async {
      final container = buildContainer();
      final notifier = await loaded(container);
      final saved = await notifier.savePersona(custom());
      final exported = notifier.exportJson(personaId: saved!.id);

      final imported = await notifier.importJson(exported);

      expect(imported.single.id, isNot('p-1'));
      expect(imported.single.name, 'Reviewer');
      expect(
        container
            .read(personasProvider)
            .customPersonas
            .map((persona) => persona.name),
        ['Reviewer', 'Reviewer'],
      );
    });

    test('keeps the stored default persona when importing', () async {
      final container = buildContainer();
      final notifier = await loaded(container);
      final exported = notifier.exportJson(
        personaId: BuiltInPersonas.conciseId,
      );
      await notifier.selectDefault(BuiltInPersonas.conciseId);

      await notifier.importJson(exported);

      expect(
        container.read(personasProvider).defaultPersonaId,
        BuiltInPersonas.conciseId,
      );
      expect(container.read(personasProvider).customPersonas, hasLength(1));
    });

    test('rejects payloads that are not persona exports', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      expect(
        () => notifier.importJson('not json'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
      expect(
        () => notifier.importJson('[1, 2, 3]'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('not a JSON object'),
          ),
        ),
      );
      expect(
        () => notifier.importJson(jsonEncode({'format': 'something-else'})),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Unrecognized persona export format'),
          ),
        ),
      );
      expect(
        () => notifier.importJson(
          jsonEncode({
            'format': personaExportFormat,
            'schemaVersion': personaExportSchemaVersion + 1,
            'personas': <Object>[],
          }),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Unsupported persona export schema version'),
          ),
        ),
      );
      expect(
        () => notifier.importJson(
          jsonEncode({'format': personaExportFormat, 'schemaVersion': 1}),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('has no personas'),
          ),
        ),
      );
    });

    test('skips unusable entries and reports nothing to import', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final imported = await notifier.importJson(
        jsonEncode({
          'format': personaExportFormat,
          'schemaVersion': personaExportSchemaVersion,
          'personas': [
            {'name': 'no id'},
            'not a map',
          ],
        }),
      );

      expect(imported, isEmpty);
      expect(container.read(personasProvider).customPersonas, isEmpty);
    });
  });
}
