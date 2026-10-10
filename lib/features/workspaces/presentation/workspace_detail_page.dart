import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/navigation/app_router.dart';
import 'package:pocket_llm/features/activity/application/activity_providers.dart';
import 'package:pocket_llm/features/git/application/git_service.dart';
import 'package:pocket_llm/features/obsidian/application/vault_notes_service.dart';
import 'package:pocket_llm/features/obsidian/application/vaults_controller.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';
import 'package:go_router/go_router.dart';

/// One project screen for everything in the workspace (Road Map 2 §13).
///
/// Chat, board, documents, bots, skills, MCP, workflows and activity stay
/// separate screens; this is the map that links them, plus the vault sync
/// conflicts and the repository state that need a home.
class WorkspaceDetailPage extends ConsumerStatefulWidget {
  const WorkspaceDetailPage({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<WorkspaceDetailPage> createState() =>
      _WorkspaceDetailPageState();
}

class _WorkspaceDetailPageState extends ConsumerState<WorkspaceDetailPage> {
  static const GitService _git = GitService();

  Future<void> _pickRepository(String workspaceId) async {
    final dir = await getDirectoryPath();
    if (dir == null) return;
    final notifier = ref.read(workspacesProvider.notifier);
    final workspace = ref
        .read(workspacesProvider)
        .workspaces
        .where((w) => w.id == workspaceId)
        .firstOrNull;
    if (workspace == null) return;
    await notifier.updateWorkspace(workspace.copyWith(repositoryPath: dir));
  }

  @override
  Widget build(BuildContext context) {
    final workspaces = ref.watch(workspacesProvider);
    final workspace = workspaces.workspaces
        .where((w) => w.id == widget.workspaceId)
        .firstOrNull;
    if (workspace == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Workspace')),
        body: const Center(child: Text('This workspace no longer exists.')),
      );
    }
    final textTheme = Theme.of(context).textTheme;
    final active = workspaces.active?.id == workspace.id;
    final binding = ref.watch(vaultsProvider).snapshot.bindingFor(workspace.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(workspace.name),
        actions: [
          if (!active)
            TextButton(
              onPressed: () =>
                  ref.read(workspacesProvider.notifier).setActive(workspace.id),
              child: const Text('Set active'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          if (workspace.description.isNotEmpty)
            Text(workspace.description, style: textTheme.bodyMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _GoChip(
                icon: Icons.chat_bubble_outline,
                label: 'Chat',
                route: AppRoutes.home,
              ),
              _GoChip(
                icon: Icons.view_kanban_outlined,
                label: 'Board',
                route: AppRoutes.kanban,
              ),
              _GoChip(
                icon: Icons.forum_outlined,
                label: 'Group chats',
                route: AppRoutes.groupChats,
              ),
              _GoChip(
                icon: Icons.account_tree_outlined,
                label: 'Workflows',
                route: AppRoutes.workflows,
              ),
              _GoChip(
                icon: Icons.timeline,
                label: 'Activity',
                route: AppRoutes.activity,
              ),
              _GoChip(
                icon: Icons.smart_toy_outlined,
                label: 'Bots',
                route: AppRoutes.bots,
              ),
              _GoChip(
                icon: Icons.extension_outlined,
                label: 'Skills',
                route: AppRoutes.skills,
              ),
              _GoChip(
                icon: Icons.hub_outlined,
                label: 'MCP',
                route: AppRoutes.mcp,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Knowledge',
            child: binding == null
                ? ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_open),
                    title: const Text('No vault linked'),
                    subtitle: const Text(
                      'Link a folder to keep research, plans and tasks as notes.',
                    ),
                    trailing: TextButton(
                      onPressed: () => context.push(AppRoutes.vaults),
                      child: const Text('Link'),
                    ),
                  )
                : _VaultDocs(workspaceId: workspace.id),
          ),
          _Section(
            title: 'Sync conflicts',
            child: _Conflicts(workspaceId: workspace.id),
          ),
          _Section(
            title: 'Repository',
            child: _Repo(
              workspaceId: workspace.id,
              repositoryPath: workspace.repositoryPath,
              onPick: () => _pickRepository(workspace.id),
            ),
          ),
          _Section(
            title: 'Recent activity',
            child: _RecentActivity(workspaceId: workspace.id),
          ),
        ],
      ),
    );
  }
}

class _GoChip extends StatelessWidget {
  const _GoChip({required this.icon, required this.label, required this.route});

  final IconData icon;
  final String label;
  final String route;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: () => context.push(route),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _VaultDocs extends ConsumerWidget {
  const _VaultDocs({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vaults = ref.watch(vaultsProvider);
    final paths = ref.read(vaultsProvider.notifier).pathsFor(workspaceId);
    final binding = vaults.snapshot.bindingFor(workspaceId);
    if (paths == null || binding == null) {
      return const Text('Vault unavailable.');
    }
    return FutureBuilder<List<String>>(
      future: const VaultNotesService().listNotes(
        paths: paths,
        permissions: binding.permissions,
      ),
      builder: (context, snapshot) {
        final notes = snapshot.data ?? const [];
        if (notes.isEmpty) {
          return Text(
            binding.projectPath.isEmpty
                ? 'No notes yet.'
                : 'No notes yet under ${binding.projectPath}.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return Column(
          children: [
            for (final note in notes.take(8))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.description_outlined, size: 20),
                title: Text(note, overflow: TextOverflow.ellipsis),
                onTap: () => _showNote(context, ref, note),
              ),
            if (notes.length > 8)
              Text(
                '… and ${notes.length - 8} more',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        );
      },
    );
  }

  Future<void> _showNote(
    BuildContext context,
    WidgetRef ref,
    String relativePath,
  ) async {
    final vaults = ref.read(vaultsProvider);
    final paths = ref.read(vaultsProvider.notifier).pathsFor(workspaceId);
    final binding = vaults.snapshot.bindingFor(workspaceId);
    if (paths == null || binding == null) return;
    final (note, error) = await const VaultNotesService().readNote(
      paths: paths,
      permissions: binding.permissions,
      relativePath: relativePath,
    );
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          relativePath,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(error?.message ?? note?.content ?? ''),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _Conflicts extends ConsumerWidget {
  const _Conflicts({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vaults = ref.watch(vaultsProvider);
    final paths = ref.read(vaultsProvider.notifier).pathsFor(workspaceId);
    final binding = vaults.snapshot.bindingFor(workspaceId);
    if (paths == null || binding == null) {
      return Text(
        'Link a vault to see sync conflicts here.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return FutureBuilder<List<VaultSyncConflict>>(
      future: const VaultNotesService().scanConflicts(
        paths: paths,
        permissions: binding.permissions,
      ),
      builder: (context, snapshot) {
        final conflicts = snapshot.data ?? const [];
        if (conflicts.isEmpty) {
          return Text(
            'No conflicts. Pocket LLM never syncs itself — it watches the '
            'folder your own sync keeps up to date.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return Column(
          children: [
            for (final conflict in conflicts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_amber_outlined),
                title: Text(conflict.originalPath),
                subtitle: Text(conflict.conflictPath),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    await const VaultNotesService().resolveConflict(
                      paths: paths,
                      permissions: binding.permissions,
                      conflict: conflict,
                      keepConflictSide: value == 'remote',
                    );
                    // ignore: unused_result
                    ref.invalidate(vaultsProvider);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'local', child: Text('Keep local')),
                    PopupMenuItem(
                      value: 'remote',
                      child: Text('Keep synced copy'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Repo extends StatelessWidget {
  const _Repo({
    required this.workspaceId,
    required this.repositoryPath,
    required this.onPick,
  });

  final String workspaceId;
  final String? repositoryPath;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final path = repositoryPath;
    if (path == null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.source_outlined),
        title: const Text('No repository set'),
        trailing: TextButton(onPressed: onPick, child: const Text('Choose')),
      );
    }
    return FutureBuilder<GitResult<GitStatus>>(
      future: _WorkspaceDetailPageState._git.status(path),
      builder: (context, snapshot) {
        final status = snapshot.data?.value;
        final subtitle = status == null
            ? path
            : '${status.branch} · '
                  '${status.isClean ? 'clean' : '${status.changedFiles.length} changed'}';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.source_outlined),
          title: const Text('Repository'),
          subtitle: Text(subtitle, overflow: TextOverflow.ellipsis),
          trailing: TextButton(onPressed: onPick, child: const Text('Change')),
        );
      },
    );
  }
}

class _RecentActivity extends ConsumerWidget {
  const _RecentActivity({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(workspaceActivityProvider(workspaceId));
    return feed.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, _) => Text('Could not load: $error'),
      data: (events) {
        if (events.isEmpty) {
          return Text(
            'Nothing yet.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return Column(
          children: [
            for (final event in events.take(5))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  event.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(event.kind.label),
              ),
          ],
        );
      },
    );
  }
}
