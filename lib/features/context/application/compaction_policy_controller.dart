import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/context/data/compaction_policy_store.dart';
import 'package:pocket_llm/features/context/domain/compaction_policy.dart';

/// Compaction policy file, opened once per session.
final compactionPolicyStoreProvider = FutureProvider<CompactionPolicyStore>(
  (ref) => CompactionPolicyStore.open(),
);

class CompactionPolicyState {
  const CompactionPolicyState({
    this.policy = const CompactionPolicy(),
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
  });

  final CompactionPolicy policy;
  final bool isReady;
  final String? errorMessage;
  final bool isReadOnly;

  CompactionPolicyState copyWith({
    CompactionPolicy? policy,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
  }) {
    return CompactionPolicyState(
      policy: policy ?? this.policy,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

final compactionPolicyProvider =
    StateNotifierProvider<CompactionPolicyNotifier, CompactionPolicyState>(
      (ref) => CompactionPolicyNotifier(ref),
    );

/// Owns the stored compaction policy.
class CompactionPolicyNotifier extends StateNotifier<CompactionPolicyState> {
  CompactionPolicyNotifier(this._ref) : super(const CompactionPolicyState()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final store = await _ref.read(compactionPolicyStoreProvider.future);
      state = CompactionPolicyState(
        policy: store.load(),
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'Compaction settings were written by a newer version of '
                  'Pocket LLM and are read-only in this build.'
            : null,
      );
    } catch (error) {
      state = CompactionPolicyState(
        isReady: true,
        errorMessage: 'Could not load compaction settings: $error',
      );
    }
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(compactionPolicyStoreProvider.future);
      if (store.isReadOnly) {
        state = state.copyWith(
          errorMessage:
              'Compaction settings were written by a newer version '
              'and are read-only in this build.',
        );
        return false;
      }
      return store.save(state.policy);
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Could not save compaction settings: $error',
      );
      return false;
    }
  }

  Future<void> update(CompactionPolicy policy) async {
    state = state.copyWith(policy: policy.normalized(), clearError: true);
    await _persist();
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}
