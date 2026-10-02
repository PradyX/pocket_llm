import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/tools/application/tool_approval_controller.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

void main() {
  const request = ToolApprovalRequest(
    tool: ToolDefinition(
      name: 'set_alarm',
      description: 'Opens the alarm app.',
      parameters: [],
      risk: ToolRiskLevel.sensitive,
    ),
    arguments: {'hour': 7, 'minute': 30},
  );

  ToolApprovalController controllerFor(ProviderContainer container) =>
      container.read(toolApprovalControllerProvider.notifier);

  test('publishes the question and completes with the answer', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = controllerFor(container);

    final answer = controller.requestApproval(request);

    expect(container.read(toolApprovalControllerProvider), same(request));
    expect(request.summary, 'set_alarm(hour: 7, minute: 30)');

    controller.approve();

    expect(await answer, isTrue);
    expect(container.read(toolApprovalControllerProvider), isNull);
  });

  test('denies when the user refuses', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = controllerFor(container);

    final answer = controller.requestApproval(request);
    controller.deny();

    expect(await answer, isFalse);
    expect(container.read(toolApprovalControllerProvider), isNull);
  });

  test('refuses a second question while one is already pending', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = controllerFor(container);

    final first = controller.requestApproval(request);
    expect(await controller.requestApproval(request), isFalse);

    controller.deny();
    expect(await first, isFalse);
  });

  test('the gate asks through the same prompt', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = controllerFor(container);
    final gate = ChatToolPermissionGate(controller);

    final answer = gate.requestApproval(request);
    expect(container.read(toolApprovalControllerProvider), same(request));

    controller.approve();
    expect(await answer, isTrue);
  });
}
