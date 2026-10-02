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

/// Reads one raw model reply.
///
/// A reply that is not a structured tool call is returned as text unchanged, so
/// ordinary chat, code blocks and JSON the user pasted are never
/// reinterpreted. The one exception is the `{"type": "message", ...}` envelope
/// the old Android contract asked for: an upgraded install still unwraps it, so
/// a model that has not noticed the new contract yet does not show raw JSON.
///
/// A tool call for an unknown tool still goes to the registry: the registry
/// then reports the unknown tool to the user and to the model, which is more
/// useful than silently showing raw JSON.
AssistantReply resolveAssistantReply(
  String raw, {
  required ToolRegistry registry,
}) {
  final structured = tryParseLlmStructuredResponse(raw);
  if (structured == null) return AssistantTextReply(raw);

  switch (structured.type) {
    case LlmStructuredResponseType.message:
      final content = structured.content?.trim() ?? '';
      return AssistantTextReply(content.isEmpty ? raw : content);
    case LlmStructuredResponseType.toolCall:
      return RegistryToolReply(
        ToolCall(
          toolName: structured.toolName ?? '',
          arguments: structured.arguments,
          rawJson: structured.rawJson,
        ),
      );
  }
}
