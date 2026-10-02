import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/domain/message_attachment.dart';
import 'package:pocket_llm/features/conversations/domain/message_tool_activity.dart';

void main() {
  group('Conversation', () {
    test('round-trips through JSON', () {
      final created = Conversation.create(
        id: 'c-1',
        title: '  Hello world  ',
        activeModelId: 'qwen2.5-1.5b',
      );
      final restored = Conversation.fromJson(created.toJson());

      expect(restored.id, 'c-1');
      expect(restored.title, 'Hello world');
      expect(restored.activeModelId, 'qwen2.5-1.5b');
      expect(restored.isPinned, isFalse);
      expect(
        restored.createdAt.millisecondsSinceEpoch,
        created.createdAt.millisecondsSinceEpoch,
      );
    });

    test('falls back to defaults for missing fields', () {
      final restored = Conversation.fromJson(const {});
      expect(restored.title, defaultConversationTitle);
      expect(restored.isPinned, isFalse);
      expect(restored.metadata, isEmpty);
    });

    test('withId keeps all other fields', () {
      final original = Conversation.create(id: 'c-1', title: 'Chat');
      final copy = original.withId('c-2');
      expect(copy.id, 'c-2');
      expect(copy.title, 'Chat');
      expect(copy.createdAt, original.createdAt);
    });

    test('copyWith can clear activeModelId', () {
      final conversation = Conversation.create(id: 'c-1', activeModelId: 'm');
      final cleared = conversation.copyWith(activeModelId: null);
      expect(cleared.activeModelId, isNull);
    });

    test('keeps the persona and profile bindings through JSON', () {
      final conversation = Conversation.create(
        id: 'c-1',
        title: 'Chat',
      ).copyWith(personaId: 'persona-1', inferenceProfileId: 'profile-1');

      final restored = Conversation.fromJson(conversation.toJson());
      expect(restored.personaId, 'persona-1');
      expect(restored.inferenceProfileId, 'profile-1');
    });

    test('reads conversations saved before personas existed', () {
      final restored = Conversation.fromJson(const {
        'id': 'c-1',
        'title': 'Old chat',
        'activeModelId': 'm-1',
      });

      expect(restored.personaId, isNull);
      expect(restored.inferenceProfileId, isNull);
      expect(restored.activeModelId, 'm-1');
    });

    test('copyWith sets and clears the persona binding', () {
      final conversation = Conversation.create(id: 'c-1', title: 'Chat');
      final bound = conversation.copyWith(personaId: 'persona-1');
      expect(bound.personaId, 'persona-1');

      final cleared = bound.copyWith(personaId: null);
      expect(cleared.personaId, isNull);
      expect(cleared.inferenceProfileId, isNull);
    });

    test('withId keeps the persona and profile bindings', () {
      final conversation = Conversation.create(
        id: 'c-1',
        title: 'Chat',
      ).copyWith(personaId: 'persona-1', inferenceProfileId: 'profile-1');

      final moved = conversation.withId('c-2');
      expect(moved.personaId, 'persona-1');
      expect(moved.inferenceProfileId, 'profile-1');
    });
  });

  group('ConversationSummary', () {
    test('round-trips through JSON', () {
      final conversation = Conversation.create(id: 'c-1', title: 'Chat');
      final summary = ConversationSummary(
        conversation: conversation,
        messageCount: 3,
        lastMessagePreview: 'Hello',
        lastMessageAt: DateTime(2026, 1, 1),
      );
      final restored = ConversationSummary.fromJson(summary.toJson());
      expect(restored.conversation.id, 'c-1');
      expect(restored.messageCount, 3);
      expect(restored.lastMessagePreview, 'Hello');
      expect(restored.lastMessageAt, DateTime(2026, 1, 1));
    });
  });

  group('Message', () {
    test('round-trips through JSON', () {
      final message = Message.create(
        conversationId: 'c-1',
        role: MessageRole.assistant,
        content: 'Hi there',
        modelId: 'model-a',
        modelName: 'Model A',
        generationStats: const MessageGenerationStats(
          generatedTokens: 12,
          elapsedMs: 1500,
          tokensPerSecond: 8.0,
        ),
        tokenCount: 12,
      );
      final restored = Message.fromJson(message.toJson());
      expect(restored.conversationId, 'c-1');
      expect(restored.role, MessageRole.assistant);
      expect(restored.content, 'Hi there');
      expect(restored.modelId, 'model-a');
      expect(restored.modelName, 'Model A');
      expect(restored.generationStats?.generatedTokens, 12);
      expect(restored.generationStats?.tokensPerSecond, 8.0);
      expect(restored.tokenCount, 12);
    });

    test('parses legacy per-model chat message JSON', () {
      final restored = Message.fromJson({
        'id': '1730000000000',
        'text': 'Legacy hello',
        'isUser': true,
        'timestamp': '2026-02-01T10:00:00.000',
        'imagePath': '/tmp/photo.png',
        'imageLabel': 'photo.png',
        'generatedTokens': 5,
        'elapsedMs': 900,
        'tokensPerSecond': 5.5,
      });
      expect(restored.role, MessageRole.user);
      expect(restored.content, 'Legacy hello');
      expect(restored.createdAt.year, 2026);
      expect(restored.imagePath, '/tmp/photo.png');
      expect(restored.imageLabel, 'photo.png');
      expect(restored.generationStats?.generatedTokens, 5);
    });

    test('reports every image attachment in order', () {
      final message = Message.create(
        conversationId: 'c-1',
        role: MessageRole.user,
        content: 'Compare these',
        attachments: [
          MessageAttachment.create(
            type: AttachmentType.image,
            path: '/tmp/one.jpg',
            label: 'one.jpg',
          ),
          MessageAttachment.create(
            type: AttachmentType.document,
            path: '/tmp/notes.txt',
          ),
          MessageAttachment.create(
            type: AttachmentType.image,
            path: '/tmp/two.jpg',
            label: 'two.jpg',
          ),
        ],
      );

      expect(message.imagePaths, ['/tmp/one.jpg', '/tmp/two.jpg']);
      expect(message.imageAttachments.map((a) => a.label), [
        'one.jpg',
        'two.jpg',
      ]);
      // Single-image accessors keep pointing at the first image.
      expect(message.imagePath, '/tmp/one.jpg');
      expect(message.imageLabel, 'one.jpg');

      final restored = Message.fromJson(message.toJson());
      expect(restored.imagePaths, ['/tmp/one.jpg', '/tmp/two.jpg']);
    });

    test('round-trips prompt and context token stats', () {
      final message = Message.create(
        conversationId: 'c-1',
        role: MessageRole.assistant,
        content: 'Answer',
        generationStats: const MessageGenerationStats(
          generatedTokens: 20,
          promptTokens: 512,
          contextTokens: 2048,
        ),
      );
      final restored = Message.fromJson(message.toJson());

      expect(restored.generationStats?.promptTokens, 512);
      expect(restored.generationStats?.contextTokens, 2048);
    });

    test('treats statistics with only legacy fields as present', () {
      final stats = MessageGenerationStats.fromJson(const {
        'generatedTokens': 4,
      });
      expect(stats?.generatedTokens, 4);
      expect(stats?.promptTokens, isNull);
      expect(MessageGenerationStats.fromJson(const {}), isNull);
    });

    test('round-trips recorded tool activity', () {
      final message = Message.create(
        conversationId: 'c-1',
        role: MessageRole.assistant,
        content: 'The answer is 20.',
        toolActivity: const [
          MessageToolActivity(
            name: 'calculator',
            arguments: 'expression: (2 + 3) * 4',
            status: MessageToolActivityStatus.success,
            output: '(2 + 3) * 4 = 20',
            durationMs: 3,
          ),
        ],
      );
      final restored = Message.fromJson(message.toJson());

      expect(restored.toolActivity, hasLength(1));
      expect(restored.toolActivity.single.name, 'calculator');
      expect(restored.toolActivity.single.arguments, 'expression: (2 + 3) * 4');
      expect(
        restored.toolActivity.single.status,
        MessageToolActivityStatus.success,
      );
      expect(restored.toolActivity.single.output, '(2 + 3) * 4 = 20');
      expect(restored.toolActivity.single.durationMs, 3);
    });

    test('reads messages saved before tool activity existed', () {
      final restored = Message.fromJson(const {
        'id': 'm-1',
        'role': 'assistant',
        'content': 'Hi',
      });

      expect(restored.toolActivity, isEmpty);
    });

    test('copyWith keeps recorded tool activity', () {
      final message = Message.create(
        conversationId: 'c-1',
        role: MessageRole.assistant,
        content: 'The answer is 20.',
        toolActivity: const [
          MessageToolActivity(
            name: 'calculator',
            arguments: '',
            status: MessageToolActivityStatus.success,
          ),
        ],
      );

      final replaced = message.copyWith(content: 'Final answer.');

      expect(replaced.toolActivity, hasLength(1));
      expect(replaced.toolActivity.single.name, 'calculator');
    });

    test('copyWith can replace conversationId and clear stats', () {
      final message = Message.create(
        conversationId: 'c-1',
        role: MessageRole.user,
        content: 'x',
        generationStats: const MessageGenerationStats(generatedTokens: 1),
      );
      final moved = message.copyWith(
        conversationId: 'c-2',
        generationStats: null,
      );
      expect(moved.conversationId, 'c-2');
      expect(moved.generationStats, isNull);
    });
  });

  group('MessageAttachment', () {
    test('round-trips through JSON', () {
      final attachment = MessageAttachment.create(
        type: AttachmentType.image,
        path: '/tmp/a.png',
        label: 'a.png',
      );
      final restored = MessageAttachment.fromJson(attachment.toJson());
      expect(restored.type, AttachmentType.image);
      expect(restored.path, '/tmp/a.png');
      expect(restored.label, 'a.png');
      expect(restored.id, attachment.id);
    });

    test('defaults unknown types to image', () {
      final restored = MessageAttachment.fromJson({
        'id': 'a-1',
        'type': 'something-else',
        'path': '/tmp/a.png',
      });
      expect(restored.type, AttachmentType.image);
    });
  });
}
