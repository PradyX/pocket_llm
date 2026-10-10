import 'package:pocket_llm/features/mcp/data/mcp_client.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_capabilities.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_server.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Exposes one allowed MCP tool as a registry entry.
///
/// Names are prefixed with the server id (`serverId_toolName`) so two
/// servers offering the same tool never collide. The risk level follows the
/// permission: ask-gated tools run as sensitive (the existing approval gate
/// asks), allowed tools as read-only or sensitive based on the server's own
/// read-only hint.
class McpToolAdapter {
  const McpToolAdapter({
    required this.server,
    required this.tool,
    required this.call,
  });

  final McpServer server;
  final McpToolInfo tool;

  /// Runs the call against a connected client.
  final Future<String> Function(Map<String, Object?> arguments) call;

  String get entryName => '${server.id}_${tool.name}';

  ToolEntry toEntry() {
    final permission = server.permissionFor(tool.name);
    final risk = permission == McpPermission.allow && tool.readOnlyHint
        ? ToolRiskLevel.readOnly
        : ToolRiskLevel.sensitive;
    return ToolEntry(
      definition: ToolDefinition(
        name: entryName,
        description: tool.description.isEmpty
            ? 'MCP tool ${tool.name} from ${server.name}.'
            : '${tool.description} (MCP: ${server.name})',
        parameters: _parametersOf(tool),
        risk: risk,
      ),
      handler: call,
    );
  }

  /// Builds adapter entries for every tool the filter selected.
  static List<ToolEntry> entriesFor({
    required List<({McpServer server, McpToolInfo tool})> selected,
    required Future<McpClient> Function(McpServer server) connect,
  }) {
    return [
      for (final item in selected)
        McpToolAdapter(
          server: item.server,
          tool: item.tool,
          call: (arguments) async {
            final client = await connect(item.server);
            try {
              return await client.callTool(item.tool.name, arguments);
            } finally {
              await client.close();
            }
          },
        ).toEntry(),
    ];
  }

  static List<ToolParameter> _parametersOf(McpToolInfo tool) {
    final schema = tool.inputSchema;
    final properties = schema['properties'];
    final required = schema['required'];
    final requiredNames = required is List
        ? required.whereType<String>().toSet()
        : <String>{};
    if (properties is! Map) return const [];
    final parameters = <ToolParameter>[];
    for (final entry in properties.entries) {
      final name = entry.key;
      if (name is! String) continue;
      final spec = entry.value is Map
          ? Map<String, dynamic>.from(entry.value as Map)
          : <String, dynamic>{};
      parameters.add(
        ToolParameter(
          name: name,
          type: _parameterType(spec['type']),
          description: spec['description'] is String
              ? spec['description'] as String
              : '',
          required: requiredNames.contains(name),
        ),
      );
    }
    return parameters;
  }

  static ToolParameterType _parameterType(Object? raw) {
    switch (raw) {
      case 'integer':
        return ToolParameterType.integer;
      case 'number':
        return ToolParameterType.number;
      case 'boolean':
        return ToolParameterType.boolean;
      default:
        return ToolParameterType.string;
    }
  }
}
