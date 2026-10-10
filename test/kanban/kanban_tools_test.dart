import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/kanban/application/kanban_tools.dart';
import 'package:pocket_llm/features/kanban/data/task_repository.dart';
import 'package:pocket_llm/features/kanban/domain/task.dart';
import 'package:pocket_llm/features/tools/application/built_in_tools.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

/// In-memory board: the tools under test never touch the filesystem.
class _FakeBoard implements TaskRepository {
  _FakeBoard([List<ProjectTask>? seed]) : tasks = [...?seed];

  List<ProjectTask> tasks;
  int? next;

  @override
  Future<List<ProjectTask>> load(String workspaceId) async =>
      tasks.where((task) => task.workspaceId == workspaceId).toList();

  @override
  Future<void> save(String workspaceId, List<ProjectTask> tasks) async {
    this.tasks = [
      for (final task in this.tasks)
        if (task.workspaceId != workspaceId) task,
      ...tasks,
    ];
  }

  @override
  Future<int?> nextNumber(String workspaceId) async => next;
}

/// Gate that allows every sensitive call, like a user tapping Allow.
class _ApprovingGate implements ToolPermissionGate {
  const _ApprovingGate();

  @override
  Future<bool> requestApproval(ToolApprovalRequest request) async => true;
}

void main() {
  ToolRegistry registryFor(
    _FakeBoard board, {
    ToolPermissionGate permissionGate = const _ApprovingGate(),
  }) {
    return ToolRegistry(
      tools: buildKanbanTools(
        KanbanToolContext(
          workspaceId: 'w1',
          repositoryFor: (_) async => board,
          actorName: 'tester',
        ),
      ),
      platform: ToolPlatform.macOS,
      permissionGate: permissionGate,
    );
  }

  group('kanban_list_tasks', () {
    test('says the board is empty', () async {
      final result = await registryFor(
        _FakeBoard(),
      ).execute(const ToolCall(toolName: 'kanban_list_tasks'));

      expect(result.isSuccess, isTrue);
      expect(result.output, 'The board is empty.');
    });

    test('lists ids, statuses and assignees', () async {
      final board = _FakeBoard([
        ProjectTask.create(
          id: 'PL-001',
          workspaceId: 'w1',
          title: 'Build the engine',
          status: TaskStatus.inProgress,
        ).copyWith(assignedBotId: 'coder'),
        ProjectTask.create(
          id: 'PL-002',
          workspaceId: 'w1',
          title: 'Write docs',
        ),
      ]);

      final result = await registryFor(
        board,
      ).execute(const ToolCall(toolName: 'kanban_list_tasks'));

      expect(result.isSuccess, isTrue);
      expect(
        result.output,
        'PL-001 [in-progress] Build the engine (assignee: coder)\n'
        'PL-002 [todo] Write docs',
      );
    });
  });

  group('kanban_create_task', () {
    test('numbers the task and saves it', () async {
      final board = _FakeBoard()..next = 7;

      final result = await registryFor(board).execute(
        const ToolCall(
          toolName: 'kanban_create_task',
          arguments: {'title': 'Track the launch'},
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, 'Created PL-007: Track the launch');
      expect(board.tasks.single.id, 'PL-007');
      expect(board.tasks.single.createdBy, 'tester');
    });

    test('skips numbers already on the board', () async {
      final board = _FakeBoard([
        ProjectTask.create(id: 'PL-001', workspaceId: 'w1', title: 'Existing'),
      ])..next = 1;

      final result = await registryFor(board).execute(
        const ToolCall(
          toolName: 'kanban_create_task',
          arguments: {'title': 'Another'},
        ),
      );

      expect(result.output, 'Created PL-002: Another');
    });

    test('is refused until the user allows it', () async {
      final board = _FakeBoard();
      final registry = registryFor(
        board,
        permissionGate: const DenySensitiveTools(),
      );

      final result = await registry.execute(
        const ToolCall(
          toolName: 'kanban_create_task',
          arguments: {'title': 'Track the launch'},
        ),
      );

      expect(result.status, ToolExecutionStatus.denied);
      expect(board.tasks, isEmpty);
    });
  });

  group('kanban_move_task', () {
    test('moves the task and reports the new status', () async {
      final board = _FakeBoard([
        ProjectTask.create(
          id: 'PL-001',
          workspaceId: 'w1',
          title: 'Build the engine',
        ),
      ]);

      final result = await registryFor(board).execute(
        const ToolCall(
          toolName: 'kanban_move_task',
          arguments: {'taskId': 'PL-001', 'status': 'in-progress'},
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.output, 'Moved PL-001 to In Progress.');
      expect(board.tasks.single.status, TaskStatus.inProgress);
    });

    test('reports an unknown id instead of moving anything', () async {
      final board = _FakeBoard();

      final result = await registryFor(board).execute(
        const ToolCall(
          toolName: 'kanban_move_task',
          arguments: {'taskId': 'PL-999', 'status': 'done'},
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.output, contains('no task PL-999'));
    });

    test('rejects a status outside the board', () async {
      final result = await registryFor(_FakeBoard()).execute(
        const ToolCall(
          toolName: 'kanban_move_task',
          arguments: {'taskId': 'PL-001', 'status': 'shipped'},
        ),
      );

      expect(result.status, ToolExecutionStatus.invalidArguments);
    });
  });

  group('extendedWith', () {
    test('adds the board to a scoped run without touching the base', () async {
      final base = buildToolRegistry(platform: ToolPlatform.macOS);
      final scoped = base.extendedWith(
        buildKanbanTools(
          KanbanToolContext(
            workspaceId: 'w1',
            repositoryFor: (_) async => _FakeBoard(),
            actorName: 'tester',
          ),
        ),
      );

      expect(base.definitionFor('kanban_list_tasks'), isNull);
      expect(scoped.definitionFor('kanban_list_tasks'), isNotNull);
      expect(
        scoped.definitionFor('calculator'),
        base.definitionFor('calculator'),
      );
    });
  });
}
