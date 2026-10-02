import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';
import 'package:pocket_llm/features/benchmark/data/comparison_set_store.dart';
import 'package:pocket_llm/features/benchmark/domain/comparison_set.dart';
import 'package:pocket_llm/features/benchmark/domain/local_benchmark_result.dart';
import 'package:pocket_llm/features/benchmark/domain/model_comparison_export.dart';
import 'package:pocket_llm/features/benchmark/domain/prompt_suite.dart';
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

/// Saved comparison sets file, opened once per session.
final comparisonSetStoreProvider = FutureProvider<ComparisonSetStore>(
  (ref) => ComparisonSetStore.open(),
);

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
    this.suitePrompts = const <String>[],
    this.suiteRuns = const <PromptSuiteRun>[],
    this.suiteRunningPrompt,
    this.savedSets = const <ComparisonSet>[],
    this.savedSetsReady = false,
    this.savedSetsReadOnly = false,
    this.notice,
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

  /// Extra prompts of the suite, after the prompt in the box. Empty for a
  /// plain single-prompt comparison.
  final List<String> suitePrompts;

  /// Answers of the last suite run, one entry per prompt.
  final List<PromptSuiteRun> suiteRuns;

  /// Prompt currently being sent by the running suite, for the progress line.
  final String? suiteRunningPrompt;

  /// Saved comparison sets, oldest first.
  final List<ComparisonSet> savedSets;

  /// False until the stored sets have been read, so the UI can stay quiet
  /// instead of showing "no saved sets" before the file was opened.
  final bool savedSetsReady;

  /// True when the set file belongs to a newer build and is left untouched.
  final bool savedSetsReadOnly;

  /// Non-error message about a set action (saved, loaded), or null.
  final String? notice;

  final String? errorMessage;

  bool get isBusy => stage == ComparisonStage.running;

  bool get hasResults => results.isNotEmpty;

  /// True when at least two answers were produced, which is when judging them
  /// makes sense.
  bool get canChoosePreferred => results.length >= 2;

  /// Whether a result's model name is hidden right now.
  bool isBlindFor(String modelId) =>
      blind && !revealedModelIds.contains(modelId);

  /// Position of a result in the last single run, which is also its blind
  /// letter.
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

  /// `Answer A`, `Answer B`… inside one run's answers.
  ///
  /// A suite repeats the same models for every prompt, so a label belongs to
  /// the position within that prompt's answers rather than to the model.
  String blindLabelIn(List<LocalBenchmarkResult> results, String modelId) {
    for (var index = 0; index < results.length; index++) {
      if (results[index].model.id == modelId) {
        return 'Answer ${String.fromCharCode(65 + index)}';
      }
    }
    return 'Answer';
  }

  /// Every prompt a suite would send, in order: the prompt in the box first,
  /// then the extra prompts.
  List<String> get activePrompts => [
    if (prompt.trim().isNotEmpty) prompt.trim(),
    for (final extra in suitePrompts)
      if (extra.trim().isNotEmpty) extra.trim(),
  ];

  /// True once a suite has produced any answer.
  bool get hasSuiteResults => suiteRuns.isNotEmpty;

  /// True when a suite can run: at least two models and two prompts.
  bool get canRunSuite =>
      !isBusy &&
      selectedModelIds.length >= ModelComparisonService.minimumModels &&
      activePrompts.length >= 2;

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
    List<String>? suitePrompts,
    List<PromptSuiteRun>? suiteRuns,
    String? suiteRunningPrompt,
    bool clearSuiteRunningPrompt = false,
    List<ComparisonSet>? savedSets,
    bool? savedSetsReady,
    bool? savedSetsReadOnly,
    String? notice,
    bool clearNotice = false,
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
      suitePrompts: suitePrompts ?? this.suitePrompts,
      suiteRuns: suiteRuns ?? this.suiteRuns,
      suiteRunningPrompt: clearSuiteRunningPrompt
          ? null
          : suiteRunningPrompt ?? this.suiteRunningPrompt,
      savedSets: savedSets ?? this.savedSets,
      savedSetsReady: savedSetsReady ?? this.savedSetsReady,
      savedSetsReadOnly: savedSetsReadOnly ?? this.savedSetsReadOnly,
      notice: clearNotice ? null : notice ?? this.notice,
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
  ModelComparisonController(this._ref) : super(const ModelComparisonState()) {
    unawaited(_loadSets());
  }

  final Ref _ref;
  bool _stopped = false;

  /// Reads the stored sets once per session.
  ///
  /// A file that cannot be opened leaves the list empty and says so instead of
  /// silently looking like "no saved sets": comparing and exporting still work
  /// without storage, and nothing is written over the file.
  Future<void> _loadSets() async {
    try {
      final store = await _ref.read(comparisonSetStoreProvider.future);
      if (!mounted) return;
      state = state.copyWith(
        savedSets: store.load(),
        savedSetsReadOnly: store.isReadOnly,
        savedSetsReady: true,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        savedSetsReady: true,
        errorMessage:
            'Saved comparison sets could not be read on this device. '
            'Comparing models still works.',
      );
    }
  }

  ComparisonSet? _setById(String id) {
    for (final set in state.savedSets) {
      if (set.id == id) return set;
    }
    return null;
  }

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

  /// Adds an extra prompt to the suite, up to [ComparisonSet.maximumPrompts].
  void addSuitePrompt(String prompt) {
    if (state.isBusy) return;
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;
    if (state.suitePrompts.length + 1 >= ComparisonSet.maximumPrompts) {
      state = state.copyWith(
        errorMessage:
            'A suite keeps at most ${ComparisonSet.maximumPrompts} prompts, '
            'including the one in the box.',
      );
      return;
    }
    state = state.copyWith(
      suitePrompts: [...state.suitePrompts, trimmed],
      clearError: true,
    );
  }

  /// Replaces one extra prompt; an emptied box removes it.
  void updateSuitePrompt(int index, String prompt) {
    if (state.isBusy) return;
    if (index < 0 || index >= state.suitePrompts.length) return;

    final trimmed = prompt.trim();
    final prompts = [...state.suitePrompts];
    if (trimmed.isEmpty) {
      prompts.removeAt(index);
    } else {
      prompts[index] = trimmed;
    }
    state = state.copyWith(suitePrompts: prompts);
  }

  void removeSuitePrompt(int index) {
    if (state.isBusy) return;
    if (index < 0 || index >= state.suitePrompts.length) return;
    final prompts = [...state.suitePrompts]..removeAt(index);
    state = state.copyWith(suitePrompts: prompts);
  }

  /// Clears the suite's answers and keeps its prompts, so the same suite can
  /// be run again. A prompt is removed from its own chip.
  void clearSuite() {
    if (state.isBusy) return;
    if (state.suiteRuns.isEmpty) return;
    state = state.copyWith(
      suiteRuns: const [],
      clearSuiteRunningPrompt: true,
      clearError: true,
    );
  }

  /// The selected models that are actually installed, in selection order.
  List<LlmModel> _selectedInstalledModels() {
    final installedById = {
      for (final model in _ref.read(installedComparisonModelsProvider))
        model.id: model,
    };
    return [
      for (final id in state.selectedModelIds)
        if (installedById[id] != null) installedById[id]!,
    ];
  }

  /// Runs every prompt of the suite through the selected models.
  ///
  /// Prompts run in order and models within a prompt run sequentially, so the
  /// suite never keeps two models resident. Answers are recorded per prompt as
  /// they arrive, which is what lets the screen show progress instead of a
  /// spinner: a stopped suite keeps the answers it already has and marks the
  /// prompts it never sent.
  Future<void> runSuite() async {
    if (state.isBusy) return;

    final models = _selectedInstalledModels();
    if (models.length < ModelComparisonService.minimumModels) {
      state = state.copyWith(
        errorMessage:
            'Choose at least ${ModelComparisonService.minimumModels} installed '
            'models to compare.',
      );
      return;
    }
    final prompts = state.activePrompts;
    if (prompts.length < 2) {
      state = state.copyWith(
        errorMessage:
            'Add at least one more prompt: a suite compares several prompts '
            'across the same models.',
      );
      return;
    }

    final service = _ref.read(modelComparisonServiceProvider);
    _stopped = false;
    state = state.copyWith(
      stage: ComparisonStage.running,
      results: const [],
      suiteRuns: const [],
      suiteRunningPrompt: prompts.first,
      queuedModelCount: models.length,
      runningModelName: models.first.name,
      wasStopped: false,
      revealedModelIds: const <String>{},
      clearPreferredModelId: true,
      clearError: true,
    );

    final completed = <PromptSuiteRun>[];
    try {
      for (var index = 0; index < prompts.length; index++) {
        final prompt = prompts[index];
        final results = <LocalBenchmarkResult>[];
        state = state.copyWith(
          suiteRunningPrompt: prompt,
          runningModelName: models.first.name,
        );

        await for (final result in service.compare(
          models: models,
          prompt: prompt,
        )) {
          results.add(result);
          state = state.copyWith(
            suiteRuns: [
              ...completed,
              PromptSuiteRun(prompt: prompt, results: [...results]),
            ],
            runningModelName: results.length < models.length
                ? models[results.length].name
                : null,
            clearRunningModelName: results.length >= models.length,
          );
        }

        completed.add(
          PromptSuiteRun(
            prompt: prompt,
            results: results,
            wasStopped: _stopped,
          ),
        );

        if (_stopped) {
          final skipped = [
            for (var rest = index + 1; rest < prompts.length; rest++)
              PromptSuiteRun(
                prompt: prompts[rest],
                results: const [],
                wasSkipped: true,
              ),
          ];
          state = state.copyWith(
            suiteRuns: [...completed, ...skipped],
            stage: ComparisonStage.finished,
            clearSuiteRunningPrompt: true,
            clearRunningModelName: true,
            wasStopped: true,
          );
          return;
        }
      }

      state = state.copyWith(
        suiteRuns: completed,
        stage: ComparisonStage.finished,
        clearSuiteRunningPrompt: true,
        clearRunningModelName: true,
        wasStopped: false,
      );
    } catch (error) {
      state = state.copyWith(
        suiteRuns: completed,
        stage: ComparisonStage.failed,
        clearSuiteRunningPrompt: true,
        clearRunningModelName: true,
        wasStopped: _stopped,
        errorMessage: _messageOf(error),
      );
    }
  }

  /// Runs the selected models sequentially, one answer at a time.
  Future<void> run() async {
    if (state.isBusy) return;

    final models = _selectedInstalledModels();
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
      suiteRuns: const [],
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

  /// Clears results and errors, keeping the chosen models, the prompt, the
  /// blind switch and the saved sets.
  ///
  /// Saved sets are stored setups rather than run state, so clearing a run
  /// never drops them.
  void clear() {
    if (state.isBusy) return;
    state = ModelComparisonState(
      prompt: state.prompt,
      selectedModelIds: state.selectedModelIds,
      blind: state.blind,
      suitePrompts: state.suitePrompts,
      savedSets: state.savedSets,
      savedSetsReady: state.savedSetsReady,
      savedSetsReadOnly: state.savedSetsReadOnly,
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
      revealedModelIds: {
        for (final result in state.results) result.model.id,
        for (final run in state.suiteRuns)
          for (final result in run.results) result.model.id,
      },
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

  /// Saves the current models, prompt and blind switch as a named set.
  ///
  /// Saving under a name that already exists replaces that set's contents
  /// instead of adding a duplicate, so the list stays a list of setups rather
  /// than of attempts. Returns true when the set was stored.
  Future<bool> saveCurrentAsSet(String name) async {
    if (state.isBusy) return false;

    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(errorMessage: 'Give the saved set a name.');
      return false;
    }
    if (state.selectedModelIds.length < ModelComparisonService.minimumModels) {
      state = state.copyWith(
        errorMessage:
            'Choose at least ${ModelComparisonService.minimumModels} models '
            'before saving a set.',
      );
      return false;
    }
    if (state.prompt.trim().isEmpty) {
      state = state.copyWith(
        errorMessage: 'Enter a prompt before saving a set.',
      );
      return false;
    }

    final existingIndex = state.savedSets.indexWhere(
      (set) => set.name.toLowerCase() == trimmed.toLowerCase(),
    );
    final existing = existingIndex >= 0 ? state.savedSets[existingIndex] : null;
    if (existing == null &&
        state.savedSets.length >= ComparisonSetStore.maximumSets) {
      state = state.copyWith(
        errorMessage:
            'Keep at most ${ComparisonSetStore.maximumSets} saved sets. '
            'Delete one first.',
      );
      return false;
    }
    final saved = ComparisonSet(
      id: existing?.id ?? 'set-${DateTime.now().millisecondsSinceEpoch}',
      name: trimmed,
      modelIds: state.selectedModelIds,
      // The suite is part of the setup: a saved set restores the extra prompts
      // as well, so a prompt suite can be re-run in one tap.
      prompts: state.activePrompts,
      blind: state.blind,
      createdAt: existing?.createdAt ?? DateTime.now(),
    ).normalized();

    final sets = [...state.savedSets];
    if (existingIndex >= 0) {
      sets[existingIndex] = saved;
    } else {
      sets.add(saved);
    }

    if (!await _persistSets(sets)) return false;
    state = state.copyWith(
      savedSets: sets,
      notice: existing == null
          ? 'Saved “${saved.name}”.'
          : 'Updated “${saved.name}”.',
      clearError: true,
    );
    return true;
  }

  /// Loads a saved set into the Compare tab.
  ///
  /// Models in the set that are no longer installed are dropped and counted in
  /// the notice, so loading never selects a model the device cannot run.
  void applySet(String id) {
    if (state.isBusy) return;
    final set = _setById(id);
    if (set == null) return;

    final installed = {
      for (final model in _ref.read(installedComparisonModelsProvider))
        model.id,
    };
    final available = [
      for (final modelId in set.modelIds)
        if (installed.contains(modelId)) modelId,
    ];
    final missing = set.modelIds.length - available.length;

    state = state.copyWith(
      stage: ComparisonStage.idle,
      prompt: set.firstPrompt,
      suitePrompts: set.prompts.skip(1).toList(growable: false),
      suiteRuns: const [],
      clearSuiteRunningPrompt: true,
      selectedModelIds: available,
      results: const [],
      queuedModelCount: 0,
      wasStopped: false,
      blind: set.blind,
      revealedModelIds: const <String>{},
      clearPreferredModelId: true,
      clearRunningModelName: true,
      notice: missing == 0
          ? 'Loaded “${set.name}”.'
          : 'Loaded “${set.name}”. $missing of ${set.modelIds.length} '
                'models in it are no longer installed.',
      clearError: true,
    );
  }

  /// Removes a saved set. The comparison itself is untouched.
  Future<bool> deleteSet(String id) async {
    if (state.isBusy) return false;
    final set = _setById(id);
    if (set == null) return false;

    final sets = [
      for (final existing in state.savedSets)
        if (existing.id != id) existing,
    ];
    if (!await _persistSets(sets)) return false;
    state = state.copyWith(
      savedSets: sets,
      notice: 'Deleted “${set.name}”.',
      clearError: true,
    );
    return true;
  }

  /// Dismisses the last set notice.
  void dismissNotice() {
    if (state.notice == null) return;
    state = state.copyWith(clearNotice: true);
  }

  /// Writes the full set list, reporting why it could not be stored.
  Future<bool> _persistSets(List<ComparisonSet> sets) async {
    try {
      final store = await _ref.read(comparisonSetStoreProvider.future);
      if (store.isReadOnly) {
        state = state.copyWith(
          errorMessage:
              'Saved sets were written by a newer version of Pocket LLM, so '
              'this build will not change them.',
        );
        return false;
      }
      if (!store.save(sets)) {
        state = state.copyWith(
          errorMessage: 'Saved sets could not be written on this device.',
        );
        return false;
      }
      return true;
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Saved sets could not be written: ${_messageOf(error)}',
      );
      return false;
    }
  }

  /// The last suite run as a portable record, or null when there is nothing to
  /// export.
  ///
  /// A suite is exported as one payload with a run per prompt, because the
  /// prompts only mean something together: the same models answered all of
  /// them under the same settings.
  PromptSuiteExport? buildSuiteExport() {
    if (!state.hasSuiteResults) return null;

    return PromptSuiteExport(
      runs: state.suiteRuns,
      blind: state.blind,
      configuration: _exportConfiguration(),
    );
  }

  /// Copies the last suite run to the clipboard in [format].
  Future<bool> copySuiteExportToClipboard(ComparisonExportFormat format) async {
    final export = buildSuiteExport();
    if (export == null) return false;

    await Clipboard.setData(
      ClipboardData(text: encodePromptSuiteExport(export, format)),
    );
    return true;
  }

  /// Settings every run of this session uses, as recorded in an export.
  ComparisonExportConfiguration _exportConfiguration() {
    return ComparisonExportConfiguration(
      systemPrompt: ModelComparisonService.systemPrompt,
      contextTokens: ModelCompatibilityService.defaultContextTokens,
      maxTokens: ModelComparisonService.outputTokensFor(
        requested: ModelComparisonService.defaultMaxTokens,
        contextTokens: ModelCompatibilityService.defaultContextTokens,
      ),
      temperature: ModelComparisonService.temperature,
      topP: ModelComparisonService.topP,
      topK: ModelComparisonService.topK,
    );
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
      configuration: _exportConfiguration(),
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
