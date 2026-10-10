import 'package:pocket_llm/core/permissions/workspace_permission.dart';
import 'package:pocket_llm/core/utils/id_generator.dart';

/// Where a skill came from (Road Map 2 §5.2).
enum SkillSource {
  /// Ships with the app; read-only code, never written to disk.
  builtIn('Built-in'),

  /// A SKILL.md folder on this device, referenced by path.
  local('Local'),

  /// Copied into the app from a file or folder the user chose.
  imported('Imported'),

  /// Lives inside a workspace folder (and may sync with it).
  workspace('Workspace');

  const SkillSource(this.label);
  final String label;
}

/// Limits that keep a skill useful: a skill is prompt text, and text costs
/// context. Values trim rather than reject so a hand-edited file cannot break
/// every request.
abstract final class SkillLimits {
  static const int maxNameCharacters = 80;
  static const int maxDescriptionCharacters = 400;
  static const int maxBodyCharacters = 12000;
  static const int maxResourceCharacters = 8000;
}

/// A reusable ability: instructions plus optional supporting resources.
///
/// Road Map 2 Phase 2.2. The manifest answers "what is this and what may it
/// need"; the body is the procedure the model reads. Only bodies selected by
/// [SkillSelector] ever reach a prompt — installing a skill costs no context
/// until it is relevant.
class Skill {
  const Skill({
    required this.id,
    required this.name,
    this.description = '',
    this.version = 1,
    this.requiredCapabilities = const {},
    this.body = '',
    this.source = SkillSource.imported,
    this.localPath,
    this.workspaceId,
    this.enabled = true,
    this.assignedBotIds = const [],
    this.resourceNames = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  factory Skill.create({
    String? id,
    required String name,
    String description = '',
    int version = 1,
    Set<String> requiredCapabilities = const {},
    String body = '',
    SkillSource source = SkillSource.imported,
    String? localPath,
    String? workspaceId,
    bool enabled = true,
    List<String> assignedBotIds = const [],
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return Skill(
      id: id ?? IdGenerator.generate('skill'),
      name: name,
      description: description,
      version: version,
      requiredCapabilities: requiredCapabilities,
      body: body,
      source: source,
      localPath: localPath,
      workspaceId: workspaceId,
      enabled: enabled,
      assignedBotIds: assignedBotIds,
      createdAt: timestamp,
      updatedAt: timestamp,
    ).normalized();
  }

  final String id;
  final String name;
  final String description;

  /// Manifest version from SKILL.md frontmatter.
  final int version;

  /// Capabilities the skill needs, e.g. `filesystem:read`. A bot may only
  /// use this skill when it allows all of them (§5.5).
  final Set<String> requiredCapabilities;

  /// The SKILL.md instructions.
  final String body;
  final SkillSource source;

  /// Folder holding SKILL.md for local/workspace skills, if any.
  final String? localPath;

  /// Workspace this skill belongs to, if any.
  final String? workspaceId;
  final bool enabled;
  final List<String> assignedBotIds;

  /// Supporting files (references/, templates/…) available on demand.
  final List<String> resourceNames;

  final DateTime createdAt;
  final DateTime updatedAt;

  Set<Capability> get capabilities =>
      requiredCapabilities.map(Capability.new).toSet();

  /// True when a bot allowing [botCapabilities] may use this skill.
  bool allowedFor(Set<Capability> botCapabilities) {
    return PermissionPolicy.skillAllowed(
      skillRequires: capabilities,
      botAllows: botCapabilities,
    );
  }

  bool get isBuiltIn => source == SkillSource.builtIn;

  Skill normalized() {
    String clamp(String value, int max) =>
        value.length <= max ? value : value.substring(0, max);
    return Skill(
      id: id,
      name: clamp(name.trim(), SkillLimits.maxNameCharacters),
      description: clamp(
        description.trim(),
        SkillLimits.maxDescriptionCharacters,
      ),
      version: version < 1 ? 1 : version,
      requiredCapabilities: requiredCapabilities
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toSet(),
      body: clamp(body, SkillLimits.maxBodyCharacters),
      source: source,
      localPath: localPath,
      workspaceId: workspaceId,
      enabled: enabled,
      assignedBotIds: List.unmodifiable(assignedBotIds),
      resourceNames: List.unmodifiable(resourceNames),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Skill copyWith({
    String? name,
    String? description,
    int? version,
    Set<String>? requiredCapabilities,
    String? body,
    String? localPath,
    String? workspaceId,
    bool? enabled,
    List<String>? assignedBotIds,
    List<String>? resourceNames,
    DateTime? updatedAt,
  }) {
    return Skill(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      version: version ?? this.version,
      requiredCapabilities: requiredCapabilities ?? this.requiredCapabilities,
      body: body ?? this.body,
      source: source,
      localPath: localPath ?? this.localPath,
      workspaceId: workspaceId ?? this.workspaceId,
      enabled: enabled ?? this.enabled,
      assignedBotIds: assignedBotIds ?? this.assignedBotIds,
      resourceNames: resourceNames ?? this.resourceNames,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    ).normalized();
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'version': version,
      'permissions': requiredCapabilities.toList()..sort(),
      'body': body,
      'source': source.name,
      'localPath': localPath,
      'workspaceId': workspaceId,
      'enabled': enabled,
      'assignedBotIds': assignedBotIds,
      'resourceNames': resourceNames,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static Skill? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final source = SkillSource.values.firstWhere(
      (candidate) => candidate.name == json['source'],
      orElse: () => SkillSource.imported,
    );
    Set<String> readCapabilities(Object? value) {
      if (value is! List) return const {};
      return value.whereType<String>().toSet();
    }

    List<String> readStrings(Object? value) {
      if (value is! List) return const [];
      return value.whereType<String>().toList(growable: false);
    }

    DateTime parseDate(Object? value) {
      if (value is String) {
        return DateTime.tryParse(value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    String readText(Object? value) => value is String ? value : '';
    return Skill(
      id: id,
      name: name,
      description: readText(json['description']),
      version: json['version'] is num ? (json['version'] as num).toInt() : 1,
      requiredCapabilities: readCapabilities(json['permissions']),
      body: readText(json['body']),
      source: source,
      localPath: json['localPath'] is String
          ? json['localPath'] as String
          : null,
      workspaceId: json['workspaceId'] is String
          ? json['workspaceId'] as String
          : null,
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      assignedBotIds: readStrings(json['assignedBotIds']),
      resourceNames: readStrings(json['resourceNames']),
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
    ).normalized();
  }
}
