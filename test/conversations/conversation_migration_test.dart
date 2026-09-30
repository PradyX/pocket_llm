import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/conversations/data/conversation_migration.dart';
import 'package:pocket_llm/features/conversations/data/conversation_repository.dart';
import 'package:pocket_llm/features/conversations/data/conversation_store.dart';

void main() {
  late Directory tempDir;
  late ConversationRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_migration_test');
    repository = ConversationRepository(
      ConversationStore(rootDirectory: tempDir),
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Map<String, dynamic> legacyPayload() {
    return {
      'byModel': {
        'model-a': [
          {
            'id': 'm1',
            'text': 'Hello',
            'isUser': true,
            'timestamp': '2026-01-01T10:00:00.000',
          },
          {
            'id': 'm2',
            'text': 'Hi!',
            'isUser': false,
            'timestamp': '2026-01-01T10:00:05.000',
            'generatedTokens': 4,
            'elapsedMs': 500,
            'tokensPerSecond': 8.0,
          },
        ],
        'model-b': <dynamic>[],
      },
    };
  }

  test('migrates per-model threads into conversations', () async {
    final migration = ConversationMigration(
      repository: repository,
      legacyChatsReader: () async => legacyPayload(),
    );

    expect(await migration.migrateLegacyChatsIfNeeded(), 1);

    final summaries = await repository.loadSummaries();
    expect(summaries, hasLength(1));
    final conversation = summaries.single.conversation;
    expect(conversation.title, 'Hello');
    expect(conversation.activeModelId, 'model-a');
    expect(summaries.single.messageCount, 2);

    final messages = await repository.loadMessages(conversation.id);
    expect(messages, hasLength(2));
    expect(messages.first.isUser, isTrue);
    expect(messages.last.modelId, 'model-a');
    expect(messages.last.generationStats?.generatedTokens, 4);
    expect(messages.last.conversationId, conversation.id);
  });

  test('is idempotent even when the migration flag is lost', () async {
    final migration = ConversationMigration(
      repository: repository,
      legacyChatsReader: () async => legacyPayload(),
    );
    expect(await migration.migrateLegacyChatsIfNeeded(), 1);

    // Lose the index (and therefore the migration flag) but keep the files.
    await File(p.join(tempDir.path, 'index.json')).delete();

    final freshRepository = ConversationRepository(
      ConversationStore(rootDirectory: tempDir),
    );
    final secondRun = ConversationMigration(
      repository: freshRepository,
      legacyChatsReader: () async => legacyPayload(),
    );

    expect(await secondRun.migrateLegacyChatsIfNeeded(), 0);
    expect(await freshRepository.loadSummaries(), hasLength(1));
  });

  test('skips malformed legacy messages but keeps the thread', () async {
    final migration = ConversationMigration(
      repository: repository,
      legacyChatsReader: () async => {
        'byModel': {
          'model-a': [
            'not-a-map',
            {
              'id': 'm1',
              'text': 'Hello',
              'isUser': true,
              'timestamp': '2026-01-01T10:00:00.000',
            },
          ],
        },
      },
    );

    expect(await migration.migrateLegacyChatsIfNeeded(), 1);
    final conversation = (await repository.loadSummaries()).single.conversation;
    expect(await repository.loadMessages(conversation.id), hasLength(1));
  });

  test('marks nothing to migrate when the legacy payload is missing', () async {
    final migration = ConversationMigration(
      repository: repository,
      legacyChatsReader: () async => null,
    );
    expect(await migration.migrateLegacyChatsIfNeeded(), 0);
    expect(await migration.migrateLegacyChatsIfNeeded(), 0);
  });

  test('retries later when the legacy store cannot be read', () async {
    final migration = ConversationMigration(
      repository: repository,
      legacyChatsReader: () async => throw StateError('storage unavailable'),
    );
    expect(await migration.migrateLegacyChatsIfNeeded(), 0);

    final secondRun = ConversationMigration(
      repository: repository,
      legacyChatsReader: () async => legacyPayload(),
    );
    expect(await secondRun.migrateLegacyChatsIfNeeded(), 1);
  });
}
