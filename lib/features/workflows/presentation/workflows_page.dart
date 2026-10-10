import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/workspaces/application/workspaces_controller.dart';
import 'package:pocket_llm/features/workflows/application/workflows_controller.dart';
import 'package:pocket_llm/features/workflows/domain/workflow.dart';

/// Workflows: deterministic bot coordination with approval gates.
///
/// Road Map 2 Phase 2.7. A run advances step by step and pauses where it
/// must: approvals wait for the user, bot tasks wait for a result. Bots
/// never bypass a gate — only a decision here moves the run past one.
class WorkflowsPage extends ConsumerWidget {
  const WorkflowsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workflowsProvider);
    final workspaces = ref.watch(workspacesProvider);
    final active = workspaces.active;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(active == null ? 'Workflows' : '${active.name} workflows'),
      ),
      body: active == null
          ? const Center(child: Text('No workspace selected.'))
          : !state.isReady
          ? const Center(child: CircularProgressIndicator())
          : Builder(
              builder: (context) {
                final notifier = ref.read(workflowsProvider.notifier);
                final workflows = notifier.workflowsFor(active.id);
                final runs = notifier.runsFor(active.id);
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: [
                    Text(
                      'Researcher → Planner → approval → Coder → Tester. '
                      'Each run survives app restart; loops stop after '
                      'three visits and ask you.',
                      style: textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    for (final workflow in workflows)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.account_tree_outlined),
                          title: Text(workflow.name),
                          subtitle: Text('${workflow.steps.length} steps'),
                          trailing: FilledButton.tonal(
                            onPressed: () => notifier.startRun(workflow),
                            child: const Text('Start'),
                          ),
                        ),
                      ),
                    if (runs.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text('Runs', style: textTheme.titleSmall),
                      const SizedBox(height: 8),
                      for (final run in runs) _RunCard(run: run),
                    ],
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
                );
              },
            ),
    );
  }
}

class _RunCard extends ConsumerWidget {
  const _RunCard({required this.run});

  final WorkflowRun run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(workflowsProvider.notifier);
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: ExpansionTile(
        leading: _statusIcon(run.status, colorScheme),
        title: Text('${_workflowName(ref, run)} · ${run.status.label}'),
        subtitle: Text(
          '${run.completedStepIds.length} steps done'
          '${run.errors.isEmpty ? '' : ' · ${run.errors.length} errors'}',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (run.status == RunStatus.waitingApproval) ...[
                  Text(
                    'Approval needed'
                    '${run.approvalNote.isEmpty ? '' : ': ${run.approvalNote}'}',
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _ApprovalRow(run: run),
                ],
                if (run.status == RunStatus.waitingBot) ...[
                  Text(
                    'Bot result needed for this step. Paste the bot\u2019s '
                    'answer to continue the run.',
                    style: textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  _BotResultRow(run: run),
                ],
                if (run.taskIds.isNotEmpty)
                  Text(
                    'Tasks: ${run.taskIds.join(', ')}',
                    style: textTheme.bodySmall,
                  ),
                if (run.documents.isNotEmpty)
                  Text(
                    'Documents: ${run.documents.join(', ')}',
                    style: textTheme.bodySmall,
                  ),
                if (run.errors.isNotEmpty)
                  Text(
                    run.errors.join('\n'),
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                    ),
                  ),
                if (!run.status.isFinished)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => notifier.cancelRun(run.id),
                      child: const Text('Cancel run'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _workflowName(WidgetRef ref, WorkflowRun run) {
    final workflows = ref
        .read(workflowsProvider.notifier)
        .workflowsFor(run.workspaceId);
    for (final workflow in workflows) {
      if (workflow.id == run.workflowId) return workflow.name;
    }
    return 'Workflow';
  }

  Widget _statusIcon(RunStatus status, ColorScheme colors) {
    return switch (status) {
      RunStatus.done => Icon(Icons.check_circle, color: colors.primary),
      RunStatus.failed => Icon(Icons.error_outline, color: colors.error),
      RunStatus.cancelled => const Icon(Icons.cancel_outlined),
      RunStatus.waitingApproval => Icon(
        Icons.pending_actions,
        color: colors.tertiary,
      ),
      RunStatus.waitingBot => const Icon(Icons.smart_toy_outlined),
      RunStatus.active => const Icon(Icons.play_arrow_outlined),
    };
  }
}

class _ApprovalRow extends ConsumerStatefulWidget {
  const _ApprovalRow({required this.run});

  final WorkflowRun run;

  @override
  ConsumerState<_ApprovalRow> createState() => _ApprovalRowState();
}

class _ApprovalRowState extends ConsumerState<_ApprovalRow> {
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(workflowsProvider.notifier);
    return Column(
      children: [
        TextField(
          controller: _noteController,
          decoration: const InputDecoration(
            hintText: 'Note (optional)',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              onPressed: () => notifier.decideApproval(
                widget.run.id,
                ApprovalDecision.approve,
                _noteController.text,
              ),
              child: const Text('Approve'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => notifier.decideApproval(
                widget.run.id,
                ApprovalDecision.requestChanges,
                _noteController.text.isEmpty
                    ? 'Please revise.'
                    : _noteController.text,
              ),
              child: const Text('Request changes'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => notifier.decideApproval(
                widget.run.id,
                ApprovalDecision.cancel,
                _noteController.text,
              ),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }
}

class _BotResultRow extends ConsumerStatefulWidget {
  const _BotResultRow({required this.run});

  final WorkflowRun run;

  @override
  ConsumerState<_BotResultRow> createState() => _BotResultRowState();
}

class _BotResultRowState extends ConsumerState<_BotResultRow> {
  final _outputController = TextEditingController();

  @override
  void dispose() {
    _outputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(workflowsProvider.notifier);
    final prompt = widget.run.currentStepId == null
        ? ''
        : widget.run.outputs[widget.run.currentStepId] ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (prompt.isNotEmpty)
          SelectableText(prompt, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        TextField(
          controller: _outputController,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Bot result',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () {
            if (_outputController.text.trim().isEmpty) return;
            notifier.completeBotStep(
              widget.run.id,
              _outputController.text.trim(),
            );
          },
          child: const Text('Record result and continue'),
        ),
      ],
    );
  }
}
