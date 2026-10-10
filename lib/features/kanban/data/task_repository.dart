import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/kanban/domain/task.dart';
import 'package:pocket_llm/features/kanban/domain/task_note_codec.dart';
import 'package:pocket_llm/features/obsidian/application/vault_notes_service.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_paths.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_registration.dart';

/// Where one workspace's tasks live, whichever side holds them.
abstract class TaskRepository {
  Future<List<ProjectTask>> load(String workspaceId);
  Future<void> save(String workspaceId, List<ProjectTask> tasks);

  /// Next human-readable number for a `PL-<n>` id, or null when numbering
  /// is not supported.
  Future<int?> nextNumber(String workspaceId);
}

/// Local JSON fallback: `kanban/<workspace>/tasks.json` (version 1).
///
/// Used until a workspace links its vault folder; the vault then becomes
/// the readable side and this file stops receiving writes.
class LocalTaskRepository implements TaskRepository {
  LocalTaskRepository(this._baseDir);

  static Future<LocalTaskRepository> open() async {
    final support = await getApplicationSupportDirectory();
    return LocalTaskRepository(Directory(p.join(support.path, 'kanban')));
  }

  final Directory _baseDir;

  File _fileFor(String workspaceId) {
    final safe = workspaceId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File(p.join(_baseDir.path, safe, 'tasks.json'));
  }

  @override
  Future<List<ProjectTask>> load(String workspaceId) async {
    final document = VersionedJsonDocument(
      file: _fileFor(workspaceId),
      currentVersion: 1,
      label: 'TaskStore',
    );
    final decoded = document.read();
    if (decoded == null) return const [];
    final raw = decoded['tasks'];
    if (raw is! List) return const [];
    final tasks = <ProjectTask>[];
    for (final entry in raw) {
      final map = entry is Map<String, dynamic>
          ? entry
          : entry is Map
          ? Map<String, dynamic>.from(entry)
          : null;
      if (map == null) continue;
      final task = ProjectTask.fromJson(map);
      if (task != null) tasks.add(task);
    }
    return tasks;
  }

  @override
  Future<void> save(String workspaceId, List<ProjectTask> tasks) async {
    final document = VersionedJsonDocument(
      file: _fileFor(workspaceId),
      currentVersion: 1,
      label: 'TaskStore',
    );
    await _fileFor(workspaceId).parent.create(recursive: true);
    document.write({
      'version': 1,
      'tasks': tasks.map((task) => task.toJson()).toList(),
    });
  }

  @override
  Future<int?> nextNumber(String workspaceId) async {
    final tasks = await load(workspaceId);
    return _nextFreeNumber(tasks.map((task) => task.id));
  }

  static int _nextFreeNumber(Iterable<String> ids) {
    var max = 0;
    for (final id in ids) {
      final match = RegExp(r'^PL-(\d+)$').firstMatch(id);
      if (match != null) {
        final number = int.tryParse(match.group(1)!) ?? 0;
        if (number > max) max = number;
      }
    }
    return max + 1;
  }
}

/// Vault-backed tasks: one Markdown note per task under `Tasks/`.
///
/// The board is constructed from the notes (§9.2); writes go through the
/// safe notes service, so agent edits and hand edits share the same
/// compare-and-swap protection.
class VaultTaskRepository implements TaskRepository {
  const VaultTaskRepository({
    required this.paths,
    required this.permissions,
    this.notes = const VaultNotesService(),
  });

  final VaultPaths paths;
  final VaultPermissions permissions;
  final VaultNotesService notes;

  String _notePath(ProjectTask task) => 'Tasks/${TaskNoteCodec.fileName(task)}';

  @override
  Future<List<ProjectTask>> load(String workspaceId) async {
    final names = await notes.listNotes(
      paths: paths,
      permissions: permissions,
      folder: 'Tasks',
    );
    final tasks = <ProjectTask>[];
    for (final name in names) {
      final (note, _) = await notes.readNote(
        paths: paths,
        permissions: permissions,
        relativePath: name,
      );
      if (note == null) continue;
      final task = TaskNoteCodec.decode(note.content, workspaceId: workspaceId);
      if (task != null) tasks.add(task);
    }
    tasks.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return tasks;
  }

  @override
  Future<void> save(String workspaceId, List<ProjectTask> tasks) async {
    for (final task in tasks) {
      await notes.writeNote(
        paths: paths,
        permissions: permissions,
        relativePath: _notePath(task),
        content: TaskNoteCodec.encode(task),
      );
    }
  }

  /// Writes one task conditionally; returns the conflict when the note
  /// changed underneath.
  Future<VaultNoteError?> saveOne(ProjectTask task) async {
    return notes.writeNote(
      paths: paths,
      permissions: permissions,
      relativePath: _notePath(task),
      content: TaskNoteCodec.encode(task),
    );
  }

  @override
  Future<int?> nextNumber(String workspaceId) async {
    final tasks = await load(workspaceId);
    return LocalTaskRepository._nextFreeNumber(tasks.map((task) => task.id));
  }
}
