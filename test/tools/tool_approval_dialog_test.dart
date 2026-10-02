import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';
import 'package:pocket_llm/features/tools/presentation/tool_approval_dialog.dart';

void main() {
  const request = ToolApprovalRequest(
    tool: ToolDefinition(
      name: 'set_alarm',
      description: 'Opens the device alarm app pre-set to the requested time.',
      parameters: [],
      risk: ToolRiskLevel.sensitive,
    ),
    arguments: {'hour': 7, 'minute': 30},
  );

  testWidgets('shows the validated call and reports both answers', (
    tester,
  ) async {
    final decisions = <bool>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolApprovalDialog(request: request, onDecision: decisions.add),
        ),
      ),
    );

    expect(find.text('Allow set_alarm?'), findsOneWidget);
    expect(find.text('set_alarm(hour: 7, minute: 30)'), findsOneWidget);
    expect(find.textContaining('another app on this device'), findsOneWidget);

    await tester.tap(find.text('Deny'));
    expect(decisions, [false]);

    await tester.tap(find.text('Allow'));
    expect(decisions, [false, true]);
  });
}
