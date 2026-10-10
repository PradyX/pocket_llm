import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/group_chat/application/group_chat_controller.dart';
import 'package:pocket_llm/features/group_chat/data/group_chat_store.dart';
import 'package:pocket_llm/features/group_chat/domain/group_chat.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_direct_chat');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        groupChatStoreProvider.overrideWith(
          (ref) async => GroupChatStore(
            File(p.join(tempDir.path, 'group_chat', 'chats.json')),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<GroupChatsNotifier> loaded(ProviderContainer container) async {
    final notifier = container.read(groupChatsProvider.notifier);
    for (var attempt = 0; attempt < 50; attempt++) {
      if (container.read(groupChatsProvider).isReady) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(groupChatsProvider).isReady, isTrue);
    return notifier;
  }

  group('directChatWith', () {
    test('creates one 1:1 room and reuses it', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final first = await notifier.directChatWith(
        workspaceId: 'ws',
        botId: 'coder',
      );
      expect(first, isNotNull);
      expect(first!.isDirect, isTrue);
      expect(first.directBotId, 'coder');
      expect(first.memberBotIds, ['coder']);

      final second = await notifier.directChatWith(
        workspaceId: 'ws',
        botId: 'coder',
      );
      expect(second?.id, first.id);
      expect(
        container
            .read(groupChatsProvider)
            .snapshot
            .chats
            .where((chat) => chat.directBotId == 'coder')
            .length,
        1,
      );
    });

    test('keeps bots separate rooms apart', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final coder = await notifier.directChatWith(
        workspaceId: 'ws',
        botId: 'coder',
      );
      final planner = await notifier.directChatWith(
        workspaceId: 'ws',
        botId: 'planner',
      );
      expect(coder?.id, isNot(planner?.id));
    });

    test('a task room stays a room', () async {
      final container = buildContainer();
      final notifier = await loaded(container);

      final room = await notifier.createChat(
        workspaceId: 'ws',
        name: 'PL-001 Build it',
        memberBotIds: const ['coder'],
      );
      expect(room?.isDirect, isFalse);
    });
  });

  group('GroupChat direct json', () {
    test('round-trips the direct bot', () {
      final chat = GroupChat.create(
        workspaceId: 'ws',
        name: 'Coder',
        memberBotIds: const ['coder'],
        directBotId: 'coder',
      );
      final decoded = GroupChat.fromJson(chat.toJson())!;
      expect(decoded.directBotId, 'coder');
      expect(decoded.isDirect, isTrue);
    });

    test('documents without the key still read as rooms', () {
      final chat = GroupChat.create(
        workspaceId: 'ws',
        name: 'Room',
        memberBotIds: const ['coder'],
      );
      final json = chat.toJson()..remove('directBotId');
      final decoded = GroupChat.fromJson(json)!;
      expect(decoded.directBotId, isNull);
      expect(decoded.isDirect, isFalse);
    });
  });

  group('roomNeedsUser', () {
    test('badges a room waiting on a pasted reply', () {
      final chat = GroupChat.create(workspaceId: 'ws', name: 'Room');
      final quiet = GroupChatsSnapshot(chats: [chat]);
      expect(roomNeedsUser(quiet, chat.id), isFalse);

      final waiting = GroupChatsSnapshot(
        chats: [chat],
        messages: {
          chat.id: [
            GroupMessage.bot(
              chatId: chat.id,
              botId: 'coder',
              botName: 'Coder',
              text: 'No model yet — paste my reply.',
              pendingPrompt: 'Answer as Coder.',
            ),
          ],
        },
      );
      expect(roomNeedsUser(waiting, chat.id), isTrue);
    });
  });
}
