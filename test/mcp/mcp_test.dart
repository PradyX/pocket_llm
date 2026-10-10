import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/mcp/application/mcp_tool_adapter.dart';
import 'package:pocket_llm/features/mcp/data/mcp_client.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_capabilities.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_server.dart';
import 'package:pocket_llm/features/mcp/domain/mcp_tool_filter.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Scripted transport: answers discovery and calls without a process.
class FakeMcpTransport implements McpTransport {
  FakeMcpTransport({this.tools = const [], this.failCall = false});

  final List<McpToolInfo> tools;
  final bool failCall;
  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add(method);
    switch (method) {
      case 'initialize':
        return {
          'serverInfo': {'name': 'fake', 'version': '0.1'},
        };
      case 'notifications/initialized':
        return {};
      case 'tools/list':
        return {
          'tools': [for (final tool in tools) tool.toJson()],
        };
      case 'tools/call':
        if (failCall) return {'isError': true};
        return {
          'content': [
            {'type': 'text', 'text': 'result of ${params['name']}'},
          ],
        };
      default:
        return {};
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('McpServer', () {
    test('validates its own config', () {
      final remote = McpServer.create(name: 'r');
      expect(remote.configError, isNotNull);

      final goodRemote = remote.copyWith(url: 'https://example.com/mcp');
      expect(goodRemote.configError, isNull);
      expect(goodRemote.canConnect, isTrue);

      final stdio = McpServer.create(
        name: 's',
        transport: McpTransportKind.stdio,
      );
      expect(stdio.configError, isNotNull);
    });

    test('resolves per-tool permissions over the default', () {
      final server = McpServer.create(name: 's', url: 'https://x.test/mcp')
          .copyWith(
            defaultPermission: McpPermission.ask,
            toolPermissions: {'read': McpPermission.allow},
          );
      expect(server.permissionFor('read'), McpPermission.allow);
      expect(server.permissionFor('write'), McpPermission.ask);
    });

    test('round-trips through JSON', () {
      final server = McpServer.create(name: 's', url: 'https://x.test/mcp');
      final restored = McpServer.fromJson(server.toJson());
      expect(restored?.url, 'https://x.test/mcp');
      expect(McpServer.fromJson(const {'name': 1}), isNull);
    });
  });

  group('McpClient', () {
    test('discovers tools and calls one', () async {
      final transport = FakeMcpTransport(
        tools: const [
          McpToolInfo(name: 'read_note', description: 'Reads a note'),
        ],
      );
      final client = McpClient(transport);
      final caps = await client.discover('server-1');
      expect(caps.tools.map((tool) => tool.name), ['read_note']);
      expect(caps.serverName, 'fake');
      expect(await client.callTool('read_note', {}), 'result of read_note');
      expect(transport.calls, contains('tools/call'));
    });

    test('a tool error raises', () async {
      final client = McpClient(FakeMcpTransport(failCall: true));
      await expectLater(client.callTool('x', {}), throwsA(isA<McpException>()));
    });
  });

  group('McpToolFilter', () {
    McpServer server(String id) =>
        McpServer.create(id: id, name: id, url: 'https://$id.test/mcp');

    test('selects relevant allowed tools and skips disabled ones', () {
      final servers = [
        server('obsidian').copyWith(
          toolPermissions: const {'delete_note': McpPermission.disabled},
        ),
      ];
      final caps = {
        'obsidian': const McpCapabilities(
          serverId: 'obsidian',
          tools: [
            McpToolInfo(name: 'read_note', description: 'Reads a vault note'),
            McpToolInfo(
              name: 'delete_note',
              description: 'Deletes a vault note forever',
            ),
            McpToolInfo(
              name: 'bake_bread',
              description: 'Unrelated kitchen helper',
            ),
          ],
        ),
      };
      final selected = McpToolFilter.select(
        servers: servers,
        capabilities: caps,
        taskText: 'read the vault note about the plan',
      );
      expect(selected.map((choice) => choice.tool.name), ['read_note']);
    });
  });

  group('McpToolAdapter', () {
    test('exposes namespaced entries with registry-compatible parameters', () {
      final server = McpServer.create(
        id: 'obsidian',
        name: 'Obsidian',
        url: 'https://x.test/mcp',
      );
      const tool = McpToolInfo(
        name: 'read_note',
        description: 'Reads a note',
        inputSchema: {
          'properties': {
            'path': {'type': 'string', 'description': 'Note path'},
          },
          'required': ['path'],
        },
      );
      final entry = McpToolAdapter(
        server: server,
        tool: tool,
        call: (arguments) async => 'ok',
      ).toEntry();
      expect(entry.definition.name, 'obsidian_read_note');
      expect(entry.definition.parameters.map((p) => p.name), ['path']);
      // Ask-gated by default, so the registry treats it as sensitive.
      expect(entry.definition.risk, ToolRiskLevel.sensitive);
    });
  });
}
