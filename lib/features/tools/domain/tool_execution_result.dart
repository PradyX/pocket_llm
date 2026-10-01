/// How one tool call ended.
///
/// Every one of these is reported to the user and to the model; nothing fails
/// silently, and a refused or unsupported call is a normal outcome rather than
/// an exception an implementation could swallow.
enum ToolExecutionStatus {
  success('Done'),
  invalidArguments('Invalid arguments'),
  denied('Not permitted'),
  unsupported('Not available here'),
  unknownTool('Unknown tool'),
  failed('Failed'),
  timedOut('Timed out');

  const ToolExecutionStatus(this.label);

  final String label;
}

/// The outcome of one tool call, with what to show the user and the model.
class ToolExecutionResult {
  const ToolExecutionResult({
    required this.toolName,
    required this.status,
    required this.output,
    this.duration = Duration.zero,
  });

  /// Tool the call named, even when no such tool exists.
  final String toolName;

  final ToolExecutionStatus status;

  /// Result text on success, otherwise why the call did not run or did not
  /// finish. Written as an actionable sentence, because both the user and the
  /// model read it.
  final String output;

  /// Wall-clock time the handler took; zero when no handler ran.
  final Duration duration;

  bool get isSuccess => status == ToolExecutionStatus.success;

  /// True when the run needs the user's decision before it could happen.
  bool get needsPermission => status == ToolExecutionStatus.denied;

  /// What the model is told when the result is fed back into the conversation.
  ///
  /// Kept as a labelled block rather than raw JSON so a small model can use it
  /// without having to parse a second schema.
  String toModelText() {
    final buffer = StringBuffer()
      ..writeln('Tool: $toolName')
      ..writeln('Status: ${status.name}');
    if (output.isNotEmpty) buffer.write('Result: $output');
    return buffer.toString().trimRight();
  }
}
