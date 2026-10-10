import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/context/data/context_budget_store.dart';
import 'package:pocket_llm/features/context/domain/context_budget.dart';

/// Budget file, opened once per session.
final contextBudgetStoreProvider = FutureProvider<ContextBudgetStore>(
  (ref) => ContextBudgetStore.open(),
);

/// The stored context budget plus its load state.
class ContextBudgetState {
  const ContextBudgetState({
    this.budget = ContextBudget.auto,
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
  });

  final ContextBudget budget;

  /// False until the stored budget has been read.
  final bool isReady;

  /// Last actionable error, or null.
  final String? errorMessage;

  /// True when the stored file belongs to a newer build, which makes the
  /// screen display-only.
  final bool isReadOnly;

  ContextBudgetState copyWith({
    ContextBudget? budget,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
  }) {
    return ContextBudgetState(
      budget: budget ?? this.budget,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

final contextBudgetProvider =
    StateNotifierProvider<ContextBudgetNotifier, ContextBudgetState>(
      (ref) => ContextBudgetNotifier(ref),
    );

/// Owns the context budget preference (Road Map 2 Phase 2.1).
///
/// Only the preference is stored; the numbers a request actually uses are
/// derived on every request from the model, the active profile and this budget,
/// so nothing here has to be kept in step with the runtime.
class ContextBudgetNotifier extends StateNotifier<ContextBudgetState> {
  ContextBudgetNotifier(this._ref) : super(const ContextBudgetState()) {
    _load();
  }

  /// Cap a manual budget starts from when the user has not picked one.
  ///
  /// Small enough for a phone-class device to honour and easy to raise; the
  /// screen states the number it is using, and the model's own limit still
  /// caps it if it is larger than the window on offer.
  static const int defaultManualContextTokens = 2048;

  final Ref _ref;

  Future<void> _load() async {
    try {
      final store = await _ref.read(contextBudgetStoreProvider.future);
      // The app can shut this provider down while the file is still opening,
      // and a disposed notifier must not be written to.
      if (!mounted) return;
      state = ContextBudgetState(
        budget: store.load(),
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'The context budget was written by a newer version of Pocket LLM '
                  'and is read-only in this build.'
            : null,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load the context budget: $error',
      );
    }
  }

  /// Switches between the automatic budget and a manual cap.
  Future<bool> setMode(ContextBudgetMode mode) async {
    if (mode == state.budget.mode) return true;
    final budget = mode == ContextBudgetMode.manual
        ? state.budget.copyWith(
            mode: mode,
            maxContextTokens:
                state.budget.maxContextTokens ?? defaultManualContextTokens,
          )
        : state.budget.copyWith(mode: mode, clearMaxContextTokens: true);
    return _apply(budget);
  }

  /// Sets the manual cap. Passing null clears it, which leaves a manual budget
  /// behaving exactly like the automatic one.
  Future<bool> setMaxContextTokens(int? tokens) async {
    final budget = tokens == null
        ? state.budget.copyWith(clearMaxContextTokens: true)
        : state.budget.copyWith(maxContextTokens: tokens);
    return _apply(budget);
  }

  /// Returns to the automatic budget and drops the stored cap.
  Future<bool> resetToAuto() async {
    if (state.budget.mode == ContextBudgetMode.auto &&
        state.budget.maxContextTokens == null) {
      return true;
    }
    return _apply(ContextBudget.auto);
  }

  /// Clears the last error once it has been shown.
  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  Future<bool> _apply(ContextBudget budget) async {
    if (state.isReadOnly) {
      state = state.copyWith(
        errorMessage:
            'The context budget was written by a newer version of Pocket LLM '
            'and is read-only in this build.',
      );
      return false;
    }

    final previous = state.budget;
    state = state.copyWith(budget: budget.normalized(), clearError: true);
    if (await _persist()) return true;
    if (!mounted) return false;
    // A failed write must not leave the screen describing a budget that was
    // never stored.
    state = state.copyWith(budget: previous);
    return false;
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(contextBudgetStoreProvider.future);
      if (store.save(state.budget)) return true;
      if (!mounted) return false;
      state = state.copyWith(
        errorMessage: store.isReadOnly
            ? 'The context budget was written by a newer version of Pocket LLM '
                  'and is read-only in this build.'
            : 'Could not save the context budget on this device.',
      );
      return false;
    } catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        errorMessage: 'Could not save the context budget: $error',
      );
      return false;
    }
  }
}
