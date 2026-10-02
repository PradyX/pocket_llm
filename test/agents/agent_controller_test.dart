import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/agents/application/agent_controller.dart';
import 'package:pocket_llm/features/agents/application/agent_loop_service.dart';
import 'package:pocket_llm/features/agents/domain/agent_run.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/application/tools_providers.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

import 'scripted_agent_runtime.dart';

void main() {
  // The log copy path writes to the platform clipboard channel.
  TestWidgetsFlutterBinding.ensureInitialized();

  final model = LlmModel(
    id: 'm-1',
    name: 'Test model',
    parameterSize: '1B',
    description: 'test model',
    isDownloaded: true,
  );

  ProviderContainer containerFor({
    required ScriptedAgentRuntime runtime,
    List<LlmModel> installedModels = const [],
  }) {
    return ProviderContainer(
      overrides: [
        installedAgentModelsProvider.overrideWithValue(installedModels),
        agentLoopServiceProvider.overrideWithValue(
          AgentLoopService(
            runtime: runtime,
            resolveModelPath: (model) async => '/models/${model.id}.gguf',
            isFileReady: (path) async => path != null,
          ),
        ),
        toolRegistryProvider.overrideWithValue(
          ToolRegistry(tools: const [], platform: ToolPlatform.macOS),
        ),
      ],
    );
  }

  test('runs a goal and streams the log into the state', () async {
    final runtime = ScriptedAgentRuntime(script: ['The answer is 42.']);
    final container = containerFor(runtime: runtime, installedModels: [model]);
    addTearDown(container.dispose);
    final controller = container.read(agentControllerProvider.notifier);

    controller
      ..setGoal('What is the answer?')
      ..setMaxIterations(3);
    await controller.run();

    final state = container.read(agentControllerProvider);
    expect(state.stage, AgentStage.finished);
    expect(state.run!.status, AgentRunStatus.completed);
    expect(state.run!.answer, 'The answer is 42.');
    expect(state.run!.maxIterations, 3);
    expect(state.steps.map((step) => step.kind), [
      AgentStepKind.goal,
      AgentStepKind.answer,
    ]);
    expect(state.errorMessage, isNull);
    expect(state.runWasIncomplete, isFalse);
  });

  test('reports an incomplete run without calling it a failure', () async {
    final runtime = ScriptedAgentRuntime(
      script: [
        jsonEncode({
          'type': 'tool_call',
          'tool': 'nope',
          'arguments': <String, Object?>{},
        }),
      ],
    );
    final container = containerFor(runtime: runtime, installedModels: [model]);
    addTearDown(container.dispose);
    final controller = container.read(agentControllerProvider.notifier);

    controller
      ..setGoal('Do something')
      ..setMaxIterations(1);
    await controller.run();

    final state = container.read(agentControllerProvider);
    expect(state.stage, AgentStage.finished);
    expect(state.run!.status, AgentRunStatus.maxIterations);
    expect(state.runWasIncomplete, isTrue);
  });

  test('refuses to run without a model or a goal', () async {
    final runtime = ScriptedAgentRuntime(script: ['never']);
    final container = containerFor(runtime: runtime);
    addTearDown(container.dispose);
    final controller = container.read(agentControllerProvider.notifier);

    controller.setGoal('Anything');
    await controller.run();
    expect(
      container.read(agentControllerProvider).errorMessage,
      contains('No local model is installed'),
    );

    final withModel = containerFor(runtime: runtime, installedModels: [model]);
    addTearDown(withModel.dispose);
    final second = withModel.read(agentControllerProvider.notifier);
    await second.run();
    expect(
      withModel.read(agentControllerProvider).errorMessage,
      contains('Describe the goal'),
    );
    expect(runtime.prompts, isEmpty);
  });

  test('cancelling stops the run and keeps what was produced', () async {
    final runtime = ScriptedAgentRuntime(script: ['Half an answer'])
      ..holdAtEnd = true;
    final container = containerFor(runtime: runtime, installedModels: [model]);
    addTearDown(container.dispose);
    final controller = container.read(agentControllerProvider.notifier);

    controller.setGoal('Something long');
    final running = controller.run();
    await pumpAgentUntil(() => runtime.isWaiting);
    controller.cancel();
    await running;

    final state = container.read(agentControllerProvider);
    expect(state.stage, AgentStage.finished);
    expect(state.run!.status, AgentRunStatus.stopped);
    expect(state.run!.answer, 'Half an answer');
    expect(state.isRunning, isFalse);
  });

  test('changing anything while a run is working is ignored', () async {
    final runtime = ScriptedAgentRuntime(script: ['answer'])..holdAtEnd = true;
    final container = containerFor(runtime: runtime, installedModels: [model]);
    addTearDown(container.dispose);
    final controller = container.read(agentControllerProvider.notifier);

    controller.setGoal('Goal');
    final running = controller.run();
    await pumpAgentUntil(() => runtime.isWaiting);

    controller
      ..setGoal('Changed')
      ..setMaxIterations(12)
      ..setModel('other')
      ..clear();
    runtime.release();
    await running;

    final state = container.read(agentControllerProvider);
    expect(state.goal, 'Goal');
    expect(state.maxIterations, AgentLoopService.defaultMaxIterations);
    expect(state.run, isNotNull);
  });

  test('clear keeps the goal and settings but drops the log', () async {
    final runtime = ScriptedAgentRuntime(script: ['answer']);
    final container = containerFor(runtime: runtime, installedModels: [model]);
    addTearDown(container.dispose);
    final controller = container.read(agentControllerProvider.notifier);

    controller
      ..setGoal('Keep me')
      ..setMaxIterations(9);
    await controller.run();
    expect(container.read(agentControllerProvider).hasLog, isTrue);

    controller.clear();
    final state = container.read(agentControllerProvider);
    expect(state.goal, 'Keep me');
    expect(state.maxIterations, 9);
    expect(state.steps, isEmpty);
    expect(state.run, isNull);
    expect(state.stage, AgentStage.idle);
  });

  test('the log can be copied as JSON and as Markdown', () async {
    final runtime = ScriptedAgentRuntime(script: ['4']);
    final container = containerFor(runtime: runtime, installedModels: [model]);
    addTearDown(container.dispose);
    final controller = container.read(agentControllerProvider.notifier);

    controller.setGoal('What is 2 + 2?');
    await controller.run();

    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    expect(await controller.copyRunAsJson(), isTrue);
    final payload = jsonDecode(copied!) as Map<String, dynamic>;
    expect(payload['format'], agentRunExportFormat);
    expect(payload['answer'], '4');

    expect(await controller.copyRunAsMarkdown(), isTrue);
    expect(copied, startsWith('# Agent run'));
    expect(copied, contains('- **Goal:** What is 2 + 2?'));
  });

  test(
    'copying without a finished run reports that there is nothing',
    () async {
      final runtime = ScriptedAgentRuntime();
      final container = containerFor(
        runtime: runtime,
        installedModels: [model],
      );
      addTearDown(container.dispose);
      final controller = container.read(agentControllerProvider.notifier);

      expect(await controller.copyRunAsJson(), isFalse);
      expect(await controller.copyRunAsMarkdown(), isFalse);
    },
  );
}
