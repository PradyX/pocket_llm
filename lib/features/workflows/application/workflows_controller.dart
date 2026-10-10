import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/activity/data/activity_store.dart';
import 'package:pocket_llm/features/activity/domain/activity_event.dart';
import 'package:pocket_llm/features/kanban/application/kanban_controller.dart';
import 'package:pocket_llm/features/kanban/domain/task.dart';
import 'package:pocket_llm/features/obsidian/application/vault_notes_service.dart';
import 'package:pocket_llm/features/obsidian/application/vaults_controller.dart';
import 'package:pocket_llm/features/workflows/data/workflow_store.dart';
import 'package:pocket_llm/features/workflows/domain/workflow.dart';
import 'package:pocket_llm/features/workflows/domain/workflow_engine.dart';

/// Workflow file, opened once per session.
final workflowStoreProvider = FutureProvider<WorkflowStore>(
  (ref) => WorkflowStore.open(),
);

class WorkflowsState {
  const WorkflowsState({
    this.snapshot = WorkflowsSnapshot.empty,
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
  });

  final WorkflowsSnapshot snapshot;
  final bool isReady;
  final String? errorMessage;
  final bool isReadOnly;

  WorkflowsState copyWith({
    WorkflowsSnapshot? snapshot,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
  }) {
    return WorkflowsState(
      snapshot: snapshot ?? this.snapshot,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

final workflowsProvider =
    StateNotifierProvider<WorkflowsNotifier, WorkflowsState>(
      (ref) => WorkflowsNotifier(ref),
    );

/// Owns workflow definitions and runs the engine's effects.
///
/// The engine decides, this executes: kanban moves, vault writes and
/// activity entries happen here, approvals and bot results resume the run.
/// Every effect failure fails visibly on the run instead of vanishing.
class WorkflowsNotifier extends StateNotifier<WorkflowsState> {
  WorkflowsNotifier(this._ref) : super(const WorkflowsState()) {
    _load();
    _ref.listen<String?>(
      activeWorkspaceIdProvider,
      (previous, next) => _load(),
    );
  }

  final Ref _ref;
  static const VaultNotesService _notes = VaultNotesService();

  Future<void> _load() async {
    try {
      final store = await _ref.read(workflowStoreProvider.future);
      state = WorkflowsState(
        snapshot: store.load(),
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'Workflows were written by a newer version of Pocket LLM and '
                  'are read-only in this build.'
            : null,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load workflows: $error',
      );
    }
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(workflowStoreProvider.future);
      if (store.isReadOnly) {
        state = state.copyWith(
          errorMessage:
              'Workflows were written by a newer version and are '
              'read-only in this build.',
        );
        return false;
      }
      return store.save(state.snapshot);
    } catch (error) {
      state = state.copyWith(errorMessage: 'Could not save workflows: $error');
      return false;
    }
  }

  List<WorkflowDefinition> workflowsFor(String workspaceId) {
    return state.snapshot.workflowsFor(workspaceId);
  }

  List<WorkflowRun> runsFor(String workspaceId) {
    final runs = state.snapshot.runsFor(workspaceId);
    runs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return runs;
  }

  WorkflowDefinition? _definitionFor(WorkflowRun run, String workspaceId) {
    for (final workflow in workflowsFor(workspaceId)) {
      if (workflow.id == run.workflowId) return workflow;
    }
    return null;
  }

  Future<void> _storeRun(WorkflowRun run) async {
    state = state.copyWith(
      snapshot: state.snapshot.upsertRun(run),
      clearError: true,
    );
    await _persist();
  }

  Future<void> _log(String workspaceId, ActivityEvent event) async {
    try {
      final store = await ActivityStore.open(workspaceId);
      store.append(event);
    } catch (_) {}
  }

  /// Starts a run and advances it to its first pause or finish.
  Future<WorkflowRun?> startRun(WorkflowDefinition workflow) async {
    final run = WorkflowRun.start(workflow: workflow);
    await _storeRun(run);
    await _log(
      workflow.workspaceId,
      ActivityEvent.create(
        workspaceId: workflow.workspaceId,
        kind: ActivityEventKind.workflowStarted,
        summary: '${workflow.name} started',
        relatedWorkflowId: run.id,
      ),
    );
    await pump(run.id);
    return _findRun(run.id);
  }

  WorkflowRun? _findRun(String runId) {
    for (final run in state.snapshot.runs) {
      if (run.id == runId) return run;
    }
    return null;
  }

  /// Advances a run: executes effects until it pauses or finishes.
  Future<void> pump(String runId) async {
    final found = _findRun(runId);
    if (found == null || found.status.isFinished) return;
    WorkflowRun run = found;
    final definition = _definitionFor(run, run.workspaceId);
    if (definition == null) {
      await _storeRun(
        run.copyWith(
          status: RunStatus.failed,
          errors: [...run.errors, 'The workflow was deleted.'],
        ),
      );
      return;
    }
    var guard = 0;
    while (guard++ < 12) {
      final advance = WorkflowEngine.advance(definition, run);
      run = advance.run;
      await _storeRun(run);
      for (final effect in advance.effects) {
        await _execute(definition, run, effect);
        run = _findRun(runId) ?? run;
      }
      if (run.status != RunStatus.active) return;
      // Active with a current step means more deterministic work now.
      if (run.currentStepId == null) return;
    }
  }

  Future<void> _execute(
    WorkflowDefinition definition,
    WorkflowRun run,
    WorkflowEffect effect,
  ) async {
    switch (effect) {
      case PrepareBotTaskEffect():
        // The prompt is the handoff: group chat (or the user) runs it and
        // records the result with completeBotStep. The task keeps it visible.
        if (effect.taskTitle.isNotEmpty) {
          final kanban = _ref.read(kanbanProvider.notifier);
          final task = await kanban.createTask(
            title: effect.taskTitle,
            description: effect.prompt,
            createdBy: run.id,
          );
          if (task != null) {
            await _storeRun(run.copyWith(taskIds: [...run.taskIds, task.id]));
          }
        }
        await _storeRun(
          (_findRun(run.id) ?? run).copyWith(
            outputs: {
              ...(_findRun(run.id) ?? run).outputs,
              effect.stepId: effect.prompt,
            },
          ),
        );
      case MoveTaskEffect():
        await _ref
            .read(kanbanProvider.notifier)
            .moveTask(effect.taskId, TaskStatus.fromKey(effect.statusKey));
      case WriteNoteEffect():
        final paths = _ref
            .read(vaultsProvider.notifier)
            .pathsFor(run.workspaceId);
        final binding = _ref
            .read(vaultsProvider)
            .snapshot
            .bindingFor(run.workspaceId);
        if (paths == null || binding == null) {
          await _storeRun(
            (_findRun(run.id) ?? run).copyWith(
              status: RunStatus.failed,
              errors: [
                ...(_findRun(run.id) ?? run).errors,
                'No vault linked for ${effect.path}.',
              ],
            ),
          );
          return;
        }
        final error = await _notes.writeNote(
          paths: paths,
          permissions: binding.permissions,
          relativePath: effect.path,
          content: effect.content,
        );
        if (error != null) {
          await _storeRun(
            (_findRun(run.id) ?? run).copyWith(
              status: RunStatus.failed,
              errors: [
                ...(_findRun(run.id) ?? run).errors,
                'Could not write ${effect.path}: ${error.message}',
              ],
            ),
          );
        } else {
          await _log(
            run.workspaceId,
            ActivityEvent.create(
              workspaceId: run.workspaceId,
              kind: ActivityEventKind.botDocumentCreated,
              summary: effect.path,
              relatedDocument: effect.path,
              relatedWorkflowId: run.id,
            ),
          );
        }
      case RequestApprovalEffect():
        await _log(
          run.workspaceId,
          ActivityEvent.create(
            workspaceId: run.workspaceId,
            kind: ActivityEventKind.approvalRequested,
            summary: effect.label,
            relatedWorkflowId: run.id,
          ),
        );
      case LogActivityEffect():
        await _log(
          run.workspaceId,
          ActivityEvent.create(
            workspaceId: run.workspaceId,
            kind: ActivityEventKind.workflowStepCompleted,
            summary: effect.summary,
            relatedWorkflowId: run.id,
          ),
        );
    }
  }

  /// Records a bot's result for the waiting step, then keeps advancing.
  Future<void> completeBotStep(String runId, String output) async {
    final run = _findRun(runId);
    if (run == null) return;
    final definition = _definitionFor(run, run.workspaceId);
    if (definition == null) return;
    final advance = WorkflowEngine.completeBotStep(definition, run, output);
    await _storeRun(advance.run);
    await pump(runId);
  }

  /// Applies the user's approval decision, then keeps advancing.
  Future<void> decideApproval(
    String runId,
    ApprovalDecision decision,
    String note,
  ) async {
    final run = _findRun(runId);
    if (run == null) return;
    final definition = _definitionFor(run, run.workspaceId);
    if (definition == null) return;
    final advance = WorkflowEngine.decideApproval(
      definition,
      run,
      decision,
      note.trim(),
    );
    await _storeRun(advance.run);
    for (final effect in advance.effects) {
      await _execute(definition, advance.run, effect);
    }
    await _log(
      run.workspaceId,
      ActivityEvent.create(
        workspaceId: run.workspaceId,
        kind: decision == ApprovalDecision.approve
            ? ActivityEventKind.approvalGranted
            : ActivityEventKind.approvalRejected,
        summary:
            '${definition.name}: ${decision.name}'
            '${note.trim().isEmpty ? '' : ' — ${note.trim()}'}',
        relatedWorkflowId: run.id,
      ),
    );
    await pump(runId);
  }

  Future<void> cancelRun(String runId) async {
    final run = _findRun(runId);
    if (run == null || run.status.isFinished) return;
    await _storeRun(run.copyWith(status: RunStatus.cancelled));
  }
}
