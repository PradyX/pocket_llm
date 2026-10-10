import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/context/domain/compaction_policy.dart';
import 'package:pocket_llm/features/context/domain/context_compaction.dart';
import 'package:pocket_llm/features/context/domain/context_inspector.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';

Message message(String id, String content, {bool pinned = false}) {
  return Message(
    id: id,
    conversationId: 'c',
    role: MessageRole.user,
    content: content,
    createdAt: DateTime.fromMillisecondsSinceEpoch(id.hashCode.abs() % 100000),
    isPinned: pinned,
  );
}

void main() {
  group('CompactionPolicy', () {
    test('normalizes out-of-range values and keeps target below trigger', () {
      const policy = CompactionPolicy(
        compactionTriggerPercent: 10,
        compactionTargetPercent: 99,
        keepRecentTurns: 500,
      );
      final normalized = policy.normalized();
      expect(
        normalized.compactionTriggerPercent,
        CompactionPolicy.minTriggerPercent,
      );
      expect(
        normalized.compactionTargetPercent,
        normalized.compactionTriggerPercent - 5,
      );
      expect(normalized.keepRecentTurns, CompactionPolicy.maxKeepRecentTurns);
    });

    test('round-trips through JSON with corrupt values falling back', () {
      const policy = CompactionPolicy(
        compactionTriggerPercent: 80,
        keepRecentTurns: 4,
        summarizeDocuments: true,
      );
      final restored = CompactionPolicy.fromJson(policy.toJson());
      expect(restored.compactionTriggerPercent, 80);
      expect(restored.keepRecentTurns, 4);
      expect(restored.summarizeDocuments, isTrue);

      final fallback = CompactionPolicy.fromJson(const {
        'compactionTriggerPercent': 'a lot',
        'memoryEnabled': 'yes',
      });
      expect(
        fallback.compactionTriggerPercent,
        CompactionPolicy.defaultTriggerPercent,
      );
      expect(fallback.memoryEnabled, isTrue);
    });
  });

  group('ContextCompactor.shouldCompact', () {
    const policy = CompactionPolicy(
      compactionTriggerPercent: 75,
      compactionTargetPercent: 55,
    );

    test('triggers at the threshold, not before', () {
      expect(
        ContextCompactor.shouldCompact(
          usedInputTokens: 749,
          usableInputTokens: 1000,
          policy: policy,
        ),
        isFalse,
      );
      expect(
        ContextCompactor.shouldCompact(
          usedInputTokens: 750,
          usableInputTokens: 1000,
          policy: policy,
        ),
        isTrue,
      );
    });
  });

  group('ContextCompactor.plan', () {
    List<Message> chat() {
      return [
        for (var i = 0; i < 10; i++)
          message('m$i', 'message number $i with some content to cost tokens'),
      ];
    }

    test('keeps pinned and recent messages, summarizes the rest', () {
      final messages = chat();
      const policy = CompactionPolicy(keepRecentTurns: 2);
      final plan = ContextCompactor.plan(
        messages: messages,
        policy: policy,
        usableInputTokens: 100000,
        pinnedMessageIds: const {'m1'},
      );
      // Recent window is keepRecentTurns * 2 messages (m6..m9) plus pin m1.
      expect(plan.keepMessageIds, containsAll(['m1', 'm6', 'm7', 'm8', 'm9']));
      // Everything fits the huge target, so older turns are pulled back.
      expect(plan.summarizeMessageIds, isEmpty);
      expect(plan.didAnything, isFalse);
    });

    test('summarizes oldest-first under a tight target', () {
      final messages = chat();
      const policy = CompactionPolicy(
        keepRecentTurns: 2,
        compactionTargetPercent: 25,
      );
      final plan = ContextCompactor.plan(
        messages: messages,
        policy: policy,
        usableInputTokens: 200,
      );
      // Pinned/recent always survive even when nothing else fits.
      expect(plan.keepMessageIds, containsAll(['m6', 'm7', 'm8', 'm9']));
      expect(plan.summarizeMessageIds, isNotEmpty);
      // Summarized set is the oldest non-recent slice.
      expect(plan.summarizeMessageIds.first, 'm0');
    });

    test('drops system chatter without summarizing it', () {
      final messages = [
        Message(
          id: 'sys',
          conversationId: 'c',
          role: MessageRole.system,
          content: 'transient status update',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
        ...chat(),
      ];
      const policy = CompactionPolicy(keepRecentTurns: 1);
      final plan = ContextCompactor.plan(
        messages: messages,
        policy: policy,
        usableInputTokens: 100000,
      );
      expect(plan.dropMessageIds, contains('sys'));
      expect(plan.summarizeMessageIds, isNot(contains('sys')));
    });
  });

  group('ContextCompactor.foldSummaries', () {
    test('folds without re-reading raw turns', () {
      expect(ContextCompactor.foldSummaries(newSummary: 'b'), 'b');
      expect(
        ContextCompactor.foldSummaries(previousSummary: 'a', newSummary: ''),
        'a',
      );
      expect(
        ContextCompactor.foldSummaries(previousSummary: 'a', newSummary: 'b'),
        'a\n\nb',
      );
    });
  });

  group('ContextUsageBreakdown', () {
    test('sums input and reports rows in inspector order', () {
      final breakdown = ContextUsageBreakdown.fromAssembly(
        systemPrompt: 'system',
        memorySection: 'memory',
        messagesTokens: 100,
        documentsTokens: 50,
        reservedOutputTokens: 200,
        budgetTokens: 1000,
      );
      expect(breakdown.usedInputTokens, greaterThan(100 + 50));
      expect(breakdown.totalTokens, breakdown.usedInputTokens + 200);
      final rows = inspectorRows(breakdown);
      expect(
        [for (final row in rows) row.label],
        [
          'System / Soul',
          'Skills',
          'Tools',
          'Memory',
          'Messages',
          'Documents',
          'Reserved output',
        ],
      );
      expect(rows.last.tokens, 200);
    });
  });
}
