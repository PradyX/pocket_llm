import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/obsidian/application/vaults_controller.dart';
import 'package:pocket_llm/features/obsidian/domain/vault_registration.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';

/// Registered Obsidian vaults and their workspace links.
///
/// Road Map 2 Phase 2.5. The vault is the human-readable knowledge layer:
/// research, plans, decisions, reports and tasks live there as Markdown.
// The app only ever writes inside a linked project folder.
class VaultsPage extends ConsumerWidget {
  const VaultsPage({super.key});

  Future<void> _register(BuildContext context, WidgetRef ref) async {
    final dir = await getDirectoryPath();
    if (dir == null || !context.mounted) return;
    final name = dir
        .split(RegExp(r'[/\\]'))
        .lastWhere((part) => part.isNotEmpty, orElse: () => 'Vault');
    final vault = await ref
        .read(vaultsProvider.notifier)
        .registerVault(name, dir);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          vault == null ? 'Could not save the vault.' : 'Registered $name.',
        ),
      ),
    );
  }

  Future<void> _link(
    BuildContext context,
    WidgetRef ref,
    VaultRegistration vault,
    String workspaceId,
  ) async {
    final controller = TextEditingController(text: 'Projects/pocketllm');
    final projectPath = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Link workspace folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder inside the vault',
            hintText: 'Projects/pocketllm',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Link'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (projectPath == null || projectPath.trim().isEmpty || !context.mounted) {
      return;
    }
    final created = await ref
        .read(vaultsProvider.notifier)
        .linkWorkspace(
          workspaceId: workspaceId,
          vaultId: vault.id,
          projectPath: projectPath,
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          created.isEmpty
              ? 'Workspace linked.'
              : 'Workspace linked. Created ${created.join(', ')}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vaultsProvider);
    final workspaces = ref.watch(workspacesProvider);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Obsidian vaults')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _register(context, ref),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Register vault'),
      ),
      body: !state.isReady
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                Text(
                  'A vault is the shared knowledge layer: notes bots read '
                  'and write as Markdown. Vaults stay local — the app never '
                  'syncs anything itself; point it at a folder your own sync '
                  'already keeps up to date.',
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (state.vaults.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No vaults registered yet.'),
                    ),
                  ),
                for (final vault in state.vaults)
                  Card(
                    child: ExpansionTile(
                      leading: const Icon(Icons.folder_open),
                      title: Text(vault.name),
                      subtitle: Text(
                        vault.rootPath,
                        overflow: TextOverflow.ellipsis,
                      ),
                      children: [
                        for (final workspace in workspaces.workspaces)
                          Builder(
                            builder: (context) {
                              final binding = state.snapshot.bindingFor(
                                workspace.id,
                              );
                              final linked = binding?.vaultId == vault.id;
                              return ListTile(
                                title: Text(workspace.name),
                                subtitle: linked
                                    ? Text(
                                        binding!.projectPath,
                                        overflow: TextOverflow.ellipsis,
                                      )
                                    : const Text('Not linked'),
                                trailing: linked
                                    ? TextButton(
                                        onPressed: () => ref
                                            .read(vaultsProvider.notifier)
                                            .unlinkWorkspace(workspace.id),
                                        child: const Text('Unlink'),
                                      )
                                    : TextButton(
                                        onPressed: () => _link(
                                          context,
                                          ref,
                                          vault,
                                          workspace.id,
                                        ),
                                        child: const Text('Link'),
                                      ),
                              );
                            },
                          ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => ref
                                .read(vaultsProvider.notifier)
                                .removeVault(vault.id),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Remove vault'),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                if (state.errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    state.errorMessage!,
                    style: textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
