import 'package:pocket_llm/features/activity/data/activity_store.dart';
import 'package:pocket_llm/features/activity/domain/activity_event.dart';
import 'package:pocket_llm/features/kanban/data/task_repository.dart';
import 'package:pocket_llm/features/kanban/domain/task.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// What a board-bound tool call needs. Resolved per call so the tools work
/// for whatever workspace the run belongs to — never just the active one.
class KanbanToolContext {
  const KanbanToolContext({
    required this.workspaceId,
    required this.repositoryFor,
    this.actorName = 'bot',
    this.onBoardChanged,
  });

  final String workspaceId;

  /// Opens the task repository the workspace currently boards from (vault
  /// notes when linked, the local store otherwise).
  final Future<TaskRepository> Function(String workspaceId) repositoryFor;

  /// Name recorded on comments and activity entries.
  final String actorName;

  /// Runs after a tool saves, so an open board can refresh. Null in tests.
  final Future<void> Function()? onBoardChanged;
}

/// Native board tools, so a bot can work the Kanban from chat or a room —
/// the Hermes `kanban_create` flow, through the same registry, validation
/// and permission gates as every other tool.
///
/// Listing is read-only; creating and moving change the shared board, so
/// they run as sensitive and the user is asked first.
List<ToolEntry> buildKanbanTools(KanbanToolContext context) {
  return [
    ToolEntry(
      definition: const ToolDefinition(
        name: 'kanban_list_tasks',
        description:
            'Lists this workspace\u2019s board tasks with their ids, titles, '
            'statuses and assignees.',
        risk: ToolRiskLevel.readOnly,
        parameters: [],
      ),
      handler: (arguments) => _listTasks(context),
    ),
    ToolEntry(
      definition: const ToolDefinition(
        name: 'kanban_create_task',
        description:
            'Creates a board task in this workspace and returns its PL id. '
            'Use it when the user asks to track work, or when a plan needs '
            'tasks before anything is implemented.',
        risk: ToolRiskLevel.sensitive,
        parameters: [
          ToolParameter(
            name: 'title',
            type: ToolParameterType.string,
            description: 'Short task title.',
            maxLength: 160,
          ),
          ToolParameter(
            name: 'description',
            type: ToolParameterType.string,
            description: 'What the task involves.',
            required: false,
            maxLength: 2000,
          ),
        ],
      ),
      handler: (arguments) => _createTask(
        context,
        title: arguments['title'] as String,
        description: (arguments['description'] as String?) ?? '',
      ),
    ),
    ToolEntry(
      definition: const ToolDefinition(
        name: 'kanban_move_task',
        description:
            'Moves a board task to another status: backlog, todo, '
            'in-progress, review, blocked or done.',
        risk: ToolRiskLevel.sensitive,
        parameters: [
          ToolParameter(
            name: 'taskId',
            type: ToolParameterType.string,
            description: 'The PL id, for example PL-001.',
            maxLength: 32,
          ),
          ToolParameter(
            name: 'status',
            type: ToolParameterType.string,
            description: 'Target status.',
            allowedValues: [
              'backlog',
              'todo',
              'in-progress',
              'review',
              'blocked',
              'done',
            ],
          ),
        ],
      ),
      handler: (arguments) => _moveTask(
        context,
        taskId: arguments['taskId'] as String,
        status: TaskStatus.fromKey(arguments['status'] as String),
      ),
    ),
  ];
}

Future<String> _listTasks(KanbanToolContext context) async {
  final repository = await context.repositoryFor(context.workspaceId);
  final tasks = await repository.load(context.workspaceId);
  if (tasks.isEmpty) return 'The board is empty.';
  return [
    for (final task in tasks)
      '${task.id} [${task.status.key}] ${task.title}'
          '${task.assignedBotId == null ? '' : ' (assignee: ${task.assignedBotId})'}',
  ].join('\n');
}

/// Creates one board task with the next free `PL-<n>` id and saves it.
///
/// Shared by the `kanban_create_task` tool and the room's message-to-task
/// action, so bots and taps number tasks the same way.
Future<ProjectTask> createBoardTask({
  required TaskRepository repository,
  required String workspaceId,
  required String title,
  String description = '',
  List<String> relatedMessages = const [],
  String? createdBy,
}) async {
  final tasks = await repository.load(workspaceId);
  final number = await repository.nextNumber(workspaceId) ?? 1;
  var candidate = 'PL-${number.toString().padLeft(3, '0')}';
  final taken = {for (final task in tasks) task.id};
  while (taken.contains(candidate)) {
    final match = RegExp(r'^PL-(\d+)$').firstMatch(candidate);
    final next = (match == null ? 0 : int.parse(match.group(1)!)) + 1;
    candidate = 'PL-${next.toString().padLeft(3, '0')}';
  }
  final task = ProjectTask.create(
    id: candidate,
    workspaceId: workspaceId,
    title: title,
    description: description,
    createdBy: createdBy,
  ).copyWith(relatedMessages: relatedMessages);
  await repository.save(workspaceId, [...tasks, task]);
  return task;
}

Future<String> _createTask(
  KanbanToolContext context, {
  required String title,
  required String description,
}) async {
  final repository = await context.repositoryFor(context.workspaceId);
  final task = await createBoardTask(
    repository: repository,
    workspaceId: context.workspaceId,
    title: title,
    description: description,
    createdBy: context.actorName,
  );
  await logBoardActivity(
    workspaceId: context.workspaceId,
    event: ActivityEvent.create(
      workspaceId: context.workspaceId,
      kind: ActivityEventKind.taskCreated,
      summary: '${task.id} created: ${task.title}',
      relatedTaskId: task.id,
    ),
  );
  await context.onBoardChanged?.call();
  return 'Created ${task.id}: ${task.title}';
}

Future<String> _moveTask(
  KanbanToolContext context, {
  required String taskId,
  required TaskStatus status,
}) async {
  final repository = await context.repositoryFor(context.workspaceId);
  final tasks = await repository.load(context.workspaceId);
  final index = tasks.indexWhere((task) => task.id == taskId);
  if (index < 0) throw Exception('There is no task $taskId on the board.');
  final updated = tasks[index].copyWith(status: status);
  final next = [...tasks]..[index] = updated;
  await repository.save(context.workspaceId, next);
  await logBoardActivity(
    workspaceId: context.workspaceId,
    event: ActivityEvent.create(
      workspaceId: context.workspaceId,
      kind: ActivityEventKind.taskMoved,
      summary: '$taskId → ${status.label}',
      relatedTaskId: taskId,
    ),
  );
  await context.onBoardChanged?.call();
  return 'Moved $taskId to ${status.label}.';
}

/// Records one board line in the workspace's activity feed.
///
/// Best-effort: a board write that cannot log still stands.
Future<void> logBoardActivity({
  required String workspaceId,
  required ActivityEvent event,
}) async {
  try {
    final store = await ActivityStore.open(workspaceId);
    store.append(event);
  } catch (_) {}
}
