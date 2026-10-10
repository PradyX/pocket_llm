import 'package:pocket_llm/core/utils/id_generator.dart';

/// How far a bot's learned facts travel (Road Map 2 §7.4).
///
/// Bots share project facts, never hidden internal reasoning. The default
/// for every template is workspace scope.
enum BotMemoryScope {
  /// Learns nothing between turns.
  none('None'),

  /// Remembers inside one conversation only.
  conversation('Conversation'),

  /// Shares facts across the workspace's chats.
  workspace('Workspace'),

  /// Shares facts across every workspace on this device.
  global('Global');

  const BotMemoryScope(this.label);
  final String label;
}

/// Limits that keep a bot usable: soul and description are prompt text.
abstract final class BotLimits {
  static const int maxNameCharacters = 60;
  static const int maxDescriptionCharacters = 400;

  /// Roughly 1500 tokens: a soul is identity, not a manual.
  static const int maxSoulCharacters = 6000;
}

/// A reusable specialized bot: more than a system prompt.
///
/// Road Map 2 Phase 2.4. The concepts stay separate on purpose:
/// ```text
/// Soul       = identity + operating principles
/// Task       = current assignment (workflows/group chat own this)
/// Memory     = learned project information (scoped by [memoryScope])
/// Context    = current conversation
/// Skill      = reusable domain procedure
/// ```
class Bot {
  const Bot({
    required this.id,
    required this.name,
    this.icon = '🤖',
    this.description = '',
    this.soul = '',
    this.modelId,
    this.contextPolicyId,
    this.inferenceProfileId,
    this.skillIds = const [],
    this.mcpServerIds = const [],
    this.toolPermissions = const {},
    this.memoryScope = BotMemoryScope.workspace,
    this.workspaceIds = const [],
    this.isBuiltIn = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Bot.create({
    String? id,
    required String name,
    String icon = '🤖',
    String description = '',
    String soul = '',
    String? modelId,
    String? contextPolicyId,
    String? inferenceProfileId,
    List<String> skillIds = const [],
    List<String> mcpServerIds = const [],
    Set<String> toolPermissions = const {},
    BotMemoryScope memoryScope = BotMemoryScope.workspace,
    List<String> workspaceIds = const [],
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return Bot(
      id: id ?? IdGenerator.generate('bot'),
      name: name,
      icon: icon,
      description: description,
      soul: soul,
      modelId: modelId,
      contextPolicyId: contextPolicyId,
      inferenceProfileId: inferenceProfileId,
      skillIds: skillIds,
      mcpServerIds: mcpServerIds,
      toolPermissions: toolPermissions,
      memoryScope: memoryScope,
      workspaceIds: workspaceIds,
      createdAt: timestamp,
      updatedAt: timestamp,
    ).normalized();
  }

  final String id;
  final String name;

  /// One emoji shown wherever the bot speaks.
  final String icon;
  final String description;

  /// Persistent identity and operating principles. Sent with every request
  /// the bot answers and preserved across compactions.
  final String soul;

  /// Preferred model; null follows the conversation's model.
  final String? modelId;
  final String? contextPolicyId;
  final String? inferenceProfileId;

  final List<String> skillIds;
  final List<String> mcpServerIds;

  /// Capability values (`filesystem:read`) this bot may exercise.
  final Set<String> toolPermissions;
  final BotMemoryScope memoryScope;

  /// Workspaces this bot belongs to; empty means every workspace.
  final List<String> workspaceIds;
  final bool isBuiltIn;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasSoul => soul.trim().isNotEmpty;

  bool visibleIn(String? workspaceId) {
    if (workspaceId == null) return true;
    return workspaceIds.isEmpty || workspaceIds.contains(workspaceId);
  }

  Bot normalized() {
    String clamp(String value, int max) =>
        value.length <= max ? value : value.substring(0, max);
    return Bot(
      id: id,
      name: clamp(name.trim(), BotLimits.maxNameCharacters).isEmpty
          ? 'Untitled bot'
          : clamp(name.trim(), BotLimits.maxNameCharacters),
      icon: icon.trim().isEmpty ? '🤖' : icon.trim(),
      description: clamp(
        description.trim(),
        BotLimits.maxDescriptionCharacters,
      ),
      soul: clamp(soul, BotLimits.maxSoulCharacters),
      modelId: modelId,
      contextPolicyId: contextPolicyId,
      inferenceProfileId: inferenceProfileId,
      skillIds: List.unmodifiable(skillIds),
      mcpServerIds: List.unmodifiable(mcpServerIds),
      toolPermissions: toolPermissions
          .map((permission) => permission.trim())
          .where((permission) => permission.isNotEmpty)
          .toSet(),
      memoryScope: memoryScope,
      workspaceIds: List.unmodifiable(workspaceIds),
      isBuiltIn: isBuiltIn,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Bot copyWith({
    String? name,
    String? icon,
    String? description,
    String? soul,
    String? modelId,
    bool clearModel = false,
    String? contextPolicyId,
    String? inferenceProfileId,
    bool clearProfile = false,
    List<String>? skillIds,
    List<String>? mcpServerIds,
    Set<String>? toolPermissions,
    BotMemoryScope? memoryScope,
    List<String>? workspaceIds,
    DateTime? updatedAt,
  }) {
    return Bot(
      id: id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      description: description ?? this.description,
      soul: soul ?? this.soul,
      modelId: clearModel ? null : (modelId ?? this.modelId),
      contextPolicyId: contextPolicyId ?? this.contextPolicyId,
      inferenceProfileId: clearProfile
          ? null
          : (inferenceProfileId ?? this.inferenceProfileId),
      skillIds: skillIds ?? this.skillIds,
      mcpServerIds: mcpServerIds ?? this.mcpServerIds,
      toolPermissions: toolPermissions ?? this.toolPermissions,
      memoryScope: memoryScope ?? this.memoryScope,
      workspaceIds: workspaceIds ?? this.workspaceIds,
      isBuiltIn: isBuiltIn,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    ).normalized();
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'icon': icon,
      'description': description,
      'soul': soul,
      'modelId': modelId,
      'contextPolicyId': contextPolicyId,
      'inferenceProfileId': inferenceProfileId,
      'skillIds': skillIds,
      'mcpServerIds': mcpServerIds,
      'toolPermissions': toolPermissions.toList()..sort(),
      'memoryScope': memoryScope.name,
      'workspaceIds': workspaceIds,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static Bot? fromJson(Map<String, dynamic> json, {bool builtIn = false}) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;

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

    String? readOpt(Object? value) => value is String ? value : null;
    return Bot(
      id: id,
      name: name,
      icon: readOpt(json['icon']) ?? '🤖',
      description: readOpt(json['description']) ?? '',
      soul: readOpt(json['soul']) ?? '',
      modelId: readOpt(json['modelId']),
      contextPolicyId: readOpt(json['contextPolicyId']),
      inferenceProfileId: readOpt(json['inferenceProfileId']),
      skillIds: readStrings(json['skillIds']),
      mcpServerIds: readStrings(json['mcpServerIds']),
      toolPermissions: readStrings(json['toolPermissions']).toSet(),
      memoryScope: BotMemoryScope.values.firstWhere(
        (candidate) => candidate.name == json['memoryScope'],
        orElse: () => BotMemoryScope.workspace,
      ),
      workspaceIds: readStrings(json['workspaceIds']),
      isBuiltIn: builtIn,
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
    ).normalized();
  }
}
