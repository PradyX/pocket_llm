import 'package:pocket_llm/features/conversations/domain/message.dart';

/// A locally written summary of the older part of a conversation.
///
/// Road Map 1 Phase 4 Strategy B. When a chat grows past its token budget the
/// newest turns keep the sliding window and everything older is condensed into
/// this summary instead of being dropped, so a long conversation stays coherent
/// past the raw context limit.
///
/// The summary is produced by the bundled local model and never leaves the
/// device. It is tied to the visible history by [coveredThroughMessageId]: the
/// anchor is what makes a stale summary safe, because a memory whose anchor is
/// no longer part of the conversation is simply not applied.
class ConversationMemory {
  const ConversationMemory({
    required this.summary,
    required this.coveredThroughMessageId,
    required this.coveredCount,
    this.updatedAt,
    this.modelId,
  });

  /// Longest stored summary, in characters (roughly 300 tokens).
  static const int maxSummaryCharacters = 1200;

  /// Heading placed in front of the summary when it is charged into a prompt.
  static const String sectionHeading =
      'Summary of earlier messages in this conversation '
      '(written locally by the previous turns):';

  final String summary;

  /// Id of the last message this summary covers: the anchor that decides which
  /// messages are represented by [summary] instead of being sent.
  final String coveredThroughMessageId;

  /// How many messages the summary stands for, for reporting.
  final int coveredCount;

  final DateTime? updatedAt;

  /// Which local model wrote it (diagnostics only).
  final String? modelId;

  bool get isEmpty => summary.trim().isEmpty;

  /// The summary as it appears in a prompt.
  String get section => '$sectionHeading\n${summary.trim()}';

  /// Index of the last covered message in [messages], or -1 when the anchor is
  /// not part of the list any more.
  int anchorIndex(List<Message> messages) {
    for (var index = messages.length - 1; index >= 0; index--) {
      if (messages[index].id == coveredThroughMessageId) return index;
    }
    return -1;
  }

  ConversationMemory copyWith({
    String? summary,
    String? coveredThroughMessageId,
    int? coveredCount,
    DateTime? updatedAt,
    String? modelId,
  }) {
    return ConversationMemory(
      summary: summary ?? this.summary,
      coveredThroughMessageId:
          coveredThroughMessageId ?? this.coveredThroughMessageId,
      coveredCount: coveredCount ?? this.coveredCount,
      updatedAt: updatedAt ?? this.updatedAt,
      modelId: modelId ?? this.modelId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'summary': summary,
      'coveredThroughMessageId': coveredThroughMessageId,
      'coveredCount': coveredCount,
      'updatedAt': updatedAt?.toIso8601String(),
      'modelId': modelId,
    };
  }

  /// Reads a stored memory, returning null for anything it cannot use.
  ///
  /// Persisted data is version-tolerant: a message written by an older build
  /// has no memory at all, and a partially written or corrupt entry is ignored
  /// rather than failing the conversation it belongs to.
  static ConversationMemory? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final payload = Map<String, dynamic>.from(raw);
    final summary = payload['summary'];
    if (summary is! String || summary.trim().isEmpty) return null;
    final anchor = payload['coveredThroughMessageId'];
    if (anchor is! String || anchor.trim().isEmpty) return null;
    final rawCount = payload['coveredCount'];
    return ConversationMemory(
      summary: summary.trim(),
      coveredThroughMessageId: anchor,
      coveredCount: rawCount is num ? rawCount.toInt() : 0,
      updatedAt: DateTime.tryParse(payload['updatedAt'] as String? ?? ''),
      modelId: payload['modelId'] as String?,
    );
  }
}
