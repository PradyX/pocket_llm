import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/skills/data/skill_store.dart';
import 'package:pocket_llm/features/skills/domain/built_in_skills.dart';
import 'package:pocket_llm/features/skills/domain/skill.dart';
import 'package:pocket_llm/features/skills/domain/skill_parser.dart';

/// Skill registry file, opened once per session.
final skillStoreProvider = FutureProvider<SkillStore>(
  (ref) => SkillStore.open(),
);

class SkillsState {
  const SkillsState({
    this.skills = const [],
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
  });

  final List<Skill> skills;
  final bool isReady;
  final String? errorMessage;
  final bool isReadOnly;

  List<Skill> get builtInSkills =>
      skills.where((skill) => skill.isBuiltIn).toList(growable: false);
  List<Skill> get customSkills =>
      skills.where((skill) => !skill.isBuiltIn).toList(growable: false);

  Skill? skillById(String? id) {
    if (id == null) return null;
    for (final skill in skills) {
      if (skill.id == id) return skill;
    }
    return null;
  }

  SkillsState copyWith({
    List<Skill>? skills,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
  }) {
    return SkillsState(
      skills: skills ?? this.skills,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
    );
  }
}

final skillsProvider = StateNotifierProvider<SkillsNotifier, SkillsState>(
  (ref) => SkillsNotifier(ref),
);

/// Owns the skill registry: install, enable/disable, assign, remove.
///
/// Built-ins are read-only and can only be enabled or disabled; everything
/// else can be edited. State changes persist as one document write.
class SkillsNotifier extends StateNotifier<SkillsState> {
  SkillsNotifier(this._ref) : super(SkillsState(skills: BuiltInSkills.all())) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final store = await _ref.read(skillStoreProvider.future);
      final snapshot = store.load();
      state = SkillsState(
        skills: snapshot.allSkills,
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'Skills were written by a newer version of Pocket LLM and are '
                  'read-only in this build.'
            : null,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load skills: $error',
      );
    }
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(skillStoreProvider.future);
      if (store.isReadOnly) {
        state = state.copyWith(
          errorMessage:
              'Skills were written by a newer version and are '
              'read-only in this build.',
        );
        return false;
      }
      final disabled = [
        for (final skill in BuiltInSkills.all())
          if (state.skillById(skill.id)?.enabled == false) skill.id,
      ];
      return store.save(
        SkillsSnapshot(
          customSkills: state.customSkills,
          disabledBuiltInIds: disabled,
        ),
      );
    } catch (error) {
      state = state.copyWith(errorMessage: 'Could not save skills: $error');
      return false;
    }
  }

  /// Imports one SKILL.md file's text as a custom skill.
  Future<Skill?> importSkillText(String text, {String? sourceName}) async {
    final parsed = SkillParser.parse(
      text,
      fallbackName: (sourceName ?? 'skill').trim().isEmpty
          ? 'skill'
          : sourceName!.trim(),
    );
    final skill = Skill.create(
      name: parsed.name,
      description: parsed.description,
      version: parsed.version,
      requiredCapabilities: parsed.permissions.toSet(),
      body: parsed.body,
    );
    state = state.copyWith(skills: [...state.skills, skill], clearError: true);
    final saved = await _persist();
    return saved ? skill : null;
  }

  Future<bool> setEnabled(String skillId, bool enabled) async {
    final skill = state.skillById(skillId);
    if (skill == null || skill.enabled == enabled) return false;
    state = state.copyWith(
      skills: [
        for (final candidate in state.skills)
          if (candidate.id == skillId)
            candidate.copyWith(enabled: enabled)
          else
            candidate,
      ],
      clearError: true,
    );
    return _persist();
  }

  /// Assigns a skill to a bot (or unassigns with null). Unassigned custom
  /// skills stay available to every bot.
  Future<bool> assignToBot(String skillId, String? botId) async {
    final skill = state.skillById(skillId);
    if (skill == null || skill.isBuiltIn) return false;
    final assigned = {...skill.assignedBotIds};
    if (botId == null) {
      assigned.clear();
    } else {
      assigned.add(botId);
    }
    state = state.copyWith(
      skills: [
        for (final candidate in state.skills)
          if (candidate.id == skillId)
            candidate.copyWith(assignedBotIds: assigned.toList())
          else
            candidate,
      ],
      clearError: true,
    );
    return _persist();
  }

  Future<bool> removeSkill(String skillId) async {
    final skill = state.skillById(skillId);
    if (skill == null || skill.isBuiltIn) return false;
    state = state.copyWith(
      skills: [
        for (final candidate in state.skills)
          if (candidate.id != skillId) candidate,
      ],
      clearError: true,
    );
    return _persist();
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}
