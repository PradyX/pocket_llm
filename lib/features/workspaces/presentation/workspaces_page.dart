import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_llm/core/navigation/app_router.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';

/// Lists project workspaces and selects the active one.
///
/// Road Map 2 Phase 2.0. The workspace is the boundary for agent access: a
/// bot only sees the workspaces it is assigned to. This screen owns the
/// list; per-workspace detail (bots, skills, vault folder, boards) arrives
/// with the later phases that introduce those members.
class WorkspacesPage extends ConsumerStatefulWidget {
  const WorkspacesPage({super.key});

  @override
  ConsumerState<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends ConsumerState<WorkspacesPage> {
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _askName({
    String? current,
    required ValueChanged<String> onSave,
  }) async {
    _nameController.text = current ?? '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(current == null ? 'New workspace' : 'Rename workspace'),
        content: TextField(
          controller: _nameController,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Workspace name'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_nameController.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    onSave(name);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(workspacesProvider);
    final notifier = ref.read(workspacesProvider.notifier);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Workspaces')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            _askName(onSave: (name) => notifier.createWorkspace(name)),
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: !state.isReady
          ? const Center(child: CircularProgressIndicator())
          : state.workspaces.isEmpty
          ? const Center(child: Text('No workspaces yet.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                Text(
                  'One workspace links a project\u2019s bots, chats, skills, '
                  'vault folder and boards. Bots only see the workspaces '
                  'they are assigned to.',
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                for (final workspace in state.workspaces)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        state.active?.id == workspace.id
                            ? Icons.check_circle
                            : Icons.folder_outlined,
                      ),
                      title: Text(workspace.name),
                      subtitle: workspace.description.isEmpty
                          ? Text(
                              '${workspace.botIds.length} bots · '
                              '${workspace.skillIds.length} skills',
                            )
                          : Text(workspace.description),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          switch (value) {
                            case 'activate':
                              notifier.setActive(workspace.id);
                            case 'rename':
                              _askName(
                                current: workspace.name,
                                onSave: (name) => notifier.renameWorkspace(
                                  workspace.id,
                                  name,
                                ),
                              );
                            case 'delete':
                              notifier.removeWorkspace(workspace.id);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'activate',
                            child: Text('Set active'),
                          ),
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                      onTap: () =>
                          context.push(AppRoutes.workspaceFor(workspace.id)),
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
