import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart'
    show TokenEstimator, formatTokens;
import 'package:pocket_llm/features/inference_profiles/application/inference_profiles_controller.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/personas/application/personas_controller.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';
import 'package:pocket_llm/features/personas/domain/persona_prompt.dart';

/// Lists built-in and custom personas and chooses the default for new chats.
class PersonasPage extends ConsumerWidget {
  const PersonasPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(personasProvider);
    final notifier = ref.read(personasProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Personas'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Export personas to clipboard',
            onPressed: () => _exportToClipboard(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.content_paste_go_outlined),
            tooltip: 'Import personas from clipboard',
            onPressed: state.isReadOnly
                ? null
                : () => _importFromClipboard(context, ref),
          ),
        ],
      ),
      floatingActionButton: state.isReadOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEditor(context, ref, null),
              icon: const Icon(Icons.add),
              label: const Text('New persona'),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          Card(
            color: colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Personas shape the voice', style: textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    'A persona is a system prompt, plus the model and inference '
                    'profile it prefers. Each conversation can use its own '
                    'persona, and switching one never touches chat history.',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          if (state.errorMessage != null)
            Card(
              color: colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  Icons.warning_amber_rounded,
                  color: colorScheme.onErrorContainer,
                ),
                title: Text(
                  state.errorMessage!,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                  ),
                ),
                trailing: IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close),
                  onPressed: notifier.clearError,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text('Built-in', style: textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Shipped with Pocket LLM. Duplicate one to change it.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          for (final persona in state.builtInPersonas)
            _PersonaTile(
              persona: persona,
              isDefault: persona.id == state.defaultPersonaId,
              onSetDefault: () => notifier.selectDefault(persona.id),
              onDuplicate: () => _duplicate(context, ref, persona),
              onExport: () => _exportToClipboard(
                context,
                ref,
                personaId: persona.id,
                personaName: persona.name,
              ),
            ),
          const SizedBox(height: 16),
          Text('Custom', style: textTheme.titleSmall),
          const SizedBox(height: 4),
          if (state.customPersonas.isEmpty)
            Text(
              'No custom personas yet. Create one for a voice, a project or a '
              'recurring style you keep re-typing.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          for (final persona in state.customPersonas)
            _PersonaTile(
              persona: persona,
              isDefault: persona.id == state.defaultPersonaId,
              onSetDefault: () => notifier.selectDefault(persona.id),
              onDuplicate: () => _duplicate(context, ref, persona),
              onExport: () => _exportToClipboard(
                context,
                ref,
                personaId: persona.id,
                personaName: persona.name,
              ),
              onEdit: state.isReadOnly
                  ? null
                  : () => _openEditor(context, ref, persona),
              onDelete: state.isReadOnly
                  ? null
                  : () => _confirmDelete(context, ref, persona),
            ),
        ],
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref,
    Persona? persona,
  ) async {
    final saved = await Navigator.of(context).push<Persona>(
      MaterialPageRoute(builder: (_) => PersonaEditorPage(persona: persona)),
    );
    if (saved == null || !context.mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved "${saved.name}".')));
  }

  Future<void> _duplicate(
    BuildContext context,
    WidgetRef ref,
    Persona persona,
  ) async {
    final copy = await ref
        .read(personasProvider.notifier)
        .duplicatePersona(persona);
    if (!context.mounted) return;
    if (copy == null) {
      _showError(context, ref);
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Created "${copy.name}".')));
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Persona persona,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${persona.name}"?'),
        content: const Text(
          'The persona is removed from this device. Conversations that used it '
          'fall back to the default persona, and their history is untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final removed = await ref
        .read(personasProvider.notifier)
        .deletePersona(persona.id);
    if (!context.mounted) return;
    if (!removed) {
      _showError(context, ref);
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Deleted "${persona.name}".')));
  }

  /// Copies one persona, or every persona, to the clipboard as JSON.
  Future<void> _exportToClipboard(
    BuildContext context,
    WidgetRef ref, {
    String? personaId,
    String? personaName,
  }) async {
    try {
      final json = ref
          .read(personasProvider.notifier)
          .exportJson(personaId: personaId);
      await Clipboard.setData(ClipboardData(text: json));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            personaName == null
                ? 'Personas copied as JSON.'
                : '"$personaName" copied as JSON.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
    }
  }

  /// Reads export JSON from a paste field and stores it as custom personas.
  Future<void> _importFromClipboard(BuildContext context, WidgetRef ref) async {
    final inputController = TextEditingController();
    final rawJson = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import personas'),
        content: TextField(
          controller: inputController,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Paste exported persona JSON here',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(inputController.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    inputController.dispose();

    if (rawJson == null || rawJson.trim().isEmpty || !context.mounted) return;
    try {
      final imported = await ref
          .read(personasProvider.notifier)
          .importJson(rawJson);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            imported.isEmpty
                ? 'Nothing to import.'
                : 'Imported ${imported.length} persona(s).',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $error')));
    }
  }

  void _showError(BuildContext context, WidgetRef ref) {
    final message = ref.read(personasProvider).errorMessage;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message ?? 'That did not work.')));
  }
}

class _PersonaTile extends StatelessWidget {
  const _PersonaTile({
    required this.persona,
    required this.isDefault,
    required this.onSetDefault,
    required this.onDuplicate,
    required this.onExport,
    this.onEdit,
    this.onDelete,
  });

  final Persona persona;
  final bool isDefault;
  final VoidCallback onSetDefault;
  final VoidCallback onDuplicate;
  final VoidCallback onExport;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: ListTile(
        selected: isDefault,
        leading: Icon(
          isDefault ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: isDefault ? colorScheme.primary : colorScheme.onSurfaceVariant,
        ),
        title: Text(persona.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (persona.description.isNotEmpty)
              Text(persona.description, style: textTheme.bodySmall),
            Text(
              persona.promptLabel,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        onTap: onSetDefault,
        trailing: PopupMenuButton<_PersonaAction>(
          tooltip: 'Persona actions',
          onSelected: (action) {
            switch (action) {
              case _PersonaAction.duplicate:
                onDuplicate();
              case _PersonaAction.export:
                onExport();
              case _PersonaAction.edit:
                onEdit?.call();
              case _PersonaAction.delete:
                onDelete?.call();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: _PersonaAction.duplicate,
              child: Text('Duplicate'),
            ),
            const PopupMenuItem(
              value: _PersonaAction.export,
              child: Text('Export'),
            ),
            if (onEdit != null)
              const PopupMenuItem(
                value: _PersonaAction.edit,
                child: Text('Edit'),
              ),
            if (onDelete != null)
              const PopupMenuItem(
                value: _PersonaAction.delete,
                child: Text('Delete'),
              ),
          ],
        ),
      ),
    );
  }
}

enum _PersonaAction { duplicate, export, edit, delete }

/// Editor for a custom persona; returns the saved persona when popped.
class PersonaEditorPage extends ConsumerStatefulWidget {
  const PersonaEditorPage({super.key, this.persona});

  /// Persona to edit, or null to create a new one.
  final Persona? persona;

  @override
  ConsumerState<PersonaEditorPage> createState() => _PersonaEditorPageState();
}

class _PersonaEditorPageState extends ConsumerState<PersonaEditorPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _promptController;
  late Persona _draft;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.persona ?? Persona.create(name: 'Custom persona');
    _nameController = TextEditingController(text: _draft.name);
    _descriptionController = TextEditingController(text: _draft.description);
    _promptController = TextEditingController(text: _draft.systemPrompt);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final profiles = ref.watch(inferenceProfilesProvider);
    final downloadedModels = ref
        .watch(modelSelectionControllerProvider)
        .models
        .where((model) => model.isDownloaded)
        .toList(growable: false);
    final promptTokens = TokenEstimator.estimateText(
      composePersonaSystemPrompt(persona: _draft),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.persona == null ? 'New persona' : 'Edit persona'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: Text(_isSaving ? 'Saving...' : 'Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Card(
            color: colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Prompt budget', style: textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(
                    'This prompt is sent with every request, around '
                    '${formatTokens(promptTokens)} tokens. Leave it empty to use '
                    'the app default assistant prompt.',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                setState(() => _draft = _draft.copyWith(name: value)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                setState(() => _draft = _draft.copyWith(description: value)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptController,
            minLines: 6,
            maxLines: 14,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'System prompt',
              alignLabelWithHint: true,
              helperText:
                  'Instructions the model follows in this conversation.',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                setState(() => _draft = _draft.copyWith(systemPrompt: value)),
          ),
          const SizedBox(height: 16),
          Text('Preferences', style: textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Both are optional. Unset means "whatever the app is set to".',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: _draft.defaultModelId,
            decoration: const InputDecoration(
              labelText: 'Preferred model',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('App default'),
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
                setState(() => _draft = _draft.copyWith(defaultModelId: value)),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: _draft.inferenceProfileId,
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
            onChanged: (value) => setState(
              () => _draft = _draft.copyWith(inferenceProfileId: value),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Give the persona a name.')));
      return;
    }

    setState(() => _isSaving = true);
    final saved = await ref
        .read(personasProvider.notifier)
        .savePersona(
          _draft.copyWith(
            name: name,
            description: _descriptionController.text.trim(),
            systemPrompt: _promptController.text,
          ),
        );
    if (!mounted) return;
    setState(() => _isSaving = false);

    if (saved == null) {
      final message = ref.read(personasProvider).errorMessage;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message ?? 'Could not save the persona.')),
      );
      return;
    }
    Navigator.of(context).pop(saved);
  }
}
