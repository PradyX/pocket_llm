import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/obsidian/domain/vault_paths.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_registration.dart';

/// Why a note operation was refused.
enum VaultNoteError {
  denied('Not allowed here.'),
  outsideProject('Outside the project folder.'),
  notFound('Note not found.'),
  conflict('The note changed since it was read.'),
  io('Could not reach the file.');

  const VaultNoteError(this.message);
  final String message;
}

/// One note read from the vault.
class VaultNote {
  const VaultNote({
    required this.relativePath,
    required this.content,
    required this.modified,
  });

  /// Workspace-relative path (`Plans/x.md`): the portable reference.
  final String relativePath;
  final String content;
  final DateTime modified;
}

/// One capped search hit.
class VaultSearchHit {
  const VaultSearchHit({required this.relativePath, required this.snippet});

  final String relativePath;
  final String snippet;
}

/// Safe note read/write inside a vault project folder (§8.4).
///
/// Rules:
/// * Reads stay inside the vault root; writes stay inside the project
///   folder. Anything else resolves to [VaultNoteError.denied].
/// * Permissions gate every operation; deletes default to off.
/// * Updates are compare-and-swap on the modification time: pass the
///   [VaultNote.modified] the read returned as [expectedModified], and a
///   meanwhile-changed note refuses with [VaultNoteError.conflict] instead
///   of silently overwriting it.
/// * Writes are atomic (temp file + rename) where the platform allows it.
class VaultNotesService {
  const VaultNotesService();

  /// Creates the standard project structure (§8.3 + §20) under [paths].
  Future<List<String>> ensureProjectStructure(
    VaultPaths paths, {
    required String projectName,
  }) async {
    final created = <String>[];
    for (final folder in VaultFolders.standard) {
      final dir = Directory(paths.projectFile(folder)!);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        created.add(folder);
      }
    }
    final indexPath = paths.projectFile('Project.md');
    if (indexPath != null && !await File(indexPath).exists()) {
      await File(indexPath).writeAsString(
        '# $projectName\n\nStatus: draft\n\nProject workspace for $projectName.\n',
      );
      created.add('Project.md');
    }
    return created;
  }

  Future<(VaultNote?, VaultNoteError?)> readNote({
    required VaultPaths paths,
    required VaultPermissions permissions,
    required String relativePath,
  }) async {
    if (!permissions.canRead) return (null, VaultNoteError.denied);
    final absolute = _readPath(paths, permissions, relativePath);
    if (absolute == null) return (null, VaultNoteError.outsideProject);
    final file = File(absolute);
    if (!await file.exists()) return (null, VaultNoteError.notFound);
    try {
      final stat = await file.stat();
      return (
        VaultNote(
          relativePath: paths.relativeToProject(absolute) ?? relativePath,
          content: await file.readAsString(),
          modified: stat.modified,
        ),
        null,
      );
    } catch (_) {
      return (null, VaultNoteError.io);
    }
  }

  /// Writes [content] to [relativePath] inside the project folder.
  ///
  /// Pass [expectedModified] from a previous read to make the write
  /// conditional; null writes unconditionally (creates included, when
  /// [VaultPermissions.canCreate] allows it).
  Future<VaultNoteError?> writeNote({
    required VaultPaths paths,
    required VaultPermissions permissions,
    required String relativePath,
    required String content,
    DateTime? expectedModified,
  }) async {
    if (!permissions.canWrite) return VaultNoteError.denied;
    final absolute = paths.projectFile(relativePath);
    if (absolute == null) return VaultNoteError.outsideProject;
    final file = File(absolute);
    final exists = await file.exists();
    if (exists && !permissions.canUpdate) return VaultNoteError.denied;
    if (!exists && !permissions.canCreate) return VaultNoteError.denied;
    try {
      if (exists && expectedModified != null) {
        final stat = await file.stat();
        if (stat.modified.difference(expectedModified).abs() >
            const Duration(milliseconds: 500)) {
          return VaultNoteError.conflict;
        }
      }
      await file.parent.create(recursive: true);
      // Atomic where rename-overwrite is supported; otherwise direct.
      final temp = File(
        p.join(file.parent.path, '.${p.basename(file.path)}.tmp'),
      );
      try {
        await temp.writeAsString(content, flush: true);
        await temp.rename(file.path);
      } catch (_) {
        if (await temp.exists()) {
          try {
            await temp.delete();
          } catch (_) {}
        }
        await file.writeAsString(content, flush: true);
      }
      return null;
    } catch (_) {
      return VaultNoteError.io;
    }
  }

  Future<VaultNoteError?> deleteNote({
    required VaultPaths paths,
    required VaultPermissions permissions,
    required String relativePath,
  }) async {
    if (!permissions.canDelete) return VaultNoteError.denied;
    final absolute = paths.projectFile(relativePath);
    if (absolute == null) return VaultNoteError.outsideProject;
    final file = File(absolute);
    if (!await file.exists()) return VaultNoteError.notFound;
    try {
      await file.delete();
      return null;
    } catch (_) {
      return VaultNoteError.io;
    }
  }

  /// Lists Markdown notes under [folder] (project-relative, default root).
  Future<List<String>> listNotes({
    required VaultPaths paths,
    required VaultPermissions permissions,
    String folder = '.',
  }) async {
    if (!permissions.canRead) return const [];
    final absolute = paths.projectFile(folder);
    if (absolute == null) return const [];
    final dir = Directory(absolute);
    if (!await dir.exists()) return const [];
    final notes = <String>[];
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.md')) continue;
        final relative = paths.relativeToProject(entity.path);
        if (relative != null) notes.add(relative);
      }
    } catch (_) {
      return const [];
    }
    notes.sort();
    return notes;
  }

  /// Keyword retrieval over the project folder (§8.5): whole-word matches in
  /// names count most, then content hits. Never loads more than the cap, and
  /// each snippet is trimmed so retrieval stays inside its budget.
  Future<List<VaultSearchHit>> searchNotes({
    required VaultPaths paths,
    required VaultPermissions permissions,
    required String query,
    int maxResults = 8,
  }) async {
    if (!permissions.canRead) return const [];
    final words = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9_]+'))
        .where((word) => word.length > 2)
        .toSet();
    if (words.isEmpty) return const [];
    final notes = await listNotes(paths: paths, permissions: permissions);
    final scored = <({String path, int score, String snippet})>[];
    for (final relative in notes) {
      final absolute = paths.projectFile(relative);
      if (absolute == null) continue;
      String content;
      try {
        content = await File(absolute).readAsString();
      } catch (_) {
        continue;
      }
      if (content.length > 20000) {
        content = content.substring(0, 20000);
      }
      final nameWords = relative
          .toLowerCase()
          .replaceAll(RegExp(r'[/_.-]'), ' ')
          .split(RegExp(r'\s+'))
          .toSet();
      final bodyWords = content
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9_]+'))
          .toSet();
      var score = 0;
      for (final word in words) {
        if (nameWords.contains(word)) score += 3;
        if (bodyWords.contains(word)) score += 1;
      }
      if (score <= 0) continue;
      scored.add((
        path: relative,
        score: score,
        snippet: _snippet(content, words),
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return [
      for (final hit in scored.take(maxResults))
        VaultSearchHit(relativePath: hit.path, snippet: hit.snippet),
    ];
  }

  String? _readPath(
    VaultPaths paths,
    VaultPermissions permissions,
    String relativePath,
  ) {
    // Project folder first; the wider vault only when permitted.
    return paths.projectFile(relativePath) ??
        (permissions.allowReadOutsideProject
            ? paths.vaultFile(relativePath)
            : null);
  }

  static String _snippet(String content, Set<String> words) {
    final lower = content.toLowerCase();
    var index = -1;
    for (final word in words) {
      final found = lower.indexOf(word);
      if (found >= 0 && (index < 0 || found < index)) index = found;
    }
    if (index < 0) {
      return content.length <= 160 ? content : '${content.substring(0, 160)}…';
    }
    final start = index - 60 < 0 ? 0 : index - 60;
    var end = index + 100;
    if (end > content.length) end = content.length;
    final snippet = content
        .substring(start, end)
        .replaceAll(RegExp(r'\s+'), ' ');
    return '${start > 0 ? '… ' : ''}$snippet${end < content.length ? ' …' : ''}';
  }
}
