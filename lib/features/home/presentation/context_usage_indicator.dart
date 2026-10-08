import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';

/// Circular token-budget meter for the chat composer.
///
/// The ring fills with the share of the model's input budget the next request
/// from this conversation would use, and carries that share as a percentage in
/// the middle. It sits in the chat's app bar, next to the new-chat button.
/// Clicking it opens the budget panel under the bar — used against available
/// tokens, the bar, the window and answer reservation, what the system prompt,
/// the tool contract, the history and any retrieved documents cost, and what
/// the assembly had to drop or shorten — so the bar stays one quiet dial until
/// the figures are asked for. A request that had to trim messages turns the
/// ring to the warning colour, so that is visible without opening anything.
class ContextUsageIndicator extends StatefulWidget {
  const ContextUsageIndicator({
    super.key,
    required this.usage,
    this.fixedSystemTokens,
    this.toolContractIncluded = false,
    this.isGenerating = false,
  });

  /// Budget of the request the composer would send, or of the one running.
  final ContextUsage usage;

  /// Tokens the system prompt and the tool contract charge on their own, or
  /// null while a request is running (the host does not report it then).
  final int? fixedSystemTokens;

  /// Whether the tool contract is part of those fixed tokens.
  final bool toolContractIncluded;

  /// Whether the numbers describe a request already running.
  final bool isGenerating;

  @override
  State<ContextUsageIndicator> createState() => _ContextUsageIndicatorState();
}

class _ContextUsageIndicatorState extends State<ContextUsageIndicator> {
  final _menuController = MenuController();

  /// Opens the panel, or closes it when it is already up, so the dial behaves
  /// like a toggle rather than something that only ever opens.
  void _togglePanel() {
    if (_menuController.isOpen) {
      _menuController.close();
    } else {
      _menuController.open();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final percent = widget.usage.percent.clamp(0.0, 1.0);
    // Something was left out to fit: worth noticing without opening the panel,
    // which is why the ring carries the warning colour then.
    final ringColor = widget.usage.trimmingLabel == null
        ? colorScheme.primary
        : colorScheme.error;

    return MenuAnchor(
      controller: _menuController,
      // The dial sits in the app bar, so the panel is laid out under it; the
      // framework flips a menu up when it does not fit below the anchor, which
      // keeps the panel on screen on every platform.
      menuChildren: [
        _ContextUsagePanel(
          usage: widget.usage,
          fixedSystemTokens: widget.fixedSystemTokens,
          toolContractIncluded: widget.toolContractIncluded,
          isGenerating: widget.isGenerating,
        ),
      ],
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(
          colorScheme.surfaceContainerHigh,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
        ),
        elevation: const WidgetStatePropertyAll(4),
      ),
      child: IconButton(
        tooltip: 'Context usage',
        onPressed: _togglePanel,
        // A plain app-bar button like the ones beside it; the ring is the icon.
        style: IconButton.styleFrom(
          foregroundColor: ringColor,
          padding: const EdgeInsets.all(7),
        ),
        icon: SizedBox(
          width: 26,
          height: 26,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CircularProgressIndicator(
                  value: percent,
                  strokeWidth: 2.5,
                  backgroundColor: colorScheme.outlineVariant,
                  color: ringColor,
                ),
              ),
              // The percentage is scaled to the ring's hole instead of being
              // sized from a guessed glyph width, so a wide percentage or a
              // large accessibility text size cannot push it over the dial.
              SizedBox(
                width: 19,
                height: 19,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${(percent * 100).round()}%',
                    maxLines: 1,
                    style: textTheme.labelSmall?.copyWith(
                      fontSize: 8,
                      height: 1,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The panel behind the dial: the same figures the readout used to print, laid
/// out as a header with its bar, then what fills the budget and what the
/// conversation costs.
class _ContextUsagePanel extends StatelessWidget {
  const _ContextUsagePanel({
    required this.usage,
    this.fixedSystemTokens,
    this.toolContractIncluded = false,
    this.isGenerating = false,
  });

  final ContextUsage usage;
  final int? fixedSystemTokens;
  final bool toolContractIncluded;
  final bool isGenerating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final percent = usage.percent.clamp(0.0, 1.0);
    final fixed = fixedSystemTokens;
    final historyTokens = fixed == null
        ? null
        : math.max(0, usage.usedTokens - fixed - usage.retrievalTokens);
    final labelStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _MetricRow(
              label: 'Context',
              value:
                  '${formatTokens(usage.usedTokens)} / '
                  '${formatTokens(usage.limitTokens)} · '
                  '${(percent * 100).round()}%',
              labelStyle: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              valueStyle: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: percent,
                minHeight: 4,
                backgroundColor: colorScheme.outlineVariant,
                color: usage.trimmingLabel == null
                    ? colorScheme.primary
                    : colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(usage.detailLabel, style: labelStyle),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text(
              'Prompt usage',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            if (fixed != null)
              _MetricRow(
                label: toolContractIncluded
                    ? 'System prompt and tools'
                    : 'System prompt',
                value: formatTokens(fixed),
              )
            else
              _MetricRow(
                label: 'Prompt input',
                value: formatTokens(usage.usedTokens),
              ),
            if (historyTokens != null)
              _MetricRow(
                label: 'Conversation history',
                value: formatTokens(historyTokens),
              ),
            if (usage.retrievedSources > 0)
              _MetricRow(
                label: 'Retrieved documents',
                value:
                    '${formatTokens(usage.retrievalTokens)} · '
                    '${usage.retrievedSources} '
                    'chunk${usage.retrievedSources == 1 ? '' : 's'}',
              ),
            const SizedBox(height: 8),
            Text(
              [
                if (isGenerating)
                  'Budget for the request now running.'
                else
                  'What the next message from this conversation would cost. '
                      'Retrieval from your knowledge collection is added when '
                      'you send it.',
                if (fixed != null && !toolContractIncluded)
                  'This model cannot call tools, so no tool contract is sent.',
              ].join(' '),
              style: labelStyle,
            ),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text(
              'Messages',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            _MetricRow(label: 'Included', value: '${usage.includedMessages}'),
            if (usage.droppedMessages > 0)
              _MetricRow(
                label: 'Dropped (older)',
                value: '${usage.droppedMessages}',
              ),
            if (usage.truncatedMessages > 0)
              _MetricRow(
                label: 'Shortened',
                value: '${usage.truncatedMessages}',
              ),
            const SizedBox(height: 8),
            Text(
              'Older turns drop once the input budget runs out, and a long '
              'message keeps its start and end.',
              style: labelStyle,
            ),
          ],
        ),
      ),
    );
  }
}

/// One label on the left, one figure on the right, as the panel reads.
class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
    this.labelStyle,
    this.valueStyle,
  });

  final String label;
  final String value;
  final TextStyle? labelStyle;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style:
                  labelStyle ??
                  textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            textAlign: TextAlign.right,
            style:
                valueStyle ??
                textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}
