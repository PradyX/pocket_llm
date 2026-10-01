import 'package:pocket_llm/core/utils/id_generator.dart';

/// Title assigned to a conversation before its first user message arrives.
const String defaultConversationTitle = 'New chat';

/// A chat thread that is independent from any single model.
///
/// A conversation can switch its [activeModelId] at any time without touching
/// its message history; each assistant message records the model that
/// generated it.
class Conversation {
  static const _unset = Object();

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? activeModelId;
  final String? personaId;
  final String? inferenceProfileId;
  final String? systemPrompt;
  final bool isPinned;
  final Map<String, dynamic> metadata;

  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.activeModelId,
    this.personaId,
    this.inferenceProfileId,
    this.systemPrompt,
    this.isPinned = false,
    this.metadata = const {},
  });

  /// Creates a fresh conversation, generating an id when [id] is omitted.
  factory Conversation.create({
    String? id,
    String? title,
    String? activeModelId,
    String? personaId,
    String? systemPrompt,
  }) {
    final trimmedTitle = (title ?? '').trim();
    final now = DateTime.now();
    return Conversation(
      id: id ?? IdGenerator.conversation(),
      title: trimmedTitle.isEmpty ? defaultConversationTitle : trimmedTitle,
      createdAt: now,
      updatedAt: now,
      activeModelId: activeModelId,
      personaId: personaId,
      systemPrompt: systemPrompt,
    );
  }

  /// Whether this conversation still carries the placeholder title.
  bool get hasDefaultTitle => title == defaultConversationTitle;

  Conversation copyWith({
    String? title,
    DateTime? updatedAt,
    Object? activeModelId = _unset,
    Object? personaId = _unset,
    Object? inferenceProfileId = _unset,
    Object? systemPrompt = _unset,
    bool? isPinned,
  }) {
    return Conversation(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      activeModelId: activeModelId == _unset
          ? this.activeModelId
          : activeModelId as String?,
      personaId: personaId == _unset ? this.personaId : personaId as String?,
      inferenceProfileId: inferenceProfileId == _unset
          ? this.inferenceProfileId
          : inferenceProfileId as String?,
      systemPrompt: systemPrompt == _unset
          ? this.systemPrompt
          : systemPrompt as String?,
      isPinned: isPinned ?? this.isPinned,
      metadata: metadata,
    );
  }

  /// Returns a copy of this conversation with a different [id].
  ///
  /// Used when importing a conversation whose id already exists locally.
  Conversation withId(String newId) {
    return Conversation(
      id: newId,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      activeModelId: activeModelId,
      personaId: personaId,
      inferenceProfileId: inferenceProfileId,
      systemPrompt: systemPrompt,
      isPinned: isPinned,
      metadata: metadata,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'activeModelId': activeModelId,
      'personaId': personaId,
      'inferenceProfileId': inferenceProfileId,
      'systemPrompt': systemPrompt,
      'isPinned': isPinned,
      'metadata': metadata,
    };
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    final rawTitle = json['title'];
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    final rawMetadata = json['metadata'];

    return Conversation(
      id: rawId is String ? rawId : '',
      title: rawTitle is String && rawTitle.trim().isNotEmpty
          ? rawTitle
          : defaultConversationTitle,
      createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          updatedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      activeModelId: json['activeModelId'] as String?,
      personaId: json['personaId'] as String?,
      inferenceProfileId: json['inferenceProfileId'] as String?,
      systemPrompt: json['systemPrompt'] as String?,
      isPinned: json['isPinned'] as bool? ?? false,
      metadata: rawMetadata is Map
          ? Map<String, dynamic>.from(rawMetadata)
          : const {},
    );
  }
}

/// Index-level view of a conversation used by the conversation list UI.
class ConversationSummary {
  final Conversation conversation;
  final int messageCount;
  final String lastMessagePreview;
  final DateTime? lastMessageAt;

  const ConversationSummary({
    required this.conversation,
    required this.messageCount,
    required this.lastMessagePreview,
    required this.lastMessageAt,
  });

  Map<String, dynamic> toJson() {
    return {
      ...conversation.toJson(),
      'messageCount': messageCount,
      'lastMessagePreview': lastMessagePreview,
      'lastMessageAt': lastMessageAt?.toIso8601String(),
    };
  }

  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    return ConversationSummary(
      conversation: Conversation.fromJson(json),
      messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      lastMessagePreview: json['lastMessagePreview'] as String? ?? '',
      lastMessageAt: DateTime.tryParse(json['lastMessageAt'] as String? ?? ''),
    );
  }
}
