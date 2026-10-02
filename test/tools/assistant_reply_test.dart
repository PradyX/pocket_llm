import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/tools/application/assistant_reply.dart';
import 'package:pocket_llm/features/tools/application/built_in_tools.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

void main() {
  ToolRegistry registry() =>
      ToolRegistry(tools: builtInToolEntries(), platform: ToolPlatform.macOS);

  AssistantReply resolve(String raw) =>
      resolveAssistantReply(raw, registry: registry());

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

    test('unwraps the JSON message envelope the old contract asked for', () {
      const raw = '{"type": "message", "content": "  Hello there.  "}';

      final reply = resolve(raw);
      expect(reply, isA<AssistantTextReply>());
      expect((reply as AssistantTextReply).text, 'Hello there.');
    });

    test('falls back to raw text for an empty message envelope', () {
      const raw = '{"type": "message", "content": "   "}';
      final reply = resolve(raw);

      expect((reply as AssistantTextReply).text, raw);
    });
  });
}
