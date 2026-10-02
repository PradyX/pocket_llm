import 'package:pocket_llm/core/utils/llm_structured_response.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

/// Builds the system prompt for one request.
///
/// The persona supplies the voice; the app supplies the tool contract. Tool
/// instructions are appended rather than replacing the persona, because
/// dropping them would hide the tools and dropping the persona would ignore the
/// user's choice.
///
/// Order matters on Android: the legacy action contract is appended after
/// [toolContract], because its stricter "actions always use JSON" rules still
/// drive alarm/event/SMS handling and are only retired once those actions move
/// into the registry themselves.
///
/// A persona without a system prompt keeps the app default assistant prompt,
/// so "General" behaves exactly like the app did before personas existed.
String composePersonaSystemPrompt({
  required Persona persona,
  String toolContract = '',
  bool androidToolCalling = false,
}) {
  final base = persona.systemPrompt.trim().isEmpty
      ? defaultAssistantSystemPrompt
      : persona.systemPrompt.trim();
  final parts = <String>[base];
  final tools = toolContract.trim();
  if (tools.isNotEmpty) parts.add(tools);
  if (androidToolCalling) parts.add(buildAndroidToolCallingSystemPrompt());
  return parts.join('\n\n');
}
