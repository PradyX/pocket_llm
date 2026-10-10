import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/kanban/data/task_repository.dart';
import 'package:pocket_llm/features/kanban/domain/task.dart';
import 'package:pocket_llm/features/kanban/domain/task_note_codec.dart';
import 'package:pocket_llm/features/obsidian/application/vault_notes_service.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_paths.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_registration.dart';

void main() {
  group('TaskStatus', () {
    test('parses frontmatter spellings', () {
      expect(TaskStatus.fromKey('in-progress'), TaskStatus.inProgress);
      expect(TaskStatus.fromKey('done'), TaskStatus.done);
      expect(TaskStatus.fromKey('nonsense'), TaskStatus.todo);
    });
  });

  group('TaskNoteCodec', () {
    test('round-trips a full task through Markdown', () {
      final task = ProjectTask.create(
        id: 'PL-001',
        workspaceId: 'w1',
        title: 'Context compaction',
        description: 'Build the engine.',
        status: TaskStatus.inProgress,
        priority: TaskPriority.high,
      );
      final withDeps = task.copyWith(
        assignedBotId: 'coder',
        dependencies: const ['PL-000'],
        relatedDocuments: const ['Plans/x.md'],
      );
      final note = TaskNoteCodec.encode(withDeps);
      expect(note, contains('id: PL-001'));
      expect(note, contains('status: in-progress'));
      expect(note, contains('- PL-000'));

      final decoded = TaskNoteCodec.decode(note, workspaceId: 'w1')!;
      expect(decoded.id, 'PL-001');
      expect(decoded.title, 'Context compaction');
      expect(decoded.status, TaskStatus.inProgress);
      expect(decoded.priority, TaskPriority.high);
      expect(decoded.assignedBotId, 'coder');
      expect(decoded.dependencies, ['PL-000']);
      expect(decoded.relatedDocuments, ['Plans/x.md']);
    });

    test('a hand-written note without an id does not board', () {
      expect(
        TaskNoteCodec.decode('# Just a note\n', workspaceId: 'w1'),
        isNull,
      );
    });

    test('file names are stable and filesystem-safe', () {
      final task = ProjectTask.create(
        id: 'PL-002',
        workspaceId: 'w1',
        title: 'Skill system: registry & loading!',
      );
      expect(
        TaskNoteCodec.fileName(task),
        'PL-002-skill-system-registry-loading.md',
      );
    });
  });

  group('ProjectTask', () {
    test('dependencies gate starting', () {
      final done = ProjectTask.create(
        id: 'PL-000',
        workspaceId: 'w',
        title: 'a',
        status: TaskStatus.done,
      );
      final open = ProjectTask.create(
        id: 'PL-001',
        workspaceId: 'w',
        title: 'b',
      );
      final gated = open.copyWith(dependencies: const ['PL-000', 'PL-999']);
      expect(gated.unblockedBy({'PL-000': done}), isFalse);
      expect(
        gated.unblockedBy({
          'PL-000': done,
          'PL-999': open.copyWith(status: TaskStatus.done),
        }),
        isTrue,
      );
    });

    test('finishing stamps completion, reopening clears it', () {
      var task = ProjectTask.create(id: 't', workspaceId: 'w', title: 't');
      task = task.copyWith(status: TaskStatus.done);
      expect(task.completedAt, isNotNull);
      task = task.copyWith(status: TaskStatus.todo);
      expect(task.completedAt, isNull);
    });
  });

  group('Task repositories', () {
    test('local store round-trips and numbers PL ids', () async {
      final dir = await Directory.systemTemp.createTemp('pocketllm_tasks');
      try {
        final repo = LocalTaskRepository(dir);
        expect(await repo.nextNumber('w1'), 1);
        await repo.save('w1', [
          ProjectTask.create(id: 'PL-001', workspaceId: 'w1', title: 'first'),
        ]);
        expect(await repo.nextNumber('w1'), 2);
        final loaded = await repo.load('w1');
        expect(loaded.map((task) => task.id), ['PL-001']);
        expect(await repo.load('unknown'), isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('vault repository boards from notes', () async {
      final vaultDir = await Directory.systemTemp.createTemp(
        'pocketllm_vtasks',
      );
      try {
        final paths = VaultPaths(
          vaultRoot: vaultDir.path,
          projectPath: 'Projects/p',
        );
        const service = VaultNotesService();
        await service.ensureProjectStructure(paths, projectName: 'p');
        final repo = VaultTaskRepository(
          paths: paths,
          permissions: VaultPermissions.defaults,
        );
        await repo.save('w1', [
          ProjectTask.create(
            id: 'PL-001',
            workspaceId: 'w1',
            title: 'Vault task',
            status: TaskStatus.inProgress,
          ),
        ]);
        final loaded = await repo.load('w1');
        expect(loaded.map((task) => task.id), ['PL-001']);
        expect(loaded.first.title, 'Vault task');
        expect(await repo.nextNumber('w1'), 2);
      } finally {
        await vaultDir.delete(recursive: true);
      }
    });
  });
}
