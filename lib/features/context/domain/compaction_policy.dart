/// Stored compaction policy: when to compact and what survives.
///
/// Road Map 2 Phase 2.1 §4.2. This is the user-facing policy; the prompt
/// builder turns it into budgets on every request, so the stored values can
/// never go stale as models change. Everything clamps into a sane range
/// rather than failing, so a hand-edited file cannot break chatting.
class CompactionPolicy {
  const CompactionPolicy({
    this.compactionTriggerPercent = defaultTriggerPercent,
    this.compactionTargetPercent = defaultTargetPercent,
    this.keepRecentTurns = defaultKeepRecentTurns,
    this.preservePinnedMessages = true,
    this.summarizeToolResults = true,
    this.summarizeDocuments = false,
    this.summarizeMcpResults = true,
    this.memoryEnabled = true,
  });

  /// Defaults from the roadmap: start compacting at 75–80% of the usable
  /// input budget and aim to land at 50–60% afterwards.
  static const int defaultTriggerPercent = 75;
  static const int defaultTargetPercent = 55;
  static const int defaultKeepRecentTurns = 6;

  static const int minTriggerPercent = 50;
  static const int maxTriggerPercent = 95;
  static const int minTargetPercent = 25;
  static const int maxTargetPercent = 90;
  static const int minKeepRecentTurns = 2;
  static const int maxKeepRecentTurns = 50;

  /// Usage share of the usable input budget at which compaction begins.
  final int compactionTriggerPercent;

  /// Usage share the compaction aims to land at afterwards.
  final int compactionTargetPercent;

  /// Newest turns always kept verbatim, even under pressure.
  final int keepRecentTurns;

  /// Pinned messages survive normal compaction.
  final bool preservePinnedMessages;

  /// Long tool outputs may be condensed independently of the chat.
  final bool summarizeToolResults;

  /// Retrieved document sections may be condensed independently.
  final bool summarizeDocuments;

  /// MCP tool outputs may be condensed independently.
  final bool summarizeMcpResults;

  /// Conversation summaries are written at all.
  final bool memoryEnabled;

  /// Copy with every value inside its allowed range and the target kept
  /// strictly below the trigger, so compaction always makes progress.
  CompactionPolicy normalized() {
    final trigger = compactionTriggerPercent.clamp(
      minTriggerPercent,
      maxTriggerPercent,
    );
    final target = compactionTargetPercent
        .clamp(minTargetPercent, maxTargetPercent)
        .clamp(0, trigger - 5);
    return CompactionPolicy(
      compactionTriggerPercent: trigger,
      compactionTargetPercent: target,
      keepRecentTurns: keepRecentTurns.clamp(
        minKeepRecentTurns,
        maxKeepRecentTurns,
      ),
      preservePinnedMessages: preservePinnedMessages,
      summarizeToolResults: summarizeToolResults,
      summarizeDocuments: summarizeDocuments,
      summarizeMcpResults: summarizeMcpResults,
      memoryEnabled: memoryEnabled,
    );
  }

  CompactionPolicy copyWith({
    int? compactionTriggerPercent,
    int? compactionTargetPercent,
    int? keepRecentTurns,
    bool? preservePinnedMessages,
    bool? summarizeToolResults,
    bool? summarizeDocuments,
    bool? summarizeMcpResults,
    bool? memoryEnabled,
  }) {
    return CompactionPolicy(
      compactionTriggerPercent:
          compactionTriggerPercent ?? this.compactionTriggerPercent,
      compactionTargetPercent:
          compactionTargetPercent ?? this.compactionTargetPercent,
      keepRecentTurns: keepRecentTurns ?? this.keepRecentTurns,
      preservePinnedMessages:
          preservePinnedMessages ?? this.preservePinnedMessages,
      summarizeToolResults: summarizeToolResults ?? this.summarizeToolResults,
      summarizeDocuments: summarizeDocuments ?? this.summarizeDocuments,
      summarizeMcpResults: summarizeMcpResults ?? this.summarizeMcpResults,
      memoryEnabled: memoryEnabled ?? this.memoryEnabled,
    ).normalized();
  }

  Map<String, dynamic> toJson() {
    return {
      'compactionTriggerPercent': compactionTriggerPercent,
      'compactionTargetPercent': compactionTargetPercent,
      'keepRecentTurns': keepRecentTurns,
      'preservePinnedMessages': preservePinnedMessages,
      'summarizeToolResults': summarizeToolResults,
      'summarizeDocuments': summarizeDocuments,
      'summarizeMcpResults': summarizeMcpResults,
      'memoryEnabled': memoryEnabled,
    };
  }

  static bool _readBool(Object? value, bool fallback) {
    return value is bool ? value : fallback;
  }

  static int _readInt(Object? value, int fallback) {
    return value is num ? value.toInt() : fallback;
  }

  /// Parses a stored policy; anything unusable falls back to the default.
  static CompactionPolicy fromJson(Map<String, dynamic> json) {
    const defaults = CompactionPolicy();
    return CompactionPolicy(
      compactionTriggerPercent: _readInt(
        json['compactionTriggerPercent'],
        defaults.compactionTriggerPercent,
      ),
      compactionTargetPercent: _readInt(
        json['compactionTargetPercent'],
        defaults.compactionTargetPercent,
      ),
      keepRecentTurns: _readInt(
        json['keepRecentTurns'],
        defaults.keepRecentTurns,
      ),
      preservePinnedMessages: _readBool(
        json['preservePinnedMessages'],
        defaults.preservePinnedMessages,
      ),
      summarizeToolResults: _readBool(
        json['summarizeToolResults'],
        defaults.summarizeToolResults,
      ),
      summarizeDocuments: _readBool(
        json['summarizeDocuments'],
        defaults.summarizeDocuments,
      ),
      summarizeMcpResults: _readBool(
        json['summarizeMcpResults'],
        defaults.summarizeMcpResults,
      ),
      memoryEnabled: _readBool(json['memoryEnabled'], defaults.memoryEnabled),
    ).normalized();
  }
}
