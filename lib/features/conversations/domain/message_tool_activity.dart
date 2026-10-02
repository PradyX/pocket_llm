/// How one tool call ended, as recorded on the message that used it.
///
/// Deliberately a copy of the tool runtime's statuses rather than a reference:
/// the conversation format should keep reading correctly even if the tool
/// implementation changes, and a stored assistant message is a snapshot of what
/// happened at the time.
enum MessageToolActivityStatus {
  success('Done'),
  invalidArguments('Invalid arguments'),
  denied('Not permitted'),
  unsupported('Not available'),
  unknownTool('Unknown tool'),
  failed('Failed'),
  timedOut('Timed out');

  const MessageToolActivityStatus(this.label);

  final String label;

  /// Parses a stored status name, or null when it is not one this build knows.
  static MessageToolActivityStatus? tryParse(String? value) {
    if (value == null) return null;
    final normalized = value.trim();
    for (final status in values) {
      if (status.name == normalized) return status;
    }
    return null;
  }
}

/// One local tool call an assistant message made.
///
/// Stored with the message so the conversation shows what ran, with what
/// arguments and what came back — including on another device after an
/// export/import. The tool result is only a record; the answer the model wrote
/// from it is the message content.
class MessageToolActivity {
  const MessageToolActivity({
    required this.name,
    required this.arguments,
    required this.status,
    this.output = '',
    this.durationMs,
  });

  /// Tool the model asked for, exactly as the registry knows it.
  final String name;

  /// Arguments read as `key: value`, already rendered for display.
  final String arguments;

  final MessageToolActivityStatus status;

  /// Result text on success, otherwise what went wrong. Shown to the user.
  final String output;

  /// How long the handler took; null when nothing ran.
  final int? durationMs;

  bool get isSuccess => status == MessageToolActivityStatus.success;

  /// `calculator(expression: (2 + 3) * 4)`.
  String get callLabel => arguments.trim().isEmpty ? name : '$name($arguments)';

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'arguments': arguments,
      'status': status.name,
      'output': output,
      'durationMs': durationMs,
    };
  }

  /// Parses one stored activity, or null when it has no usable tool name.
  static MessageToolActivity? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;

    return MessageToolActivity(
      name: name,
      arguments: raw['arguments'] is String ? raw['arguments'] as String : '',
      // An unknown status is shown as a failure rather than dropped, so a
      // record written by a newer build is still visible in this one.
      status:
          MessageToolActivityStatus.tryParse(raw['status'] as String?) ??
          MessageToolActivityStatus.failed,
      output: raw['output'] is String ? raw['output'] as String : '',
      durationMs: (raw['durationMs'] as num?)?.toInt(),
    );
  }

  /// Parses a stored list of activities, skipping entries that cannot be used.
  static List<MessageToolActivity> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final activities = <MessageToolActivity>[];
    for (final entry in raw) {
      final activity = MessageToolActivity.fromJson(entry);
      if (activity != null) activities.add(activity);
    }
    return activities;
  }
}
