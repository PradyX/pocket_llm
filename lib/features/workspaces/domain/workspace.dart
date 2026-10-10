import 'package:pocket_llm/core/utils/id_generator.dart';

/// A project workspace: the boundary linking bots, chats, skills, MCP
/// servers, boards, documents and memory.
///
/// Road Map 2 Phase 2.0. A bot assigned to workspace A never sees workspace
/// B unless it is also assigned there; every workspace-scoped lookup filters
/// by [id].
class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    this.description = '',
    this.obsidianVaultId,
    this.obsidianProjectPath = '',
    this.repositoryPath,
    this.defaultModelId,
    this.defaultContextPolicyId,
    this.botIds = const [],
    this.skillIds = const [],
    this.mcpServerIds = const [],
    this.boardIds = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  factory Workspace.create({
    String? id,
    required String name,
    String description = '',
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return Workspace(
      id: id ?? IdGenerator.generate('workspace'),
      name: name.trim().isEmpty ? 'Untitled workspace' : name.trim(),
      description: description.trim(),
      createdAt: timestamp,
      updatedAt: timestamp,
    ).normalized();
  }

  final String id;
  final String name;
  final String description;

  /// Registered vault this workspace reads/writes, if any.
  final String? obsidianVaultId;

  /// Workspace-relative directory inside the vault (e.g. `Projects/pocketllm`).
  final String obsidianProjectPath;

  /// Local Git checkout bots work in, if any. Device-specific, never synced.
  final String? repositoryPath;

  final String? defaultModelId;
  final String? defaultContextPolicyId;

  final List<String> botIds;
  final List<String> skillIds;
  final List<String> mcpServerIds;
  final List<String> boardIds;

  final DateTime createdAt;
  final DateTime updatedAt;

  Workspace normalized() {
    return Workspace(
      id: id,
      name: name.trim().isEmpty ? 'Untitled workspace' : name.trim(),
      description: description.trim(),
      obsidianVaultId: obsidianVaultId,
      obsidianProjectPath: obsidianProjectPath.trim(),
      repositoryPath: repositoryPath,
      defaultModelId: defaultModelId,
      defaultContextPolicyId: defaultContextPolicyId,
      botIds: List.unmodifiable(botIds),
      skillIds: List.unmodifiable(skillIds),
      mcpServerIds: List.unmodifiable(mcpServerIds),
      boardIds: List.unmodifiable(boardIds),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Workspace copyWith({
    String? name,
    String? description,
    String? obsidianVaultId,
    bool clearVault = false,
    String? obsidianProjectPath,
    String? repositoryPath,
    bool clearRepository = false,
    String? defaultModelId,
    String? defaultContextPolicyId,
    List<String>? botIds,
    List<String>? skillIds,
    List<String>? mcpServerIds,
    List<String>? boardIds,
    DateTime? updatedAt,
  }) {
    return Workspace(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      obsidianVaultId: clearVault
          ? null
          : (obsidianVaultId ?? this.obsidianVaultId),
      obsidianProjectPath: obsidianProjectPath ?? this.obsidianProjectPath,
      repositoryPath: clearRepository
          ? null
          : (repositoryPath ?? this.repositoryPath),
      defaultModelId: defaultModelId ?? this.defaultModelId,
      defaultContextPolicyId:
          defaultContextPolicyId ?? this.defaultContextPolicyId,
      botIds: botIds ?? this.botIds,
      skillIds: skillIds ?? this.skillIds,
      mcpServerIds: mcpServerIds ?? this.mcpServerIds,
      boardIds: boardIds ?? this.boardIds,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    ).normalized();
  }

  /// True when [botId] may access this workspace.
  bool allowsBot(String botId) => botIds.contains(botId);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'obsidianVaultId': obsidianVaultId,
      'obsidianProjectPath': obsidianProjectPath,
      'repositoryPath': repositoryPath,
      'defaultModelId': defaultModelId,
      'defaultContextPolicyId': defaultContextPolicyId,
      'botIds': botIds,
      'skillIds': skillIds,
      'mcpServerIds': mcpServerIds,
      'boardIds': boardIds,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static Workspace? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    DateTime parseDate(Object? value) {
      if (value is String) {
        return DateTime.tryParse(value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    List<String> readIds(Object? value) {
      if (value is! List) return const [];
      return value.whereType<String>().toList(growable: false);
    }

    return Workspace(
      id: id,
      name: name,
      description: json['description'] is String
          ? json['description'] as String
          : '',
      obsidianVaultId: json['obsidianVaultId'] is String
          ? json['obsidianVaultId'] as String
          : null,
      obsidianProjectPath: json['obsidianProjectPath'] is String
          ? json['obsidianProjectPath'] as String
          : '',
      repositoryPath: json['repositoryPath'] is String
          ? json['repositoryPath'] as String
          : null,
      defaultModelId: json['defaultModelId'] is String
          ? json['defaultModelId'] as String
          : null,
      defaultContextPolicyId: json['defaultContextPolicyId'] is String
          ? json['defaultContextPolicyId'] as String
          : null,
      botIds: readIds(json['botIds']),
      skillIds: readIds(json['skillIds']),
      mcpServerIds: readIds(json['mcpServerIds']),
      boardIds: readIds(json['boardIds']),
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
    ).normalized();
  }
}
