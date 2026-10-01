import 'package:pocket_llm/core/utils/llm_structured_response.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

/// Builds the system prompt for one request.
///
/// The persona supplies the voice; the platform supplies the tool contract.
/// On Android the structured tool-calling instructions are appended rather
/// than replacing the persona, because dropping them would break tool calls
/// and dropping the persona would ignore the user's choice.
///
/// A persona without a system prompt keeps the app default assistant prompt,
/// so "General" behaves exactly like the app did before personas existed.
String composePersonaSystemPrompt({
  required Persona persona,
  bool androidToolCalling = false,
}) {
  final base = persona.systemPrompt.trim().isEmpty
      ? defaultAssistantSystemPrompt
      : persona.systemPrompt.trim();
  if (!androidToolCalling) return base;
  return '$base\n\n${buildAndroidToolCallingSystemPrompt()}';
}
