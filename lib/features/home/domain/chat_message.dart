/// Represents a single message in the chat conversation.
class ChatMessage {
  static const _unset = Object();

  final String id;
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final String? imagePath;
  final String? imageLabel;
  final int? generatedTokens;
  final int? elapsedMs;
  final double? tokensPerSecond;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.imagePath,
    this.imageLabel,
    this.generatedTokens,
    this.elapsedMs,
    this.tokensPerSecond,
  });

  ChatMessage copyWith({
    String? text,
    Object? imagePath = _unset,
    Object? imageLabel = _unset,
    int? generatedTokens,
    int? elapsedMs,
    double? tokensPerSecond,
  }) {
    return ChatMessage(
      id: id,
      text: text ?? this.text,
      isUser: isUser,
      timestamp: timestamp,
      imagePath: imagePath == _unset ? this.imagePath : imagePath as String?,
      imageLabel: imageLabel == _unset
          ? this.imageLabel
          : imageLabel as String?,
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
      'imagePath': imagePath,
      'imageLabel': imageLabel,
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
      imagePath: json['imagePath'] as String?,
      imageLabel: json['imageLabel'] as String?,
      generatedTokens: (json['generatedTokens'] as num?)?.toInt(),
      elapsedMs: (json['elapsedMs'] as num?)?.toInt(),
      tokensPerSecond: (json['tokensPerSecond'] as num?)?.toDouble(),
    );
  }
}
