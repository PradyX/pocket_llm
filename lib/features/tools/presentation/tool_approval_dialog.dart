import 'package:flutter/material.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';

/// Asks whether one sensitive tool may run.
///
/// The box shows the exact call the registry validated — the tool name and the
/// coerced arguments — not raw model output, so the user decides on what would
/// really happen. Nothing runs until Allow is tapped; any other way of closing
/// the dialog is treated as a refusal.
class ToolApprovalDialog extends StatelessWidget {
  const ToolApprovalDialog({
    super.key,
    required this.request,
    required this.onDecision,
  });

  final ToolApprovalRequest request;

  /// Called with true only when the user allows the call.
  final ValueChanged<bool> onDecision;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return AlertDialog(
      icon: const Icon(Icons.shield_outlined),
      title: Text('Allow ${request.tool.name}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(request.tool.description),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              request.summary,
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'This hands the action to another app on this device. Pocket LLM '
            'waits for your answer before anything happens.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => onDecision(false),
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed: () => onDecision(true),
          child: const Text('Allow'),
        ),
      ],
    );
  }
}
