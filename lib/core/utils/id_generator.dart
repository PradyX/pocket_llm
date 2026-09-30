import 'dart:math';

/// Generates locally-unique identifiers for conversations, messages and
/// attachments.
///
/// Format: `prefix-timestampCounterRandom`, base36 encoded.
///
/// IDs only need to be unique within a single device installation, which the
/// millisecond timestamp combined with a per-process counter and a random
/// suffix guarantees in practice. The result is filesystem-safe so it can be
/// used directly as a stored file name.
class IdGenerator {
  IdGenerator._();

  static int _counter = 0;
  static final Random _random = Random();

  /// Generates a new identifier with the given [prefix].
  static String generate(String prefix) {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final counter = (_counter++ & 0xFFFF).toRadixString(36);
    final random = _random.nextInt(0xFFFFFF).toRadixString(36);
    return '$prefix-$timestamp$counter$random';
  }

  /// Identifier for a conversation.
  static String conversation() => generate('c');

  /// Identifier for a chat message.
  static String message() => generate('m');

  /// Identifier for a message attachment.
  static String attachment() => generate('a');
}
