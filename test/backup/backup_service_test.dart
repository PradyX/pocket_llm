import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/backup/application/backup_service.dart';
import 'package:pocket_llm/features/backup/domain/backup_archive.dart';
import 'package:pocket_llm/features/benchmark/application/benchmark_history.dart';
import 'package:pocket_llm/features/conversations/data/conversation_repository.dart';
import 'package:pocket_llm/features/conversations/data/conversation_store.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/documents/data/document_index_store.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/inference_profiles/data/inference_profile_store.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';
import 'package:pocket_llm/features/personas/data/persona_store.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

/// One device's stores, over a temporary directory.
class _Device {
  _Device(this.root);

  final Directory root;
  final Map<String, String> settings = {};

  late final ConversationRepository conversations = ConversationRepository(
    ConversationStore(rootDirectory: Directory('${root.path}/conversations')),
  );
  late final PersonaStore personas = PersonaStore(
    File('${root.path}/personas/personas.json'),
  );
  late final InferenceProfileStore profiles = InferenceProfileStore(
    File('${root.path}/inference_profiles/profiles.json'),
  );
  late final BenchmarkHistory benchmarks = BenchmarkHistory(
    File('${root.path}/benchmarks/history.json'),
  );
  late final DocumentIndexStore documents = DocumentIndexStore(
    File('${root.path}/documents/index.json'),
  );

  BackupService get service => BackupService(
    conversations: conversations,
    personas: personas,
    profiles: profiles,
    readSetting: (key) async => settings[key],
    writeSetting: (key, value) async => settings[key] = value,
    benchmarks: benchmarks,
    documents: documents,
  );
}

BenchmarkRunRecord _run(String id) => BenchmarkRunRecord(
  id: id,
  modelId: 'qwen-2.5-0.5b-instruct',
  modelName: 'Qwen2.5 0.5B Instruct',
  modelParameterSize: '494M',
  modelPromptFormatId: 'chatml',
  latencyMs: 1200,
  tokensPerSecond: 18.5,
  generatedTokens: 64,
  outputTextPreview: 'hello',
  errorMessage: null,
  isSuccess: true,
  timestamp: DateTime(2026, 10, 8, 10),
);

IndexedDocument _document() => IndexedDocument(
  source: DocumentSource(
    id: 'doc-1',
    path: '/tmp/notes.txt',
    name: 'notes.txt',
    format: DocumentFormat.text,
    sizeBytes: 120,
    modifiedAt: DateTime(2026, 10, 7),
    addedAt: DateTime(2026, 10, 7),
  ),
  chunks: const [
    DocumentChunk(index: 0, text: 'local text', startOffset: 0, endOffset: 10),
  ],
  charCount: 10,
  indexedAt: DateTime(2026, 10, 7),
  contentHash: 'abcd',
);

void main() {
  late Directory temp;
  late _Device source;
  late _Device target;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('backup-test');
    source = _Device(Directory('${temp.path}/source'));
    target = _Device(Directory('${temp.path}/target'));
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> seed(_Device device) async {
    final conversation = await device.conversations.createConversation(
      id: 'c-1',
      title: 'Local chat',
      activeModelId: 'qwen-2.5-0.5b-instruct',
    );
    await device.conversations.saveMessages(conversation, [
      Message(
        id: 'm-1',
        conversationId: conversation.id,
        role: MessageRole.user,
        content: 'What is 18% of 2450?',
        createdAt: DateTime(2026, 10, 8, 9),
      ),
      Message(
        id: 'm-2',
        conversationId: conversation.id,
        role: MessageRole.assistant,
        content: '441',
        createdAt: DateTime(2026, 10, 8, 9, 1),
        modelId: 'qwen-2.5-0.5b-instruct',
        modelName: 'Qwen2.5 0.5B Instruct',
      ),
    ]);
    device.personas.save(
      device.personas.load().upsert(
        // Not a built-in name: those are seeded on every device, so a persona
        // that clashes with one is renamed on import (covered below).
        Persona.create(name: 'Local researcher', systemPrompt: 'Be brief.'),
      ),
    );
    device.profiles.save(
      device.profiles.load().upsert(
        InferenceProfile.create(name: 'Fast local'),
      ),
    );
    device.settings['inference_settings'] = '{"maxTokens":512}';
    device.settings['voice_settings'] = '{"speakingRate":1.0}';
    device.benchmarks.writeAll([_run('run-1')]);
    device.documents.save(DocumentIndexSnapshot.empty.upsert(_document()));
  }

  test('a backup carries every selected section and nothing else', () async {
    await seed(source);

    final archive = await source.service.capture(
      selection: BackupSelection.everything,
      appVersion: '1.5.0',
    );

    expect(archive.manifest.countOf(BackupSection.conversations), 1);
    expect(archive.manifest.countOf(BackupSection.personas), 1);
    expect(archive.manifest.countOf(BackupSection.inferenceProfiles), 1);
    expect(archive.manifest.countOf(BackupSection.settings), 2);
    expect(archive.manifest.countOf(BackupSection.benchmarks), 1);
    expect(archive.manifest.countOf(BackupSection.knowledge), 1);

    final narrowed = await source.service.capture(
      selection: const BackupSelection(
        conversations: false,
        personas: false,
        inferenceProfiles: false,
        settings: false,
        benchmarks: false,
        knowledge: false,
      ),
      appVersion: '1.5.0',
    );
    expect(narrowed.sections, isEmpty);
  });

  test(
    'a backup restores onto an empty device and reports missing models',
    () async {
      await seed(source);
      final archive = await source.service.capture(
        selection: BackupSelection.everything,
        appVersion: '1.5.0',
      );

      // Round trip through the file format, as a real import would.
      final restored = await target.service.apply(
        BackupArchive.decode(archive.encode()),
        installedModelIds: const {},
      );

      expect(restored.conversationsImported, 1);
      expect(restored.conversationsAddedAsCopies, 0);
      expect(restored.personasImported, 1);
      expect(restored.profilesImported, 1);
      expect(restored.settingsRestored, 2);
      expect(restored.benchmarkRunsImported, 1);
      expect(restored.knowledgeDocumentsImported, 1);
      // The conversation names the model it was written with; the target device
      // does not have it, so the import reports rather than fails.
      expect(restored.missingModels, ['Qwen2.5 0.5B Instruct']);
      expect(restored.notes, isEmpty);

      final conversations = await target.conversations.loadSummaries();
      expect(conversations, hasLength(1));
      final messages = await target.conversations.loadMessages('c-1');
      expect(messages.map((message) => message.content), [
        'What is 18% of 2450?',
        '441',
      ]);
      expect(target.settings['inference_settings'], '{"maxTokens":512}');
      expect(
        target.personas.load().customPersonas.single.name,
        'Local researcher',
      );
      expect(target.profiles.load().customProfiles.single.name, 'Fast local');
      expect(target.benchmarks.loadRuns().single.id, 'run-1');
      expect(
        target.documents.read()?.documents.single.chunks.single.text,
        'local text',
      );

      // A model that is installed is not reported.
      final withModel = await target.service.apply(
        BackupArchive.decode(archive.encode()),
        installedModelIds: const {'qwen-2.5-0.5b-instruct'},
      );
      expect(withModel.missingModels, isEmpty);
    },
  );

  test('importing twice adds copies instead of overwriting chats', () async {
    await seed(source);
    final encoded = (await source.service.capture(
      selection: const BackupSelection(),
      appVersion: '1.5.0',
    )).encode();

    await target.service.apply(
      BackupArchive.decode(encoded),
      installedModelIds: const {},
    );
    final second = await target.service.apply(
      BackupArchive.decode(encoded),
      installedModelIds: const {},
    );

    expect(second.conversationsImported, 1);
    expect(second.conversationsAddedAsCopies, 1);
    expect(
      second.notes.single,
      contains('were already here and were added as copies'),
    );
    expect(await target.conversations.loadSummaries(), hasLength(2));
    // The first import is untouched.
    expect(
      (await target.conversations.loadMessages('c-1')).map((m) => m.content),
      ['What is 18% of 2450?', '441'],
    );
  });

  test('a persona whose name is taken is imported as a copy', () async {
    await seed(source);
    final encoded = (await source.service.capture(
      selection: const BackupSelection(
        conversations: false,
        personas: true,
        inferenceProfiles: false,
        settings: false,
        benchmarks: false,
      ),
      appVersion: '1.5.0',
    )).encode();

    // The target already has a persona with the same name and another id.
    target.personas.save(
      target.personas.load().upsert(
        Persona.create(id: 'local-persona', name: 'Local researcher'),
      ),
    );

    final report = await target.service.apply(
      BackupArchive.decode(encoded),
      installedModelIds: const {},
    );

    expect(report.personasImported, 1);
    expect(report.personasRenamed, 1);
    final names = target.personas
        .load()
        .customPersonas
        .map((persona) => persona.name)
        .toList();
    expect(
      names,
      containsAll(['Local researcher', 'Local researcher (imported)']),
    );

    // Importing the same file again changes nothing: the id is already here.
    final again = await target.service.apply(
      BackupArchive.decode(encoded),
      installedModelIds: const {},
    );
    expect(again.personasImported, 0);
    expect(again.personasSkipped, 1);
    expect(target.personas.load().customPersonas, hasLength(2));
  });

  test('one unreadable section does not stop the rest of the import', () async {
    await seed(source);
    final archive = await source.service.capture(
      selection: BackupSelection.everything,
      appVersion: '1.5.0',
    );
    // Damage the conversation section the way a hand-edited file would be.
    final damaged = BackupArchive(
      manifest: archive.manifest,
      sections: {
        ...archive.sections,
        BackupSection.conversations: {'format': 'not.this.app'},
      },
    );

    final report = await target.service.apply(
      BackupArchive.decode(damaged.encode()),
      installedModelIds: const {},
    );

    expect(report.conversationsImported, 0);
    expect(report.notes.single, contains('Conversations were not imported'));
    // Everything else still arrived.
    expect(report.personasImported, 1);
    expect(report.profilesImported, 1);
    expect(report.benchmarkRunsImported, 1);
    expect(report.settingsRestored, 2);
    expect(report.knowledgeDocumentsImported, 1);
  });

  test(
    'unknown settings keys and duplicate benchmark runs are reported',
    () async {
      final archive = BackupArchive(
        manifest: BackupManifest(
          appVersion: '1.5.0',
          createdAt: DateTime(2026, 10, 8),
          platform: 'linux',
          counts: const {},
        ),
        sections: {
          BackupSection.settings: {
            'inference_settings': '{"maxTokens":256}',
            'some_future_setting': '{"x":1}',
          },
          BackupSection.benchmarks: [
            _run('run-1').toJson(),
            _run('run-1').toJson(),
          ],
        },
      );

      final report = await target.service.apply(
        archive,
        installedModelIds: const {},
      );

      expect(report.settingsRestored, 1);
      expect(report.notes, contains(contains('some_future_setting')));
      expect(report.benchmarkRunsImported, 1);
      expect(report.benchmarkRunsSkipped, 1);
    },
  );

  test('a backup with only settings still imports', () async {
    await seed(source);
    final archive = await source.service.capture(
      selection: const BackupSelection(
        conversations: false,
        personas: false,
        inferenceProfiles: false,
        settings: true,
        benchmarks: false,
      ),
      appVersion: '1.5.0',
    );

    expect(archive.includedSections, [BackupSection.settings]);
    final report = await target.service.apply(
      archive,
      installedModelIds: const {},
    );
    expect(report.settingsRestored, 2);
    expect(report.isEmpty, isFalse);
  });
}
