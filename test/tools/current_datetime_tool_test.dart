import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/tools/application/built_in_tools.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/current_datetime_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

void main() {
  ToolRegistry registryWith(DateTime now) =>
      buildToolRegistry(platform: ToolPlatform.macOS, clock: () => now);

  test('reads the device clock in local time by default', () async {
    final registry = registryWith(DateTime(2026, 10, 1, 9, 30, 5));

    final result = await registry.execute(
      const ToolCall(toolName: 'current_datetime'),
    );

    expect(result.isSuccess, isTrue);
    expect(result.output, '2026-10-01 09:30:05 (Thursday)');
  });

  test('reads UTC when asked', () async {
    final registry = registryWith(DateTime.utc(2026, 10, 1, 9, 30, 5));

    final result = await registry.execute(
      const ToolCall(
        toolName: 'current_datetime',
        arguments: {'timezone': 'utc'},
      ),
    );

    expect(result.output, '2026-10-01 09:30:05 UTC (Thursday)');
  });

  test('rejects a timezone it does not know', () async {
    final registry = registryWith(DateTime(2026, 10, 1));

    final result = await registry.execute(
      const ToolCall(
        toolName: 'current_datetime',
        arguments: {'timezone': 'mars'},
      ),
    );

    expect(result.status, ToolExecutionStatus.invalidArguments);
    expect(result.output, contains('local, utc'));
  });

  test('names the weekday for every day of the week', () {
    expect(weekdayName(DateTime.monday), 'Monday');
    expect(weekdayName(DateTime.sunday), 'Sunday');
    expect(weekdayName(0), 'Unknown day');
  });
}
