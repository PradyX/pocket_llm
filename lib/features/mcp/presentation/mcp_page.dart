import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/mcp/application/mcp_controller.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_server.dart';

/// MCP servers: what is configured, what each one offers, and what each
/// tool may do.
///
/// Road Map 2 Phase 2.3. Discovery runs on demand per server and its result
/// is cached locally; permissions default to asking and can be tightened to
/// read-only or disabled per tool.
class McpPage extends ConsumerWidget {
  const McpPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mcpProvider);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('MCP servers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editServer(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
      body: !state.isReady
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                Text(
                  'Bots use external tools through these servers. Remote '
                  'servers work everywhere; command servers only run on '
                  'desktop — never on a phone.',
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (state.servers.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No MCP servers yet.'),
                    ),
                  ),
                for (final server in state.servers) _ServerCard(server: server),
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

  Future<void> _editServer(
    BuildContext context,
    WidgetRef ref,
    McpServer? existing,
  ) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final targetController = TextEditingController(
      text: existing == null
          ? ''
          : existing.transport == McpTransportKind.remote
          ? existing.url
          : '${existing.command} ${existing.args.join(' ')}'.trim(),
    );
    var transport = existing?.transport ?? McpTransportKind.remote;
    final saved = await showDialog<McpServer>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add MCP server' : 'Edit server'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                SegmentedButton<McpTransportKind>(
                  segments: const [
                    ButtonSegment(
                      value: McpTransportKind.remote,
                      label: Text('Remote'),
                    ),
                    ButtonSegment(
                      value: McpTransportKind.stdio,
                      label: Text('Command'),
                    ),
                  ],
                  selected: {transport},
                  onSelectionChanged: (selection) =>
                      setDialogState(() => transport = selection.first),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: targetController,
                  decoration: InputDecoration(
                    labelText: transport == McpTransportKind.remote
                        ? 'Server URL'
                        : 'Command and arguments',
                    hintText: transport == McpTransportKind.remote
                        ? 'https://example.com/mcp'
                        : 'npx -y example-mcp-server',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text;
                if (name.trim().isEmpty) return;
                final target = targetController.text.trim();
                McpServer server = (existing ?? McpServer.create(name: name))
                    .copyWith(name: name, transport: transport);
                if (transport == McpTransportKind.remote) {
                  server = server.copyWith(url: target);
                } else {
                  final parts = target
                      .split(RegExp(r'\s+'))
                      .where((part) => part.isNotEmpty)
                      .toList();
                  server = server.copyWith(
                    command: parts.isEmpty ? '' : parts.first,
                    args: parts.length <= 1 ? const [] : parts.sublist(1),
                  );
                }
                Navigator.of(context).pop(server);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    targetController.dispose();
    if (saved != null) {
      await ref.read(mcpProvider.notifier).upsertServer(saved);
    }
  }
}

class _ServerCard extends ConsumerWidget {
  const _ServerCard({required this.server});

  final McpServer server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mcpProvider);
    final notifier = ref.read(mcpProvider.notifier);
    final caps = state.snapshot.capabilities[server.id];
    final connecting = state.connectingServerIds.contains(server.id);
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: ExpansionTile(
        leading: Icon(
          server.transport == McpTransportKind.remote
              ? Icons.cloud_outlined
              : Icons.terminal,
        ),
        title: Text(server.name),
        subtitle: Text(
          server.transport.label +
              (caps == null ? '' : ' · ${caps.tools.length} tools'),
        ),
        trailing: Switch(
          value: server.enabled,
          onChanged: (enabled) =>
              notifier.upsertServer(server.copyWith(enabled: enabled)),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (server.configError != null)
                  Text(
                    server.configError!,
                    style: textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: connecting
                          ? null
                          : () => notifier.connectServer(server.id),
                      icon: connecting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(caps == null ? 'Connect' : 'Reconnect'),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Delete server',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => notifier.removeServer(server.id),
                    ),
                  ],
                ),
                if (caps != null && caps.tools.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Tools', style: textTheme.titleSmall),
                  for (final tool in caps.tools)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            tool.name,
                            style: textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownButton<McpPermission>(
                          value: server.permissionFor(tool.name),
                          items: [
                            for (final permission in McpPermission.values)
                              DropdownMenuItem(
                                value: permission,
                                child: Text(permission.label),
                              ),
                          ],
                          onChanged: (permission) {
                            if (permission == null) return;
                            notifier.setToolPermission(
                              server.id,
                              tool.name,
                              permission,
                            );
                          },
                        ),
                      ],
                    ),
                ],
                if (caps != null && caps.tools.isEmpty)
                  Text(
                    'Connected, but this server offers no tools.',
                    style: textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
