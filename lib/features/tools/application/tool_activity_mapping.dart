import 'package:pocket_llm/features/conversations/domain/message_tool_activity.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

/// Snapshot of one tool run for the conversation record.
///
/// The message keeps what the user needs to see afterwards; the live types stay
/// out of the stored format.
MessageToolActivity messageToolActivityFrom({
  required ToolCall call,
  required ToolExecutionResult result,
}) {
  return MessageToolActivity(
    name: result.toolName.isEmpty ? call.toolName : result.toolName,
    arguments: renderToolArguments(call.arguments),
    status: switch (result.status) {
      ToolExecutionStatus.success => MessageToolActivityStatus.success,
      ToolExecutionStatus.invalidArguments =>
        MessageToolActivityStatus.invalidArguments,
      ToolExecutionStatus.denied => MessageToolActivityStatus.denied,
      ToolExecutionStatus.unsupported => MessageToolActivityStatus.unsupported,
      ToolExecutionStatus.unknownTool => MessageToolActivityStatus.unknownTool,
      ToolExecutionStatus.failed => MessageToolActivityStatus.failed,
      ToolExecutionStatus.timedOut => MessageToolActivityStatus.timedOut,
    },
    output: result.output,
    durationMs: result.duration > Duration.zero
        ? result.duration.inMilliseconds
        : null,
  );
}
