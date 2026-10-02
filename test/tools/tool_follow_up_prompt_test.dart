import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/features/tools/application/tool_follow_up_prompt.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

void main() {
  const callJson =
      '{"type": "tool_call", "tool": "calculator", '
      '"arguments": {"expression": "2 + 2"}}';

  group('buildToolFollowUpMessages', () {
    test('keeps the history and adds the call and its result', () {
      final history = [const LlmPromptMessage.user('What is 2 + 2?')];

      final messages = buildToolFollowUpMessages(
        history: history,
        rawToolCall: callJson,
        result: const ToolExecutionResult(
          toolName: 'calculator',
          status: ToolExecutionStatus.success,
          output: '2 + 2 = 4',
        ),
      );

      expect(messages, hasLength(3));
      expect(messages[0].isUser, isTrue);
      expect(messages[0].text, 'What is 2 + 2?');
      expect(messages[1].isUser, isFalse);
      expect(messages[1].text, callJson);
      expect(messages[2].isUser, isTrue);
      expect(messages[2].text, contains('Tool: calculator'));
      expect(messages[2].text, contains('Status: success'));
      expect(messages[2].text, contains('Result: 2 + 2 = 4'));
      expect(
        messages[2].text,
        contains('Do not call another tool in this reply.'),
      );
    });

    test('carries a failure result so the model can explain it', () {
      final messages = buildToolFollowUpMessages(
        history: const [],
        rawToolCall: callJson,
        result: const ToolExecutionResult(
          toolName: 'calculator',
          status: ToolExecutionStatus.timedOut,
          output: 'calculator did not finish and was stopped.',
        ),
      );

      expect(messages, hasLength(2));
      expect(messages.last.text, contains('Status: timedOut'));
      expect(messages.last.text, contains('did not finish'));
    });
  });
}
