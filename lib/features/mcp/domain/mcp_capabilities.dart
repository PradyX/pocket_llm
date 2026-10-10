/// What one MCP server offers, as discovered at connect time (§6.3).
///
/// Stored locally so the tool list survives restarts without reconnecting;
/// a stale cache is refreshed on the next successful connection.
class McpCapabilities {
  const McpCapabilities({
    required this.serverId,
    this.tools = const [],
    this.resources = const [],
    this.prompts = const [],
    this.serverName,
    this.serverVersion,
    this.discoveredAt,
  });

  static const McpCapabilities empty = McpCapabilities(serverId: '');

  final String serverId;
  final List<McpToolInfo> tools;
  final List<McpResourceInfo> resources;
  final List<McpPromptInfo> prompts;
  final String? serverName;
  final String? serverVersion;
  final DateTime? discoveredAt;

  bool get isEmpty => tools.isEmpty && resources.isEmpty && prompts.isEmpty;

  Map<String, dynamic> toJson() {
    return {
      'serverId': serverId,
      'tools': tools.map((tool) => tool.toJson()).toList(),
      'resources': resources.map((resource) => resource.toJson()).toList(),
      'prompts': prompts.map((prompt) => prompt.toJson()).toList(),
      'serverName': serverName,
      'serverVersion': serverVersion,
      'discoveredAt': discoveredAt?.toIso8601String(),
    };
  }

  static McpCapabilities fromJson(Map<String, dynamic> json) {
    List<T> readList<T>(
      Object? value,
      T? Function(Map<String, dynamic>) parse,
    ) {
      if (value is! List) return const [];
      final items = <T>[];
      for (final entry in value) {
        final map = entry is Map<String, dynamic>
            ? entry
            : entry is Map
            ? Map<String, dynamic>.from(entry)
            : null;
        if (map == null) continue;
        final item = parse(map);
        if (item != null) items.add(item);
      }
      return items;
    }

    DateTime? discoveredAt;
    if (json['discoveredAt'] is String) {
      discoveredAt = DateTime.tryParse(json['discoveredAt'] as String);
    }
    return McpCapabilities(
      serverId: json['serverId'] is String ? json['serverId'] as String : '',
      tools: readList(json['tools'], McpToolInfo.fromJson),
      resources: readList(json['resources'], McpResourceInfo.fromJson),
      prompts: readList(json['prompts'], McpPromptInfo.fromJson),
      serverName: json['serverName'] is String
          ? json['serverName'] as String
          : null,
      serverVersion: json['serverVersion'] is String
          ? json['serverVersion'] as String
          : null,
      discoveredAt: discoveredAt,
    );
  }
}

/// One tool a server exposes, with its JSON Schema and hints.
class McpToolInfo {
  const McpToolInfo({
    required this.name,
    this.description = '',
    this.inputSchema = const {},
    this.readOnlyHint = false,
  });

  final String name;
  final String description;

  /// The tool's `inputSchema` (JSON Schema object), kept verbatim so calls
  /// validate the way the server expects.
  final Map<String, dynamic> inputSchema;

  /// From the MCP `readOnlyHint` annotation: true means the tool changes
  /// nothing, which is what the read-only permission level allows.
  final bool readOnlyHint;

  /// Namespaced name offered to the model: `server_tool`.
  String namespaced(String serverName) => '${serverName}_$name';

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'inputSchema': inputSchema,
      'readOnlyHint': readOnlyHint,
    };
  }

  static McpToolInfo? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    var schema = const <String, dynamic>{};
    if (json['inputSchema'] is Map) {
      schema = Map<String, dynamic>.from(json['inputSchema'] as Map);
    }
    return McpToolInfo(
      name: name,
      description: json['description'] is String
          ? json['description'] as String
          : '',
      inputSchema: schema,
      readOnlyHint: json['readOnlyHint'] is bool
          ? json['readOnlyHint'] as bool
          : false,
    );
  }

  /// Parses one entry of a `tools/list` result, tolerating servers that omit
  /// annotations or nest them either way the spec allows.
  static McpToolInfo? fromRpc(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    var schema = const <String, dynamic>{};
    if (json['inputSchema'] is Map) {
      schema = Map<String, dynamic>.from(json['inputSchema'] as Map);
    }
    var readOnlyHint = false;
    final annotations = json['annotations'];
    if (annotations is Map) {
      final hint = annotations['readOnlyHint'];
      if (hint is bool) readOnlyHint = hint;
    }
    final title = json['title'];
    final description = json['description'];
    return McpToolInfo(
      name: name,
      description: description is String
          ? description
          : (title is String ? title : ''),
      inputSchema: schema,
      readOnlyHint: readOnlyHint,
    );
  }
}

class McpResourceInfo {
  const McpResourceInfo({
    required this.uri,
    this.name = '',
    this.mimeType = '',
  });

  final String uri;
  final String name;
  final String mimeType;

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'name': name,
    'mimeType': mimeType,
  };

  static McpResourceInfo? fromJson(Map<String, dynamic> json) {
    final uri = json['uri'];
    if (uri is! String || uri.isEmpty) return null;
    return McpResourceInfo(
      uri: uri,
      name: json['name'] is String ? json['name'] as String : '',
      mimeType: json['mimeType'] is String ? json['mimeType'] as String : '',
    );
  }
}

class McpPromptInfo {
  const McpPromptInfo({required this.name, this.description = ''});

  final String name;
  final String description;

  Map<String, dynamic> toJson() => {'name': name, 'description': description};

  static McpPromptInfo? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    return McpPromptInfo(
      name: name,
      description: json['description'] is String
          ? json['description'] as String
          : '',
    );
  }
}
