import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/tools/application/assistant_reply.dart';
import 'package:pocket_llm/features/tools/application/built_in_tools.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

void main() {
  ToolRegistry registry() =>
      ToolRegistry(tools: builtInToolEntries(), platform: ToolPlatform.macOS);

  AssistantReply resolve(String raw, {bool legacy = false}) =>
      resolveAssistantReply(
        raw,
        registry: registry(),
        legacyToolsEnabled: legacy,
      );

  group('resolveAssistantReply', () {
    test('keeps plain text exactly as it came', () {
      const raw = 'A normal answer with {braces} inside.';
      final reply = resolve(raw);

      expect(reply, isA<AssistantTextReply>());
      expect((reply as AssistantTextReply).text, raw);
    });

    test('keeps malformed JSON as text', () {
      const raw = '{"type": "tool_call", "tool": "calculator"';
      final reply = resolve(raw);

      expect(reply, isA<AssistantTextReply>());
      expect((reply as AssistantTextReply).text, raw);
    });

    test('routes a known tool call to the registry', () {
      const raw =
          '{"type": "tool_call", "tool": "calculator", '
          '"arguments": {"expression": "(2 + 3) * 4"}}';
      final reply = resolve(raw);

      expect(reply, isA<RegistryToolReply>());
      final call = (reply as RegistryToolReply).call;
      expect(call.toolName, 'calculator');
      expect(call.arguments['expression'], '(2 + 3) * 4');
      expect(call.rawJson, isNotEmpty);
    });

    test('accepts a tool call wrapped in a code fence', () {
      const raw =
          '```json\n'
          '{"type": "tool_call", "tool": "current_datetime", '
          '"arguments": {"timezone": "utc"}}\n'
          '```';
      final reply = resolve(raw);

      expect(reply, isA<RegistryToolReply>());
      expect((reply as RegistryToolReply).call.toolName, 'current_datetime');
    });

    test('routes an unknown tool to the registry so it reports the miss', () {
      const raw =
          '{"type": "tool_call", "tool": "launch_rocket", "arguments": {}}';
      final reply = resolve(raw);

      expect(reply, isA<RegistryToolReply>());
      expect((reply as RegistryToolReply).call.toolName, 'launch_rocket');
    });

    test('routes an unknown tool to the legacy path only on Android', () {
      const raw =
          '{"type": "tool_call", "tool": "set_alarm", '
          '"arguments": {"hour": 7, "minute": 0}}';

      final legacy = resolve(raw, legacy: true);
      expect(legacy, isA<LegacyToolReply>());
      expect((legacy as LegacyToolReply).rawJson, contains('set_alarm'));

      final modern = resolve(raw);
      expect(modern, isA<RegistryToolReply>());
    });

    test('unwraps a legacy JSON message only when the legacy path is on', () {
      const raw = '{"type": "message", "content": "  Hello there.  "}';

      expect(resolve(raw), isA<AssistantTextReply>());
      expect((resolve(raw) as AssistantTextReply).text, raw);

      final legacy = resolve(raw, legacy: true);
      expect(legacy, isA<AssistantTextReply>());
      expect((legacy as AssistantTextReply).text, 'Hello there.');
    });

    test('falls back to raw text for an empty legacy message', () {
      const raw = '{"type": "message", "content": "   "}';
      final legacy = resolve(raw, legacy: true);

      expect((legacy as AssistantTextReply).text, raw);
    });
  });
}
