import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/skills/application/skills_controller.dart';
import 'package:pocket_llm/features/skills/domain/skill.dart';

/// The skill registry: what is installed, what is on, and what each skill
/// may need.
///
/// Road Map 2 Phase 2.2. Installing costs no context: only skills the
/// selector deems relevant to the current task are loaded into a prompt,
// and supporting resources load on demand from there.
class SkillsPage extends ConsumerWidget {
  const SkillsPage({super.key});

  Future<void> _importFile(BuildContext context, WidgetRef ref) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Skill', extensions: ['md']),
      ],
    );
    if (file == null) return;
    final text = await File(file.path).readAsString();
    final name = file.name.endsWith('.md')
        ? file.name.substring(0, file.name.length - 3)
        : file.name;
    final skill = await ref
        .read(skillsProvider.notifier)
        .importSkillText(text, sourceName: name);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          skill == null
              ? 'Could not save the skill.'
              : 'Imported ${skill.name}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(skillsProvider);
    final notifier = ref.read(skillsProvider.notifier);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Skills')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _importFile(context, ref),
        icon: const Icon(Icons.upload_file),
        label: const Text('Import SKILL.md'),
      ),
      body: !state.isReady
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                Text(
                  'Skills are reusable procedures a bot can follow. Only '
                  'skills relevant to the current task are loaded, so '
                  'installing one costs no context until it is needed.',
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (state.skills.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No skills yet. Import a SKILL.md file.'),
                    ),
                  ),
                for (final skill in state.skills)
                  _SkillTile(
                    skill: skill,
                    onToggle: (enabled) =>
                        notifier.setEnabled(skill.id, enabled),
                    onDelete: skill.isBuiltIn
                        ? null
                        : () => notifier.removeSkill(skill.id),
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

class _SkillTile extends StatelessWidget {
  const _SkillTile({
    required this.skill,
    required this.onToggle,
    required this.onDelete,
  });

  final Skill skill;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: ExpansionTile(
        leading: Icon(
          skill.source == SkillSource.builtIn
              ? Icons.auto_awesome
              : Icons.extension_outlined,
        ),
        title: Text(skill.name),
        subtitle: Text(
          skill.description.isEmpty
              ? skill.source.label
              : '${skill.source.label} · ${skill.description}',
        ),
        trailing: Switch(value: skill.enabled, onChanged: onToggle),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (skill.requiredCapabilities.isNotEmpty)
                  Text(
                    'Needs: ${skill.requiredCapabilities.join(', ')}',
                    style: textTheme.bodySmall,
                  ),
                if (skill.resourceNames.isNotEmpty)
                  Text(
                    'Resources: ${skill.resourceNames.join(', ')}',
                    style: textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                Text(
                  skill.body,
                  style: textTheme.bodySmall,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                ),
                if (onDelete != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
