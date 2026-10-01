import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/application/conversation_context_builder.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/conversations/domain/message_attachment.dart';
import 'package:pocket_llm/features/documents/domain/document.dart';
import 'package:pocket_llm/features/documents/domain/document_context.dart';
import 'package:pocket_llm/features/documents/domain/document_retrieval.dart';

void main() {
  const builder = ConversationContextBuilder();

  // `system` costs 8 tokens (2 text + 6 overhead); a 40-character message
  // costs 16 tokens (10 text + 6 overhead).
  const systemPrompt = 'system';
  const systemPromptTokens = 8;
  const messageTokens = 16;

  /// usable = 200 - 64 - 16 = 120 tokens, 112 of them after the system prompt.
  const tightPolicy = ContextPolicy(
    contextTokens: 200,
    reservedOutputTokens: 64,
    safetyMarginTokens: 16,
  );

  Message message(
    String id,
    String content, {
    List<MessageAttachment> attachments = const [],
  }) {
    return Message(
      id: id,
      conversationId: 'c-1',
      role: MessageRole.user,
      content: content,
      createdAt: DateTime(2026, 1, 1),
      attachments: attachments,
    );
  }

  List<Message> sizedMessages(int count) {
    return [
      for (var index = 0; index < count; index++) message('m$index', 'a' * 40),
    ];
  }

  ContextAssembly build(
    List<Message> messages, {
    ContextPolicy policy = tightPolicy,
  }) {
    return builder.build(
      messages: messages,
      systemPrompt: systemPrompt,
      policy: policy,
    );
  }

  group('ConversationContextBuilder', () {
    test('includes every message when the conversation fits', () {
      final assembly = build([
        message('m1', 'Hello'),
        message('m2', 'Hi! How can I help?'),
      ]);

      expect(assembly.messages.map((m) => m.id), ['m1', 'm2']);
      expect(assembly.isEmpty, isFalse);
      expect(assembly.usage.includedMessages, 2);
      expect(assembly.usage.droppedMessages, 0);
      expect(assembly.usage.truncatedMessages, 0);
    });

    test('keeps messages in chronological order', () {
      final assembly = build([
        message('m1', 'one'),
        message('m2', 'two'),
        message('m3', 'three'),
      ]);
      expect(assembly.messages.map((m) => m.id), ['m1', 'm2', 'm3']);
    });

    test('charges the system prompt and reports the full budget', () {
      final assembly = build([message('m1', 'Hello')]);

      expect(assembly.systemPrompt, systemPrompt);
      expect(assembly.usage.usedTokens, systemPromptTokens + 8);
      expect(assembly.usage.limitTokens, tightPolicy.usableInputTokens);
      expect(assembly.usage.contextTokens, 200);
      expect(assembly.usage.reservedOutputTokens, 64);
    });

    test('drops the oldest messages first when the budget runs out', () {
      final assembly = build(sizedMessages(8));

      expect(assembly.messages.length, 7);
      // The newest message is the one that survives.
      expect(assembly.messages.last.id, 'm7');
      expect(assembly.messages.first.id, 'm1');
      expect(assembly.usage.droppedMessages, 1);
      expect(assembly.usage.usedTokens, systemPromptTokens + 7 * messageTokens);
      expect(assembly.usage.remainingTokens, 0);
    });

    test('stops at the first older message that does not fit', () {
      final assembly = build([
        message('m1', 'a' * 40),
        message('m2', 'a' * 400),
        message('m3', 'a' * 40),
      ]);

      expect(assembly.messages.map((m) => m.id), ['m3']);
      expect(assembly.usage.droppedMessages, 2);
    });

    test('never drops the newest message', () {
      final oversized = message('m1', 'a' * 2000);
      final assembly = build([oversized]);

      expect(assembly.messages.length, 1);
      expect(assembly.messages.single.content, isNotEmpty);
      expect(assembly.usage.droppedMessages, 0);
      expect(assembly.usage.truncatedMessages, 1);
      expect(
        assembly.usage.usedTokens,
        lessThanOrEqualTo(tightPolicy.usableInputTokens),
      );
      expect(assembly.messages.single.id, 'm1');
    });

    test('shortens a single oversized message instead of dropping it', () {
      final long = message('m1', 'b' * 3000);
      final assembly = build([
        long,
      ], policy: tightPolicy.copyWith(maxMessageTokens: 100));

      final content = assembly.messages.single.content;
      expect(content, contains(' ... '));
      expect(TokenEstimator.estimateText(content), lessThanOrEqualTo(100));
      expect(assembly.messages.single.createdAt, long.createdAt);
      expect(assembly.usage.truncatedMessages, 1);
    });

    test('charges an attached image against the budget', () {
      final attachment = MessageAttachment.create(
        type: AttachmentType.image,
        path: '/tmp/a.png',
        label: 'a.png',
      );
      const roomyPolicy = ContextPolicy(
        contextTokens: 1024,
        reservedOutputTokens: 64,
        safetyMarginTokens: 16,
      );
      final withImage = build([
        message('m1', 'What is in this image?', attachments: [attachment]),
      ], policy: roomyPolicy);
      final withoutImage = build([
        message('m1', 'What is in this image?'),
      ], policy: roomyPolicy);

      expect(
        withImage.usage.usedTokens - withoutImage.usage.usedTokens,
        TokenEstimator.imageTokens,
      );
      expect(withImage.messages.single.attachments, hasLength(1));
    });

    test('does not overshoot the window to keep an image that cannot fit', () {
      final attachment = MessageAttachment.create(
        type: AttachmentType.image,
        path: '/tmp/a.png',
        label: 'a.png',
      );
      final assembly = build([
        message('m1', 'What is in this image?', attachments: [attachment]),
      ]);

      expect(assembly.messages, isEmpty);
      expect(
        assembly.usage.usedTokens,
        lessThanOrEqualTo(tightPolicy.usableInputTokens),
      );
      expect(assembly.usage.droppedMessages, 1);
    });

    test('ignores empty messages without counting them as dropped', () {
      final assembly = build([
        message('m1', ''),
        message('m2', '   '),
        message('m3', 'Hello'),
      ]);

      expect(assembly.messages.map((m) => m.id), ['m3']);
      expect(assembly.usage.droppedMessages, 0);
    });

    test('keeps an image-only message when the window has room', () {
      final attachment = MessageAttachment.create(
        type: AttachmentType.image,
        path: '/tmp/a.png',
        label: 'a.png',
      );
      const roomyPolicy = ContextPolicy(
        contextTokens: 1024,
        reservedOutputTokens: 64,
        safetyMarginTokens: 16,
      );
      final assembly = build([
        message('m1', '', attachments: [attachment]),
      ], policy: roomyPolicy);

      expect(assembly.messages, hasLength(1));
      expect(assembly.usage.droppedMessages, 0);
    });

    test('reports an empty conversation without crashing', () {
      final assembly = build(const []);
      expect(assembly.isEmpty, isTrue);
      expect(assembly.usage.usedTokens, systemPromptTokens);
      expect(assembly.usage.includedMessages, 0);
    });

    test('preserves an oversized system prompt and reports the overshoot', () {
      final assembly = builder.build(
        messages: [message('m1', 'Hello')],
        systemPrompt: 's' * 600,
        policy: tightPolicy,
      );

      expect(assembly.messages, isEmpty);
      expect(
        assembly.usage.usedTokens,
        greaterThan(assembly.usage.limitTokens),
      );
      expect(assembly.usage.droppedMessages, 1);
    });

    test(
      'honours the model declared context through ContextPolicy.forModel',
      () {
        final policy = ContextPolicy.forModel(
          runtimeContextTokens: 4096,
          declaredContextTokens: 2048,
          reservedOutputTokens: 512,
        );
        final assembly = builder.build(
          messages: [message('m1', 'Hello')],
          systemPrompt: systemPrompt,
          policy: policy,
        );

        expect(assembly.usage.contextTokens, 2048);
        expect(assembly.usage.limitTokens, 2048 - 512 - 64);
      },
    );
  });

  group('retrieved documents', () {
    /// A section of exactly 394 characters: 99 tokens, so the composed system
    /// message costs 6 (system) + 2 (separator) + 394 characters = 107 tokens.
    final section = 'x' * 394;

    DocumentContext contextWith({int chunks = 1}) {
      return DocumentContext(
        section: section,
        hits: [
          for (var index = 0; index < chunks; index++)
            DocumentSearchHit(
              documentId: 'doc-$index',
              documentName: 'notes$index.md',
              chunk: DocumentChunk(
                index: 0,
                text: 'chunk $index',
                startOffset: 0,
                endOffset: 7,
              ),
              score: 1,
              matchedTerms: const {'docker'},
            ),
        ],
        tokenCount: 99,
      );
    }

    ContextPolicy tightPolicy() => const ContextPolicy(
      contextTokens: 300,
      reservedOutputTokens: 100,
      retrievalTokens: 99,
    );

    test('appends the section to the system prompt and reports it', () {
      final assembly = builder.build(
        messages: [message('m1', 'Hello')],
        systemPrompt: systemPrompt,
        policy: tightPolicy(),
        documentContext: contextWith(),
      );

      expect(assembly.systemPrompt, startsWith(systemPrompt));
      expect(assembly.systemPrompt, contains(section));
      expect(assembly.usage.retrievedSources, 1);
      expect(assembly.usage.retrievalTokens, 99);
      expect(assembly.usage.retrievalLabel, contains('1 document chunk'));
    });

    test('charges documents before history and drops what no longer fits', () {
      final messages = [message('m-old', 'a' * 40), message('m-new', 'b' * 40)];

      final withDocuments = builder.build(
        messages: messages,
        systemPrompt: systemPrompt,
        policy: tightPolicy(),
        documentContext: contextWith(),
      );
      final withoutDocuments = builder.build(
        messages: messages,
        systemPrompt: systemPrompt,
        policy: tightPolicy(),
      );

      expect(withDocuments.messages.map((m) => m.id), ['m-new']);
      expect(withDocuments.usage.droppedMessages, 1);
      expect(withoutDocuments.messages.map((m) => m.id), ['m-old', 'm-new']);
      expect(withDocuments.usage.retrievedSources, 1);
    });

    test('leaves the prompt untouched when nothing was retrieved', () {
      final without = builder.build(
        messages: [message('m1', 'Hello')],
        systemPrompt: systemPrompt,
        policy: tightPolicy(),
      );
      final empty = builder.build(
        messages: [message('m1', 'Hello')],
        systemPrompt: systemPrompt,
        policy: tightPolicy(),
        documentContext: DocumentContext.empty,
      );

      expect(empty.systemPrompt, without.systemPrompt);
      expect(empty.usage.retrievedSources, 0);
      expect(empty.usage.retrievalTokens, 0);
      expect(empty.usage.retrievalLabel, isNull);
    });
  });
}
