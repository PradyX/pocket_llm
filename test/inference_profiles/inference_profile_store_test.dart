import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/inference_profiles/data/inference_profile_store.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';

void main() {
  late Directory tempDir;
  late File file;
  late InferenceProfileStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_profiles_test');
    file = File(p.join(tempDir.path, 'inference_profiles', 'profiles.json'));
    store = InferenceProfileStore(file);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  InferenceProfile custom({String id = 'p-1', String name = 'Phone chat'}) {
    return InferenceProfile.create(
      id: id,
      name: name,
      description: 'Small context',
    ).copyWith(contextTokens: 2048, threads: 4);
  }

  group('InferenceProfileStore', () {
    test('reports the built-ins when nothing has been saved yet', () {
      final snapshot = store.load();

      expect(snapshot.customProfiles, isEmpty);
      expect(snapshot.activeProfileId, BuiltInProfiles.balancedId);
      expect(snapshot.allProfiles, hasLength(3));
      expect(store.isReadOnly, isFalse);
    });

    test('round-trips a custom profile and the active selection', () {
      expect(
        store.save(
          InferenceProfilesSnapshot(
            customProfiles: [custom()],
            activeProfileId: 'p-1',
          ),
        ),
        isTrue,
      );

      final reloaded = InferenceProfileStore(file).load();
      expect(reloaded.customProfiles, hasLength(1));
      expect(reloaded.customProfiles.single.name, 'Phone chat');
      expect(reloaded.customProfiles.single.contextTokens, 2048);
      expect(reloaded.customProfiles.single.threads, 4);
      expect(reloaded.activeProfileId, 'p-1');
      expect(reloaded.allProfiles, hasLength(4));
    });

    test('writes a versioned payload without the built-ins', () {
      store.save(
        InferenceProfilesSnapshot(
          customProfiles: [custom()],
          activeProfileId: 'p-1',
        ),
      );

      final payload =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(payload['version'], InferenceProfileStore.currentVersion);
      expect(payload['activeProfileId'], 'p-1');
      final profiles = payload['profiles'] as List<dynamic>;
      expect(profiles, hasLength(1));
      expect((profiles.single as Map<String, dynamic>)['id'], 'p-1');
    });

    test('recovers from an unreadable payload and preserves it', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('not json at all');

      expect(store.load().customProfiles, isEmpty);
      store.save(InferenceProfilesSnapshot.empty);

      final backups = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
      expect(backups.single.readAsStringSync(), 'not json at all');
    });

    test('treats a payload where no entry parses as unreadable', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'profiles': [
            <String, dynamic>{},
            {'name': 'no id'},
          ],
        }),
      );

      expect(store.load().customProfiles, isEmpty);
      store.save(InferenceProfilesSnapshot.empty);

      final backups = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
    });

    test('keeps unreadable entries from being rewritten as a backup', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'activeProfileId': 'p-9',
          'profiles': [
            {'id': 'p-9', 'name': 'Good', 'threads': 4},
          ],
        }),
      );

      final snapshot = store.load();
      expect(snapshot.customProfiles.single.name, 'Good');
      expect(snapshot.activeProfileId, 'p-9');
      store.save(snapshot);

      final backups = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((entry) => entry.path.contains('.corrupt-'));
      expect(backups, isEmpty);
    });

    test('leaves a file from a newer build untouched', () {
      final raw = jsonEncode({
        'version': InferenceProfileStore.currentVersion + 1,
        'activeProfileId': 'p-1',
        'profiles': [
          {'id': 'p-1', 'name': 'Future', 'contextTokens': 65536},
        ],
      });
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(raw);

      final snapshot = store.load();
      expect(snapshot.customProfiles, isEmpty);
      expect(snapshot.activeProfileId, BuiltInProfiles.balancedId);
      expect(store.isReadOnly, isTrue);
      expect(store.save(InferenceProfilesSnapshot.empty), isFalse);
      expect(file.readAsStringSync(), raw);
    });

    test('ignores stored built-in entries so the shipped ones win', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'profiles': [
            {
              'id': BuiltInProfiles.balancedId,
              'name': 'Edited built-in',
              'contextTokens': 512,
            },
            {
              'id': 'p-2',
              'name': 'Also built in',
              'isBuiltIn': true,
              'contextTokens': 512,
            },
            {'id': 'p-3', 'name': 'Real custom'},
          ],
        }),
      );

      final snapshot = store.load();
      expect(snapshot.customProfiles.map((profile) => profile.id), ['p-3']);
      expect(
        snapshot.allProfiles
            .firstWhere((profile) => profile.id == BuiltInProfiles.balancedId)
            .name,
        'Balanced',
      );
    });

    test('defaults the active profile to the balanced built-in', () {
      expect(
        InferenceProfilesSnapshot.empty.activeProfileId,
        BuiltInProfiles.balancedId,
      );
      expect(store.load().activeProfileId, BuiltInProfiles.balancedId);
      expect(store.load().allProfiles.first.id, BuiltInProfiles.balancedId);
    });

    test('upsert replaces by id and appends new profiles', () {
      final snapshot = InferenceProfilesSnapshot(
        customProfiles: [
          custom(),
          custom(id: 'p-2', name: 'Second'),
        ],
        activeProfileId: 'p-1',
      );

      final replaced = snapshot.upsert(custom(name: 'Renamed'));
      expect(replaced.customProfiles.map((profile) => profile.name), [
        'Renamed',
        'Second',
      ]);

      final added = snapshot.upsert(custom(id: 'p-3', name: 'Third'));
      expect(added.customProfiles, hasLength(3));
      expect(added.customProfiles.last.id, 'p-3');
    });

    test('remove falls back to the default when the active profile goes', () {
      final snapshot = InferenceProfilesSnapshot(
        customProfiles: [
          custom(),
          custom(id: 'p-2', name: 'Second'),
        ],
        activeProfileId: 'p-1',
      );

      final removed = snapshot.remove('p-1');
      expect(removed.customProfiles.map((profile) => profile.id), ['p-2']);
      expect(removed.activeProfileId, BuiltInProfiles.balancedId);

      final untouched = snapshot.remove('p-2');
      expect(untouched.activeProfileId, 'p-1');
    });
  });
}
