import 'package:pocket_llm/core/utils/id_generator.dart';

/// Debugging and recovery record for one compaction pass.
///
/// Road Map 2 Phase 2.1 §4.7. Stores what the context looked like before the
/// pass, what was extracted and which model did it, so a bad summary can be
/// diagnosed — and a future recovery flow can offer the pre-compaction text.
class CompactionCheckpoint {
  const CompactionCheckpoint({
    required this.id,
    required this.conversationId,
    required this.beforeCompactionMessageId,
    required this.summary,
    required this.extractedMemory,
    required this.keptMessageIds,
    required this.summarizedMessageIds,
    required this.timestamp,
    this.modelUsed,
  });

  factory CompactionCheckpoint.create({
    String? id,
    required String conversationId,
    required String beforeCompactionMessageId,
    required String summary,
    required String extractedMemory,
    List<String> keptMessageIds = const [],
    List<String> summarizedMessageIds = const [],
    String? modelUsed,
    DateTime? now,
  }) {
    return CompactionCheckpoint(
      id: id ?? IdGenerator.generate('compaction'),
      conversationId: conversationId,
      beforeCompactionMessageId: beforeCompactionMessageId,
      summary: summary,
      extractedMemory: extractedMemory,
      keptMessageIds: List.unmodifiable(keptMessageIds),
      summarizedMessageIds: List.unmodifiable(summarizedMessageIds),
      timestamp: now ?? DateTime.now(),
      modelUsed: modelUsed,
    );
  }

  final String id;
  final String conversationId;

  /// Last message covered by this pass: the anchor for recovery.
  final String beforeCompactionMessageId;
  final String summary;
  final String extractedMemory;
  final List<String> keptMessageIds;
  final List<String> summarizedMessageIds;
  final DateTime timestamp;

  /// Local model that wrote the summary, if one did.
  final String? modelUsed;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'beforeCompactionMessageId': beforeCompactionMessageId,
      'summary': summary,
      'extractedMemory': extractedMemory,
      'keptMessageIds': keptMessageIds,
      'summarizedMessageIds': summarizedMessageIds,
      'timestamp': timestamp.toIso8601String(),
      'modelUsed': modelUsed,
    };
  }

  static CompactionCheckpoint? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final conversationId = json['conversationId'];
    final anchor = json['beforeCompactionMessageId'];
    if (id is! String || conversationId is! String || anchor is! String) {
      return null;
    }
    List<String> readIds(Object? value) {
      if (value is! List) return const [];
      return value.whereType<String>().toList(growable: false);
    }

    DateTime timestamp = DateTime.fromMillisecondsSinceEpoch(0);
    if (json['timestamp'] is String) {
      timestamp = DateTime.tryParse(json['timestamp'] as String) ?? timestamp;
    }
    String readText(Object? value) => value is String ? value : '';
    return CompactionCheckpoint(
      id: id,
      conversationId: conversationId,
      beforeCompactionMessageId: anchor,
      summary: readText(json['summary']),
      extractedMemory: readText(json['extractedMemory']),
      keptMessageIds: readIds(json['keptMessageIds']),
      summarizedMessageIds: readIds(json['summarizedMessageIds']),
      timestamp: timestamp,
      modelUsed: json['modelUsed'] is String
          ? json['modelUsed'] as String
          : null,
    );
  }
}
