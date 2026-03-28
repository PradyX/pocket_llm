import 'dart:convert';

enum LlmStructuredResponseType { message, toolCall }

class LlmStructuredResponse {
  final LlmStructuredResponseType type;
  final String rawJson;
  final String? content;
  final String? toolName;
  final Map<String, dynamic> arguments;

  const LlmStructuredResponse._({
    required this.type,
    required this.rawJson,
    this.content,
    this.toolName,
    this.arguments = const {},
  });

  const LlmStructuredResponse.message({
    required String rawJson,
    required String content,
  }) : this._(
         type: LlmStructuredResponseType.message,
         rawJson: rawJson,
         content: content,
       );

  const LlmStructuredResponse.toolCall({
    required String rawJson,
    required String toolName,
    Map<String, dynamic> arguments = const {},
  }) : this._(
         type: LlmStructuredResponseType.toolCall,
         rawJson: rawJson,
         toolName: toolName,
         arguments: arguments,
       );
}

const defaultAssistantSystemPrompt = 'You are a helpful and concise assistant.';

String buildAndroidToolCallingSystemPrompt() {
  return '''
You are an AI assistant with access to tools.

Available tools:
1. set_alarm(hour, minute)
2. create_event(title, start_time)
3. send_sms(phone, message)

Rules:
- If user asks to perform an action -> return ONLY JSON tool call
- If no action needed -> return normal message JSON
- Do NOT mix text and JSON
- Always follow schema exactly
- If required information is missing -> return message JSON asking a concise clarification question

If user intent requires action, return ONLY:
{
  "type": "tool_call",
  "tool": "<tool_name>",
  "arguments": { ... }
}

If normal chat:
{
  "type": "message",
  "content": "<text>"
}

User: Set alarm at 7 AM
Output:
{
  "type": "tool_call",
  "tool": "set_alarm",
  "arguments": { "hour": 7, "minute": 0 }
}

User: Hello
Output:
{
  "type": "message",
  "content": "Hello! How can I help you?"
}
''';
}

LlmStructuredResponse? tryParseLlmStructuredResponse(String raw) {
  final normalized = _normalizeStructuredCandidate(raw);
  if (normalized == null) return null;

  try {
    final decoded = jsonDecode(normalized);
    if (decoded is! Map) return null;

    final payload = Map<String, dynamic>.from(decoded);
    final type = (payload['type'] as String?)?.trim();
    switch (type) {
      case 'message':
        final content = (payload['content'] as String?)?.trim();
        if (content == null || content.isEmpty) return null;
        return LlmStructuredResponse.message(
          rawJson: normalized,
          content: content,
        );
      case 'tool_call':
        final toolName = (payload['tool'] as String?)?.trim() ?? '';
        final arguments = payload['arguments'];
        return LlmStructuredResponse.toolCall(
          rawJson: normalized,
          toolName: toolName,
          arguments: arguments is Map<String, dynamic>
              ? arguments
              : arguments is Map
              ? Map<String, dynamic>.from(arguments)
              : const {},
        );
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

String? _normalizeStructuredCandidate(String raw) {
  var candidate = raw.trim();
  if (candidate.isEmpty) return null;

  if (candidate.startsWith('```')) {
    final lines = candidate.split('\n');
    if (lines.isNotEmpty) {
      final firstLine = lines.first.trim();
      final lastLine = lines.last.trim();
      if (firstLine.startsWith('```') &&
          lastLine == '```' &&
          lines.length >= 3) {
        candidate = lines.sublist(1, lines.length - 1).join('\n').trim();
        if (candidate.startsWith('json')) {
          candidate = candidate.substring(4).trimLeft();
        }
      }
    }
  }

  if (!candidate.startsWith('{') || !candidate.endsWith('}')) {
    return null;
  }

  return candidate;
}
