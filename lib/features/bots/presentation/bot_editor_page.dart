import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/bots/application/bots_controller.dart';
import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/inference_profiles/application/inference_profiles_controller.dart';
import 'package:pocket_llm/features/mcp/application/mcp_controller.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/skills/application/skills_controller.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';

/// Edits one custom bot: identity, soul, model and profile choice, skills,
/// MCP servers, tool permissions, memory scope and workspaces.
class BotEditorPage extends ConsumerStatefulWidget {
  const BotEditorPage({super.key, required this.botId});

  final String botId;

  @override
  ConsumerState<BotEditorPage> createState() => _BotEditorPageState();
}

class _BotEditorPageState extends ConsumerState<BotEditorPage> {
  late TextEditingController _name;
  late TextEditingController _icon;
  late TextEditingController _description;
  late TextEditingController _soul;
  late TextEditingController _permissions;
  var _initializedFor = '';

  @override
  void dispose() {
    _name.dispose();
    _icon.dispose();
    _description.dispose();
    _soul.dispose();
    _permissions.dispose();
    super.dispose();
  }

  void _initFrom(Bot bot) {
    if (_initializedFor == bot.id) return;
    _initializedFor = bot.id;
    _name = TextEditingController(text: bot.name);
    _icon = TextEditingController(text: bot.icon);
    _description = TextEditingController(text: bot.description);
    _soul = TextEditingController(text: bot.soul);
    _permissions = TextEditingController(
      text: (bot.toolPermissions.toList()..sort()).join(', '),
    );
  }

  Future<void> _save(Bot bot) async {
    final permissions = _permissions.text
        .split(RegExp(r'[,\s]+'))
        .map((permission) => permission.trim())
        .where((permission) => permission.isNotEmpty)
        .toSet();
    final updated = bot.copyWith(
      name: _name.text,
      icon: _icon.text,
      description: _description.text,
      soul: _soul.text,
      toolPermissions: permissions,
    );
    final saved = await ref.read(botsProvider.notifier).updateBot(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved ? 'Bot saved.' : 'Could not save the bot.')),
    );
    if (saved) _initializedFor = '';
  }

  @override
  Widget build(BuildContext context) {
    final bots = ref.watch(botsProvider);
    final bot = bots.botById(widget.botId);
    if (bot == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit bot')),
        body: const Center(child: Text('This bot no longer exists.')),
      );
    }
    _initFrom(bot);

    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final skills = ref.watch(skillsProvider);
    final mcp = ref.watch(mcpProvider);
    final workspaces = ref.watch(workspacesProvider);
    final profiles = ref.watch(inferenceProfilesProvider);
    final downloadedModels = ref
        .watch(modelSelectionControllerProvider)
        .models
        .where((model) => model.isDownloaded)
        .toList(growable: false);
    final soulTokens = TokenEstimator.estimateText(_soul.text);

    Future<void> update(Bot updated) =>
        ref.read(botsProvider.notifier).updateBot(updated);

    return Scaffold(
      appBar: AppBar(
        title: Text('Edit ${bot.name}'),
        actions: [
          FilledButton.tonal(
            onPressed: () => _save(bot),
            child: const Text('Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _icon,
                  decoration: const InputDecoration(
                    labelText: 'Icon (emoji)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 5,
                child: TextField(
                  controller: _description,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _soul,
            minLines: 8,
            maxLines: 16,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Soul',
              alignLabelWithHint: true,
              helperText:
                  'Identity and operating principles (~$soulTokens tokens). '
                  'Survives every compaction.',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Text('Run preferences', style: textTheme.titleSmall),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: bot.modelId,
            decoration: const InputDecoration(
              labelText: 'Preferred model',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Conversation model'),
              ),
              for (final model in downloadedModels)
                DropdownMenuItem<String?>(
                  value: model.id,
                  child: Text(
                    '${model.name} · ${model.parameterSize}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) =>
                update(bot.copyWith(modelId: value, clearModel: value == null)),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: bot.inferenceProfileId,
            decoration: const InputDecoration(
              labelText: 'Inference profile',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('App active profile'),
              ),
              for (final profile in profiles.profiles)
                DropdownMenuItem<String?>(
                  value: profile.id,
                  child: Text(profile.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => update(
              bot.copyWith(
                inferenceProfileId: value,
                clearProfile: value == null,
              ),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<BotMemoryScope>(
            initialValue: bot.memoryScope,
            decoration: const InputDecoration(
              labelText: 'Memory scope',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final scope in BotMemoryScope.values)
                DropdownMenuItem(value: scope, child: Text(scope.label)),
            ],
            onChanged: (scope) {
              if (scope != null) update(bot.copyWith(memoryScope: scope));
            },
          ),
          const SizedBox(height: 16),
          Text('Skills', style: textTheme.titleSmall),
          if (!skills.isReady)
            const LinearProgressIndicator()
          else if (skills.skills.isEmpty)
            Text('No skills installed yet.', style: textTheme.bodySmall)
          else
            for (final skill in skills.skills)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(skill.name),
                subtitle: skill.enabled
                    ? null
                    : const Text('Disabled in the registry'),
                value: bot.skillIds.contains(skill.id),
                onChanged: !skill.enabled
                    ? null
                    : (selected) {
                        final ids = bot.skillIds.toSet();
                        if (selected == true) {
                          ids.add(skill.id);
                        } else {
                          ids.remove(skill.id);
                        }
                        update(bot.copyWith(skillIds: ids.toList()));
                      },
              ),
          const SizedBox(height: 8),
          Text('MCP servers', style: textTheme.titleSmall),
          if (!mcp.isReady)
            const LinearProgressIndicator()
          else if (mcp.servers.isEmpty)
            Text('No MCP servers configured yet.', style: textTheme.bodySmall)
          else
            for (final server in mcp.servers)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(server.name),
                subtitle: !server.enabled ? const Text('Disabled') : null,
                value: bot.mcpServerIds.contains(server.id),
                onChanged: !server.enabled
                    ? null
                    : (selected) {
                        final ids = bot.mcpServerIds.toSet();
                        if (selected == true) {
                          ids.add(server.id);
                        } else {
                          ids.remove(server.id);
                        }
                        update(bot.copyWith(mcpServerIds: ids.toList()));
                      },
              ),
          const SizedBox(height: 8),
          TextField(
            controller: _permissions,
            decoration: const InputDecoration(
              labelText: 'Tool permissions',
              helperText:
                  'Comma-separated capabilities, e.g. filesystem:read. '
                  'A skill needing anything else stays unavailable.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text('Workspaces', style: textTheme.titleSmall),
          Text(
            'Empty means every workspace. Otherwise the bot only sees the '
            'checked ones.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (workspaces.isReady)
            for (final workspace in workspaces.workspaces)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(workspace.name),
                value: bot.workspaceIds.contains(workspace.id),
                onChanged: (selected) {
                  final ids = bot.workspaceIds.toSet();
                  if (selected == true) {
                    ids.add(workspace.id);
                  } else {
                    ids.remove(workspace.id);
                  }
                  update(bot.copyWith(workspaceIds: ids.toList()));
                },
              ),
        ],
      ),
    );
  }
}
