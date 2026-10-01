import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/personas/data/persona_store.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

void main() {
  late Directory tempDir;
  late File file;
  late PersonaStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_personas_test');
    file = File(p.join(tempDir.path, 'personas', 'personas.json'));
    store = PersonaStore(file);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

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

  List<File> backups() => tempDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((entry) => entry.path.contains('.corrupt-'))
      .toList();

  group('PersonaStore', () {
    test('reports the built-ins when nothing has been saved yet', () {
      final snapshot = store.load();

      expect(snapshot.customPersonas, isEmpty);
      expect(snapshot.defaultPersonaId, BuiltInPersonas.generalId);
      expect(snapshot.allPersonas, hasLength(5));
      expect(store.isReadOnly, isFalse);
    });

    test('round-trips a custom persona and the default selection', () {
      expect(
        store.save(
          PersonasSnapshot(customPersonas: [custom()], defaultPersonaId: 'p-1'),
        ),
        isTrue,
      );

      final reloaded = PersonaStore(file).load();
      expect(reloaded.customPersonas, hasLength(1));
      expect(reloaded.customPersonas.single.name, 'Reviewer');
      expect(
        reloaded.customPersonas.single.systemPrompt,
        'Review code carefully.',
      );
      expect(reloaded.customPersonas.single.defaultModelId, 'm-1');
      expect(reloaded.customPersonas.single.inferenceProfileId, 'profile-1');
      expect(reloaded.defaultPersonaId, 'p-1');
      expect(reloaded.allPersonas, hasLength(6));
    });

    test('writes a versioned payload without the built-ins', () {
      store.save(
        PersonasSnapshot(customPersonas: [custom()], defaultPersonaId: 'p-1'),
      );

      final payload =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(payload['version'], PersonaStore.currentVersion);
      expect(payload['defaultPersonaId'], 'p-1');
      final personas = payload['personas'] as List<dynamic>;
      expect(personas, hasLength(1));
      expect((personas.single as Map<String, dynamic>)['id'], 'p-1');
    });

    test('recovers from an unreadable payload and preserves it', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('definitely not json');

      expect(store.load().customPersonas, isEmpty);
      store.save(PersonasSnapshot.empty);

      expect(backups(), hasLength(1));
      expect(backups().single.readAsStringSync(), 'definitely not json');
    });

    test('treats a payload where no persona parses as unreadable', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'personas': [
            <String, dynamic>{},
            {'name': 'no id'},
          ],
        }),
      );

      expect(store.load().customPersonas, isEmpty);
      store.save(PersonasSnapshot.empty);

      expect(backups(), hasLength(1));
    });

    test('leaves a file from a newer build untouched', () {
      final raw = jsonEncode({
        'version': PersonaStore.currentVersion + 1,
        'defaultPersonaId': 'p-9',
        'personas': [
          {'id': 'p-9', 'name': 'Future persona'},
        ],
      });
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(raw);

      final snapshot = store.load();
      expect(snapshot.customPersonas, isEmpty);
      expect(snapshot.defaultPersonaId, BuiltInPersonas.generalId);
      expect(store.isReadOnly, isTrue);
      expect(store.save(PersonasSnapshot.empty), isFalse);
      expect(file.readAsStringSync(), raw);
    });

    test('ignores stored built-in personas so the shipped ones win', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'personas': [
            {
              'id': BuiltInPersonas.codingId,
              'name': 'Edited built-in',
              'systemPrompt': 'Obedient.',
            },
            {
              'id': 'p-2',
              'name': 'Also built in',
              'isBuiltIn': true,
              'systemPrompt': 'Obedient.',
            },
            {'id': 'p-3', 'name': 'Real custom'},
          ],
        }),
      );

      final snapshot = store.load();
      expect(snapshot.customPersonas.map((persona) => persona.id), ['p-3']);
      expect(
        snapshot.allPersonas
            .firstWhere((persona) => persona.id == BuiltInPersonas.codingId)
            .name,
        'Coding',
      );
    });

    test('upsert replaces by id and appends new personas', () {
      final snapshot = PersonasSnapshot(
        customPersonas: [
          custom(),
          custom(id: 'p-2', name: 'Second'),
        ],
        defaultPersonaId: 'p-1',
      );

      final replaced = snapshot.upsert(custom(name: 'Renamed'));
      expect(replaced.customPersonas.map((persona) => persona.name), [
        'Renamed',
        'Second',
      ]);

      final added = snapshot.upsert(custom(id: 'p-3', name: 'Third'));
      expect(added.customPersonas, hasLength(3));
      expect(added.customPersonas.last.id, 'p-3');
    });

    test('remove falls back to the general persona when the default goes', () {
      final snapshot = PersonasSnapshot(
        customPersonas: [
          custom(),
          custom(id: 'p-2', name: 'Second'),
        ],
        defaultPersonaId: 'p-1',
      );

      final removed = snapshot.remove('p-1');
      expect(removed.customPersonas.map((persona) => persona.id), ['p-2']);
      expect(removed.defaultPersonaId, BuiltInPersonas.generalId);

      final untouched = snapshot.remove('p-2');
      expect(untouched.defaultPersonaId, 'p-1');
    });
  });
}
