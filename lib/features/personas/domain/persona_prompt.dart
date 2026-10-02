import 'package:pocket_llm/core/utils/llm_structured_response.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

/// Builds the system prompt for one request.
///
/// The persona supplies the voice; the app supplies the tool contract. Tool
/// instructions are appended rather than replacing the persona, because
/// dropping them would hide the tools and dropping the persona would ignore
/// the user's choice.
///
/// A persona without a system prompt keeps the app default assistant prompt,
/// so "General" behaves exactly like the app did before personas existed.
String composePersonaSystemPrompt({
  required Persona persona,
  String toolContract = '',
}) {
  final base = persona.systemPrompt.trim().isEmpty
      ? defaultAssistantSystemPrompt
      : persona.systemPrompt.trim();
  final tools = toolContract.trim();
  if (tools.isEmpty) return base;
  return '$base\n\n$tools';
}
