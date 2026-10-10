import 'package:pocket_llm/core/utils/id_generator.dart';

/// How the app reaches an MCP server (Road Map 2 §6.2).
enum McpTransportKind {
  /// Spawned process over newline-delimited JSON-RPC. Desktop only: Android
  /// and iOS never spawn arbitrary Node/Python processes.
  stdio('Standard I/O'),

  /// Remote server over HTTP (Streamable HTTP POST). Every platform.
  remote('Remote HTTP');

  const McpTransportKind(this.label);
  final String label;
}

/// Permission for one MCP server or one of its tools (§6.4).
enum McpPermission {
  /// Never offered to the model and never runs.
  disabled('Disabled'),

  /// Offered only when the tool declares itself read-only.
  readOnly('Read-only'),

  /// The user decides on every call.
  ask('Ask every time'),

  /// Runs without asking.
  allow('Always allow');

  const McpPermission(this.label);
  final String label;
}

/// One configured MCP server: what it is and what it may do.
///
/// The config (this file's JSON) never holds secrets: tokens live in secure
/// device storage keyed by server id, and the synced vault never sees them
/// (§19).
class McpServer {
  const McpServer({
    required this.id,
    required this.name,
    this.transport = McpTransportKind.remote,
    this.command = '',
    this.args = const [],
    this.url = '',
    this.enabled = true,
    this.defaultPermission = McpPermission.ask,
    this.toolPermissions = const {},
    this.workspaceIds = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  factory McpServer.create({
    String? id,
    required String name,
    McpTransportKind transport = McpTransportKind.remote,
    String command = '',
    List<String> args = const [],
    String url = '',
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return McpServer(
      id: id ?? IdGenerator.generate('mcp'),
      name: name.trim().isEmpty ? 'Untitled MCP server' : name.trim(),
      transport: transport,
      command: command.trim(),
      args: args,
      url: url.trim(),
      createdAt: timestamp,
      updatedAt: timestamp,
    ).normalized();
  }

  final String id;
  final String name;
  final McpTransportKind transport;

  /// Executable for stdio servers (e.g. `npx`); unused for remote servers.
  final String command;
  final List<String> args;

  /// Endpoint for remote servers; unused for stdio servers.
  final String url;
  final bool enabled;

  /// Permission used by tools without their own entry.
  final McpPermission defaultPermission;

  /// Per-tool overrides, keyed by tool name.
  final Map<String, McpPermission> toolPermissions;

  /// Workspaces this server is visible in; empty means every workspace.
  final List<String> workspaceIds;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// True when this server may appear in [workspaceId]'s toolset.
  bool visibleIn(String? workspaceId) {
    if (workspaceId == null) return true;
    return workspaceIds.isEmpty || workspaceIds.contains(workspaceId);
  }

  McpPermission permissionFor(String toolName) {
    return toolPermissions[toolName] ?? defaultPermission;
  }

  /// What is wrong with this config, or null when it can connect.
  String? get configError {
    switch (transport) {
      case McpTransportKind.stdio:
        if (command.isEmpty) return 'A stdio server needs a command.';
        return null;
      case McpTransportKind.remote:
        final uri = Uri.tryParse(url);
        if (url.isEmpty || uri == null || !uri.hasScheme) {
          return 'A remote server needs an http(s) URL.';
        }
        return null;
    }
  }

  bool get canConnect => enabled && configError == null;

  McpServer normalized() {
    return McpServer(
      id: id,
      name: name.trim().isEmpty ? 'Untitled MCP server' : name.trim(),
      transport: transport,
      command: command.trim(),
      args: List.unmodifiable(args),
      url: url.trim(),
      enabled: enabled,
      defaultPermission: defaultPermission,
      toolPermissions: Map.unmodifiable(toolPermissions),
      workspaceIds: List.unmodifiable(workspaceIds),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  McpServer copyWith({
    String? name,
    McpTransportKind? transport,
    String? command,
    List<String>? args,
    String? url,
    bool? enabled,
    McpPermission? defaultPermission,
    Map<String, McpPermission>? toolPermissions,
    List<String>? workspaceIds,
    DateTime? updatedAt,
  }) {
    return McpServer(
      id: id,
      name: name ?? this.name,
      transport: transport ?? this.transport,
      command: command ?? this.command,
      args: args ?? this.args,
      url: url ?? this.url,
      enabled: enabled ?? this.enabled,
      defaultPermission: defaultPermission ?? this.defaultPermission,
      toolPermissions: toolPermissions ?? this.toolPermissions,
      workspaceIds: workspaceIds ?? this.workspaceIds,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    ).normalized();
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'transport': transport.name,
      'command': command,
      'args': args,
      'url': url,
      'enabled': enabled,
      'defaultPermission': defaultPermission.name,
      'toolPermissions': {
        for (final entry in toolPermissions.entries)
          entry.key: entry.value.name,
      },
      'workspaceIds': workspaceIds,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static McpServer? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final transport = McpTransportKind.values.firstWhere(
      (candidate) => candidate.name == json['transport'],
      orElse: () => McpTransportKind.remote,
    );
    final defaultPermission = McpPermission.values.firstWhere(
      (candidate) => candidate.name == json['defaultPermission'],
      orElse: () => McpPermission.ask,
    );
    final toolPermissions = <String, McpPermission>{};
    final rawPermissions = json['toolPermissions'];
    if (rawPermissions is Map) {
      for (final entry in rawPermissions.entries) {
        final tool = entry.key;
        if (tool is! String) continue;
        toolPermissions[tool] = McpPermission.values.firstWhere(
          (candidate) => candidate.name == entry.value,
          orElse: () => defaultPermission,
        );
      }
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

    return McpServer(
      id: id,
      name: name,
      transport: transport,
      command: json['command'] is String ? json['command'] as String : '',
      args: readStrings(json['args']),
      url: json['url'] is String ? json['url'] as String : '',
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      defaultPermission: defaultPermission,
      toolPermissions: toolPermissions,
      workspaceIds: readStrings(json['workspaceIds']),
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
    ).normalized();
  }
}
