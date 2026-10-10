import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pocket_llm/features/mcp/domain/mcp_capabilities.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_server.dart';

/// What a failed MCP call reports.
class McpException implements Exception {
  McpException(this.message);
  final String message;
  @override
  String toString() => 'McpException: $message';
}

/// One JSON-RPC channel to a server. Implementations own exactly one
/// transport each; the client speaks the same MCP verbs over all of them.
abstract class McpTransport {
  /// Sends a request and returns the `result` object.
  Future<Map<String, dynamic>> send(String method, Map<String, dynamic> params);
  Future<void> close();
}

/// Newline-delimited JSON-RPC over a spawned process (desktop only).
///
/// The constructor refuses on Android and iOS: mobile never spawns arbitrary
/// local processes (§6.2), so a stdio server configured there fails closed
/// with a message instead of crashing the app.
class StdioMcpTransport implements McpTransport {
  StdioMcpTransport._(this._process, this._pending);

  static Future<StdioMcpTransport> connect(McpServer server) async {
    if (Platform.isAndroid || Platform.isIOS) {
      throw McpException(
        'Stdio MCP servers are not supported on mobile. Use a remote server.',
      );
    }
    late Process process;
    try {
      process = await Process.start(
        server.command,
        server.args,
        runInShell: Platform.isWindows,
      );
    } catch (error) {
      throw McpException('Could not start "${server.command}": $error');
    }
    final pending = <int, Completer<Map<String, dynamic>>>{};
    var nextId = 1;
    final transport = StdioMcpTransport._(process, pending);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => transport._onLine(line),
          onError: (Object error) => transport._failAll('$error'),
        );
    unawaited(
      process.exitCode.then((code) {
        transport._failAll('The server process exited (code $code).');
      }),
    );
    transport._nextId = nextId;
    return transport;
  }

  final Process _process;
  final Map<int, Completer<Map<String, dynamic>>> _pending;
  var _nextId = 1;

  void _onLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final id = decoded['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (decoded.containsKey('error')) {
      completer.completeError(
        McpException('Server error: ${decoded['error']}'),
      );
    } else {
      final result = decoded['result'];
      completer.complete(
        result is Map<String, dynamic>
            ? result
            : result is Map
            ? Map<String, dynamic>.from(result)
            : <String, dynamic>{},
      );
    }
  }

  void _failAll(String message) {
    for (final completer in _pending.removeAll()) {
      if (!completer.isCompleted) {
        completer.completeError(McpException(message));
      }
    }
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params,
  ) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw McpException('Timed out waiting for "$method".');
      },
    );
  }

  @override
  Future<void> close() async {
    _failAll('The connection was closed.');
    _process.stdin.close();
    _process.kill();
  }
}

extension on Map<int, Completer<Map<String, dynamic>>> {
  Iterable<Completer<Map<String, dynamic>>> removeAll() {
    final values = this.values.toList();
    clear();
    return values;
  }
}

/// Streamable HTTP: one POST per request, plain JSON or an SSE reply.
class RemoteMcpTransport implements McpTransport {
  RemoteMcpTransport._(this._endpoint, this._headers);

  static Future<RemoteMcpTransport> connect(
    McpServer server, {
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.tryParse(server.url);
    if (uri == null || !uri.hasScheme) {
      throw McpException('"${server.url}" is not a usable HTTP URL.');
    }
    return RemoteMcpTransport._(uri, headers);
  }

  final Uri _endpoint;
  final Map<String, String> _headers;
  final _client = HttpClient();

  @override
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params,
  ) async {
    final request = await _client.postUrl(_endpoint);
    request.headers.contentType = ContentType.json;
    request.headers.set('Accept', 'application/json, text/event-stream');
    for (final entry in _headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': params,
      }),
    );
    final response = await request.close().timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw McpException('Timed out waiting for "$method".'),
    );
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw McpException(
        'Server answered ${response.statusCode}: ${_truncate(body)}',
      );
    }
    return _parseResult(body, method);
  }

  Map<String, dynamic> _parseResult(String body, String method) {
    // Plain JSON first; SSE (`data: {...}` lines) as the fallback.
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      for (final line in body.split('\n')) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        try {
          decoded = jsonDecode(trimmed.substring(5).trim());
          break;
        } catch (_) {
          continue;
        }
      }
    }
    if (decoded is Map) {
      final map = Map<String, dynamic>.from(decoded);
      if (map.containsKey('error')) {
        throw McpException('Server error: ${map['error']}');
      }
      final result = map['result'];
      if (result is Map) return Map<String, dynamic>.from(result);
    }
    throw McpException('Could not understand the "$method" reply.');
  }

  static String _truncate(String text) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ');
    return collapsed.length <= 160
        ? collapsed
        : '${collapsed.substring(0, 160)}…';
  }

  @override
  Future<void> close() async {
    _client.close(force: true);
  }
}

/// Minimal MCP client: initialize, discover, call.
///
/// Speaks the `2024-11-05` verbs every conforming server answers
/// (`initialize`, `tools/list`, `tools/call`, plus best-effort
/// `resources/list` and `prompts/list`). Anything a server does not implement
/// reads as empty rather than failing the connection.
class McpClient {
  McpClient(this._transport);

  /// Opens [server] over the transport its config declares.
  static Future<McpClient> connect(
    McpServer server, {
    Future<McpTransport> Function(McpServer)? transportFor,
  }) async {
    final transport = await (transportFor ?? _defaultTransport)(server);
    return McpClient(transport);
  }

  static Future<McpTransport> _defaultTransport(McpServer server) {
    switch (server.transport) {
      case McpTransportKind.stdio:
        return StdioMcpTransport.connect(server);
      case McpTransportKind.remote:
        return RemoteMcpTransport.connect(server);
    }
  }

  final McpTransport _transport;

  static const String protocolVersion = '2024-11-05';

  /// Handshakes and returns what the server offers.
  Future<McpCapabilities> discover(String serverId) async {
    final init = await _transport.send('initialize', {
      'protocolVersion': protocolVersion,
      'capabilities': {},
      'clientInfo': {'name': 'pocket-llm', 'version': '1'},
    });
    String? serverName;
    String? serverVersion;
    final info = init['serverInfo'];
    if (info is Map) {
      if (info['name'] is String) serverName = info['name'] as String;
      if (info['version'] is String) serverVersion = info['version'] as String;
    }
    // Notifications are best-effort: a server that rejects them still works.
    try {
      await _transport.send('notifications/initialized', {});
    } catch (_) {}

    final tools = await _list('tools/list', 'tools', McpToolInfo.fromRpc);
    final resources = await _list('resources/list', 'resources', (json) {
      final uri = json['uri'];
      if (uri is! String || uri.isEmpty) return null;
      return McpResourceInfo(
        uri: uri,
        name: json['name'] is String ? json['name'] as String : '',
        mimeType: json['mimeType'] is String ? json['mimeType'] as String : '',
      );
    });
    final prompts = await _list('prompts/list', 'prompts', (json) {
      final name = json['name'];
      if (name is! String || name.isEmpty) return null;
      return McpPromptInfo(
        name: name,
        description: json['description'] is String
            ? json['description'] as String
            : '',
      );
    });

    return McpCapabilities(
      serverId: serverId,
      tools: tools,
      resources: resources,
      prompts: prompts,
      serverName: serverName,
      serverVersion: serverVersion,
      discoveredAt: DateTime.now(),
    );
  }

  Future<List<T>> _list<T>(
    String method,
    String key,
    T? Function(Map<String, dynamic>) parse,
  ) async {
    Map<String, dynamic> result;
    try {
      result = await _transport.send(method, {});
    } catch (_) {
      return const [];
    }
    final raw = result[key];
    if (raw is! List) return [];
    final items = <T>[];
    for (final entry in raw) {
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

  /// Calls one tool and returns its text content.
  Future<String> callTool(String name, Map<String, Object?> arguments) async {
    final result = await _transport.send('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final content = result['content'];
    if (content is List) {
      final parts = <String>[];
      for (final entry in content) {
        if (entry is Map && entry['text'] is String) {
          parts.add(entry['text'] as String);
        }
      }
      if (parts.isNotEmpty) return parts.join('\n');
    }
    if (result['isError'] == true) {
      throw McpException('The tool reported an error.');
    }
    return const JsonEncoder.withIndent('  ').convert(result);
  }

  Future<void> close() => _transport.close();
}
