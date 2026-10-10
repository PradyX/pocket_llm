import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/skills/domain/skill.dart';

/// One skill selected for the current task, with the prompt section to inject.
class SelectedSkill {
  const SelectedSkill({required this.skill, required this.sectionTokens});

  final Skill skill;
  final int sectionTokens;
}

/// Progressive skill loading (Road Map 2 §5.3).
///
/// Installed skills cost no context until they are relevant: this ranks the
/// enabled skills against the task text with a local keyword overlap (no
/// model call, works offline), then takes skills newest-most-relevant-first
/// while they fit the skill share of the usable input budget.
abstract final class SkillSelector {
  /// Share of the usable input budget skills may take at most.
  static const int maximumSkillShare = 4;

  /// Ranks [skills] against [taskText], most relevant first.
  ///
  /// Only enabled skills assigned to [botId] (or unassigned, which means
  /// available to every bot) in [workspaceId] (or global, when null) are
  /// candidates. A zero score never selects: installing an unrelated skill
  /// must not tax the prompt.
  static List<Skill> rank({
    required List<Skill> skills,
    required String taskText,
    String? botId,
    String? workspaceId,
  }) {
    final words = _keywords(taskText);
    final scored = <({Skill skill, int score})>[];
    for (final skill in skills) {
      if (!skill.enabled) continue;
      if (workspaceId != null &&
          skill.workspaceId != null &&
          skill.workspaceId != workspaceId) {
        continue;
      }
      if (botId != null &&
          skill.assignedBotIds.isNotEmpty &&
          !skill.assignedBotIds.contains(botId)) {
        continue;
      }
      final score = _score(skill, words);
      if (score > 0) scored.add((skill: skill, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return [for (final entry in scored) entry.skill];
  }

  /// Selects skills that fit [usableInputTokens], most relevant first.
  static List<SelectedSkill> select({
    required List<Skill> ranked,
    required int usableInputTokens,
  }) {
    final budget = usableInputTokens ~/ maximumSkillShare;
    final selected = <SelectedSkill>[];
    var used = 0;
    for (final skill in ranked) {
      final cost = sectionTokens(skill);
      if (used + cost > budget) continue;
      used += cost;
      selected.add(SelectedSkill(skill: skill, sectionTokens: cost));
    }
    return selected;
  }

  /// Prompt section for one skill, with its resource list for on-demand loads.
  static String sectionFor(Skill skill) {
    final buffer = StringBuffer('Skill: ${skill.name}');
    if (skill.description.isNotEmpty) {
      buffer.write(' — ${skill.description}');
    }
    buffer.write('\n${skill.body.trim()}');
    if (skill.resourceNames.isNotEmpty) {
      buffer.write('\nAvailable resources: ${skill.resourceNames.join(', ')}');
    }
    return buffer.toString();
  }

  static int sectionTokens(Skill skill) =>
      TokenEstimator.estimateText(sectionFor(skill));

  static Set<String> _keywords(String text) {
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.length > 2)
        .toSet();
  }

  static int _score(Skill skill, Set<String> words) {
    if (words.isEmpty) return 0;
    // Whole words only: substring matching ranks unrelated skills whose
    // text happens to contain a query fragment.
    final haystack = _keywords(
      '${skill.name} ${skill.description} ${skill.body}',
    );
    var score = 0;
    for (final word in words) {
      if (haystack.contains(word)) score += word.length > 5 ? 2 : 1;
    }
    // The name decides what a skill is for: a name hit counts triple.
    final nameWords = _keywords(skill.name);
    for (final word in words) {
      if (nameWords.contains(word)) score += 3;
    }
    return score;
  }
}
