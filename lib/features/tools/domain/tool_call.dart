/// One request from the model to run a tool.
///
/// The model only ever produces one of these; it cannot run anything itself.
/// The registry validates and coerces [arguments] against the tool's declared
/// parameters before a handler sees them.
class ToolCall {
  const ToolCall({
    required this.toolName,
    this.arguments = const {},
    this.rawJson = '',
  });

  /// Name the model asked for, exactly as it wrote it.
  final String toolName;

  /// Arguments as the model produced them.
  final Map<String, Object?> arguments;

  /// The JSON the model produced, kept so tool activity can show what was
  /// actually asked for instead of a reconstruction.
  final String rawJson;

  ToolCall copyWith({
    String? toolName,
    Map<String, Object?>? arguments,
    String? rawJson,
  }) {
    return ToolCall(
      toolName: toolName ?? this.toolName,
      arguments: arguments ?? this.arguments,
      rawJson: rawJson ?? this.rawJson,
    );
  }
}
