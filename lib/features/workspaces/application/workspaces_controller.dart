import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/workspaces/data/workspace_store.dart';
import 'package:pocket_llm/features/workspaces/domain/workspace.dart';

/// Workspace file, opened once per session.
final workspaceStoreProvider = FutureProvider<WorkspaceStore>(
  (ref) => WorkspaceStore.open(),
);

/// All workspaces plus the active selection.
class WorkspacesState {
  const WorkspacesState({
    this.snapshot = WorkspacesSnapshot.empty,
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
  });

  final WorkspacesSnapshot snapshot;
  final bool isReady;
  final String? errorMessage;
  final bool isReadOnly;

  Workspace? get active => snapshot.active;
  List<Workspace> get workspaces => snapshot.workspaces;

  WorkspacesState copyWith({
    WorkspacesSnapshot? snapshot,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
  }) {
    return WorkspacesState(
      snapshot: snapshot ?? this.snapshot,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

final workspacesProvider =
    StateNotifierProvider<WorkspacesNotifier, WorkspacesState>(
      (ref) => WorkspacesNotifier(ref),
    );

/// Owns the workspace list and the active selection.
///
/// The first launch seeds one workspace so every workspace-scoped lookup has
/// a boundary to filter by from the start.
class WorkspacesNotifier extends StateNotifier<WorkspacesState> {
  WorkspacesNotifier(this._ref) : super(const WorkspacesState()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final store = await _ref.read(workspaceStoreProvider.future);
      final snapshot = store.load();
      final effective = snapshot.workspaces.isEmpty
          ? WorkspacesSnapshot(
              workspaces: [Workspace.create(name: 'My workspace')],
            )
          : snapshot;
      final withActive =
          effective.activeWorkspaceId == null && effective.workspaces.isNotEmpty
          ? effective.withActive(effective.workspaces.first.id)
          : effective;
      state = WorkspacesState(
        snapshot: withActive,
        isReady: true,
        isReadOnly: store.isReadOnly,
      );
      if (!store.isReadOnly && snapshot.workspaces.isEmpty) {
        store.save(withActive);
      }
    } catch (error) {
      final fallback = Workspace.create(name: 'My workspace');
      state = WorkspacesState(
        snapshot: WorkspacesSnapshot(
          workspaces: [fallback],
          activeWorkspaceId: fallback.id,
        ),
        isReady: true,
        errorMessage: 'Could not load workspaces: $error',
      );
    }
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(workspaceStoreProvider.future);
      if (store.isReadOnly) {
        state = state.copyWith(
          errorMessage:
              'Workspaces were written by a newer version and are '
              'read-only in this build.',
        );
        return false;
      }
      return store.save(state.snapshot);
    } catch (error) {
      state = state.copyWith(errorMessage: 'Could not save workspaces: $error');
      return false;
    }
  }

  Future<void> createWorkspace(String name) async {
    final workspace = Workspace.create(name: name);
    state = state.copyWith(
      snapshot: state.snapshot.upsert(workspace).withActive(workspace.id),
      clearError: true,
    );
    await _persist();
  }

  Future<void> renameWorkspace(String id, String name) async {
    final workspace = _byId(id);
    if (workspace == null) return;
    state = state.copyWith(
      snapshot: state.snapshot.upsert(
        workspace.copyWith(name: name, updatedAt: DateTime.now()),
      ),
      clearError: true,
    );
    await _persist();
  }

  Future<void> setActive(String? id) async {
    state = state.copyWith(
      snapshot: state.snapshot.withActive(id),
      clearError: true,
    );
    await _persist();
  }

  /// Removes a workspace. The last workspace cannot be removed: scoped
  /// lookups always need a boundary.
  Future<void> removeWorkspace(String id) async {
    if (state.snapshot.workspaces.length <= 1) return;
    state = state.copyWith(
      snapshot: state.snapshot.remove(id),
      clearError: true,
    );
    await _persist();
  }

  Future<void> updateWorkspace(Workspace workspace) async {
    state = state.copyWith(
      snapshot: state.snapshot.upsert(workspace),
      clearError: true,
    );
    await _persist();
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  Workspace? _byId(String id) {
    for (final workspace in state.snapshot.workspaces) {
      if (workspace.id == id) return workspace;
    }
    return null;
  }
}
