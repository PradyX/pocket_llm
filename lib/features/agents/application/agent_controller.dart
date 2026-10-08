import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/agents/application/agent_loop_service.dart';
import 'package:pocket_llm/features/agents/domain/agent_run.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/tools/application/tools_providers.dart';

/// Models installed on this device — the only ones an agent run can use.
///
/// The screen and the controller filter this list by tool capability, because
/// an agent run is a sequence of tool calls: a model whose chat template has no
/// tool protocol can never complete one. The capability comes from each file's
/// own template, not from its name.
final installedAgentModelsProvider = Provider<List<LlmModel>>((ref) {
  return [
    for (final model in ref.watch(modelSelectionControllerProvider).models)
      if (model.isDownloaded) model,
  ];
});

/// Installed models an agent run can actually use.
List<LlmModel> agentRunnableModels(List<LlmModel> installed) => [
  for (final model in installed)
    if (model.supportsToolCalling) model,
];

/// Installed models that cannot call tools, so the screen can say why they are
/// not on offer instead of leaving an unexplained gap.
List<LlmModel> agentNonToolModels(List<LlmModel> installed) => [
  for (final model in installed)
    if (!model.supportsToolCalling) model,
];

/// Where an agent run is.
enum AgentStage {
  /// No run yet.
  idle,

  /// The loop is working.
  running,

  /// The run ended (completed, stopped or hit one of its limits).
  finished,

  /// The run could not start or the loop failed.
  failed,
}

/// What the agent screen shows.
class AgentState {
  const AgentState({
    this.goal = '',
    this.modelId,
    this.maxIterations = AgentLoopService.defaultMaxIterations,
    this.stage = AgentStage.idle,
    this.steps = const <AgentStep>[],
    this.run,
    this.errorMessage,
  });

  /// Goal the run works towards.
  final String goal;

  /// Id of the model to run with; null means "the first installed one".
  final String? modelId;

  /// Iteration limit the next run will use.
  final int maxIterations;

  final AgentStage stage;

  /// Steps produced so far, so the log fills in while the loop works.
  final List<AgentStep> steps;

  /// The finished run, once there is one.
  final AgentRun? run;

  final String? errorMessage;

  bool get isRunning => stage == AgentStage.running;

  bool get hasLog => steps.isNotEmpty;

  /// True when the last run stopped before answering its goal.
  bool get runWasIncomplete => run?.status.isIncomplete ?? false;

  AgentState copyWith({
    String? goal,
    String? modelId,
    int? maxIterations,
    AgentStage? stage,
    List<AgentStep>? steps,
    AgentRun? run,
    bool clearRun = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return AgentState(
      goal: goal ?? this.goal,
      modelId: modelId ?? this.modelId,
      maxIterations: maxIterations ?? this.maxIterations,
      stage: stage ?? this.stage,
      steps: steps ?? this.steps,
      run: clearRun ? null : run ?? this.run,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

final agentControllerProvider =
    StateNotifierProvider<AgentController, AgentState>(AgentController.new);

/// Runs one goal through the local tools, on demand.
///
/// The agent is separate from chat on purpose: a conversation never starts a
/// loop, and a run never writes to a conversation. Everything the loop does is
/// in the log on screen, and every tool call still goes through the registry,
/// so a sensitive tool waits for the same approval prompt chat uses.
class AgentController extends StateNotifier<AgentState> {
  AgentController(this._ref) : super(const AgentState());

  final Ref _ref;

  void setGoal(String goal) {
    if (state.isRunning) return;
    state = state.copyWith(goal: goal, clearError: true);
  }

  void setModel(String modelId) {
    if (state.isRunning) return;
    state = state.copyWith(modelId: modelId);
  }

  void setMaxIterations(int value) {
    if (state.isRunning) return;
    state = state.copyWith(
      maxIterations: value.clamp(1, AgentLoopService.maximumIterations),
    );
  }

  /// Runs the current goal, streaming every step into the log.
  Future<void> run() async {
    if (state.isRunning) return;
    final models = agentRunnableModels(_ref.read(installedAgentModelsProvider));
    if (models.isEmpty) {
      final withoutTools = agentNonToolModels(
        _ref.read(installedAgentModelsProvider),
      );
      final installedNames = withoutTools.map((model) => model.name).join(', ');
      state = state.copyWith(
        stage: AgentStage.failed,
        errorMessage: withoutTools.isEmpty
            ? 'No local model is installed. Download or import a GGUF model '
                  'first.'
            : 'None of your installed models can call tools, so an agent run '
                  'has nothing to work with. Install a model whose chat '
                  'template supports tool calling — $installedNames cannot — '
                  'or ask for the same thing in a normal chat.',
      );
      return;
    }
    if (state.goal.trim().isEmpty) {
      state = state.copyWith(
        stage: AgentStage.failed,
        errorMessage: 'Describe the goal the agent should work on.',
      );
      return;
    }

    final model = _modelFor(models) ?? models.first;
    state = state.copyWith(
      modelId: model.id,
      stage: AgentStage.running,
      steps: const [],
      clearRun: true,
      clearError: true,
    );

    try {
      final run = await _ref
          .read(agentLoopServiceProvider)
          .run(
            model: model,
            goal: state.goal,
            registry: _ref.read(toolRegistryProvider),
            maxIterations: state.maxIterations,
            onStep: (step) {
              if (!mounted) return;
              state = state.copyWith(steps: [...state.steps, step]);
            },
          );
      if (!mounted) return;
      state = state.copyWith(
        stage: run.status == AgentRunStatus.failed
            ? AgentStage.failed
            : AgentStage.finished,
        run: run,
        steps: run.steps,
        errorMessage: run.errorMessage,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        stage: AgentStage.failed,
        errorMessage: _messageOf(error),
      );
    }
  }

  /// Stops the turn that is generating; what it produced stays in the log.
  void cancel() {
    if (!state.isRunning) return;
    _ref.read(agentLoopServiceProvider).cancel();
  }

  /// Clears the log and the finished run, keeping the goal and the settings.
  void clear() {
    if (state.isRunning) return;
    state = AgentState(
      goal: state.goal,
      modelId: state.modelId,
      maxIterations: state.maxIterations,
    );
  }

  /// Copies the finished run's log as versioned JSON.
  Future<bool> copyRunAsJson() {
    final run = state.run;
    if (run == null) return Future.value(false);
    return _copy(const JsonEncoder.withIndent('  ').convert(run.toJson()));
  }

  /// Copies the finished run's log as a readable report.
  Future<bool> copyRunAsMarkdown() {
    final run = state.run;
    if (run == null) return Future.value(false);
    return _copy(encodeAgentRunMarkdown(run));
  }

  Future<bool> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  }

  LlmModel? _modelFor(List<LlmModel> models) {
    final id = state.modelId;
    if (id == null) return null;
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// `Exception: something` reads badly in the UI, so the prefix is dropped.
  static String _messageOf(Object error) {
    const prefix = 'Exception: ';
    final text = error.toString();
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }
}
