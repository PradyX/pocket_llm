/// One shared permission system for native tools, skills, MCP, bots,
/// Obsidian, Kanban and workflows (Road Map 2 §15).
///
/// A decision always considers bot + workspace + capability + resource, and
/// resolves to a single level. The ordering is Denied < Ask < Allowed.
enum PermissionLevel {
  denied('Denied'),
  ask('Ask every time'),
  workspace('Allowed in workspace'),
  always('Always allowed');

  const PermissionLevel(this.label);
  final String label;

  bool get allows =>
      this == PermissionLevel.workspace || this == PermissionLevel.always;
  bool get asks => this == PermissionLevel.ask;
}

/// What is being guarded: `filesystem.read`, `shell.execute`, `vault.write`…
class Capability {
  const Capability(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is Capability && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// One rule: who may do what, where.
class PermissionRule {
  const PermissionRule({
    required this.botId,
    required this.workspaceId,
    required this.capability,
    this.resourcePattern,
    required this.level,
  });

  /// `*` matches any bot; empty workspace matches every workspace.
  final String botId;
  final String workspaceId;
  final Capability capability;

  /// Glob-ish prefix: `Projects/pocketllm/**` or null for any resource.
  final String? resourcePattern;
  final PermissionLevel level;

  bool matches({
    required String botId,
    required String workspaceId,
    required Capability capability,
    String? resource,
  }) {
    if (this.botId != '*' && this.botId != botId) return false;
    if (this.workspaceId.isNotEmpty && this.workspaceId != workspaceId) {
      return false;
    }
    if (this.capability != capability) return false;
    final pattern = resourcePattern;
    if (pattern == null || pattern.isEmpty) return true;
    final target = resource ?? '';
    if (pattern.endsWith('/**')) {
      return target.startsWith(pattern.substring(0, pattern.length - 3));
    }
    return target == pattern;
  }

  Map<String, dynamic> toJson() => {
    'botId': botId,
    'workspaceId': workspaceId,
    'capability': capability.value,
    'resourcePattern': resourcePattern,
    'level': level.name,
  };

  static PermissionRule? fromJson(Map<String, dynamic> json) {
    final botId = json['botId'];
    final workspaceId = json['workspaceId'];
    final capability = json['capability'];
    final levelName = json['level'];
    if (botId is! String || workspaceId is! String || capability is! String) {
      return null;
    }
    final level = PermissionLevel.values.firstWhere(
      (candidate) => candidate.name == levelName,
      orElse: () => PermissionLevel.denied,
    );
    final pattern = json['resourcePattern'] is String
        ? json['resourcePattern'] as String
        : null;
    return PermissionRule(
      botId: botId,
      workspaceId: workspaceId,
      capability: Capability(capability),
      resourcePattern: pattern,
      level: level,
    );
  }
}

/// Resolves the effective level for one action.
///
/// Rules are evaluated in order; the first match wins, so callers put the
/// most specific rule first. No matching rule means [PermissionLevel.ask],
/// which is the safe default for anything that acts outside the app.
class PermissionPolicy {
  const PermissionPolicy({this.rules = const []});

  final List<PermissionRule> rules;

  PermissionLevel decide({
    required String botId,
    required String workspaceId,
    required Capability capability,
    String? resource,
  }) {
    for (final rule in rules) {
      if (rule.matches(
        botId: botId,
        workspaceId: workspaceId,
        capability: capability,
        resource: resource,
      )) {
        return rule.level;
      }
    }
    return PermissionLevel.ask;
  }

  /// Combines what a skill needs with what a bot allows (Road Map 2 §5.5).
  static bool skillAllowed({
    required Set<Capability> skillRequires,
    required Set<Capability> botAllows,
  }) {
    return skillRequires.every(botAllows.contains);
  }

  static PermissionPolicy defaultPolicy() {
    return const PermissionPolicy(
      rules: [
        PermissionRule(
          botId: '*',
          workspaceId: '',
          capability: Capability('shell.execute'),
          level: PermissionLevel.ask,
        ),
        PermissionRule(
          botId: '*',
          workspaceId: '',
          capability: Capability('vault.delete'),
          level: PermissionLevel.ask,
        ),
      ],
    );
  }
}
