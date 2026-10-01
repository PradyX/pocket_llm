import 'package:pocket_llm/core/utils/id_generator.dart';
import 'package:pocket_llm/features/conversations/domain/message_attachment.dart';
import 'package:pocket_llm/features/conversations/domain/message_source.dart';

/// Who authored a message.
enum MessageRole {
  user,
  assistant,
  system;

  /// Parses a role name, or null when the value is unknown.
  static MessageRole? tryParse(String? value) {
    if (value == null) return null;
    final normalized = value.trim().toLowerCase();
    for (final role in values) {
      if (role.name == normalized) return role;
    }
    return null;
  }
}

/// Generation statistics captured for one assistant response.
class MessageGenerationStats {
  final int? generatedTokens;
  final int? elapsedMs;
  final double? tokensPerSecond;

  /// Input tokens the prompt used, as estimated when the request was built.
  final int? promptTokens;

  /// Context window the request ran with.
  final int? contextTokens;

  const MessageGenerationStats({
    this.generatedTokens,
    this.elapsedMs,
    this.tokensPerSecond,
    this.promptTokens,
    this.contextTokens,
  });

  bool get isEmpty =>
      generatedTokens == null &&
      elapsedMs == null &&
      tokensPerSecond == null &&
      promptTokens == null &&
      contextTokens == null;

  Map<String, dynamic> toJson() {
    return {
      'generatedTokens': generatedTokens,
      'elapsedMs': elapsedMs,
      'tokensPerSecond': tokensPerSecond,
      'promptTokens': promptTokens,
      'contextTokens': contextTokens,
    };
  }

  /// Parses statistics from a map of generation fields.
  ///
  /// Returns null when no statistics are present.
  static MessageGenerationStats? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final stats = MessageGenerationStats(
      generatedTokens: (raw['generatedTokens'] as num?)?.toInt(),
      elapsedMs: (raw['elapsedMs'] as num?)?.toInt(),
      tokensPerSecond: (raw['tokensPerSecond'] as num?)?.toDouble(),
      promptTokens: (raw['promptTokens'] as num?)?.toInt(),
      contextTokens: (raw['contextTokens'] as num?)?.toInt(),
    );
    return stats.isEmpty ? null : stats;
  }
}

/// One message in a conversation.
class Message {
  static const _unset = Object();

  final String id;
  final String conversationId;
  final MessageRole role;
  final String content;
  final DateTime createdAt;

  /// Model that generated this message (set for assistant messages).
  final String? modelId;

  /// Display name of the generating model at generation time.
  final String? modelName;

  final List<MessageAttachment> attachments;
  final MessageGenerationStats? generationStats;

  /// Local document chunks that were given to the model for this answer.
  ///
  /// Empty for messages that were not built from the document index, including
  /// every message saved before documents existed.
  final List<MessageSource> sources;

  /// Token count estimate when known locally.
  final int? tokenCount;

  const Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.modelId,
    this.modelName,
    this.attachments = const [],
    this.generationStats,
    this.sources = const [],
    this.tokenCount,
  });

  /// Creates a new message with a generated id.
  factory Message.create({
    required String conversationId,
    required MessageRole role,
    String content = '',
    DateTime? createdAt,
    String? modelId,
    String? modelName,
    List<MessageAttachment> attachments = const [],
    MessageGenerationStats? generationStats,
    List<MessageSource> sources = const [],
    int? tokenCount,
  }) {
    return Message(
      id: IdGenerator.message(),
      conversationId: conversationId,
      role: role,
      content: content,
      createdAt: createdAt ?? DateTime.now(),
      modelId: modelId,
      modelName: modelName,
      attachments: attachments,
      generationStats: generationStats,
      sources: sources,
      tokenCount: tokenCount,
    );
  }

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;

  /// First image attachment, for UI that renders a single image today.
  MessageAttachment? get imageAttachment {
    for (final attachment in attachments) {
      if (attachment.type == AttachmentType.image) return attachment;
    }
    return null;
  }

  /// Path of the image attachment, if any.
  String? get imagePath => imageAttachment?.path;

  /// Label of the image attachment, if any.
  String? get imageLabel => imageAttachment?.label;

  Message copyWith({
    String? conversationId,
    String? content,
    String? modelId,
    String? modelName,
    List<MessageAttachment>? attachments,
    Object? generationStats = _unset,
    List<MessageSource>? sources,
    Object? tokenCount = _unset,
  }) {
    return Message(
      id: id,
      conversationId: conversationId ?? this.conversationId,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
      modelId: modelId ?? this.modelId,
      modelName: modelName ?? this.modelName,
      attachments: attachments ?? this.attachments,
      generationStats: generationStats == _unset
          ? this.generationStats
          : generationStats as MessageGenerationStats?,
      sources: sources ?? this.sources,
      tokenCount: tokenCount == _unset ? this.tokenCount : tokenCount as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'role': role.name,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
      'modelId': modelId,
      'modelName': modelName,
      'attachments': attachments.map((a) => a.toJson()).toList(),
      'generationStats': generationStats?.toJson(),
      'sources': sources.map((source) => source.toJson()).toList(),
      'tokenCount': tokenCount,
    };
  }

  /// Parses message JSON in both the current format and the legacy per-model
  /// chat format (`isUser`, `text`, `timestamp`, `imagePath`/`imageLabel`,
  /// flattened generation statistics).
  factory Message.fromJson(Map<String, dynamic> json) {
    final role =
        MessageRole.tryParse(json['role'] as String?) ??
        ((json['isUser'] as bool? ?? false)
            ? MessageRole.user
            : MessageRole.assistant);
    final content =
        (json['content'] as String?) ?? (json['text'] as String?) ?? '';
    final createdAt =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.tryParse(json['timestamp'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);

    final attachments = <MessageAttachment>[];
    final rawAttachments = json['attachments'];
    if (rawAttachments is List) {
      for (final raw in rawAttachments) {
        if (raw is Map) {
          attachments.add(
            MessageAttachment.fromJson(Map<String, dynamic>.from(raw)),
          );
        }
      }
    }

    final legacyImagePath = json['imagePath'];
    if (attachments.isEmpty &&
        legacyImagePath is String &&
        legacyImagePath.isNotEmpty) {
      attachments.add(
        MessageAttachment.fromLegacyImage(
          path: legacyImagePath,
          label: json['imageLabel'] as String?,
        ),
      );
    }

    // New messages nest statistics under `generationStats`; legacy messages
    // store `generatedTokens`/`elapsedMs`/`tokensPerSecond` at the top level.
    final rawStats = json['generationStats'];
    final generationStats = rawStats != null
        ? MessageGenerationStats.fromJson(rawStats)
        : MessageGenerationStats.fromJson(json);

    return Message(
      id: json['id'] as String? ?? '',
      conversationId: json['conversationId'] as String? ?? '',
      role: role,
      content: content,
      createdAt: createdAt,
      modelId: json['modelId'] as String?,
      modelName: json['modelName'] as String?,
      attachments: attachments,
      generationStats: generationStats,
      // Absent on every message saved before citations existed, and on
      // messages that simply used no documents.
      sources: MessageSource.listFromJson(json['sources']),
      tokenCount: (json['tokenCount'] as num?)?.toInt(),
    );
  }
}
