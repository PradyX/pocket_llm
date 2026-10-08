import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/data/conversation_store.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/presentation/conversation_controller.dart';

void main() {
  // The controller's startup path reads the stores through platform plugins.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_lifecycle_test');
    // Deleting a conversation also removes the attachments its messages
    // carried, which resolves the app's own directory through the platform
    // channel; pointing that at the temporary directory keeps the test off the
    // real app folders.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tempDir.path,
        );
    container = ProviderContainer(
      overrides: [
        conversationStoreProvider.overrideWithValue(
          ConversationStore(rootDirectory: tempDir),
        ),
      ],
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    container.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Reads the controller until its asynchronous startup has finished.
  ///
  /// The controller is auto-disposed, so it also needs a listener for that
  /// startup to run to completion.
  Future<ConversationListState> start() async {
    final subscription = container.listen(
      conversationControllerProvider,
      (previous, next) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    for (var attempt = 0; attempt < 200; attempt++) {
      final state = container.read(conversationControllerProvider);
      if (state.isInitialized) return state;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('ConversationController did not finish initializing');
  }

  Message message(String conversationId, MessageRole role, String content) {
    return Message.create(
      conversationId: conversationId,
      role: role,
      content: content,
    );
  }

  test('the list entry follows the messages that were saved', () async {
    await start();
    final controller = container.read(conversationControllerProvider.notifier);
    final conversation = await controller.createConversation(id: 'c-1');

    await controller.saveConversationMessages(conversation.id, [
      message(conversation.id, MessageRole.user, 'hey'),
      message(
        conversation.id,
        MessageRole.assistant,
        'I can perform: calculator, date and chat history searches',
      ),
    ]);

    final afterSend = container
        .read(conversationControllerProvider)
        .summaries
        .single;
    expect(afterSend.messageCount, 2);
    expect(afterSend.lastMessagePreview, contains('I can perform'));

    // Saving an empty list is the store's clear path; the entry must not keep
    // describing messages that are no longer there.
    await controller.saveConversationMessages(conversation.id, const []);

    final afterClear = container
        .read(conversationControllerProvider)
        .summaries
        .single;
    expect(afterClear.messageCount, 0);
    expect(afterClear.lastMessagePreview, isEmpty);
    expect(afterClear.lastMessageAt, isNull);
  });

  test(
    'deleting the active conversation opens the most recent one left',
    () async {
      await start();
      final controller = container.read(
        conversationControllerProvider.notifier,
      );
      await controller.createConversation(id: 'c-1');
      final active = await controller.createConversation(id: 'c-2');
      await controller.saveConversationMessages(active.id, [
        message(active.id, MessageRole.user, 'second chat'),
      ]);

      await controller.deleteConversation(active.id);

      final state = container.read(conversationControllerProvider);
      expect(state.summaries, hasLength(1));
      expect(state.summaries.single.conversation.id, 'c-1');
      expect(state.activeConversationId, 'c-1');
      expect(state.activeConversation?.id, 'c-1');
    },
  );

  test('deleting the last conversation leaves nothing active', () async {
    await start();
    final controller = container.read(conversationControllerProvider.notifier);
    final only = await controller.createConversation(id: 'c-1');
    await controller.saveConversationMessages(only.id, [
      message(only.id, MessageRole.user, 'hey'),
    ]);

    await controller.deleteConversation(only.id);

    final state = container.read(conversationControllerProvider);
    expect(state.summaries, isEmpty);
    expect(state.activeConversationId, isNull);
    expect(state.activeConversation, isNull);
    expect(
      await container.read(conversationRepositoryProvider).loadMessages('c-1'),
      isEmpty,
    );
  });
}
