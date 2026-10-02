import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocket_llm/features/agents/application/agent_controller.dart';
import 'package:pocket_llm/features/agents/application/agent_loop_service.dart';
import 'package:pocket_llm/features/agents/domain/agent_run.dart';
import 'package:pocket_llm/features/tools/application/tools_providers.dart';

/// Exercises the real agent wiring on this machine: the tool registry the app
/// builds for this platform, the installed-model list the Agent screen reads,
/// and — when a model is installed — one real run through the local engine.
///
/// Unit tests cover the loop against a scripted runtime; what they cannot cover
/// is the provider graph, the platform's adverised tools and a model that
/// really answers. The test prints what it found, so it is useful on a machine
/// with nothing installed.
///
/// Run on a desktop or device:
///
/// ```bash
/// flutter test integration_test/device_agent_smoke_test.dart -d macos
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the agent registry and model list are real', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(const SizedBox.shrink());

    final registry = container.read(toolRegistryProvider);
    final tools = registry.supportedDefinitions
        .map((definition) => '${definition.name} (${definition.risk.label})')
        .toList();
    // ignore: avoid_print
    print('agent tools on this platform: ${tools.length}');
    for (final tool in tools) {
      // ignore: avoid_print
      print('  $tool');
    }
    expect(
      registry.describeForPrompt(),
      contains('tool_call'),
      reason: 'the model is told how to call a tool',
    );

    final models = container.read(installedAgentModelsProvider);
    // ignore: avoid_print
    print('installed models: ${models.length}');
    for (final model in models) {
      // ignore: avoid_print
      print('  ${model.name} (${model.id})');
    }
  });

  testWidgets('a real goal runs through the agent loop', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(const SizedBox.shrink());

    final models = container.read(installedAgentModelsProvider);
    if (models.isEmpty) {
      // ignore: avoid_print
      print(
        'skipping: no installed model, so the agent loop cannot run here. '
        'Add a GGUF model through Model Selection first.',
      );
      return;
    }

    final controller = container.read(agentControllerProvider.notifier);
    controller
      ..setModel(models.first.id)
      ..setMaxIterations(4)
      ..setGoal(
        'What is 18% of 2450? Use the calculator tool, then answer in one '
        'sentence.',
      );

    await controller.run().timeout(const Duration(minutes: 10));

    final state = container.read(agentControllerProvider);
    final run = state.run;
    expect(run, isNotNull);
    // ignore: avoid_print
    print(
      'agent run: ${run!.status.label} · ${run.iterations} iteration(s) · '
      '${run.toolCallCount} tool call(s)',
    );
    for (final step in run.steps) {
      // ignore: avoid_print
      print(
        '  ${step.index}. ${step.kind.label}'
        '${step.toolName == null ? '' : ' ${step.toolName}'}'
        '${step.status == null ? '' : ' [${step.status}]'}',
      );
    }
    // ignore: avoid_print
    print('answer: ${run.answer}');

    // A run must always end inside its own limits, whatever it answers.
    expect(run.status, isNot(AgentRunStatus.failed), reason: run.errorMessage);
    expect(run.iterations, lessThanOrEqualTo(4));
    expect(state.isRunning, isFalse);
  });
}
