import 'package:pocket_llm/core/utils/llm_structured_response.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';

/// What one raw model reply is.
///
/// The model can only ask; nothing here runs a tool. This split exists so the
/// decision is a pure function that can be tested without a model, a device or
/// a UI, and so the controller has one place to route every reply through.
sealed class AssistantReply {
  const AssistantReply();
}

/// A normal answer, ready to show and store.
class AssistantTextReply extends AssistantReply {
  const AssistantTextReply(this.text);

  final String text;
}

/// A tool call this app's registry can run.
class RegistryToolReply extends AssistantReply {
  const RegistryToolReply(this.call);

  final ToolCall call;
}

/// A tool call only the legacy Android action path knows.
class LegacyToolReply extends AssistantReply {
  const LegacyToolReply(this.rawJson);

  /// The exact payload the Android executor expects.
  final String rawJson;
}

/// Reads one raw model reply.
///
/// A reply that is not structured is returned as text unchanged, so ordinary
/// chat, code blocks and JSON the user pasted are never reinterpreted. A tool
/// call for an unknown tool goes back through the registry on purpose: the
/// registry then reports the unknown tool to the user and to the model, which
/// is more useful than silently showing raw JSON.
AssistantReply resolveAssistantReply(
  String raw, {
  required ToolRegistry registry,
  required bool legacyToolsEnabled,
}) {
  final structured = tryParseLlmStructuredResponse(raw);
  if (structured == null) return AssistantTextReply(raw);

  switch (structured.type) {
    case LlmStructuredResponseType.message:
      // Only the legacy Android contract wraps answers in a JSON message; on
      // other platforms such an object is shown as it came, so JSON the user
      // explicitly asked for is never unwrapped.
      if (!legacyToolsEnabled) return AssistantTextReply(raw);
      final content = structured.content?.trim() ?? '';
      return AssistantTextReply(content.isEmpty ? raw : content);
    case LlmStructuredResponseType.toolCall:
      final call = ToolCall(
        toolName: structured.toolName ?? '',
        arguments: structured.arguments,
        rawJson: structured.rawJson,
      );
      if (registry.definitionFor(call.toolName) != null) {
        return RegistryToolReply(call);
      }
      if (legacyToolsEnabled) return LegacyToolReply(structured.rawJson);
      return RegistryToolReply(call);
  }
}
