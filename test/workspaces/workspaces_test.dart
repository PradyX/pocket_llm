import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/obsidian/data/vault_store.dart';
import 'package:pocket_llm/features/workspaces/domain/workspace.dart';

void main() {
  group('Workspace', () {
    test('round-trips the repository path and vault link', () {
      final workspace = Workspace.create(name: 'P').copyWith(
        obsidianVaultId: 'v1',
        obsidianProjectPath: 'Projects/p',
        repositoryPath: '/home/user/code/p',
      );
      final restored = Workspace.fromJson(workspace.toJson())!;
      expect(restored.repositoryPath, '/home/user/code/p');
      expect(restored.obsidianVaultId, 'v1');
      // Older files without the new fields still load.
      final legacy = Workspace.fromJson(const {'id': 'w', 'name': 'W'})!;
      expect(legacy.repositoryPath, isNull);
      expect(legacy.obsidianProjectPath, isEmpty);
    });

    test('bots only see assigned workspaces through allowsBot', () {
      final workspace = Workspace.create(
        name: 'P',
      ).copyWith(botIds: const ['coder']);
      expect(workspace.allowsBot('coder'), isTrue);
      expect(workspace.allowsBot('planner'), isFalse);
    });
  });

  group('WorkspaceVaultBinding', () {
    test('round-trips permissions with the defaults intact', () {
      const binding = WorkspaceVaultBinding(
        workspaceId: 'w',
        vaultId: 'v',
        projectPath: 'Projects/p',
      );
      final restored = WorkspaceVaultBinding.fromJson(binding.toJson())!;
      expect(restored.projectPath, 'Projects/p');
      expect(restored.permissions.canDelete, isFalse);
      expect(
        WorkspaceVaultBinding.fromJson(const {'workspaceId': 'w'}),
        isNull,
      );
    });
  });
}
