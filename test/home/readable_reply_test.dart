import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/home/domain/readable_reply.dart';

void main() {
  Message user(String content) => Message(
    id: 'user-1',
    conversationId: 'conversation-1',
    role: MessageRole.user,
    content: content,
    createdAt: DateTime(2026, 1, 1),
  );

  Message assistant(
    String content, {
    String id = 'assistant-1',
    bool hasStats = true,
  }) => Message(
    id: id,
    conversationId: 'conversation-1',
    role: MessageRole.assistant,
    content: content,
    createdAt: DateTime(2026, 1, 1),
    generationStats: hasStats
        ? const MessageGenerationStats(generatedTokens: 12, elapsedMs: 900)
        : null,
  );

  group('shouldReadFinishedReply', () {
    test('reads only when an enabled generation just finished', () {
      expect(
        shouldReadFinishedReply(
          wasGenerating: true,
          isGenerating: false,
          readAloudEnabled: true,
        ),
        isTrue,
      );
    });

    test('never speaks while a reply is still being written', () {
      expect(
        shouldReadFinishedReply(
          wasGenerating: true,
          isGenerating: true,
          readAloudEnabled: true,
        ),
        isFalse,
      );
    });

    test('never speaks when reading aloud is switched off', () {
      expect(
        shouldReadFinishedReply(
          wasGenerating: true,
          isGenerating: false,
          readAloudEnabled: false,
        ),
        isFalse,
      );
    });

    test('never speaks on state that was not a generation', () {
      expect(
        shouldReadFinishedReply(
          wasGenerating: false,
          isGenerating: false,
          readAloudEnabled: true,
        ),
        isFalse,
      );
      expect(
        shouldReadFinishedReply(
          wasGenerating: false,
          isGenerating: true,
          readAloudEnabled: true,
        ),
        isFalse,
      );
    });
  });

  group('lastReadableReply', () {
    test('returns the newest reply the app generated', () {
      final reply = assistant('The answer.');
      final found = lastReadableReply([user('Question?'), reply]);

      expect(found, same(reply));
    });

    test('ignores a placeholder that has not produced anything yet', () {
      expect(
        lastReadableReply([
          user('Question?'),
          assistant('Thinking...', hasStats: false),
        ]),
        isNull,
      );
    });

    test('never falls back to an older reply', () {
      expect(
        lastReadableReply([
          user('First?'),
          assistant('First answer.'),
          user('Second?'),
          assistant('Thinking...', id: 'assistant-2', hasStats: false),
        ]),
        isNull,
      );
    });

    test('ignores an empty reply', () {
      expect(lastReadableReply([user('Question?'), assistant('   ')]), isNull);
    });

    test('reads a reply that was stopped early', () {
      final stopped = assistant('Half an answ');
      expect(lastReadableReply([user('Question?'), stopped]), same(stopped));
    });

    test('reports nothing when the conversation has no reply', () {
      expect(lastReadableReply(const []), isNull);
      expect(lastReadableReply([user('Question?')]), isNull);
    });
  });
}
