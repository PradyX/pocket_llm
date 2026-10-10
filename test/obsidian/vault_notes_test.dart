import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/obsidian/application/vault_notes_service.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_paths.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_registration.dart';

void main() {
  late Directory vaultDir;
  late VaultPaths paths;
  const service = VaultNotesService();

  setUp(() async {
    vaultDir = await Directory.systemTemp.createTemp('pocketllm_vault');
    paths = VaultPaths(
      vaultRoot: vaultDir.path,
      projectPath: 'Projects/pocketllm',
    );
  });

  tearDown(() async {
    if (await vaultDir.exists()) {
      await vaultDir.delete(recursive: true);
    }
  });

  group('VaultPaths', () {
    test('contains paths inside, refuses escapes', () {
      expect(paths.projectFile('Plans/x.md'), isNotNull);
      expect(paths.projectFile('../../etc/passwd'), isNull);
      expect(paths.projectFile('..'), isNull);
      expect(paths.vaultFile('Personal/y.md'), isNotNull);
      expect(paths.vaultFile('../../escape.md'), isNull);
    });

    test('vault registrations parse and reject garbage', () {
      final vault = VaultRegistration.create(
        name: 'V',
        rootPath: vaultDir.path,
      );
      expect(
        VaultRegistration.fromJson(vault.toJson())?.rootPath,
        vaultDir.path,
      );
      expect(VaultRegistration.fromJson(const {'name': 'x'}), isNull);
    });
  });

  group('VaultNotesService', () {
    test('scaffolds the standard structure', () async {
      final created = await service.ensureProjectStructure(
        paths,
        projectName: 'pocketllm',
      );
      expect(created, containsAll(['Research', 'Plans', 'Project.md']));
      // Second run creates nothing: scaffolding is idempotent.
      expect(
        await service.ensureProjectStructure(paths, projectName: 'pocketllm'),
        isEmpty,
      );
    });

    test('writes, reads and refuses escapes', () async {
      const permissions = VaultPermissions.defaults;
      expect(
        await service.writeNote(
          paths: paths,
          permissions: permissions,
          relativePath: 'Plans/x.md',
          content: '# Hello',
        ),
        isNull,
      );
      final (note, error) = await service.readNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Plans/x.md',
      );
      expect(error, isNull);
      expect(note?.content, '# Hello');
      expect(note?.relativePath, 'Plans/x.md');

      expect(
        await service.writeNote(
          paths: paths,
          permissions: permissions,
          relativePath: '../../escape.md',
          content: 'x',
        ),
        VaultNoteError.outsideProject,
      );
    });

    test('conditional writes detect conflicts', () async {
      const permissions = VaultPermissions.defaults;
      await service.writeNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Plans/y.md',
        content: 'v1',
      );
      final (note, _) = await service.readNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Plans/y.md',
      );
      // Someone else writes first, clearly after the read above.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await service.writeNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Plans/y.md',
        content: 'v2',
      );
      expect(
        await service.writeNote(
          paths: paths,
          permissions: permissions,
          relativePath: 'Plans/y.md',
          content: 'stale',
          expectedModified: note!.modified,
        ),
        VaultNoteError.conflict,
      );
    });

    test('permissions gate deletes by default', () async {
      const permissions = VaultPermissions.defaults;
      await service.writeNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Plans/z.md',
        content: 'x',
      );
      expect(
        await service.deleteNote(
          paths: paths,
          permissions: permissions,
          relativePath: 'Plans/z.md',
        ),
        VaultNoteError.denied,
      );
      expect(
        await service.deleteNote(
          paths: paths,
          permissions: const VaultPermissions(canDelete: true),
          relativePath: 'Plans/z.md',
        ),
        isNull,
      );
    });

    test('sync conflicts surface and resolve explicitly', () async {
      const permissions = VaultPermissions.defaults;
      await service.ensureProjectStructure(paths, projectName: 'p');
      await service.writeNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Architecture.md',
        content: 'local version',
      );
      await service.writeNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Architecture.sync-conflict-20240101-120000-DEVICE.md',
        content: 'remote version',
      );
      final conflicts = await service.scanConflicts(
        paths: paths,
        permissions: permissions,
      );
      expect(conflicts.map((c) => c.originalPath), ['Architecture.md']);

      // Keeping the remote side copies it over the original.
      expect(
        await service.resolveConflict(
          paths: paths,
          permissions: const VaultPermissions(),
          conflict: conflicts.single,
          keepConflictSide: true,
        ),
        isNull,
      );
      final (note, _) = await service.readNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Architecture.md',
      );
      expect(note?.content, 'remote version');
      expect(
        await service.scanConflicts(paths: paths, permissions: permissions),
        isEmpty,
      );
    });

    test('search ranks name hits above body hits', () async {
      const permissions = VaultPermissions.defaults;
      await service.ensureProjectStructure(paths, projectName: 'p');
      await service.writeNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Research/context-compaction.md',
        content: 'Notes about compaction budgets.',
      );
      await service.writeNote(
        paths: paths,
        permissions: permissions,
        relativePath: 'Plans/other.md',
        content: 'This mentions compaction once.',
      );
      final hits = await service.searchNotes(
        paths: paths,
        permissions: permissions,
        query: 'context compaction',
      );
      expect(
        hits.map((hit) => hit.relativePath).first,
        'Research/context-compaction.md',
      );
      expect(hits.first.snippet, isNotEmpty);
    });
  });
}
