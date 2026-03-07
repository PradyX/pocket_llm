/// Represents a single message in the chat conversation.
class ChatMessage {
  final String id;
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final int? generatedTokens;
  final int? elapsedMs;
  final double? tokensPerSecond;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.generatedTokens,
    this.elapsedMs,
    this.tokensPerSecond,
  });

  ChatMessage copyWith({
    String? text,
    int? generatedTokens,
    int? elapsedMs,
    double? tokensPerSecond,
  }) {
    return ChatMessage(
      id: id,
      text: text ?? this.text,
      isUser: isUser,
      timestamp: timestamp,
      generatedTokens: generatedTokens ?? this.generatedTokens,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      tokensPerSecond: tokensPerSecond ?? this.tokensPerSecond,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'isUser': isUser,
      'timestamp': timestamp.toIso8601String(),
      'generatedTokens': generatedTokens,
      'elapsedMs': elapsedMs,
      'tokensPerSecond': tokensPerSecond,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      isUser: json['isUser'] as bool? ?? false,
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      generatedTokens: (json['generatedTokens'] as num?)?.toInt(),
      elapsedMs: (json['elapsedMs'] as num?)?.toInt(),
      tokensPerSecond: (json['tokensPerSecond'] as num?)?.toDouble(),
    );
  }
}
