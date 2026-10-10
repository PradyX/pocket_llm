import 'package:pocket_llm/features/bots/domain/bot.dart';

/// Assembles what one bot is told for a task: soul, skills, memory.
///
/// Road Map 2 §4.4 target structure, bot half:
/// ```text
/// SOUL
/// SKILLS
/// PROJECT MEMORY
/// CURRENT TASK
/// ```
/// The conversation half (summary, decisions, recent messages) is owned by
/// the context builder; this produces the stable prefix that compaction
/// always preserves.
abstract final class BotPrompt {
  /// The stable prefix for [bot]: soul, then skill sections, then workspace
  /// memory. Empty parts are skipped so a bot without skills or memory
  /// still gets a clean prompt.
  static String assemble({
    required Bot bot,
    List<String> skillSections = const [],
    String projectMemory = '',
    String fallbackAssistantPrompt = '',
  }) {
    final parts = <String>[];
    final soul = bot.soul.trim();
    if (soul.isNotEmpty) {
      parts.add(soul);
    } else if (fallbackAssistantPrompt.trim().isNotEmpty) {
      parts.add(fallbackAssistantPrompt.trim());
    }
    for (final section in skillSections) {
      final trimmed = section.trim();
      if (trimmed.isNotEmpty) parts.add(trimmed);
    }
    final memory = projectMemory.trim();
    if (memory.isNotEmpty) {
      parts.add('Project memory (shared facts, not reasoning):\n$memory');
    }
    return parts.join('\n\n');
  }

  /// The task suffix: what the bot should do right now.
  static String taskSection(String task) {
    final trimmed = task.trim();
    if (trimmed.isEmpty) return '';
    return 'Current task:\n$trimmed';
  }
}
