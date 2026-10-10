import 'package:pocket_llm/features/context/domain/compaction_policy.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';

/// How one message is treated when the window fills up.
///
/// Road Map 2 Phase 2.1 §4.4. Old messages are never simply deleted: durable
/// information is extracted into memory/the summary first, and these classes
/// decide what is extracted, what is kept and what can go.
enum CompactMessageClass {
  /// User- or bot-pinned: always survives normal compaction.
  pinned('Pinned'),

  /// Inside the recent window: always kept verbatim.
  recent('Recent'),

  /// Carries tool calls or retrieved sources: condensed first when the
  /// policy allows independent compression.
  toolOutput('Tool output'),

  /// Ordinary conversation: summarized once it leaves the recent window.
  normal('Conversation'),

  /// Runtime status chatter: dropped first, never summarized.
  temporary('Temporary');

  const CompactMessageClass(this.label);
  final String label;
}

/// Classifies one message for compaction.
///
/// Order matters: pinned beats recent, recent beats everything, and system
/// status messages are temporary because re-sending them helps no one.
CompactMessageClass classifyMessage(
  Message message, {
  required bool isPinned,
  required bool isRecent,
}) {
  if (isPinned) return CompactMessageClass.pinned;
  if (isRecent) return CompactMessageClass.recent;
  if (message.role == MessageRole.system) return CompactMessageClass.temporary;
  if (message.toolActivity.isNotEmpty || message.sources.isNotEmpty) {
    return CompactMessageClass.toolOutput;
  }
  return CompactMessageClass.normal;
}

/// What one compaction pass decided.
class CompactionPlan {
  const CompactionPlan({
    required this.keepMessageIds,
    required this.summarizeMessageIds,
    required this.dropMessageIds,
    required this.estimatedKeptTokens,
    required this.estimatedFreedTokens,
  });

  /// Messages sent verbatim (pinned + recent + whatever still fits).
  final List<String> keepMessageIds;

  /// Older messages to fold into the summary/memory first.
  final List<String> summarizeMessageIds;

  /// Temporary messages dropped without summarizing.
  final List<String> dropMessageIds;

  final int estimatedKeptTokens;
  final int estimatedFreedTokens;

  bool get didAnything =>
      summarizeMessageIds.isNotEmpty || dropMessageIds.isNotEmpty;
}

/// Pure compaction engine: no I/O, no model, fully testable.
///
/// The algorithm:
/// 1. Pinned messages and the newest [CompactionPolicy.keepRecentTurns]
///    turns are always kept.
/// 2. Temporary messages are dropped without summarizing.
/// 3. Everything else is summarized oldest-first until the kept total is at
///    or under the target share of the usable input budget.
abstract final class ContextCompactor {
  /// True when [usedInputTokens] has reached the policy trigger.
  static bool shouldCompact({
    required int usedInputTokens,
    required int usableInputTokens,
    required CompactionPolicy policy,
  }) {
    if (usableInputTokens <= 0) return usedInputTokens > 0;
    return usedInputTokens * 100 >=
        usableInputTokens * policy.compactionTriggerPercent;
  }

  /// Token budget the kept context must fit after compacting.
  static int targetTokens({
    required int usableInputTokens,
    required CompactionPolicy policy,
  }) {
    return (usableInputTokens * policy.compactionTargetPercent) ~/ 100;
  }

  /// Splits [messages] (chronological) into keep / summarize / drop.
  static CompactionPlan plan({
    required List<Message> messages,
    required CompactionPolicy policy,
    required int usableInputTokens,
    Set<String> pinnedMessageIds = const {},
  }) {
    int cost(Message message) => TokenEstimator.estimateMessage(
      message.content,
      imageCount: message.attachments.length,
    );

    final keep = <Message>[];
    final summarize = <Message>[];
    final drop = <Message>[];

    final recentCount = policy.keepRecentTurns * 2;
    final recentFrom = messages.length - recentCount < 0
        ? 0
        : messages.length - recentCount;

    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      final pinned =
          policy.preservePinnedMessages &&
          (message.isPinned || pinnedMessageIds.contains(message.id));
      final classification = classifyMessage(
        message,
        isPinned: pinned,
        isRecent: index >= recentFrom,
      );
      switch (classification) {
        case CompactMessageClass.pinned:
        case CompactMessageClass.recent:
          keep.add(message);
        case CompactMessageClass.temporary:
          drop.add(message);
        case CompactMessageClass.toolOutput:
        case CompactMessageClass.normal:
          summarize.add(message);
      }
    }

    // Newest-first refill: if everything kept still fits the target, pull
    // summarized messages back newest-first instead of summarizing them.
    var keptTokens = keep.fold<int>(0, (sum, message) => sum + cost(message));
    final target = targetTokens(
      usableInputTokens: usableInputTokens,
      policy: policy,
    );
    for (
      var index = summarize.length - 1;
      index >= 0 && keptTokens <= target;
      index--
    ) {
      final candidate = summarize[index];
      final candidateCost = cost(candidate);
      if (keptTokens + candidateCost <= target) {
        keep.add(candidate);
        keptTokens += candidateCost;
        summarize.removeAt(index);
      } else {
        break;
      }
    }
    keep.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final summarizeTokens = summarize.fold<int>(
      0,
      (sum, message) => sum + cost(message),
    );
    final dropTokens = drop.fold<int>(0, (sum, message) => sum + cost(message));

    return CompactionPlan(
      keepMessageIds: [for (final message in keep) message.id],
      summarizeMessageIds: [for (final message in summarize) message.id],
      dropMessageIds: [for (final message in drop) message.id],
      estimatedKeptTokens: keptTokens,
      estimatedFreedTokens: summarizeTokens + dropTokens,
    );
  }

  /// Folds an older summary into a newer one without re-reading raw turns.
  ///
  /// Hierarchical compaction (§4.5): each refresh only ever sees the newly
  /// dropped turns plus what earlier refreshes already condensed, so a
  /// long-lived chat never re-sends its whole history to summarize it.
  static String foldSummaries({
    String? previousSummary,
    required String newSummary,
  }) {
    final previous = (previousSummary ?? '').trim();
    final fresh = newSummary.trim();
    if (previous.isEmpty) return fresh;
    if (fresh.isEmpty) return previous;
    return '$previous\n\n$fresh';
  }
}
