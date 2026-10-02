import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/message_tool_activity.dart';
import 'package:pocket_llm/features/tools/application/tool_activity_mapping.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

void main() {
  ToolCall call() => const ToolCall(
    toolName: 'calculator',
    arguments: {'expression': '(2 + 3) * 4'},
  );

  group('messageToolActivityFrom', () {
    test('records a successful run with its arguments and duration', () {
      final activity = messageToolActivityFrom(
        call: call(),
        result: const ToolExecutionResult(
          toolName: 'calculator',
          status: ToolExecutionStatus.success,
          output: '(2 + 3) * 4 = 20',
          duration: Duration(milliseconds: 3),
        ),
      );

      expect(activity.name, 'calculator');
      expect(activity.arguments, 'expression: (2 + 3) * 4');
      expect(activity.status, MessageToolActivityStatus.success);
      expect(activity.isSuccess, isTrue);
      expect(activity.output, '(2 + 3) * 4 = 20');
      expect(activity.durationMs, 3);
      expect(activity.callLabel, 'calculator(expression: (2 + 3) * 4)');
    });

    test('maps every runtime status to its recorded counterpart', () {
      const expected = {
        ToolExecutionStatus.success: MessageToolActivityStatus.success,
        ToolExecutionStatus.invalidArguments:
            MessageToolActivityStatus.invalidArguments,
        ToolExecutionStatus.denied: MessageToolActivityStatus.denied,
        ToolExecutionStatus.unsupported: MessageToolActivityStatus.unsupported,
        ToolExecutionStatus.unknownTool: MessageToolActivityStatus.unknownTool,
        ToolExecutionStatus.failed: MessageToolActivityStatus.failed,
        ToolExecutionStatus.timedOut: MessageToolActivityStatus.timedOut,
      };

      for (final entry in expected.entries) {
        final activity = messageToolActivityFrom(
          call: call(),
          result: ToolExecutionResult(
            toolName: 'calculator',
            status: entry.key,
            output: 'message',
          ),
        );
        expect(activity.status, entry.value);
      }
    });

    test('keeps a missing duration and call arguments empty', () {
      final activity = messageToolActivityFrom(
        call: const ToolCall(toolName: 'current_datetime'),
        result: const ToolExecutionResult(
          toolName: 'current_datetime',
          status: ToolExecutionStatus.failed,
          output: 'the clock went missing',
          duration: Duration.zero,
        ),
      );

      expect(activity.durationMs, isNull);
      expect(activity.arguments, isEmpty);
      expect(activity.callLabel, 'current_datetime');
      expect(activity.isSuccess, isFalse);
    });

    test('uses the runtime tool name when the result has one', () {
      final activity = messageToolActivityFrom(
        call: call(),
        result: const ToolExecutionResult(
          toolName: 'renamed_tool',
          status: ToolExecutionStatus.success,
          output: 'ok',
        ),
      );

      expect(activity.name, 'renamed_tool');
    });
  });
}
