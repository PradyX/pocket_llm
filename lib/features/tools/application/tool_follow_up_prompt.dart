import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

/// Messages for the one follow-up turn after a tool ran.
///
/// The model sees the call it made and the result, then answers in prose. The
/// result is delivered as a user turn because the runtime's chat templates only
/// carry user and assistant roles; it is clearly labelled so a small model does
/// not read it as something the user typed.
///
/// [history] must be the same message list the first prompt was built from, so
/// the follow-up differs only by the tool exchange. The closing line asks for
/// no further tool call: this app runs one tool per user turn.
List<LlmPromptMessage> buildToolFollowUpMessages({
  required List<LlmPromptMessage> history,
  required String rawToolCall,
  required ToolExecutionResult result,
}) {
  return [
    ...history,
    LlmPromptMessage.assistant(rawToolCall),
    LlmPromptMessage.user(
      'The tool ran on this device. Its result follows.\n\n'
      '${result.toModelText()}\n\n'
      "Answer the user's original request using this result. Do not call "
      'another tool in this reply.',
    ),
  ];
}
