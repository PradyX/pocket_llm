import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pocket_llm/core/services/device_profile_service.dart';
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/features/agents/domain/agent_run.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/model_selection/data/model_compatibility_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/tools/application/assistant_reply.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

/// The engine operations an agent run needs.
///
/// Kept behind an interface so the loop can be tested without loading a GGUF
/// model: tests supply a scripted runtime, the app supplies
/// [LlmAgentRuntime].
abstract class AgentRuntime {
  /// True while the shared engine is already generating something else.
  bool get isGenerating;

  /// Loads [modelPath] for an agent run.
  Future<void> load({required String modelPath, required int contextTokens});

  /// Streams one completion for [prompt].
  Stream<String> generate(String prompt, {required int maxTokens});

  /// Asks the running generation to stop; text produced so far is kept.
  void cancel();
}

/// Runs agent turns on the app's shared local engine.
///
/// The app keeps one model resident at a time; using the same engine is what
/// makes that hold for chat, voice, comparison and agent runs alike.
class LlmAgentRuntime implements AgentRuntime {
  LlmAgentRuntime(this._llmService);

  final LlmService _llmService;

  @override
  bool get isGenerating => _llmService.isGenerating;

  @override
  Future<void> load({required String modelPath, required int contextTokens}) {
    return _llmService.ensureModelLoaded(
      modelPath,
      nCtx: contextTokens,
      nBatch: contextTokens,
      // Low, fixed sampling: an agent decides what to do next, so the same goal
      // on the same model should take the same route.
      temperature: AgentLoopService.temperature,
      topP: AgentLoopService.topP,
      topK: AgentLoopService.topK,
    );
  }

  @override
  Stream<String> generate(String prompt, {required int maxTokens}) {
    return _llmService.generateResponse(prompt, maxTokens: maxTokens);
  }

  @override
  void cancel() => _llmService.stopGeneration();
}

/// Agent loop over the app's shared local engine.
final agentLoopServiceProvider = Provider<AgentLoopService>((ref) {
  final storage = ref.watch(modelStorageServiceProvider);
  final deviceProfileService = ref.watch(deviceProfileServiceProvider);

  return AgentLoopService(
    runtime: LlmAgentRuntime(ref.watch(llmServiceProvider)),
    resolveModelPath: storage.resolveModelPath,
    isFileReady: storage.isModelPathDownloaded,
    readDeviceProfile: deviceProfileService.collect,
  );
});

/// Runs one goal through the local tools, step by step, with hard limits.
///
/// The loop is deliberately small and bounded:
///
/// ```text
/// goal -> model -> tool call -> registry -> result -> model -> ... -> answer
/// ```
///
/// * At most [maxIterations] model turns, so a run can never go on forever.
/// * Input tokens are counted against [tokenBudget] before every turn.
/// * The same call twice in a row ends the run instead of repeating work.
/// * Cancelling stops the current generation and keeps what it produced.
/// * Every tool call goes through the registry, so platform support, argument
///   validation, permission and timeouts are exactly the ones chat uses; the
///   model can request, never execute.
/// * The log records each step, so the run can be reviewed afterwards.
class AgentLoopService {
  AgentLoopService({
    required AgentRuntime runtime,
    required this.resolveModelPath,
    required this.isFileReady,
    this.readDeviceProfile,
  }) : _runtime = runtime;

  /// Iterations a run uses unless the user asks for fewer or more.
  static const int defaultMaxIterations = 6;

  /// Hard ceiling on iterations, so a UI value can never remove the bound.
  static const int maximumIterations = 12;

  /// Output budget of each model turn.
  static const int defaultMaxTokens = 256;

  /// Sampler settings shared by every turn of a run.
  static const double temperature = 0.2;
  static const double topP = 0.8;
  static const int topK = 40;

  /// Longest goal accepted, so one run cannot be started with a document.
  static const int maximumGoalLength = 2000;

  /// Instruction the agent runs under.
  ///
  /// The tool contract comes from the registry, so the model is only ever told
  /// about tools this device can really run.
  static const String systemPrompt =
      'You are a local agent running entirely on this device. Work towards the '
      "user's goal step by step. Use a tool when it gives you a fact or an "
      'action you need, and never invent a result. After each tool result, '
      'either call the next tool you need or answer the goal in plain text. '
      'When the goal is answered, reply with the answer as plain text.';

  final AgentRuntime _runtime;

  /// Absolute path of a model's main GGUF file.
  final Future<String?> Function(LlmModel model) resolveModelPath;

  /// Whether a model file exists, is complete and carries GGUF bytes.
  final Future<bool> Function(String? path) isFileReady;

  /// Device snapshot for the run header, when the app supplies one.
  final Future<DeviceProfile> Function()? readDeviceProfile;

  bool _cancelled = false;

  /// Runs [goal] until the model answers, a limit is reached or the user stops.
  ///
  /// [onStep] is called for every logged step as it happens, so a caller can
  /// show progress without waiting for the run to finish.
  Future<AgentRun> run({
    required LlmModel model,
    required String goal,
    required ToolRegistry registry,
    int maxIterations = defaultMaxIterations,
    int? maxTokens,
    void Function(AgentStep step)? onStep,
  }) async {
    final trimmedGoal = goal.trim();
    if (trimmedGoal.isEmpty) {
      throw Exception('Describe the goal the agent should work on.');
    }
    if (trimmedGoal.length > maximumGoalLength) {
      throw Exception('Keep the goal under $maximumGoalLength characters.');
    }
    if (_runtime.isGenerating) {
      throw Exception('Stop the current answer before starting an agent run.');
    }

    final contextTokens = ModelCompatibilityService.defaultContextTokens;
    final outputTokens = (maxTokens ?? defaultMaxTokens).clamp(
      64,
      contextTokens ~/ 4,
    );
    final policy = ContextPolicy.forModel(
      runtimeContextTokens: contextTokens,
      reservedOutputTokens: outputTokens,
      declaredContextTokens: model.ggufMetadata?.contextLength,
    );
    final tokenBudget = policy.usableInputTokens;
    final iterations = maxIterations.clamp(1, maximumIterations);

    final steps = <AgentStep>[];
    var iteration = 0;
    var usedIterations = 0;
    var estimatedInputTokens = 0;
    var answer = '';
    var status = AgentRunStatus.completed;
    String? errorMessage;

    void log(AgentStep step) {
      steps.add(step);
      onStep?.call(step);
    }

    final startedAt = DateTime.now();
    log(
      AgentStep(
        index: 1,
        kind: AgentStepKind.goal,
        text: trimmedGoal,
        iteration: 0,
      ),
    );

    AgentRun build(AgentRunStatus runStatus) {
      return AgentRun(
        goal: trimmedGoal,
        modelId: model.id,
        modelName: model.name,
        steps: [...steps],
        status: runStatus,
        maxIterations: iterations,
        tokenBudget: tokenBudget,
        iterations: usedIterations,
        estimatedInputTokens: estimatedInputTokens,
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        answer: answer,
        errorMessage: errorMessage,
      );
    }

    _cancelled = false;

    final modelPath = await resolveModelPath(model);
    if (modelPath == null ||
        modelPath.trim().isEmpty ||
        !await isFileReady(modelPath)) {
      errorMessage = 'Model file is missing or incomplete on this device.';
      return build(AgentRunStatus.failed);
    }

    try {
      await _runtime.load(modelPath: modelPath, contextTokens: contextTokens);
    } catch (error) {
      errorMessage = _messageOf(error);
      return build(AgentRunStatus.failed);
    }

    final history = <LlmPromptMessage>[LlmPromptMessage.user(trimmedGoal)];
    final requestedCalls = <String>{};
    final stopToken = modelStopToken(model.promptFormatId);
    var nextIndex = steps.length + 1;

    for (iteration = 1; iteration <= iterations; iteration++) {
      final promptBundle = buildModelChatPrompt(
        history,
        systemPrompt: _systemPromptWithTools(registry),
        promptFormatId: model.promptFormatId,
      );
      final promptTokens =
          TokenEstimator.estimateText(promptBundle.prompt) +
          TokenEstimator.messageOverheadTokens;

      if (promptTokens + outputTokens > tokenBudget) {
        status = AgentRunStatus.budgetReached;
        log(
          AgentStep(
            index: nextIndex++,
            kind: AgentStepKind.notice,
            iteration: iteration,
            text:
                'Stopped before this turn: the prompt plus the answer '
                'reservation would need about '
                '${promptTokens + outputTokens} tokens, more than the '
                '$tokenBudget-token input budget.',
          ),
        );
        return build(status);
      }
      // Counted only once the turn really runs, so a stopped-before-starting
      // run reports the turns it used.
      usedIterations = iteration;
      estimatedInputTokens += promptTokens;

      final buffer = StringBuffer();
      var generatedTokens = 0;
      var failed = false;
      try {
        await for (final token in _runtime.generate(
          promptBundle.prompt,
          maxTokens: outputTokens,
        )) {
          final cleanToken = token.replaceAll(stopToken, '');
          if (cleanToken.isNotEmpty) {
            buffer.write(cleanToken);
            generatedTokens++;
          }
          if (token.contains(stopToken)) break;
        }
      } catch (error) {
        if (!_cancelled) {
          errorMessage = _messageOf(error);
          failed = true;
        }
      }

      final rawText = buildFinalResponseText(buffer.toString());
      if (_cancelled) {
        status = AgentRunStatus.stopped;
        answer = rawText.trim();
        log(
          AgentStep(
            index: nextIndex++,
            kind: AgentStepKind.notice,
            iteration: iteration,
            text: 'Stopped by the user.',
          ),
        );
        return build(status);
      }
      if (failed) {
        log(
          AgentStep(
            index: nextIndex++,
            kind: AgentStepKind.notice,
            iteration: iteration,
            text: 'The model failed during this turn.',
          ),
        );
        return build(AgentRunStatus.failed);
      }
      if (generatedTokens == 0 && rawText.trim().isEmpty) {
        status = AgentRunStatus.stopped;
        log(
          AgentStep(
            index: nextIndex++,
            kind: AgentStepKind.notice,
            iteration: iteration,
            text: 'The model produced no text, so the run stopped.',
          ),
        );
        return build(status);
      }

      final reply = resolveAssistantReply(rawText, registry: registry);
      switch (reply) {
        case AssistantTextReply(:final text):
          answer = text.trim();
          log(
            AgentStep(
              index: nextIndex++,
              kind: AgentStepKind.answer,
              iteration: iteration,
              text: answer,
            ),
          );
          return build(AgentRunStatus.completed);

        case RegistryToolReply(:final call):
          // A tool turn is exactly the JSON call — no prose — because the
          // registry's contract asks for only the JSON object. Reasoning the
          // model wants to record goes in its final answer.
          final activity = _activityText(call.toolName, call.arguments);
          if (!requestedCalls.add(activity)) {
            status = AgentRunStatus.noProgress;
            log(
              AgentStep(
                index: nextIndex++,
                kind: AgentStepKind.notice,
                iteration: iteration,
                text:
                    'The model asked for $activity again without changing '
                    'anything, so the run stopped instead of repeating it.',
              ),
            );
            return build(status);
          }

          final result = await registry.execute(call);
          log(
            AgentStep(
              index: nextIndex++,
              kind: AgentStepKind.toolCall,
              iteration: iteration,
              text: result.toolName,
              toolName: result.toolName,
              arguments: renderToolArguments(call.arguments),
              status: _statusLabel(result.status),
              durationMs: result.duration.inMilliseconds,
            ),
          );
          log(
            AgentStep(
              index: nextIndex++,
              kind: AgentStepKind.observation,
              iteration: iteration,
              text: result.output,
              toolName: result.toolName,
              status: _statusLabel(result.status),
            ),
          );

          history
            ..add(LlmPromptMessage.assistant(rawText))
            ..add(
              LlmPromptMessage.user(
                'The tool ran on this device. Its result follows.\n\n'
                '${result.toModelText()}\n\n'
                'Decide what to do next: call another tool if you need one, '
                'or answer the goal in plain text.',
              ),
            );

          if (_cancelled) {
            status = AgentRunStatus.stopped;
            log(
              AgentStep(
                index: nextIndex++,
                kind: AgentStepKind.notice,
                iteration: iteration,
                text: 'Stopped by the user.',
              ),
            );
            return build(status);
          }
      }
    }

    log(
      AgentStep(
        index: nextIndex++,
        kind: AgentStepKind.notice,
        iteration: iterations,
        text:
            'Reached the limit of $iterations '
            'iteration${iterations == 1 ? '' : 's'} without a final answer.',
      ),
    );
    return build(AgentRunStatus.maxIterations);
  }

  /// Asks the running turn to stop; what it produced is kept.
  void cancel() {
    _cancelled = true;
    _runtime.cancel();
  }

  /// The agent instruction plus the tools this device can really run.
  static String _systemPromptWithTools(ToolRegistry registry) {
    final contract = registry.describeForPrompt();
    if (contract.isEmpty) return systemPrompt;
    return '$systemPrompt\n\n$contract';
  }

  static String _activityText(String tool, Map<String, Object?> arguments) {
    return '$tool(${renderToolArguments(arguments)})';
  }

  static String _statusLabel(ToolExecutionStatus status) {
    return switch (status) {
      ToolExecutionStatus.success => 'Success',
      ToolExecutionStatus.invalidArguments => 'Invalid arguments',
      ToolExecutionStatus.denied => 'Denied',
      ToolExecutionStatus.unsupported => 'Not supported here',
      ToolExecutionStatus.unknownTool => 'Unknown tool',
      ToolExecutionStatus.failed => 'Failed',
      ToolExecutionStatus.timedOut => 'Timed out',
    };
  }

  /// `Exception: something` reads badly in the UI, so the prefix is dropped.
  static String _messageOf(Object error) {
    const prefix = 'Exception: ';
    final text = error.toString();
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }
}
