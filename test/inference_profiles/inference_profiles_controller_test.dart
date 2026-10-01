import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/inference_profiles/application/inference_profiles_controller.dart';
import 'package:pocket_llm/features/inference_profiles/data/inference_profile_store.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';

void main() {
  late Directory tempDir;
  late File file;
  late InferenceProfileStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_profiles_ctrl');
    file = File(p.join(tempDir.path, 'inference_profiles', 'profiles.json'));
    store = InferenceProfileStore(file);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        inferenceProfileStoreProvider.overrideWith((ref) async => store),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Reads the notifier and waits for the stored selection to load.
  Future<InferenceProfilesNotifier> loaded(ProviderContainer container) async {
    final notifier = container.read(inferenceProfilesProvider.notifier);
    for (var attempt = 0; attempt < 50; attempt++) {
      if (container.read(inferenceProfilesProvider).isReady) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(inferenceProfilesProvider).isReady, isTrue);
    return notifier;
  }

  group('InferenceProfilesNotifier', () {
    test('starts on the built-ins with the balanced profile active', () async {
      final container = buildContainer();
      await loaded(container);

      final state = container.read(inferenceProfilesProvider);
      expect(state.builtInProfiles, hasLength(3));
      expect(state.customProfiles, isEmpty);
      expect(state.activeProfile.name, 'Balanced');
      expect(state.errorMessage, isNull);
    });

    test('keeps a selection across sessions', () async {
      final container = buildContainer();
      final notifier = await loaded(container);
      expect(await notifier.select(BuiltInProfiles.batterySaverId), isTrue);

      final reopened = buildContainer();
      await loaded(reopened);
      expect(
        reopened.read(inferenceProfilesProvider).activeProfile.name,
        'Battery Saver',
      );
    });

    test('ignores unknown profile ids', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      expect(await notifier.select('missing'), isFalse);
      expect(
        container.read(inferenceProfilesProvider).activeProfileId,
        BuiltInProfiles.balancedId,
      );
    });

    test('saves a custom profile and reloads it', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final saved = await notifier.saveProfile(
        InferenceProfile.create(
          id: 'p-1',
          name: 'Phone chat',
        ).copyWith(contextTokens: 2048, threads: 4),
      );
      expect(saved, isNotNull);

      final reopened = buildContainer();
      await loaded(reopened);
      final state = reopened.read(inferenceProfilesProvider);
      expect(state.customProfiles, hasLength(1));
      expect(state.profileById('p-1')?.contextTokens, 2048);
      expect(state.profileById('p-1')?.threads, 4);
    });

    test('clamps values before they are stored', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final saved = await notifier.saveProfile(
        InferenceProfile.create(
          id: 'p-1',
          name: 'Over the top',
        ).copyWith(contextTokens: 999999, temperature: 9),
      );

      expect(saved?.contextTokens, InferenceProfileLimits.maxContextTokens);
      expect(saved?.temperature, InferenceProfileLimits.maxTemperature);
    });

    test('refuses to edit or delete a built-in profile', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      expect(
        await notifier.saveProfile(
          BuiltInProfiles.balanced.copyWith(name: 'Edited'),
        ),
        isNull,
      );
      expect(
        container.read(inferenceProfilesProvider).errorMessage,
        contains('read-only'),
      );

      notifier.clearError();
      expect(await notifier.deleteProfile(BuiltInProfiles.balancedId), isFalse);
      expect(
        container.read(inferenceProfilesProvider).errorMessage,
        contains('cannot be deleted'),
      );
      expect(
        container.read(inferenceProfilesProvider).builtInProfiles,
        hasLength(3),
      );
    });

    test('duplicates a built-in into an editable copy', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final copy = await notifier.duplicateProfile(
        BuiltInProfiles.batterySaver,
      );

      expect(copy, isNotNull);
      expect(copy!.isBuiltIn, isFalse);
      expect(copy.name, 'Battery Saver copy');
      expect(copy.contextTokens, 1024);
      expect(
        container.read(inferenceProfilesProvider).customProfiles,
        hasLength(1),
      );
      expect(
        container.read(inferenceProfilesProvider).builtInProfiles,
        hasLength(3),
      );
    });

    test('deleting the active profile falls back to balanced', () async {
      final container = buildContainer();
      final notifier = await loaded(container);
      final saved = await notifier.saveProfile(
        InferenceProfile.create(id: 'p-1', name: 'Temporary'),
      );
      await notifier.select(saved!.id);
      expect(container.read(inferenceProfilesProvider).activeProfileId, 'p-1');

      expect(await notifier.deleteProfile('p-1'), isTrue);

      final state = container.read(inferenceProfilesProvider);
      expect(state.customProfiles, isEmpty);
      expect(state.activeProfileId, BuiltInProfiles.balancedId);
      expect(state.activeProfile.name, 'Balanced');
    });

    test('reports profiles written by a newer build as read-only', () async {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({'version': 99, 'profiles': <Object>[]}),
      );

      final container = buildContainer();
      final notifier = await loaded(container);
      final state = container.read(inferenceProfilesProvider);

      expect(state.isReadOnly, isTrue);
      expect(state.errorMessage, contains('newer version'));
      expect(state.activeProfile.name, 'Balanced');

      final saved = await notifier.saveProfile(
        InferenceProfile.create(id: 'p-1', name: 'Blocked'),
      );
      expect(saved, isNull);
      expect(
        container.read(inferenceProfilesProvider).errorMessage,
        contains('newer version'),
      );
    });
  });
}
