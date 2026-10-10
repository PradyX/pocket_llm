import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocket_llm/core/data/versioned_json_document.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_capabilities.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_server.dart';

/// Persisted MCP servers plus the last discovered capabilities of each.
///
/// Storage format (version 1):
/// ```json
/// {"version": 1, "servers": [...], "capabilities": {"server-id": {...}}}
/// ```
/// Secrets are never stored here: auth headers live in secure device storage
/// keyed by server id.
class McpStore {
  McpStore(File file)
    : _document = VersionedJsonDocument(
        file: file,
        currentVersion: currentVersion,
        label: 'McpStore',
      );

  static const int currentVersion = 1;

  static Future<McpStore> open() async {
    final support = await getApplicationSupportDirectory();
    return McpStore(File(p.join(support.path, 'mcp', 'servers.json')));
  }

  final VersionedJsonDocument _document;

  String get filePath => _document.filePath;
  bool get isReadOnly => _document.isReadOnly;

  McpSnapshot load() {
    final decoded = _document.read();
    if (decoded == null) return McpSnapshot.empty;
    return McpSnapshot.fromJson(decoded);
  }

  bool save(McpSnapshot snapshot) {
    return _document.write({
      'version': currentVersion,
      'servers': snapshot.servers.map((s) => s.toJson()).toList(),
      'capabilities': {
        for (final entry in snapshot.capabilities.entries)
          entry.key: entry.value.toJson(),
      },
    });
  }
}

class McpSnapshot {
  const McpSnapshot({required this.servers, this.capabilities = const {}});

  static const McpSnapshot empty = McpSnapshot(servers: []);

  final List<McpServer> servers;

  /// Last discovery result per server id; may be stale, never authoritative.
  final Map<String, McpCapabilities> capabilities;

  McpSnapshot upsertServer(McpServer server) {
    final updated = <McpServer>[];
    var replaced = false;
    for (final existing in servers) {
      if (existing.id == server.id) {
        updated.add(server);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(server);
    return McpSnapshot(servers: updated, capabilities: capabilities);
  }

  McpSnapshot removeServer(String serverId) {
    final updatedCaps = Map<String, McpCapabilities>.from(capabilities)
      ..remove(serverId);
    return McpSnapshot(
      servers: servers.where((server) => server.id != serverId).toList(),
      capabilities: updatedCaps,
    );
  }

  McpSnapshot withCapabilities(McpCapabilities caps) {
    final updated = Map<String, McpCapabilities>.from(capabilities)
      ..[caps.serverId] = caps;
    return McpSnapshot(servers: servers, capabilities: updated);
  }

  static McpSnapshot fromJson(Map<String, dynamic> json) {
    final servers = <McpServer>[];
    final raw = json['servers'];
    if (raw is List) {
      for (final entry in raw) {
        final map = entry is Map<String, dynamic>
            ? entry
            : entry is Map
            ? Map<String, dynamic>.from(entry)
            : null;
        if (map == null) continue;
        final server = McpServer.fromJson(map);
        if (server != null) servers.add(server);
      }
    }
    final capabilities = <String, McpCapabilities>{};
    final rawCaps = json['capabilities'];
    if (rawCaps is Map) {
      for (final entry in rawCaps.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! Map) continue;
        capabilities[key] = McpCapabilities.fromJson(
          Map<String, dynamic>.from(value),
        );
      }
    }
    return McpSnapshot(servers: servers, capabilities: capabilities);
  }
}
