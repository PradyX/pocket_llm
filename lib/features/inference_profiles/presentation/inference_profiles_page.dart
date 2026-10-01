import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/settings/inference_settings_provider.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart'
    show formatTokens;
import 'package:pocket_llm/features/inference_profiles/application/inference_profiles_controller.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile.dart';

/// Lists built-in and custom inference profiles and lets one be activated.
class InferenceProfilesPage extends ConsumerWidget {
  const InferenceProfilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(inferenceProfilesProvider);
    final notifier = ref.read(inferenceProfilesProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Inference Profiles')),
      floatingActionButton: state.isReadOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEditor(context, ref, null),
              icon: const Icon(Icons.add),
              label: const Text('New profile'),
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
                  Text(
                    'Profiles bundle runtime settings',
                    style: textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Context size, threads, GPU offload and sampling. The '
                    'active profile is used for every request, and a profile '
                    'only changes what you set in it — everything else keeps '
                    'the app default for this device.',
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
          _ActiveProfilePreview(profile: state.activeProfile),
          const SizedBox(height: 16),
          Text('Built-in', style: textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Shipped with Pocket LLM. Duplicate one to change it.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          for (final profile in state.builtInProfiles)
            _ProfileTile(
              profile: profile,
              isActive: profile.id == state.activeProfileId,
              onSelect: () => notifier.select(profile.id),
              onDuplicate: () => _duplicate(context, ref, profile),
            ),
          const SizedBox(height: 16),
          Text('Custom', style: textTheme.titleSmall),
          const SizedBox(height: 4),
          if (state.customProfiles.isEmpty)
            Text(
              'No custom profiles yet. Create one for a device, a model size '
              'or a workflow you keep coming back to.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          for (final profile in state.customProfiles)
            _ProfileTile(
              profile: profile,
              isActive: profile.id == state.activeProfileId,
              onSelect: () => notifier.select(profile.id),
              onDuplicate: () => _duplicate(context, ref, profile),
              onEdit: state.isReadOnly
                  ? null
                  : () => _openEditor(context, ref, profile),
              onDelete: state.isReadOnly
                  ? null
                  : () => _confirmDelete(context, ref, profile),
            ),
        ],
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref,
    InferenceProfile? profile,
  ) async {
    final saved = await Navigator.of(context).push<InferenceProfile>(
      MaterialPageRoute(
        builder: (_) => InferenceProfileEditorPage(profile: profile),
      ),
    );
    if (saved == null || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved "${saved.name}".'),
        action: SnackBarAction(
          label: 'Activate',
          onPressed: () =>
              ref.read(inferenceProfilesProvider.notifier).select(saved.id),
        ),
      ),
    );
  }

  Future<void> _duplicate(
    BuildContext context,
    WidgetRef ref,
    InferenceProfile profile,
  ) async {
    final copy = await ref
        .read(inferenceProfilesProvider.notifier)
        .duplicateProfile(profile);
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
    InferenceProfile profile,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${profile.name}"?'),
        content: const Text(
          'The profile is removed from this device. Conversations are not '
          'affected.',
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
        .read(inferenceProfilesProvider.notifier)
        .deleteProfile(profile.id);
    if (!context.mounted) return;
    if (!removed) {
      _showError(context, ref);
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Deleted "${profile.name}".')));
  }

  void _showError(BuildContext context, WidgetRef ref) {
    final message = ref.read(inferenceProfilesProvider).errorMessage;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message ?? 'That did not work.')));
  }
}

/// What the active profile resolves to on this device.
class _ActiveProfilePreview extends ConsumerWidget {
  const _ActiveProfilePreview({required this.profile});

  final InferenceProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = ref
        .read(inferenceProfileResolverProvider)
        .resolve(
          profile: profile,
          settings: ref.watch(inferenceSettingsProvider),
        );
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Active: ${profile.name}',
                    style: textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(resolved.summaryLabel, style: textTheme.bodySmall),
            const SizedBox(height: 2),
            Text(resolved.outputLabel, style: textTheme.bodySmall),
            for (final note in resolved.notes) ...[
              const SizedBox(height: 6),
              Text(
                '• $note',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.isActive,
    required this.onSelect,
    required this.onDuplicate,
    this.onEdit,
    this.onDelete,
  });

  final InferenceProfile profile;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback onDuplicate;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: ListTile(
        selected: isActive,
        leading: Icon(
          isActive ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: isActive ? colorScheme.primary : colorScheme.onSurfaceVariant,
        ),
        title: Text(profile.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(profile.summaryLabel, style: textTheme.bodySmall),
            if (profile.description.isNotEmpty)
              Text(
                profile.description,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        onTap: onSelect,
        trailing: PopupMenuButton<_ProfileAction>(
          tooltip: 'Profile actions',
          onSelected: (action) {
            switch (action) {
              case _ProfileAction.duplicate:
                onDuplicate();
              case _ProfileAction.edit:
                onEdit?.call();
              case _ProfileAction.delete:
                onDelete?.call();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: _ProfileAction.duplicate,
              child: Text('Duplicate'),
            ),
            if (onEdit != null)
              const PopupMenuItem(
                value: _ProfileAction.edit,
                child: Text('Edit'),
              ),
            if (onDelete != null)
              const PopupMenuItem(
                value: _ProfileAction.delete,
                child: Text('Delete'),
              ),
          ],
        ),
      ),
    );
  }
}

enum _ProfileAction { duplicate, edit, delete }

/// Editor for a custom profile; returns the saved profile when popped.
class InferenceProfileEditorPage extends ConsumerStatefulWidget {
  const InferenceProfileEditorPage({super.key, this.profile});

  /// Profile to edit, or null to create a new one.
  final InferenceProfile? profile;

  @override
  ConsumerState<InferenceProfileEditorPage> createState() =>
      _InferenceProfileEditorPageState();
}

class _InferenceProfileEditorPageState
    extends ConsumerState<InferenceProfileEditorPage> {
  static const List<int> _contextChoices = [
    512,
    1024,
    2048,
    4096,
    8192,
    16384,
    32768,
  ];
  static const List<int> _batchChoices = [64, 128, 256, 512, 1024, 2048, 4096];
  static const List<int> _outputChoices = [64, 128, 256, 512, 1024, 2048, 4096];

  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late InferenceProfile _draft;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.profile ?? InferenceProfile.create(name: 'Custom profile');
    _nameController = TextEditingController(text: _draft.name);
    _descriptionController = TextEditingController(text: _draft.description);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final resolved = ref
        .read(inferenceProfileResolverProvider)
        .resolve(
          profile: _draft,
          settings: ref.watch(inferenceSettingsProvider),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile == null ? 'New profile' : 'Edit profile'),
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
                  Text('On this device', style: textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text(resolved.summaryLabel, style: textTheme.bodySmall),
                  Text(resolved.outputLabel, style: textTheme.bodySmall),
                  for (final note in resolved.notes) ...[
                    const SizedBox(height: 6),
                    Text(
                      '• $note',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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
          const SizedBox(height: 16),
          _overrideGroup(
            title: 'Context size',
            subtitle: 'How much conversation the model can see at once',
            enabled: _draft.contextTokens != null,
            onToggle: (enabled) => setState(() {
              _draft = enabled
                  ? _draft.copyWith(contextTokens: 4096)
                  : _draft.copyWith(clearContextTokens: true);
            }),
            child: _choiceSlider(
              label: 'Context window',
              choices: _contextChoices,
              value: _draft.contextTokens ?? 4096,
              onChanged: (value) => setState(
                () => _draft = _draft.copyWith(contextTokens: value),
              ),
            ),
          ),
          _overrideGroup(
            title: 'Prompt batch size',
            subtitle: 'Tokens processed per batch while reading the prompt',
            enabled: _draft.batchTokens != null,
            onToggle: (enabled) => setState(() {
              _draft = enabled
                  ? _draft.copyWith(batchTokens: 512)
                  : _draft.copyWith(clearBatchTokens: true);
            }),
            child: _choiceSlider(
              label: 'Batch size',
              choices: _batchChoices,
              value: _draft.batchTokens ?? 512,
              onChanged: (value) =>
                  setState(() => _draft = _draft.copyWith(batchTokens: value)),
            ),
          ),
          _overrideGroup(
            title: 'Threads',
            subtitle: 'Compute threads for generation and prompt processing',
            enabled: _draft.threads != null || _draft.threadsBatch != null,
            onToggle: (enabled) => setState(() {
              _draft = enabled
                  ? _draft.copyWith(threads: 4, threadsBatch: 4)
                  : _draft.copyWith(
                      clearThreads: true,
                      clearThreadsBatch: true,
                    );
            }),
            child: Column(
              children: [
                _intSlider(
                  label: 'Generation threads',
                  value: _draft.threads ?? 4,
                  min: 1,
                  max: 16,
                  onChanged: (value) =>
                      setState(() => _draft = _draft.copyWith(threads: value)),
                ),
                _intSlider(
                  label: 'Prompt threads',
                  value: _draft.threadsBatch ?? 4,
                  min: 1,
                  max: 16,
                  onChanged: (value) => setState(
                    () => _draft = _draft.copyWith(threadsBatch: value),
                  ),
                ),
              ],
            ),
          ),
          _overrideGroup(
            title: 'GPU offload',
            subtitle: 'Layers kept on the GPU and where the KV cache lives',
            enabled: _draft.gpuLayers != null || _draft.offloadKqv != null,
            onToggle: (enabled) => setState(() {
              _draft = enabled
                  ? _draft.copyWith(gpuLayers: 32, offloadKqv: true)
                  : _draft.copyWith(
                      clearGpuLayers: true,
                      clearOffloadKqv: true,
                    );
            }),
            child: Column(
              children: [
                _intSlider(
                  label: 'GPU layers',
                  value: _draft.gpuLayers ?? 32,
                  min: 0,
                  max: 200,
                  step: 8,
                  onChanged: (value) => setState(
                    () => _draft = _draft.copyWith(gpuLayers: value),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep KV cache on GPU'),
                  value: _draft.offloadKqv ?? false,
                  onChanged: (value) => setState(
                    () => _draft = _draft.copyWith(offloadKqv: value),
                  ),
                ),
              ],
            ),
          ),
          _overrideGroup(
            title: 'Sampling',
            subtitle: 'Overrides the sampling settings in Settings',
            enabled:
                _draft.temperature != null ||
                _draft.topP != null ||
                _draft.topK != null,
            onToggle: (enabled) => setState(() {
              _draft = enabled
                  ? _draft.copyWith(temperature: 0.7, topP: 0.9, topK: 40)
                  : _draft.copyWith(
                      clearTemperature: true,
                      clearTopP: true,
                      clearTopK: true,
                    );
            }),
            child: Column(
              children: [
                _doubleSlider(
                  label: 'Temperature',
                  value: _draft.temperature ?? 0.7,
                  min: 0,
                  max: 2,
                  onChanged: (value) => setState(
                    () => _draft = _draft.copyWith(temperature: value),
                  ),
                ),
                _doubleSlider(
                  label: 'Top-p',
                  value: _draft.topP ?? 0.9,
                  min: 0.1,
                  max: 1,
                  onChanged: (value) =>
                      setState(() => _draft = _draft.copyWith(topP: value)),
                ),
                _intSlider(
                  label: 'Top-k',
                  value: _draft.topK ?? 40,
                  min: 1,
                  max: 100,
                  onChanged: (value) =>
                      setState(() => _draft = _draft.copyWith(topK: value)),
                ),
              ],
            ),
          ),
          _overrideGroup(
            title: 'Answer length',
            subtitle: 'Maximum tokens generated for one answer',
            enabled: _draft.maxOutputTokens != null,
            onToggle: (enabled) => setState(() {
              _draft = enabled
                  ? _draft.copyWith(maxOutputTokens: 512)
                  : _draft.copyWith(clearMaxOutputTokens: true);
            }),
            child: _choiceSlider(
              label: 'Maximum output',
              choices: _outputChoices,
              value: _draft.maxOutputTokens ?? 512,
              onChanged: (value) => setState(
                () => _draft = _draft.copyWith(maxOutputTokens: value),
              ),
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
      ).showSnackBar(const SnackBar(content: Text('Give the profile a name.')));
      return;
    }

    setState(() => _isSaving = true);
    final saved = await ref
        .read(inferenceProfilesProvider.notifier)
        .saveProfile(
          _draft.copyWith(
            name: name,
            description: _descriptionController.text.trim(),
          ),
        );
    if (!mounted) return;
    setState(() => _isSaving = false);

    if (saved == null) {
      final message = ref.read(inferenceProfilesProvider).errorMessage;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message ?? 'Could not save the profile.')),
      );
      return;
    }
    Navigator.of(context).pop(saved);
  }

  Widget _overrideGroup({
    required String title,
    required String subtitle,
    required bool enabled,
    required ValueChanged<bool> onToggle,
    required Widget child,
  }) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SwitchListTile(
            title: Text(title),
            subtitle: Text(subtitle),
            value: enabled,
            onChanged: onToggle,
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: child,
            ),
        ],
      ),
    );
  }

  /// A labelled slider whose steps are the given token counts.
  Widget _choiceSlider({
    required String label,
    required List<int> choices,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    var index = choices.indexOf(value);
    if (index < 0) {
      // A stored value outside the offered steps still edits sensibly.
      index = 0;
      for (var i = 0; i < choices.length; i++) {
        if (choices[i] <= value) index = i;
      }
    }
    return _sliderRow(
      label: label,
      valueLabel: formatTokens(choices[index]),
      child: Slider(
        value: index.toDouble(),
        min: 0,
        max: (choices.length - 1).toDouble(),
        divisions: choices.length - 1,
        label: formatTokens(choices[index]),
        onChanged: (raw) =>
            onChanged(choices[raw.round().clamp(0, choices.length - 1)]),
      ),
    );
  }

  Widget _intSlider({
    required String label,
    required int value,
    required int min,
    required int max,
    int step = 1,
    required ValueChanged<int> onChanged,
  }) {
    final divisions = ((max - min) / step).round();
    final current = value.clamp(min, max);
    return _sliderRow(
      label: label,
      valueLabel: '$current',
      child: Slider(
        value: current.toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: divisions <= 0 ? null : divisions,
        label: '$current',
        onChanged: (raw) => onChanged(raw.round().clamp(min, max)),
      ),
    );
  }

  Widget _doubleSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    double step = 0.05,
    required ValueChanged<double> onChanged,
  }) {
    final divisions = ((max - min) / step).round();
    final current = value.clamp(min, max).toDouble();
    return _sliderRow(
      label: label,
      valueLabel: current.toStringAsFixed(2),
      child: Slider(
        value: current,
        min: min,
        max: max,
        divisions: divisions <= 0 ? null : divisions,
        label: current.toStringAsFixed(2),
        onChanged: onChanged,
      ),
    );
  }

  Widget _sliderRow({
    required String label,
    required String valueLabel,
    required Widget child,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: textTheme.bodyMedium)),
            Text(valueLabel, style: textTheme.bodyMedium),
          ],
        ),
        child,
      ],
    );
  }
}
