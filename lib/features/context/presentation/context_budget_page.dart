import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart'
    show formatTokens;
import 'package:pocket_llm/features/context/application/context_budget_controller.dart';
import 'package:pocket_llm/features/context/domain/context_budget.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';

/// Chooses how much of a model's context window one request may use.
///
/// Road Map 2 Phase 2.1. Auto follows the model, the active inference profile
/// and this platform; Manual caps the prompt. The screen states the window a
/// request would really get, and it never claims the cap is honoured when the
/// model or platform lowers it further.
class ContextBudgetPage extends ConsumerWidget {
  const ContextBudgetPage({super.key});

  /// Caps offered by the slider, from the smallest sensible window upwards.
  ///
  /// A power-of-two ladder is what the runtime and the GGUF files themselves
  /// use, so every choice is one a model can actually be loaded with.
  static const List<int> capOptions = [
    512,
    1024,
    2048,
    4096,
    8192,
    16384,
    32768,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(contextBudgetProvider);
    final notifier = ref.read(contextBudgetProvider.notifier);
    final window = ref.watch(selectedContextWindowProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final budget = state.budget;

    // The same three inputs a request uses, described in the words the screen
    // shows, so the figures here cannot drift from what is really sent.
    final outcome = window == null
        ? null
        : describeContextBudget(
            budget: budget,
            runtimeContextTokens: window.resolvedConfig.contextTokens,
            declaredContextTokens: window.declaredContextTokens,
            reservedOutputTokens: window.resolvedConfig.maxOutputTokens,
          );

    return Scaffold(
      appBar: AppBar(title: const Text('Context')),
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
                    'Every request is built against a token budget',
                    style: textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The system prompt, the summary of earlier turns, any '
                    'retrieved documents and the recent messages all share one '
                    'budget, and the space kept for the answer is reserved '
                    'before anything else. Older turns that no longer fit are '
                    'condensed locally instead of being dropped.',
                    style: textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The model is still loaded with the window the active '
                    'inference profile asks for: a smaller budget only sends '
                    'fewer tokens, it does not change how the model runs.',
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
          Card(
            clipBehavior: Clip.antiAlias,
            child: RadioGroup<ContextBudgetMode>(
              groupValue: budget.mode,
              onChanged: state.isReadOnly
                  ? (value) {}
                  : (value) {
                      if (value == null) return;
                      notifier.setMode(value);
                    },
              child: Column(
                children: [
                  const RadioListTile<ContextBudgetMode>(
                    value: ContextBudgetMode.auto,
                    title: Text('Automatic (recommended)'),
                    subtitle: Text(
                      "Use whatever the model's declared limit, the active "
                      'inference profile and this platform allow.',
                    ),
                  ),
                  const Divider(height: 1),
                  const RadioListTile<ContextBudgetMode>(
                    value: ContextBudgetMode.manual,
                    title: Text('Manual limit'),
                    subtitle: Text(
                      'Cap how much of the window a request may use. Useful for '
                      'keeping replies fast on a phone-class device.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (budget.isManual) ...[
            const SizedBox(height: 16),
            _CapCard(
              budget: budget,
              outcome: outcome,
              onChanged: state.isReadOnly
                  ? null
                  : (tokens) => notifier.setMaxContextTokens(tokens),
            ),
          ],
          const SizedBox(height: 16),
          if (outcome == null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.memory),
                title: const Text('No model selected'),
                subtitle: const Text(
                  'Select an installed model to see the window this budget '
                  'applies to. The choice is saved now and used as soon as a '
                  'model is loaded.',
                ),
              ),
            )
          else
            _ResolvedWindowCard(
              outcome: outcome,
              modelName: window!.model.name,
              profileName: window.resolvedConfig.profileName,
            ),
          if (budget.isManual) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: state.isReadOnly ? null : notifier.resetToAuto,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Remove the limit and use Automatic'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The manual cap, as a ladder of windows a model can really be loaded with.
class _CapCard extends StatelessWidget {
  const _CapCard({
    required this.budget,
    required this.outcome,
    required this.onChanged,
  });

  final ContextBudget budget;
  final ContextBudgetOutcome? outcome;
  final ValueChanged<int?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final stored = budget.maxContextTokens;
    final options = _optionsWith(stored);
    final index = stored == null ? 0 : options.indexOf(stored);
    final selected = options[index < 0 ? 0 : index];
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Limit', style: textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '${formatTokens(selected)} tokens of prompt may be sent.',
              style: textTheme.bodyMedium,
            ),
            Slider(
              value: (index < 0 ? 0 : index).toDouble(),
              max: (options.length - 1).toDouble(),
              divisions: options.length - 1,
              label: formatTokens(selected),
              onChanged: onChanged == null
                  ? null
                  : (value) => onChanged!(options[value.round()]),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatTokens(options.first), style: textTheme.bodySmall),
                Text(formatTokens(options.last), style: textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "The model's own limit still applies: a larger choice here can "
              'never make a request bigger than the model or this platform '
              'allows.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (outcome?.capNote != null) ...[
              const SizedBox(height: 8),
              Text(
                outcome!.capNote!,
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

  /// The ladder, extended when a stored cap is not one of its steps (an older
  /// choice, or a hand-edited file), so the slider can always show it.
  static List<int> _optionsWith(int? stored) {
    if (stored == null || ContextBudgetPage.capOptions.contains(stored)) {
      return ContextBudgetPage.capOptions;
    }
    return [...ContextBudgetPage.capOptions, stored]..sort();
  }
}

/// What one request from the selected model would really get.
class _ResolvedWindowCard extends StatelessWidget {
  const _ResolvedWindowCard({
    required this.outcome,
    required this.modelName,
    required this.profileName,
  });

  final ContextBudgetOutcome outcome;
  final String modelName;
  final String profileName;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('On this device', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            _Row(
              label: 'Current budget',
              value: '${outcome.budgetLabel} tokens',
              colorScheme: colorScheme,
              textTheme: textTheme,
            ),
            _Row(
              label: 'Model maximum',
              value: '${outcome.modelMaximumLabel} tokens',
              colorScheme: colorScheme,
              textTheme: textTheme,
            ),
            _Row(
              label: 'Reserved for the answer',
              value: '${formatTokens(outcome.reservedOutputTokens)} tokens',
              colorScheme: colorScheme,
              textTheme: textTheme,
            ),
            const SizedBox(height: 8),
            Text(
              '$modelName with the $profileName profile. Images and retrieved '
              'local documents are charged against this budget when a message '
              'is sent, and a persona that pins an inference profile replaces '
              'the profile shown here.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    required this.colorScheme,
    required this.textTheme,
  });

  final String label;
  final String value;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: textTheme.bodyMedium)),
          Text(
            value,
            style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
