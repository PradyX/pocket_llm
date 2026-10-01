import 'dart:math' as math;

import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';

/// One assembled prompt: the messages that fit, the system prompt, and what
/// the assembly cost.
class ContextAssembly {
  const ContextAssembly({
    required this.messages,
    required this.systemPrompt,
    required this.usage,
  });

  /// Messages in chronological order, ready to be rendered into a prompt.
  final List<Message> messages;

  final String systemPrompt;
  final ContextUsage usage;

  bool get isEmpty => messages.isEmpty;
}

/// Builds model input from a conversation, newest-first, within a token budget.
///
/// Rules, in order of priority:
///
/// 1. The system prompt is always preserved and charged first.
/// 2. Output tokens are reserved before any history is considered.
/// 3. The newest message is always included; it is truncated when a single
///    turn cannot fit on its own, so the user's question is never dropped. A
///    turn is only skipped in the degenerate case where even its attachments
///    and role overhead do not fit, and that is reported as a dropped message.
/// 4. Older messages are added while they fit, newest first; the rest are
///    dropped (sliding context, no summary yet).
/// 5. A message larger than [ContextPolicy.maxMessageTokens] keeps its head and
///    tail, with the middle removed.
///
/// The result reports what happened so the UI can show context usage instead
/// of silently trimming a conversation.
class ConversationContextBuilder {
  const ConversationContextBuilder();

  ContextAssembly build({
    required List<Message> messages,
    required String systemPrompt,
    required ContextPolicy policy,
  }) {
    final systemCost = TokenEstimator.estimateMessage(systemPrompt);
    final available = math.max(0, policy.usableInputTokens - systemCost);

    final included = <Message>[];
    var truncatedCount = 0;
    var usedByMessages = 0;

    final candidates = <Message>[
      for (final message in messages)
        if (message.content.trim().isNotEmpty || message.attachments.isNotEmpty)
          message,
    ];

    for (var index = candidates.length - 1; index >= 0; index--) {
      final message = candidates[index];
      final imageCount = message.attachments.isEmpty
          ? 0
          : message.attachments.length;
      var text = message.content;
      var cost = _cost(text, imageCount);
      var wasTruncated = false;

      if (cost > policy.maxMessageTokens) {
        text = TokenEstimator.truncate(text, policy.maxMessageTokens);
        cost = _cost(text, imageCount);
        wasTruncated = true;
      }

      final isNewest = included.isEmpty;
      final remaining = available - usedByMessages;

      if (cost > remaining) {
        if (!isNewest) break;
        // A single oversized turn still has to go through: keep head and tail.
        // Attachments are not optional, so only the text is trimmed.
        final fixedCost =
            TokenEstimator.messageOverheadTokens +
            imageCount * TokenEstimator.imageTokens;
        final textBudget = remaining - fixedCost;
        if (textBudget <= 0) break;
        text = TokenEstimator.truncate(text, textBudget);
        cost = _cost(text, imageCount);
        wasTruncated = true;
      }

      included.add(
        text == message.content ? message : message.copyWith(content: text),
      );
      usedByMessages += cost;
      if (wasTruncated) truncatedCount++;
    }

    final includedMessages = included.reversed.toList(growable: false);
    final used = systemCost + usedByMessages;

    return ContextAssembly(
      messages: includedMessages,
      systemPrompt: systemPrompt,
      usage: ContextUsage(
        usedTokens: used,
        limitTokens: policy.usableInputTokens,
        contextTokens: policy.contextTokens,
        reservedOutputTokens: policy.reservedOutputTokens,
        includedMessages: includedMessages.length,
        droppedMessages: candidates.length - includedMessages.length,
        truncatedMessages: truncatedCount,
      ),
    );
  }

  int _cost(String text, int imageCount) {
    return TokenEstimator.estimateMessage(text, imageCount: imageCount);
  }
}
