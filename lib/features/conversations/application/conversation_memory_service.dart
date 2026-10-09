import 'package:pocket_llm/core/inference/inference_engine.dart';
import 'package:pocket_llm/core/utils/llm_prompt_utils.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/conversations/domain/conversation_memory.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';

/// Writes and refreshes the local summary of a conversation's older turns.
///
/// Road Map 1 Phase 4 Strategy B. The summary is produced by the bundled local
/// model through the [InferenceEngine] seam, so it stays on the device and
/// works offline; nothing here talks to a network service.
///
/// The policy is deliberately conservative: a refresh only runs once enough
/// text has fallen out of the window that summarizing is cheaper than losing
/// it, and a failed or empty generation keeps the previous memory instead of
/// replacing it with nothing.
class ConversationMemoryService {
  const ConversationMemoryService();

  /// Fewer newly dropped messages than this are left to the sliding window.
  static const int minimumNewMessages = 2;

  /// Newly dropped text below this estimate is not worth a local generation.
  static const int minimumNewTokens = 320;

  /// Tokens the summarizer may write.
  static const int summaryMaxTokens = 320;

  /// Longest single message handed to the summarizer.
  static const int maxSourceMessageTokens = 400;

  /// Total tokens of message text the summarizer is given.
  static const int sourceBudgetTokens = 900;

  static const String _systemPrompt =
      'You condense a chat transcript into long-term memory. Keep only facts, '
      'decisions, names, numbers, preferences, open questions and unfinished '
      'tasks. Never invent details, never guess, and never add commentary, '
      'greetings or headings. Write plain prose in the third person.';

  /// Estimates the text of [messages] the way the context budget does.
  static int estimateTokens(Iterable<Message> messages) {
    var total = 0;
    for (final message in messages) {
      total += TokenEstimator.estimateMessage(
        message.content,
        imageCount: message.attachments.length,
      );
    }
    return total;
  }

  /// Whether [omitted] is worth summarizing now.
  ///
  /// A single dropped message, or a couple of short ones, re-sends more cheaply
  /// than it summarizes; waiting until the lost text is substantial also keeps
  /// a refresh from running after every single turn.
  bool shouldRefresh(List<Message> omitted) {
    if (omitted.length < minimumNewMessages) return false;
    return estimateTokens(omitted) >= minimumNewTokens;
  }

  /// The prompt that asks the local model for the updated summary.
  ///
  /// [previousSummary] is folded in rather than re-read, which is what keeps a
  /// long chat cheap: each refresh only ever sees the newly dropped turns plus
  /// what earlier refreshes already condensed. The oldest of [messages] are
  /// dropped when they do not fit, and the prompt says so, because a summary
  /// must not silently pretend it saw text it never received.
  String buildPrompt({
    required List<Message> messages,
    String? previousSummary,
  }) {
    final selected = <String>[];
    var used = 0;
    var skipped = 0;

    for (final message in messages.reversed) {
      var text = message.content.trim();
      if (text.isEmpty) {
        if (message.attachments.isEmpty) continue;
        text = '(${message.attachments.length} shared image(s))';
      }
      final tokens = TokenEstimator.estimateMessage(text);
      if (tokens > maxSourceMessageTokens) {
        text = TokenEstimator.truncate(text, maxSourceMessageTokens);
      }
      final cost = TokenEstimator.estimateMessage(text);
      if (used + cost > sourceBudgetTokens) {
        skipped++;
        continue;
      }
      used += cost;
      selected.add('${message.isUser ? 'User' : 'Assistant'}: $text');
    }
    final transcript = selected.reversed.join('\n');

    final body = StringBuffer();
    final existing = previousSummary?.trim() ?? '';
    if (existing.isNotEmpty) {
      body
        ..writeln('Summary so far:')
        ..writeln(existing)
        ..writeln();
    }
    if (skipped > 0) {
      body
        ..writeln('($skipped older message(s) are not shown below.)')
        ..writeln();
    }
    body
      ..writeln('Newer messages, oldest first:')
      ..writeln(transcript.isEmpty ? '(none)' : transcript)
      ..writeln()
      ..write(
        'Write the updated memory of this conversation as plain prose. '
        'Keep it under 200 words. Include the detail that matters for '
        'continuing the conversation later.',
      );

    return buildModelChatPrompt([
      LlmPromptMessage.user(body.toString()),
    ], systemPrompt: _systemPrompt).prompt;
  }

  /// Cleans up what the model wrote, or returns null when there is nothing
  /// usable.
  ///
  /// Reasoning blocks are dropped rather than summarized: a model that only
  /// produced a `<think>` block has not written the memory yet, and a half
  /// answer is worse than keeping the previous summary. Whitespace is collapsed
  /// and the result is capped, so a model that runs long cannot turn a summary
  /// into a second conversation inside the window.
  String? normalize(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // Still inside a reasoning block that was never closed: nothing to keep.
    final open = trimmed.lastIndexOf('<think>');
    if (open >= 0 && trimmed.indexOf('</think>', open) < 0) return null;
    final closing = trimmed.lastIndexOf('</think>');
    final answer = closing < 0
        ? trimmed
        : trimmed.substring(closing + '</think>'.length);

    var collapsed = answer.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final prefix in const ['Summary so far:', 'Summary:', 'Memory:']) {
      if (collapsed.toLowerCase().startsWith(prefix.toLowerCase())) {
        collapsed = collapsed.substring(prefix.length).trim();
        break;
      }
    }
    if (collapsed.isEmpty) return null;
    if (collapsed.length > ConversationMemory.maxSummaryCharacters) {
      collapsed =
          '${collapsed.substring(0, ConversationMemory.maxSummaryCharacters - 3).trimRight()}...';
    }
    return collapsed;
  }

  /// Runs one local generation and returns the updated memory, or null when
  /// the model produced nothing usable.
  ///
  /// [anchorMessageId] is the id of the newest message the summary covers and
  /// [coveredCount] how many messages from the start of the conversation that
  /// stands for, so the stored memory lines up with the history that will be
  /// assembled next.
  Future<ConversationMemory?> refresh({
    required InferenceEngine engine,
    required List<Message> messages,
    required String anchorMessageId,
    required int coveredCount,
    required String? modelId,
    ConversationMemory? previous,
  }) async {
    if (messages.isEmpty || anchorMessageId.isEmpty) return null;
    final raw = StringBuffer();
    final stream = engine.generateResponse(
      buildPrompt(messages: messages, previousSummary: previous?.summary),
      maxTokens: summaryMaxTokens,
    );
    await for (final token in stream) {
      raw.write(token);
    }
    final summary = normalize(raw.toString());
    if (summary == null) return null;
    return ConversationMemory(
      summary: summary,
      coveredThroughMessageId: anchorMessageId,
      coveredCount: coveredCount,
      updatedAt: DateTime.now(),
      modelId: modelId,
    );
  }
}
