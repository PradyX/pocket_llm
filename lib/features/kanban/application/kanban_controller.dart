import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/activity/data/activity_store.dart';
import 'package:pocket_llm/features/activity/domain/activity_event.dart';
import 'package:pocket_llm/features/kanban/data/task_repository.dart';
import 'package:pocket_llm/features/kanban/domain/task.dart';
import 'package:pocket_llm/features/obsidian/application/vaults_controller.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';

/// Active workspace id, shared by every workspace-scoped screen.
final activeWorkspaceIdProvider = Provider<String?>((ref) {
  return ref.watch(workspacesProvider).active?.id;
});

class KanbanState {
  const KanbanState({
    this.tasks = const [],
    this.isReady = false,
    this.errorMessage,
    this.usesVault = false,
  });

  final List<ProjectTask> tasks;
  final bool isReady;
  final String? errorMessage;
  final bool usesVault;

  Map<String, ProjectTask> get byId => {
    for (final task in tasks) task.id: task,
  };

  List<ProjectTask> inStatus(TaskStatus status) {
    return tasks.where((task) => task.status == status).toList();
  }

  KanbanState copyWith({
    List<ProjectTask>? tasks,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? usesVault,
  }) {
    return KanbanState(
      tasks: tasks ?? this.tasks,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      usesVault: usesVault ?? this.usesVault,
    );
  }
}

final kanbanProvider = StateNotifierProvider<KanbanNotifier, KanbanState>(
  (ref) => KanbanNotifier(ref),
);

/// Owns one workspace's board: tasks, moves, assignments and comments.
///
/// Bots use the same operations the UI does (§9.3): create, assign, move,
/// comment, link document, mark blocked, mark complete. Moves into Done and
/// assignments write an activity entry so the board's history outlives chat.
class KanbanNotifier extends StateNotifier<KanbanState> {
  KanbanNotifier(this._ref) : super(const KanbanState()) {
    _ref.listen<String?>(
      activeWorkspaceIdProvider,
      (previous, next) => reload(),
    );
    reload();
  }

  final Ref _ref;
  TaskRepository? _repository;
  String? _workspaceId;

  Future<TaskRepository> _resolveRepository(String workspaceId) async {
    final vaults = _ref.read(vaultsProvider);
    final binding = vaults.snapshot.bindingFor(workspaceId);
    if (binding != null) {
      final paths = _ref.read(vaultsProvider.notifier).pathsFor(workspaceId);
      if (paths != null) {
        return VaultTaskRepository(
          paths: paths,
          permissions: binding.permissions,
        );
      }
    }
    return LocalTaskRepository.open();
  }

  Future<void> reload() async {
    final workspaceId = _ref.read(activeWorkspaceIdProvider);
    _workspaceId = workspaceId;
    if (workspaceId == null) {
      state = state.copyWith(tasks: const [], isReady: true);
      return;
    }
    try {
      _repository = await _resolveRepository(workspaceId);
      final tasks = await _repository!.load(workspaceId);
      state = KanbanState(
        tasks: tasks,
        isReady: true,
        usesVault: _repository is VaultTaskRepository,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load tasks: $error',
      );
    }
  }

  Future<void> _persist() async {
    final workspaceId = _workspaceId;
    final repository = _repository;
    if (workspaceId == null || repository == null) return;
    try {
      await repository.save(workspaceId, state.tasks);
    } catch (error) {
      state = state.copyWith(errorMessage: 'Could not save tasks: $error');
    }
  }

  void _replace(ProjectTask task) {
    state = state.copyWith(
      tasks: [
        for (final candidate in state.tasks)
          if (candidate.id == task.id) task else candidate,
      ],
      clearError: true,
    );
  }

  Future<void> _log(ActivityEvent event) async {
    try {
      final store = await ActivityStore.open(event.workspaceId);
      store.append(event);
    } catch (_) {}
  }

  String _nextLocalId(String workspaceId, List<ProjectTask> tasks) {
    var max = 0;
    for (final task in tasks) {
      final match = RegExp(r'^PL-(\d+)$').firstMatch(task.id);
      if (match != null) {
        final number = int.tryParse(match.group(1)!) ?? 0;
        if (number > max) max = number;
      }
    }
    return 'PL-${(max + 1).toString().padLeft(3, '0')}';
  }

  /// Creates a task with the next `PL-<n>` id in this workspace.
  Future<ProjectTask?> createTask({
    required String title,
    String description = '',
    TaskPriority priority = TaskPriority.medium,
    String? createdBy,
  }) async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return null;
    var number = await _repository?.nextNumber(workspaceId);
    number ??= 0;
    var candidate = number <= 0
        ? _nextLocalId(workspaceId, state.tasks)
        : 'PL-${number.toString().padLeft(3, '0')}';
    while (state.byId.containsKey(candidate)) {
      final match = RegExp(r'^PL-(\d+)$').firstMatch(candidate);
      final next = (match == null ? 0 : int.parse(match.group(1)!)) + 1;
      candidate = 'PL-${next.toString().padLeft(3, '0')}';
    }
    final task = ProjectTask.create(
      id: candidate,
      workspaceId: workspaceId,
      title: title,
      description: description,
      priority: priority,
      createdBy: createdBy,
    );
    state = state.copyWith(tasks: [...state.tasks, task], clearError: true);
    await _persist();
    await _log(
      ActivityEvent.create(
        workspaceId: workspaceId,
        kind: ActivityEventKind.taskCreated,
        summary: '${task.id} created: ${task.title}',
      ),
    );
    return task;
  }

  Future<void> moveTask(String taskId, TaskStatus status) async {
    final task = state.byId[taskId];
    if (task == null || task.status == status) return;
    final updated = task.copyWith(status: status);
    _replace(updated);
    await _persist();
    final workspaceId = _workspaceId;
    if (workspaceId == null) return;
    await _log(
      ActivityEvent.create(
        workspaceId: workspaceId,
        kind: ActivityEventKind.taskMoved,
        summary: '${task.id} → ${status.label}',
        relatedTaskId: task.id,
        actorBotId: updated.assignedBotId,
      ),
    );
  }

  Future<void> assignTask(String taskId, String? botId) async {
    final task = state.byId[taskId];
    if (task == null) return;
    _replace(task.copyWith(assignedBotId: botId, clearAssignee: botId == null));
    await _persist();
    final workspaceId = _workspaceId;
    if (workspaceId == null || botId == null) return;
    await _log(
      ActivityEvent.create(
        workspaceId: workspaceId,
        kind: ActivityEventKind.taskAssigned,
        summary: '${task.id} assigned to $botId',
        relatedTaskId: task.id,
        actorBotId: botId,
      ),
    );
  }

  Future<void> addComment(String taskId, String author, String text) async {
    final task = state.byId[taskId];
    final trimmed = text.trim();
    if (task == null || trimmed.isEmpty) return;
    _replace(
      task.copyWith(
        comments: [
          ...task.comments,
          TaskComment(author: author, text: trimmed, createdAt: DateTime.now()),
        ],
      ),
    );
    await _persist();
  }

  Future<void> linkDocument(String taskId, String documentPath) async {
    final task = state.byId[taskId];
    if (task == null || task.relatedDocuments.contains(documentPath)) return;
    _replace(
      task.copyWith(relatedDocuments: [...task.relatedDocuments, documentPath]),
    );
    await _persist();
  }

  Future<void> deleteTask(String taskId) async {
    state = state.copyWith(
      tasks: [
        for (final task in state.tasks)
          if (task.id != taskId) task,
      ],
      clearError: true,
    );
    await _persist();
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}
