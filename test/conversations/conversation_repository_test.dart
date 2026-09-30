import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/data/conversation_repository.dart';
import 'package:pocket_llm/features/conversations/data/conversation_store.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';

void main() {
  late Directory tempDir;
  late ConversationRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_repo_test');
    repository = ConversationRepository(
      ConversationStore(rootDirectory: tempDir),
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('creates conversations with the default title', () async {
    final created = await repository.createConversation();
    expect(created.title, defaultConversationTitle);
  });

  test('renames, pins and switches the active model', () async {
    await repository.createConversation(id: 'c-1');
    await repository.renameConversation('c-1', 'Renamed');
    await repository.setPinned('c-1', true);
    await repository.setActiveModel('c-1', 'model-b');

    final updated = await repository.getConversation('c-1');
    expect(updated?.title, 'Renamed');
    expect(updated?.isPinned, isTrue);
    expect(updated?.activeModelId, 'model-b');
  });

  test('updating a missing conversation throws', () async {
    expect(
      () => repository.renameConversation('missing', 'x'),
      throwsA(isA<StateError>()),
    );
  });

  test('saving messages bumps updatedAt and clearing keeps the chat', () async {
    final created = await repository.createConversation(id: 'c-1');
    final message = Message.create(
      conversationId: 'c-1',
      role: MessageRole.user,
      content: 'Hi',
    );
    final saved = await repository.saveMessages(created, [message]);
    expect(saved.updatedAt.isBefore(created.updatedAt), isFalse);
    expect(await repository.loadMessages('c-1'), hasLength(1));

    await repository.clearMessages('c-1');
    expect(await repository.loadMessages('c-1'), isEmpty);
    expect(await repository.getConversation('c-1'), isNotNull);
  });

  test('deletes conversations', () async {
    await repository.createConversation(id: 'c-1');
    await repository.deleteConversation('c-1');
    expect(await repository.loadSummaries(), isEmpty);
  });

  test('exports and re-imports conversations without overwriting', () async {
    await repository.createConversation(id: 'c-1', title: 'Original');
    final conversation = await repository.getConversation('c-1');
    expect(conversation, isNotNull);
    await repository.saveMessages(conversation!, [
      Message.create(
        conversationId: 'c-1',
        role: MessageRole.user,
        content: 'Hello',
      ),
    ]);

    final payload = await repository.exportPayload();
    expect(payload['format'], conversationExportFormat);
    expect(payload['schemaVersion'], conversationExportSchemaVersion);
    expect((payload['conversations'] as List), hasLength(1));

    final json = await repository.exportJson(conversationIds: const ['c-1']);
    final imported = await repository.importJson(json);
    expect(imported, hasLength(1));
    expect(imported.single.id, isNot('c-1'));
    expect(await repository.loadSummaries(), hasLength(2));
    expect(await repository.loadMessages(imported.single.id), hasLength(1));
  });

  test('rejects unknown export formats', () async {
    expect(
      () => repository.importJson('{"format":"other"}'),
      throwsA(isA<FormatException>()),
    );
  });
}
