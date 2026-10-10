import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_capabilities.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_server.dart';

/// Lazy MCP tool selection (Road Map 2 §6.5).
///
/// A server can expose dozens of tools and the app can host several servers;
/// injecting every schema would drown a small local model. This ranks the
/// *allowed* tools against the task text locally and takes the most relevant
/// few, so the model sees a handful of schemas instead of hundreds.
class McpToolChoice {
  const McpToolChoice({required this.server, required this.tool});

  final McpServer server;
  final McpToolInfo tool;

  String get qualifiedName => '${server.id}/${tool.name}';
}

abstract final class McpToolFilter {
  /// Most tools offered to one task. Small local models degrade past this.
  static const int maxToolsPerTask = 8;

  /// Share of the usable input budget MCP schemas may take.
  static const int maximumMcpShare = 4;

  /// Selects tools for [taskText] from [servers] and their [capabilities].
  ///
  /// Disabled servers and tools never surface; ask-gated tools do (the gate
  /// asks at call time, and hiding them would make the model unable to even
  /// propose the call). Read-only tools surface only when [allowReadOnly]
  /// is true or they are explicitly allowed.
  static List<McpToolChoice> select({
    required List<McpServer> servers,
    required Map<String, McpCapabilities> capabilities,
    required String taskText,
    String? workspaceId,
    bool allowReadOnly = true,
    int maxTools = maxToolsPerTask,
    int usableInputTokens = 0,
  }) {
    final words = _keywords(taskText);
    final scored = <({McpToolChoice choice, int score, int cost})>[];
    for (final server in servers) {
      if (!server.enabled || !server.visibleIn(workspaceId)) continue;
      final caps = capabilities[server.id];
      if (caps == null) continue;
      for (final tool in caps.tools) {
        final permission = server.permissionFor(tool.name);
        if (permission == McpPermission.disabled) continue;
        if (permission == McpPermission.readOnly &&
            !tool.readOnlyHint &&
            !allowReadOnly) {
          continue;
        }
        final score = _score(tool, words);
        if (score <= 0) continue;
        scored.add((
          choice: McpToolChoice(server: server, tool: tool),
          score: score,
          cost: _schemaTokens(tool),
        ));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final selected = <McpToolChoice>[];
    var used = 0;
    final budget = usableInputTokens > 0
        ? usableInputTokens ~/ maximumMcpShare
        : 1 << 30;
    for (final entry in scored) {
      if (selected.length >= maxTools) break;
      if (used + entry.cost > budget) continue;
      used += entry.cost;
      selected.add(entry.choice);
    }
    return selected;
  }

  /// Rough schema cost: names and descriptions dominate what the model reads.
  static int _schemaTokens(McpToolInfo tool) {
    return TokenEstimator.estimateText(
      '${tool.name} ${tool.description} ${tool.inputSchema}',
    );
  }

  static Set<String> _keywords(String text) {
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9_]+'))
        .where((word) => word.length > 2)
        .toSet();
  }

  static int _score(McpToolInfo tool, Set<String> words) {
    if (words.isEmpty) return 0;
    // Whole words only: substring matching ranks `bake_bread` for `read`.
    // Underscores split tool names into words first (`read_note` → read).
    final haystack = _keywords(
      '${tool.name} ${tool.description}'.replaceAll('_', ' '),
    );
    var score = 0;
    for (final word in words) {
      if (haystack.contains(word)) score += word.length > 5 ? 2 : 1;
    }
    final nameWords = _keywords(tool.name.replaceAll('_', ' '));
    for (final word in words) {
      if (nameWords.contains(word)) score += 3;
    }
    return score;
  }
}
