import 'dart:math' as math;

import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/conversation_memory.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/documents/domain/document_context.dart';

/// One assembled prompt: the messages that fit, the system prompt, and what
/// the assembly cost.
class ContextAssembly {
  const ContextAssembly({
    required this.messages,
    required this.systemPrompt,
    required this.usage,
    this.omittedMessages = const [],
  });

  /// Messages in chronological order, ready to be rendered into a prompt.
  final List<Message> messages;

  final String systemPrompt;
  final ContextUsage usage;

  /// Older messages neither sent nor already covered by the conversation's
  /// memory. Road Map 1 Phase 4 Strategy B: these are what a memory refresh
  /// has to condense, and an empty list means nothing is being lost.
  final List<Message> omittedMessages;

  bool get isEmpty => messages.isEmpty;
}

/// Builds model input from a conversation, newest-first, within a token budget.
///
/// Rules, in order of priority:
///
/// 1. The system prompt is always preserved and charged first, together with
///    the conversation's memory summary and the retrieved local document
///    section ([documentContext]), which is sized by the caller against the
///    same policy.
///
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
/// Road Map 1 Phase 4 Strategy B: when the conversation carries a
/// [ConversationMemory], the messages it covers are represented by its summary
/// and are not candidates at all, and the summary is charged right after the
/// system prompt. Messages that still fall outside the window are reported in
/// [ContextAssembly.omittedMessages] so the caller can condense them instead of
/// losing them.
///
/// The result reports what happened so the UI can show context usage instead
/// of silently trimming a conversation.
class ConversationContextBuilder {
  const ConversationContextBuilder();

  ContextAssembly build({
    required List<Message> messages,
    required String systemPrompt,
    required ContextPolicy policy,
    DocumentContext? documentContext,
    ConversationMemory? memory,
  }) {
    // A memory only applies while its anchor is still part of the history: a
    // summary of messages the user has since deleted would describe a chat
    // that no longer exists.
    final anchoredMemory = memory != null && !memory.isEmpty ? memory : null;
    final coveredUpTo = anchoredMemory == null
        ? -1
        : anchoredMemory.anchorIndex(messages);
    final coveredMessages = coveredUpTo < 0 ? 0 : coveredUpTo + 1;
    final memorySection = coveredMessages == 0
        ? ''
        : anchoredMemory!.section.trim();

    // Order follows the roadmap: system prompt, memory summary, recent
    // messages. Retrieved local documents belong to the question being asked
    // now and sit closest to it, and are charged before any history: an old
    // conversation can never push them out of the window.
    final documentSection = documentContext?.section.trim() ?? '';
    final sections = <String>[
      if (systemPrompt.trim().isNotEmpty) systemPrompt,
      if (memorySection.isNotEmpty) memorySection,
      if (documentSection.isNotEmpty) documentSection,
    ];
    final fullSystemPrompt = sections.join('\n\n');
    final systemCost = TokenEstimator.estimateMessage(fullSystemPrompt);
    final available = math.max(0, policy.usableInputTokens - systemCost);

    final included = <Message>[];
    var truncatedCount = 0;
    var usedByMessages = 0;

    // Messages the summary stands for are not candidates at all: sending them
    // again would spend the window on text that is already condensed.
    final candidates = <Message>[
      for (var index = coveredMessages; index < messages.length; index++)
        if (_visible(messages[index])) messages[index],
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
    final includedIds = {for (final message in includedMessages) message.id};
    final omittedMessages = <Message>[
      for (final message in candidates)
        if (!includedIds.contains(message.id)) message,
    ];

    return ContextAssembly(
      messages: includedMessages,
      systemPrompt: fullSystemPrompt,
      omittedMessages: omittedMessages,
      usage: ContextUsage(
        usedTokens: used,
        limitTokens: policy.usableInputTokens,
        contextTokens: policy.contextTokens,
        reservedOutputTokens: policy.reservedOutputTokens,
        includedMessages: includedMessages.length,
        droppedMessages: omittedMessages.length,
        truncatedMessages: truncatedCount,
        memoryTokens: memorySection.isEmpty
            ? 0
            : TokenEstimator.estimateText(memorySection),
        memoryCoveredMessages: coveredMessages,
        retrievalTokens: documentSection.isEmpty
            ? 0
            : TokenEstimator.estimateText(documentSection),
        retrievedSources: documentContext?.hits.length ?? 0,
      ),
    );
  }

  /// Whether a message carries anything worth sending.
  bool _visible(Message message) =>
      message.content.trim().isNotEmpty || message.attachments.isNotEmpty;

  int _cost(String text, int imageCount) {
    return TokenEstimator.estimateMessage(text, imageCount: imageCount);
  }
}
