import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/skills/domain/built_in_skills.dart';
import 'package:pocket_llm/features/skills/domain/skill.dart';

/// Persisted skill registry: user skills plus per-skill state.
///
/// Built-ins are code and never written; they seed every load. Bodies are
/// small (clamped to a few thousand tokens), so custom skills live in this
/// one document instead of a file tree.
class SkillStore {
  SkillStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'SkillStore',
      );

  static const int currentVersion = 1;

  static Future<SkillStore> open() async {
    final support = await getApplicationSupportDirectory();
    return SkillStore(File(p.join(support.path, 'skills', 'skills.json')));
  }

  final VersionedJsonDocument _document;

  String get filePath => _document.filePath;
  bool get isReadOnly => _document.isReadOnly;

  SkillsSnapshot load() {
    final decoded = _document.read();
    if (decoded == null) return SkillsSnapshot.empty;
    return SkillsSnapshot.fromJson(decoded);
  }

  bool save(SkillsSnapshot snapshot) {
    return _document.write({
      'version': currentVersion,
      'skills': snapshot.customSkills.map((s) => s.toJson()).toList(),
      'disabledBuiltInIds': snapshot.disabledBuiltInIds,
    });
  }
}

/// Custom skills plus which built-ins the user turned off; built-ins are
/// prepended by [allSkills].
class SkillsSnapshot {
  const SkillsSnapshot({
    required this.customSkills,
    this.disabledBuiltInIds = const [],
  });

  static const SkillsSnapshot empty = SkillsSnapshot(customSkills: []);

  final List<Skill> customSkills;

  /// Built-in ids disabled by the user.
  final List<String> disabledBuiltInIds;

  /// Built-ins (with stored disables applied) followed by custom skills.
  List<Skill> get allSkills => [
    for (final skill in BuiltInSkills.all())
      if (disabledBuiltInIds.contains(skill.id))
        skill.copyWith(enabled: false)
      else
        skill,
    ...customSkills,
  ];

  SkillsSnapshot upsert(Skill skill) {
    final updated = <Skill>[];
    var replaced = false;
    for (final existing in customSkills) {
      if (existing.id == skill.id) {
        updated.add(skill);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(skill);
    return SkillsSnapshot(
      customSkills: updated,
      disabledBuiltInIds: disabledBuiltInIds,
    );
  }

  SkillsSnapshot remove(String skillId) {
    return SkillsSnapshot(
      customSkills: customSkills.where((skill) => skill.id != skillId).toList(),
      disabledBuiltInIds: disabledBuiltInIds,
    );
  }

  /// Records a built-in enable/disable that survives restarts.
  SkillsSnapshot withBuiltInEnabled(String skillId, bool enabled) {
    final disabled = disabledBuiltInIds.toSet();
    if (enabled) {
      disabled.remove(skillId);
    } else {
      disabled.add(skillId);
    }
    return SkillsSnapshot(
      customSkills: customSkills,
      disabledBuiltInIds: disabled.toList(),
    );
  }

  static SkillsSnapshot fromJson(Map<String, dynamic> json) {
    final raw = json['skills'];
    final skills = <Skill>[];
    if (raw is List) {
      for (final entry in raw) {
        final map = entry is Map<String, dynamic>
            ? entry
            : entry is Map
            ? Map<String, dynamic>.from(entry)
            : null;
        if (map == null) continue;
        // Built-ins are code: a stored copy (from an older build) is ignored.
        if (map['source'] == SkillSource.builtIn.name) continue;
        final skill = Skill.fromJson(map);
        if (skill != null) skills.add(skill);
      }
    }
    List<String> readIds(Object? value) {
      if (value is! List) return const [];
      return value.whereType<String>().toList(growable: false);
    }

    return SkillsSnapshot(
      customSkills: skills,
      disabledBuiltInIds: readIds(json['disabledBuiltInIds']),
    );
  }
}
