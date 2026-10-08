import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/agents/application/agent_controller.dart';
import 'package:pocket_llm/features/agents/application/agent_loop_service.dart';
import 'package:pocket_llm/features/agents/domain/agent_run.dart';
import 'package:pocket_llm/features/tools/application/tool_approval_controller.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/presentation/tool_approval_dialog.dart';

/// Runs one goal through the local tools, step by step.
///
/// Deliberately separate from chat: a conversation never starts a loop, the
/// loop never writes to a conversation, and the run is bounded by an iteration
/// limit and a token budget that are both on screen.
class AgentPage extends ConsumerStatefulWidget {
  const AgentPage({super.key});

  @override
  ConsumerState<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends ConsumerState<AgentPage> {
  late final TextEditingController _goalController = TextEditingController(
    text: ref.read(agentControllerProvider).goal,
  );

  @override
  void dispose() {
    _goalController.dispose();
    super.dispose();
  }

  /// Closing the dialog any other way than Allow is a refusal, so a prompt
  /// that disappears can never be read as consent.
  Future<void> _askForToolApproval(ToolApprovalRequest request) async {
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ToolApprovalDialog(
        request: request,
        onDecision: (value) => Navigator.of(dialogContext).pop(value),
      ),
    );
    if (!mounted) return;
    final controller = ref.read(toolApprovalControllerProvider.notifier);
    approved == true ? controller.approve() : controller.deny();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(agentControllerProvider);
    final controller = ref.read(agentControllerProvider.notifier);
    final installed = ref.watch(installedAgentModelsProvider);
    final models = agentRunnableModels(installed);
    final nonToolModels = agentNonToolModels(installed);

    ref.listen<ToolApprovalRequest?>(toolApprovalControllerProvider, (_, next) {
      if (next != null) unawaited(_askForToolApproval(next));
    });

    final selectedModelId =
        state.modelId ?? (models.isEmpty ? null : models.first.id);

    return Scaffold(
      appBar: AppBar(title: const Text('Agent')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.auto_awesome_outlined,
                      color: colorScheme.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Local agent',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Give the model a goal and let it work through the '
                          'local tools one step at a time. Everything runs on '
                          'this device, the run stops at its limits, and every '
                          'step is listed below.',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Goal',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _goalController,
                    enabled: !state.isRunning,
                    minLines: 2,
                    maxLines: 5,
                    maxLength: AgentLoopService.maximumGoalLength,
                    onChanged: controller.setGoal,
                    decoration: const InputDecoration(
                      hintText:
                          'e.g. What is 18% of 2450, and what day is it today?',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'The agent can use the read-only tools this device has '
                    '(calculator, date, chat search, documents, installed '
                    'models). Anything sensitive still asks for permission '
                    'first.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Model',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (models.isEmpty)
                    Text(
                      nonToolModels.isEmpty
                          ? 'No local model is installed yet. Download or '
                                'import a GGUF model to run an agent.'
                          : 'None of the installed models can call tools, '
                                'which an agent run needs. '
                                '${nonToolModels.map((model) => model.name).join(', ')} '
                                '${nonToolModels.length == 1 ? 'has' : 'have'} '
                                'no tool protocol in the chat template, so '
                                'only a model whose template supports tool '
                                'calling can run an agent.',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final model in models)
                          ChoiceChip(
                            label: Text(model.name),
                            selected: model.id == selectedModelId,
                            onSelected: state.isRunning
                                ? null
                                : (_) => controller.setModel(model.id),
                          ),
                      ],
                    ),
                  const SizedBox(height: 14),
                  Text(
                    'Limits',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'At most ${state.maxIterations} model '
                          'turn${state.maxIterations == 1 ? '' : 's'} per run, '
                          'and each turn must fit the context budget.',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      DropdownButton<int>(
                        value: state.maxIterations,
                        onChanged: state.isRunning
                            ? null
                            : (value) => controller.setMaxIterations(
                                value ?? AgentLoopService.defaultMaxIterations,
                              ),
                        items: [
                          for (final value in const [3, 6, 9, 12])
                            DropdownMenuItem(
                              value: value,
                              child: Text('$value turns'),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: state.isRunning || models.isEmpty
                            ? null
                            : controller.run,
                        icon: state.isRunning
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          state.isRunning ? 'Working...' : 'Run agent',
                        ),
                      ),
                      if (state.isRunning)
                        OutlinedButton.icon(
                          onPressed: controller.cancel,
                          icon: const Icon(Icons.stop_rounded),
                          label: const Text('Stop'),
                        ),
                      if (state.hasLog && !state.isRunning)
                        TextButton.icon(
                          onPressed: controller.clear,
                          icon: const Icon(Icons.clear_all_rounded),
                          label: const Text('Clear log'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (state.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _AgentNotice(
                icon: Icons.error_outline_rounded,
                text: state.errorMessage!,
                isError: true,
              ),
            ),
          if (state.hasLog) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Execution log',
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    state.run?.summaryLabel ??
                        '${state.steps.length} step'
                            '${state.steps.length == 1 ? '' : 's'} so far',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (state.run != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _AgentNotice(
                  icon: state.runWasIncomplete
                      ? Icons.report_problem_outlined
                      : Icons.check_circle_outline_rounded,
                  text: state.runWasIncomplete
                      ? '${state.run!.status.label}. The log shows how far the '
                            'run got.'
                      : 'Finished: ${state.run!.status.label}.',
                ),
              ),
            for (final step in state.steps) _AgentStepTile(step: step),
            if (state.run != null && !state.isRunning)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Copy log',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _copyRun(markdown: false),
                      icon: const Icon(Icons.copy_all_outlined, size: 18),
                      label: const Text('JSON'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _copyRun(markdown: true),
                      icon: const Icon(Icons.copy_all_outlined, size: 18),
                      label: const Text('Markdown'),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _copyRun({required bool markdown}) async {
    final controller = ref.read(agentControllerProvider.notifier);
    try {
      final copied = markdown
          ? await controller.copyRunAsMarkdown()
          : await controller.copyRunAsJson();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            copied
                ? 'Run copied as ${markdown ? 'Markdown' : 'JSON'}.'
                : 'There is nothing to copy yet.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copy failed: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

/// One line of the execution log.
class _AgentStepTile extends StatelessWidget {
  const _AgentStepTile({required this.step});

  final AgentStep step;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (icon, tone) = switch (step.kind) {
      AgentStepKind.goal => (Icons.flag_outlined, colorScheme.primary),
      AgentStepKind.toolCall => (Icons.build_outlined, colorScheme.secondary),
      AgentStepKind.observation => (
        Icons.visibility_outlined,
        colorScheme.onSurfaceVariant,
      ),
      AgentStepKind.answer => (Icons.check_circle_outline, colorScheme.primary),
      AgentStepKind.notice => (
        Icons.info_outline_rounded,
        colorScheme.onSurfaceVariant,
      ),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: tone),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${step.index}. ${step.kind.label}'
                    '${step.iteration == null ? '' : ' · turn ${step.iteration}'}',
                    style: textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (step.status != null)
                  Text(
                    step.status!,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (step.durationMs != null && step.durationMs! > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '${step.durationMs} ms',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            if (step.toolName != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${step.toolName}'
                  '${step.arguments == null || step.arguments!.isEmpty ? '()' : '(${step.arguments})'}',
                  style: textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (step.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(step.text.trim()),
              ),
          ],
        ),
      ),
    );
  }
}

/// Inline message card, matching the app's other screens.
class _AgentNotice extends StatelessWidget {
  const _AgentNotice({
    required this.icon,
    required this.text,
    this.isError = false,
  });

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = isError ? colorScheme.error : colorScheme.onSurfaceVariant;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
