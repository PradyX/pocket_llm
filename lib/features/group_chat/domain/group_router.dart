import 'package:pocket_llm/features/bots/domain/bot.dart';
import 'package:pocket_llm/features/group_chat/domain/group_chat.dart';

/// Picks the next speaker without any model call.
///
/// The order is fixed: an explicit `@mention` always wins (manual intent
/// beats automation), then the linked workflow's waiting bot, then — only
/// in auto mode — a local relevance vote. No rule ever returns two bots at
/// once, which is what keeps Bot A → Bot B → Bot A … impossible without
/// the user's next line or the next workflow step.
abstract final class GroupRouter {
  /// Bot ids mentioned as `@name` in [text], in mention order.
  static List<String> mentions({
    required String text,
    required List<Bot> members,
  }) {
    final lower = text.toLowerCase();
    final found = <String>[];
    for (final bot in members) {
      final handle = '@${bot.name.toLowerCase()}';
      if (lower.contains(handle) && !found.contains(bot.id)) {
        found.add(bot.id);
      }
    }
    return found;
  }

  /// Next speaker after the user's line, or null when nobody should answer
  /// (the user spoke to nobody in manual mode, or auto found nothing).
  static String? nextSpeaker({
    required GroupChat chat,
    required List<Bot> members,
    required String userText,
    String? workflowWaitingBotId,
  }) {
    final mentioned = mentions(text: userText, members: members);
    if (mentioned.isNotEmpty) return mentioned.first;

    // A direct chat is one bot's room: every line is for them.
    if (chat.directBotId != null &&
        members.any((bot) => bot.id == chat.directBotId)) {
      return chat.directBotId;
    }

    if (chat.mode == SpeakerMode.workflow && workflowWaitingBotId != null) {
      if (members.any((bot) => bot.id == workflowWaitingBotId)) {
        return workflowWaitingBotId;
      }
    }

    if (chat.mode == SpeakerMode.auto) {
      return _relevancePick(members: members, text: userText);
    }
    return null;
  }

  /// Speaker after a bot's answer: only mentions continue the chain, and at
  /// most one bot follows. Returns null when the floor returns to the user.
  static String? followUpSpeaker({
    required List<Bot> members,
    required String botText,
    required int roundsUsed,
    required int maxRounds,
  }) {
    if (roundsUsed >= maxRounds) return null;
    final mentioned = mentions(text: botText, members: members);
    return mentioned.isEmpty ? null : mentioned.first;
  }

  /// Local relevance vote: the member whose name, description and soul
  /// share the most whole words with the text. Zero overlap votes for
  /// nobody — auto mode stays silent rather than guessing.
  static String? _relevancePick({
    required List<Bot> members,
    required String text,
  }) {
    final words = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.length > 2)
        .toSet();
    if (words.isEmpty) return null;
    String? best;
    var bestScore = 0;
    for (final bot in members) {
      final haystack = '${bot.name} ${bot.description} ${bot.soul}'
          .toLowerCase();
      final haystackWords = haystack.split(RegExp(r'[^a-z0-9]+')).toSet();
      var score = 0;
      for (final word in words) {
        if (haystackWords.contains(word)) score += 1;
      }
      if (score > bestScore) {
        bestScore = score;
        best = bot.id;
      }
    }
    return best;
  }
}
