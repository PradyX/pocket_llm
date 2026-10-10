import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/bots/application/bots_controller.dart';
import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/bots/presentation/bot_editor_page.dart';

/// The bot registry: templates to duplicate, custom bots to shape.
///
/// Road Map 2 Phase 2.4. A bot is identity (soul), capabilities (skills,
/// MCP, tool permissions) and memory scope — not just a system prompt. The
/// editor owns the details; this screen owns the list.
class BotsPage extends ConsumerWidget {
  const BotsPage({super.key});

  Future<void> _askName(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New bot'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Bot name'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final bot = await ref.read(botsProvider.notifier).createBot(name.trim());
    if (bot != null && context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => BotEditorPage(botId: bot.id)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(botsProvider);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Bots')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _askName(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New bot'),
      ),
      body: !state.isReady
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                Text(
                  'Bots are specialists with a Soul: identity and operating '
                  'principles that survive every compaction. Duplicate a '
                  'template to shape your own.',
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                for (final bot in state.bots) _BotTile(bot: bot),
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

class _BotTile extends ConsumerWidget {
  const _BotTile({required this.bot});

  final Bot bot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(botsProvider.notifier);
    return Card(
      child: ListTile(
        leading: Text(bot.icon, style: const TextStyle(fontSize: 24)),
        title: Text(bot.name),
        subtitle: Text(
          bot.description.isEmpty
              ? (bot.isBuiltIn ? 'Template' : 'Custom bot')
              : bot.description,
        ),
        trailing: bot.isBuiltIn
            ? IconButton(
                tooltip: 'Duplicate template',
                icon: const Icon(Icons.content_copy),
                onPressed: () async {
                  final copy = await notifier.duplicateTemplate(bot.id);
                  if (copy != null && context.mounted) {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => BotEditorPage(botId: copy.id),
                      ),
                    );
                  }
                },
              )
            : PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'delete') notifier.removeBot(bot.id);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
        onTap: bot.isBuiltIn
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => BotEditorPage(botId: bot.id),
                ),
              ),
      ),
    );
  }
}
