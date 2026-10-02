import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';
import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/benchmark/domain/model_comparison_export.dart';
import 'package:pocket_llm/features/model_selection/data/model_compatibility_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';

/// Prompt a new comparison starts with.
///
/// Short and factual, so answers fit the shared output budget and differences
/// between models come from the models rather than from a long instruction.
const String defaultComparisonPrompt =
    'Explain the difference between a process and a thread in two sentences.';

/// Models installed on this device — the only ones a comparison can run.
final installedComparisonModelsProvider = Provider<List<LlmModel>>((ref) {
  return [
    for (final model in ref.watch(modelSelectionControllerProvider).models)
      if (model.isDownloaded) model,
  ];
});

/// Where one comparison run is.
enum ComparisonStage {
  /// Nothing has been compared yet.
  idle,

  /// Models are answering, one after another.
  running,

  /// Every chosen model finished (or the run was stopped).
  finished,

  /// The run could not start or the service failed.
  failed,
}

/// What the comparison section shows.
class ModelComparisonState {
  const ModelComparisonState({
    this.stage = ComparisonStage.idle,
    this.prompt = defaultComparisonPrompt,
    this.selectedModelIds = const <String>[],
    this.results = const <LocalBenchmarkResult>[],
    this.runningModelName,
    this.queuedModelCount = 0,
    this.wasStopped = false,
    this.blind = false,
    this.revealedModelIds = const <String>{},
    this.preferredModelId,
    this.errorMessage,
  });

  final ComparisonStage stage;

  /// Prompt that will be sent verbatim to every model.
  final String prompt;

  /// Chosen model ids, in the order the user picked them. Runs follow this
  /// order, so the sequence is visible and predictable.
  final List<String> selectedModelIds;

  /// Answers completed so far, each with its own metrics.
  final List<LocalBenchmarkResult> results;

  /// Model currently generating, for the progress line.
  final String? runningModelName;

  /// How many models this run queued, for the progress line.
  final int queuedModelCount;

  /// True when the user stopped the run; finished answers may be partial.
  final bool wasStopped;

  /// True when the run is judged without model names: cards are labelled
  /// `Answer A`, `Answer B`… and a model is only named when the user reveals
  /// it or picks its answer.
  final bool blind;

  /// Models whose names the user revealed in a blind run.
  final Set<String> revealedModelIds;

  /// Model whose answer the user preferred; null until one is chosen.
  final String? preferredModelId;

  final String? errorMessage;

  bool get isBusy => stage == ComparisonStage.running;

  bool get hasResults => results.isNotEmpty;

  /// True when at least two answers were produced, which is when judging them
  /// makes sense.
  bool get canChoosePreferred => results.length >= 2;

  /// Whether a result's model name is hidden right now.
  bool isBlindFor(String modelId) =>
      blind && !revealedModelIds.contains(modelId);

  /// Position of a result in the run, which is also its blind letter.
  int indexOfModel(String modelId) {
    for (var index = 0; index < results.length; index++) {
      if (results[index].model.id == modelId) return index;
    }
    return -1;
  }

  /// `Answer A`, `Answer B`… for a result, by its position in the run.
  String blindLabelFor(String modelId) {
    final index = indexOfModel(modelId);
    if (index < 0) return 'Answer';
    return 'Answer ${String.fromCharCode(65 + index)}';
  }

  int get selectedCount => selectedModelIds.length;

  bool get isSelectionFull =>
      selectedModelIds.length >= ModelComparisonService.maximumModels;

  bool get canRun =>
      !isBusy &&
      selectedModelIds.length >= ModelComparisonService.minimumModels &&
      prompt.trim().isNotEmpty;

  ModelComparisonState copyWith({
    ComparisonStage? stage,
    String? prompt,
    List<String>? selectedModelIds,
    List<LocalBenchmarkResult>? results,
    String? runningModelName,
    int? queuedModelCount,
    bool? wasStopped,
    bool? blind,
    Set<String>? revealedModelIds,
    String? preferredModelId,
    bool clearPreferredModelId = false,
    String? errorMessage,
    bool clearError = false,
    bool clearRunningModelName = false,
  }) {
    return ModelComparisonState(
      stage: stage ?? this.stage,
      prompt: prompt ?? this.prompt,
      selectedModelIds: selectedModelIds ?? this.selectedModelIds,
      results: results ?? this.results,
      runningModelName: clearRunningModelName
          ? null
          : runningModelName ?? this.runningModelName,
      queuedModelCount: queuedModelCount ?? this.queuedModelCount,
      wasStopped: wasStopped ?? this.wasStopped,
      blind: blind ?? this.blind,
      revealedModelIds: revealedModelIds ?? this.revealedModelIds,
      preferredModelId: clearPreferredModelId
          ? null
          : preferredModelId ?? this.preferredModelId,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

final modelComparisonControllerProvider =
    StateNotifierProvider<ModelComparisonController, ModelComparisonState>(
      (ref) => ModelComparisonController(ref),
    );

/// Runs one prompt across the chosen installed models.
///
/// The controller owns the selection and the prompt, so the screen only draws
/// them; nothing here writes to a conversation. Answers stay in this section
/// until the user copies them or exports a run.
class ModelComparisonController extends StateNotifier<ModelComparisonState> {
  ModelComparisonController(this._ref) : super(const ModelComparisonState());

  final Ref _ref;
  bool _stopped = false;

  void setPrompt(String prompt) {
    if (state.prompt == prompt) return;
    state = state.copyWith(prompt: prompt);
  }

  /// Adds or removes a model from the run; the fifth selection is ignored.
  void toggleModel(String modelId) {
    if (state.isBusy) return;

    final selected = [...state.selectedModelIds];
    if (selected.remove(modelId)) {
      state = state.copyWith(selectedModelIds: selected, clearError: true);
      return;
    }

    if (state.isSelectionFull) return;
    state = state.copyWith(
      selectedModelIds: [...selected, modelId],
      clearError: true,
    );
  }

  /// Runs the selected models sequentially, one answer at a time.
  Future<void> run() async {
    if (state.isBusy) return;

    final installedById = {
      for (final model in _ref.read(installedComparisonModelsProvider))
        model.id: model,
    };
    final models = [
      for (final id in state.selectedModelIds)
        if (installedById[id] != null) installedById[id]!,
    ];
    if (models.length < ModelComparisonService.minimumModels) {
      state = state.copyWith(
        errorMessage:
            'Choose at least ${ModelComparisonService.minimumModels} installed '
            'models to compare.',
      );
      return;
    }
    if (state.prompt.trim().isEmpty) {
      state = state.copyWith(
        errorMessage: 'Enter a prompt to send to every model.',
      );
      return;
    }

    final service = _ref.read(modelComparisonServiceProvider);
    _stopped = false;
    state = state.copyWith(
      stage: ComparisonStage.running,
      results: const [],
      queuedModelCount: models.length,
      runningModelName: models.first.name,
      wasStopped: false,
      revealedModelIds: const <String>{},
      clearPreferredModelId: true,
      clearError: true,
    );

    try {
      await for (final result in service.compare(
        models: models,
        prompt: state.prompt,
      )) {
        final results = [...state.results, result];
        state = state.copyWith(
          results: results,
          runningModelName: results.length < models.length
              ? models[results.length].name
              : null,
          clearRunningModelName: results.length >= models.length,
        );
      }
      state = state.copyWith(
        stage: ComparisonStage.finished,
        clearRunningModelName: true,
        wasStopped: _stopped,
      );
    } catch (error) {
      state = state.copyWith(
        stage: ComparisonStage.failed,
        clearRunningModelName: true,
        wasStopped: _stopped,
        errorMessage: _messageOf(error),
      );
    }
  }

  /// Stops the model that is generating; the run ends after its partial
  /// answer and the remaining models are never loaded.
  void cancel() {
    if (!state.isBusy) return;
    _stopped = true;
    _ref.read(modelComparisonServiceProvider).cancel();
  }

  /// Clears results and errors, keeping the chosen models, the prompt and the
  /// blind switch.
  void clear() {
    if (state.isBusy) return;
    state = ModelComparisonState(
      prompt: state.prompt,
      selectedModelIds: state.selectedModelIds,
      blind: state.blind,
    );
  }

  /// Turns blind judging on or off.
  ///
  /// Turning it on hides every name again until the user reveals or picks one;
  /// turning it off reveals them, because the answers are already on screen.
  /// An existing preference is kept either way — the user can clear it.
  void setBlind(bool blind) {
    if (state.isBusy || state.blind == blind) return;
    state = state.copyWith(blind: blind, revealedModelIds: const <String>{});
  }

  /// Reveals one model in a blind run, or every one of them.
  void revealModel(String modelId) {
    if (state.isBusy || state.revealedModelIds.contains(modelId)) return;
    state = state.copyWith(
      revealedModelIds: {...state.revealedModelIds, modelId},
    );
  }

  void revealAll() {
    if (state.isBusy) return;
    state = state.copyWith(
      revealedModelIds: {for (final result in state.results) result.model.id},
    );
  }

  /// Records which answer the user preferred.
  ///
  /// Choosing in a blind run also reveals that model, because the preference
  /// names it; the other answers stay blind, so a second pick stays honest.
  void choosePreferred(String modelId) {
    if (state.isBusy || !state.canChoosePreferred) return;
    state = state.copyWith(
      preferredModelId: modelId,
      revealedModelIds: {...state.revealedModelIds, modelId},
      clearError: true,
    );
  }

  void clearPreferred() {
    if (state.isBusy || state.preferredModelId == null) return;
    state = state.copyWith(clearPreferredModelId: true);
  }

  /// The current results as a portable run, or null when there is nothing to
  /// export.
  ///
  /// The settings recorded are the ones the run actually used, not whatever
  /// the controls say now: a comparison is only meaningful with its prompt,
  /// window, output budget and sampler attached.
  ModelComparisonExport? buildExport() {
    if (!state.hasResults) return null;

    return ModelComparisonExport(
      prompt: state.prompt.trim(),
      wasStopped: state.wasStopped,
      blind: state.blind,
      preferredModelId: state.preferredModelId,
      configuration: ComparisonExportConfiguration(
        systemPrompt: ModelComparisonService.systemPrompt,
        contextTokens: ModelCompatibilityService.defaultContextTokens,
        maxTokens: ModelComparisonService.outputTokensFor(
          requested: ModelComparisonService.defaultMaxTokens,
          contextTokens: ModelCompatibilityService.defaultContextTokens,
        ),
        temperature: ModelComparisonService.temperature,
        topP: ModelComparisonService.topP,
        topK: ModelComparisonService.topK,
      ),
      results: state.results,
    );
  }

  /// Copies the current results to the clipboard in [format].
  ///
  /// Nothing is written to a file and nothing leaves the device: the same
  /// clipboard flow the conversation and persona exports use. Returns false
  /// when there is nothing to export.
  Future<bool> copyExportToClipboard(ComparisonExportFormat format) async {
    final export = buildExport();
    if (export == null) return false;

    await Clipboard.setData(
      ClipboardData(text: encodeComparisonExport(export, format)),
    );
    return true;
  }

  /// `Exception: something` reads badly in the UI, so the prefix is dropped.
  static String _messageOf(Object error) {
    const prefix = 'Exception: ';
    final text = error.toString();
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }
}
