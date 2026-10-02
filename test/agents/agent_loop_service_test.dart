import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/agents/application/agent_loop_service.dart';
import 'package:pocket_llm/features/agents/domain/agent_run.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

import 'scripted_agent_runtime.dart';

void main() {
  final model = LlmModel(
    id: 'm-1',
    name: 'Test model',
    parameterSize: '1B',
    description: 'test model',
    isDownloaded: true,
  );

  AgentLoopService serviceFor(ScriptedAgentRuntime runtime) {
    return AgentLoopService(
      runtime: runtime,
      resolveModelPath: (model) async => '/models/${model.id}.gguf',
      isFileReady: (path) async => path != null,
    );
  }

  /// A registry with one read-only tool and one sensitive tool, so permission
  /// handling can be observed without a platform channel.
  ToolRegistry registryFor({
    required List<String> calls,
    bool allowSensitive = false,
    bool failSensitive = false,
  }) {
    return ToolRegistry(
      platform: ToolPlatform.macOS,
      permissionGate: _Gate(allowSensitive),
      tools: [
        ToolEntry(
          definition: const ToolDefinition(
            name: 'lookup',
            description: 'Looks something up locally.',
            parameters: [
              ToolParameter(
                name: 'what',
                type: ToolParameterType.string,
                description: 'What to look up.',
              ),
            ],
            risk: ToolRiskLevel.readOnly,
          ),
          handler: (arguments) async {
            calls.add('lookup(${arguments['what']})');
            return 'looked up: ${arguments['what']}';
          },
        ),
        ToolEntry(
          definition: const ToolDefinition(
            name: 'act',
            description: 'Acts outside the app.',
            parameters: [],
            risk: ToolRiskLevel.sensitive,
          ),
          handler: (arguments) async {
            calls.add('act');
            if (failSensitive) throw Exception('the action failed');
            return 'acted';
          },
        ),
      ],
    );
  }

  String toolCall(String name, [Map<String, Object?> arguments = const {}]) {
    return jsonEncode({
      'type': 'tool_call',
      'tool': name,
      'arguments': arguments,
    });
  }

  test('answers a goal that needs no tool', () async {
    final runtime = ScriptedAgentRuntime(script: ['4 is even.']);
    final service = serviceFor(runtime);

    final run = await service.run(
      model: model,
      goal: 'Is 4 even?',
      registry: registryFor(calls: []),
    );

    expect(run.status, AgentRunStatus.completed);
    expect(run.answer, '4 is even.');
    expect(run.iterations, 1);
    expect(run.toolCallCount, 0);
    expect(run.steps.map((step) => step.kind), [
      AgentStepKind.goal,
      AgentStepKind.answer,
    ]);
    expect(run.modelName, 'Test model');
    expect(run.tokenBudget, greaterThan(0));
    expect(run.estimatedInputTokens, greaterThan(0));
    expect(run.duration, isNotNull);
  });

  test('uses a tool, feeds the result back and answers', () async {
    final runtime = ScriptedAgentRuntime(
      script: [
        // A tool turn is only the JSON call: the registry's contract asks for
        // exactly that, so a prefix would not be recognised as a call.
        toolCall('lookup', {'what': 'answer'}),
        'The lookup said: looked up: answer.',
      ],
    );
    final calls = <String>[];
    final service = serviceFor(runtime);

    final run = await service.run(
      model: model,
      goal: 'What is the answer?',
      registry: registryFor(calls: calls),
    );

    expect(run.status, AgentRunStatus.completed);
    expect(calls, ['lookup(answer)']);
    expect(run.iterations, 2);
    expect(run.toolCallCount, 1);
    expect(run.failedToolCallCount, 0);
    expect(run.steps.map((step) => step.kind), [
      AgentStepKind.goal,
      AgentStepKind.toolCall,
      AgentStepKind.observation,
      AgentStepKind.answer,
    ]);
    final call = run.steps[1];
    expect(call.toolName, 'lookup');
    expect(call.arguments, 'what: answer');
    expect(call.status, 'Success');
    expect(run.steps[2].text, 'looked up: answer');
    // The model is told the result in the follow-up prompt.
    expect(runtime.prompts.last, contains('looked up: answer'));
    expect(runtime.prompts.last, contains('Decide what to do next'));
  });

  test('stops when the model repeats the same call', () async {
    final runtime = ScriptedAgentRuntime(
      script: [
        toolCall('lookup', {'what': 'the same'}),
        toolCall('lookup', {'what': 'the same'}),
      ],
    );
    final calls = <String>[];
    final service = serviceFor(runtime);

    final run = await service.run(
      model: model,
      goal: 'Look it up twice',
      registry: registryFor(calls: calls),
    );

    expect(run.status, AgentRunStatus.noProgress);
    // The repeated call never ran.
    expect(calls, ['lookup(the same)']);
    expect(run.iterations, 2);
    expect(run.steps.last.kind, AgentStepKind.notice);
    expect(run.steps.last.text, contains('again without changing anything'));
  });

  test('stops at the iteration limit', () async {
    final runtime = ScriptedAgentRuntime(
      script: [
        toolCall('lookup', {'what': 'one'}),
        toolCall('lookup', {'what': 'two'}),
        toolCall('lookup', {'what': 'three'}),
      ],
    );
    final service = serviceFor(runtime);

    final run = await service.run(
      model: model,
      goal: 'Keep looking things up',
      registry: registryFor(calls: []),
      maxIterations: 3,
    );

    expect(run.status, AgentRunStatus.maxIterations);
    expect(run.iterations, 3);
    expect(run.maxIterations, 3);
    expect(run.answer, isEmpty);
    expect(run.steps.last.text, contains('Reached the limit of 3'));
  });

  test(
    'a sensitive tool waits for permission and is reported when refused',
    () async {
      final runtime = ScriptedAgentRuntime(
        script: [toolCall('act'), 'I could not do that.'],
      );
      final calls = <String>[];
      final service = serviceFor(runtime);

      final run = await service.run(
        model: model,
        goal: 'Act',
        registry: registryFor(calls: calls),
      );

      expect(calls, isEmpty);
      expect(run.toolCallCount, 1);
      expect(run.failedToolCallCount, 1);
      final call = run.steps.firstWhere(
        (step) => step.kind == AgentStepKind.toolCall,
      );
      expect(call.status, 'Denied');
      // The model is told the refusal, so it can answer without the tool.
      expect(runtime.prompts.last, contains('did not allow'));
      expect(run.status, AgentRunStatus.completed);
      expect(run.answer, 'I could not do that.');
    },
  );

  test('an approved sensitive tool runs and a failure is reported', () async {
    final runtime = ScriptedAgentRuntime(script: [toolCall('act'), 'Done.']);
    final calls = <String>[];
    final service = serviceFor(runtime);

    final run = await service.run(
      model: model,
      goal: 'Act',
      registry: registryFor(calls: calls, allowSensitive: true),
    );

    expect(calls, ['act']);
    expect(run.status, AgentRunStatus.completed);
    expect(run.failedToolCallCount, 0);

    final failing = serviceFor(
      ScriptedAgentRuntime(script: [toolCall('act'), 'It failed.']),
    );
    final failedRun = await failing.run(
      model: model,
      goal: 'Act',
      registry: registryFor(
        calls: [],
        allowSensitive: true,
        failSensitive: true,
      ),
    );
    expect(failedRun.status, AgentRunStatus.completed);
    expect(failedRun.failedToolCallCount, 1);
    expect(
      failedRun.steps
          .firstWhere((step) => step.kind == AgentStepKind.observation)
          .text,
      contains('the action failed'),
    );
  });

  test('cancelling keeps the partial answer and stops the loop', () async {
    final runtime = ScriptedAgentRuntime(script: ['Working on it'])
      ..holdAtEnd = true;
    final service = serviceFor(runtime);

    final runFuture = service.run(
      model: model,
      goal: 'Something long',
      registry: registryFor(calls: []),
    );
    await pumpAgentUntil(() => runtime.isWaiting);
    service.cancel();
    final run = await runFuture;

    expect(runtime.cancelled, isTrue);
    expect(run.status, AgentRunStatus.stopped);
    expect(run.answer, 'Working on it');
    expect(run.steps.last.text, 'Stopped by the user.');
  });

  test('reports a missing model file and never loads it', () async {
    final runtime = ScriptedAgentRuntime(script: ['never']);
    final service = AgentLoopService(
      runtime: runtime,
      resolveModelPath: (model) async => null,
      isFileReady: (path) async => false,
    );

    final run = await service.run(
      model: model,
      goal: 'Anything',
      registry: registryFor(calls: []),
    );

    expect(run.status, AgentRunStatus.failed);
    expect(run.errorMessage, contains('missing or incomplete'));
    expect(runtime.loadedModelPaths, isEmpty);
  });

  test('reports a model that cannot be loaded', () async {
    final runtime = ScriptedAgentRuntime(
      script: ['never'],
      failingModelPaths: const ['/models/m-1.gguf'],
    );

    final run = await serviceFor(runtime).run(
      model: model,
      goal: 'Anything',
      registry: registryFor(calls: []),
    );

    expect(run.status, AgentRunStatus.failed);
    expect(run.errorMessage, contains('failed to load'));
  });

  test(
    'refuses an empty goal, a goal that is too long and a busy engine',
    () async {
      final runtime = ScriptedAgentRuntime(script: ['x']);
      final service = serviceFor(runtime);
      final registry = registryFor(calls: []);

      await expectLater(
        service.run(model: model, goal: '   ', registry: registry),
        throwsA(predicate((error) => '$error'.contains('Describe the goal'))),
      );
      await expectLater(
        service.run(
          model: model,
          goal: 'x' * (AgentLoopService.maximumGoalLength + 1),
          registry: registry,
        ),
        throwsA(predicate((error) => '$error'.contains('Keep the goal under'))),
      );

      runtime.isGenerating = true;
      await expectLater(
        service.run(model: model, goal: 'A goal', registry: registry),
        throwsA(predicate((error) => '$error'.contains('Stop the current'))),
      );
    },
  );

  test('stops before a turn that would exceed the token budget', () async {
    final runtime = ScriptedAgentRuntime(script: ['never sent']);
    final service = serviceFor(runtime);
    // A model that declares a small window makes the input budget too small
    // for the agent instruction plus the tools plus an answer reservation.
    final smallModel = LlmModel(
      id: 'm-2',
      name: 'Small window model',
      parameterSize: '1B',
      description: 'test model',
      isDownloaded: true,
      ggufMetadata: const GgufMetadata(
        architecture: 'llama',
        name: 'small',
        version: 3,
        kvCount: 1,
        tensorCount: 1,
        fileSizeBytes: 1024,
        parameterCount: 1,
        quantization: 'Q4_K_M',
        contextLength: 512,
      ),
    );

    final run = await service.run(
      model: smallModel,
      goal: 'Anything',
      registry: registryFor(calls: []),
    );

    expect(run.status, AgentRunStatus.budgetReached);
    expect(run.iterations, 0);
    expect(runtime.loadedModelPaths, isNotEmpty);
    expect(runtime.prompts, isEmpty);
    expect(run.tokenBudget, lessThan(300));
    expect(run.steps.last.kind, AgentStepKind.notice);
    expect(run.steps.last.text, contains('Stopped before this turn'));
  });

  test('the log is exported as versioned JSON and a readable report', () {
    final step = AgentStep(
      index: 2,
      kind: AgentStepKind.toolCall,
      iteration: 1,
      text: 'calculator',
      toolName: 'calculator',
      arguments: 'expression: 2 + 2',
      status: 'Success',
      durationMs: 12,
    );
    final run = AgentRun(
      goal: 'What is 2 + 2?',
      modelId: 'm-1',
      modelName: 'Test model',
      steps: [
        const AgentStep(
          index: 1,
          kind: AgentStepKind.goal,
          text: 'What is 2 + 2?',
          iteration: 0,
        ),
        step,
        const AgentStep(
          index: 3,
          kind: AgentStepKind.answer,
          text: '4',
          iteration: 2,
        ),
      ],
      status: AgentRunStatus.completed,
      maxIterations: 6,
      tokenBudget: 3500,
      iterations: 2,
      estimatedInputTokens: 120,
      startedAt: DateTime(2026, 10, 2, 12),
      finishedAt: DateTime(2026, 10, 2, 12, 0, 30),
      answer: '4',
    );

    final payload = run.toJson();
    expect(payload['format'], agentRunExportFormat);
    expect(payload['schemaVersion'], agentRunExportSchemaVersion);
    expect(payload['toolCalls'], 1);
    expect(payload['steps'], hasLength(3));
    expect(run.summaryLabel, 'Completed · 2 iterations · 1 tool call · 30s');

    final markdown = encodeAgentRunMarkdown(run);
    expect(markdown, startsWith('# Agent run'));
    expect(markdown, contains('- **Goal:** What is 2 + 2?'));
    expect(markdown, contains('2. Tool call (iteration 1)'));
    expect(markdown, contains('`calculator(expression: 2 + 2)` — Success'));
    expect(markdown, contains('## Answer'));
    expect(markdown, contains('4'));
  });
}

/// Permission gate the tests drive.
class _Gate implements ToolPermissionGate {
  const _Gate(this.allows);

  final bool allows;

  @override
  Future<bool> requestApproval(ToolApprovalRequest request) async => allows;
}
