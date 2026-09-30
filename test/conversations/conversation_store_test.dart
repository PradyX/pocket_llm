import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/conversations/data/conversation_store.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';

void main() {
  late Directory tempDir;
  late ConversationStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_store_test');
    store = ConversationStore(rootDirectory: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Conversation conversation({String id = 'c-1', String title = 'Chat'}) {
    return Conversation.create(id: id, title: title);
  }

  Message message(String conversationId, String content) {
    return Message.create(
      conversationId: conversationId,
      role: MessageRole.user,
      content: content,
    );
  }

  File indexFile() => File(p.join(tempDir.path, 'index.json'));

  test('starts empty and writes a valid index after loading', () async {
    expect(await store.loadSummaries(), isEmpty);
    expect(await indexFile().exists(), isTrue);
    final decoded = jsonDecode(await indexFile().readAsString()) as Map;
    expect(decoded['schemaVersion'], conversationStoreSchemaVersion);
  });

  test('creates, loads and updates conversations', () async {
    await store.createConversation(conversation());
    final summaries = await store.loadSummaries();
    expect(summaries, hasLength(1));

    final loaded = await store.loadConversation('c-1');
    expect(loaded?.title, 'Chat');

    await store.updateConversation(loaded!.copyWith(title: 'Renamed'));
    expect((await store.loadConversation('c-1'))?.title, 'Renamed');
  });

  test('saves messages and updates the summary preview', () async {
    await store.createConversation(conversation());
    await store.saveMessages(conversation(), [message('c-1', 'Hello there')]);

    final messages = await store.loadMessages('c-1');
    expect(messages, hasLength(1));
    expect(messages.single.content, 'Hello there');

    final summary = (await store.loadSummaries()).single;
    expect(summary.messageCount, 1);
    expect(summary.lastMessagePreview, 'Hello there');
    expect(summary.lastMessageAt, isNotNull);
  });

  test('deletes a conversation file and index entry', () async {
    await store.createConversation(conversation());
    await store.deleteConversation('c-1');
    expect(await store.loadSummaries(), isEmpty);
    expect(await File(p.join(tempDir.path, 'c-1.json')).exists(), isFalse);
  });

  test('rebuilds a corrupt index from conversation files', () async {
    await store.createConversation(conversation());
    await indexFile().writeAsString('not json');

    final summaries = await store.loadSummaries();
    expect(summaries, hasLength(1));
    expect(summaries.single.conversation.id, 'c-1');

    final index = jsonDecode(await indexFile().readAsString()) as Map;
    expect(index['schemaVersion'], conversationStoreSchemaVersion);
  });

  test('skips corrupt conversation files without deleting them', () async {
    await store.createConversation(conversation());
    final corrupt = File(p.join(tempDir.path, 'c-broken.json'));
    await corrupt.writeAsString('{ not valid json');

    final summaries = await store.loadSummaries();
    expect(summaries, hasLength(1));
    expect(await corrupt.exists(), isTrue);
  });

  test('leaves an index with an unsupported schema untouched', () async {
    const futureIndex = '{"schemaVersion": 99, "conversations": []}';
    await indexFile().writeAsString(futureIndex);

    expect(await store.loadSummaries(), isEmpty);
    expect(await indexFile().readAsString(), futureIndex);
  });

  test('round-trips metadata flags', () async {
    expect(await store.readMetaFlag('migrated'), isFalse);
    await store.writeMetaFlag('migrated', true);
    expect(await store.readMetaFlag('migrated'), isTrue);
    final index = jsonDecode(await indexFile().readAsString()) as Map;
    expect((index['meta'] as Map)['migrated'], isTrue);
  });

  test('leaves no temporary files behind after writes', () async {
    await store.createConversation(conversation());
    await store.saveMessages(conversation(), [message('c-1', 'Hello')]);
    final leftovers = tempDir.listSync().whereType<File>().where(
      (file) => file.path.endsWith('.tmp'),
    );
    expect(leftovers, isEmpty);
  });
}
