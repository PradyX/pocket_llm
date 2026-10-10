import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/mcp/data/mcp_client.dart';
import 'package:pocket_llm/features/mcp/data/mcp_store.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_server.dart';

/// MCP server registry file, opened once per session.
final mcpStoreProvider = FutureProvider<McpStore>((ref) => McpStore.open());

class McpState {
  const McpState({
    this.snapshot = McpSnapshot.empty,
    this.isReady = false,
    this.errorMessage,
    this.isReadOnly = false,
    this.connectingServerIds = const {},
  });

  final McpSnapshot snapshot;
  final bool isReady;
  final String? errorMessage;
  final bool isReadOnly;
  final Set<String> connectingServerIds;

  List<McpServer> get servers => snapshot.servers;

  McpState copyWith({
    McpSnapshot? snapshot,
    bool? isReady,
    String? errorMessage,
    bool clearError = false,
    bool? isReadOnly,
    Set<String>? connectingServerIds,
  }) {
    return McpState(
      snapshot: snapshot ?? this.snapshot,
      isReady: isReady ?? this.isReady,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isReadOnly: isReadOnly ?? this.isReadOnly,
      connectingServerIds: connectingServerIds ?? this.connectingServerIds,
    );
  }
}

final mcpProvider = StateNotifierProvider<McpNotifier, McpState>(
  (ref) => McpNotifier(ref),
);

/// Owns MCP servers, their permissions and their discovered capabilities.
///
/// Connecting refreshes the cached capabilities; a failed connection keeps
/// the previous cache and reports the error, so one offline server never
/// hides the rest of the registry.
class McpNotifier extends StateNotifier<McpState> {
  McpNotifier(this._ref) : super(const McpState()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final store = await _ref.read(mcpStoreProvider.future);
      state = McpState(
        snapshot: store.load(),
        isReady: true,
        isReadOnly: store.isReadOnly,
        errorMessage: store.isReadOnly
            ? 'MCP servers were written by a newer version of Pocket LLM and '
                  'are read-only in this build.'
            : null,
      );
    } catch (error) {
      state = state.copyWith(
        isReady: true,
        errorMessage: 'Could not load MCP servers: $error',
      );
    }
  }

  Future<bool> _persist() async {
    try {
      final store = await _ref.read(mcpStoreProvider.future);
      if (store.isReadOnly) {
        state = state.copyWith(
          errorMessage:
              'MCP servers were written by a newer version and are '
              'read-only in this build.',
        );
        return false;
      }
      return store.save(state.snapshot);
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Could not save MCP servers: $error',
      );
      return false;
    }
  }

  McpServer? serverById(String id) {
    for (final server in state.servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  Future<void> upsertServer(McpServer server) async {
    state = state.copyWith(
      snapshot: state.snapshot.upsertServer(server.normalized()),
      clearError: true,
    );
    await _persist();
  }

  Future<void> removeServer(String serverId) async {
    state = state.copyWith(
      snapshot: state.snapshot.removeServer(serverId),
      clearError: true,
    );
    await _persist();
  }

  Future<void> setToolPermission(
    String serverId,
    String toolName,
    McpPermission permission,
  ) async {
    final server = serverById(serverId);
    if (server == null) return;
    final permissions = Map<String, McpPermission>.from(server.toolPermissions)
      ..[toolName] = permission;
    state = state.copyWith(
      snapshot: state.snapshot.upsertServer(
        server.copyWith(toolPermissions: permissions),
      ),
      clearError: true,
    );
    await _persist();
  }

  /// Connects, refreshes the capability cache and reports the tool count.
  ///
  /// Returns null on failure (with [McpState.errorMessage] set); the
  /// previous cache survives either way.
  Future<int?> connectServer(String serverId) async {
    final server = serverById(serverId);
    if (server == null) return null;
    final configError = server.configError;
    if (configError != null) {
      state = state.copyWith(errorMessage: configError);
      return null;
    }
    state = state.copyWith(
      connectingServerIds: {...state.connectingServerIds, serverId},
      clearError: true,
    );
    McpClient? client;
    try {
      client = await McpClient.connect(server);
      final caps = await client.discover(server.id);
      state = state.copyWith(
        snapshot: state.snapshot.withCapabilities(caps),
        connectingServerIds: state.connectingServerIds
            .where((id) => id != serverId)
            .toSet(),
      );
      await _persist();
      return caps.tools.length;
    } catch (error) {
      state = state.copyWith(
        errorMessage: 'Could not connect to ${server.name}: $error',
        connectingServerIds: state.connectingServerIds
            .where((id) => id != serverId)
            .toSet(),
      );
      return null;
    } finally {
      try {
        await client?.close();
      } catch (_) {}
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}
