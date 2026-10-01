import 'package:pocket_llm/features/conversations/domain/message.dart';

/// Whether a finished generation should be read aloud.
///
/// Only the transition from running to finished counts: opening a
/// conversation, switching models or starting the app never speaks a word.
bool shouldReadFinishedReply({
  required bool wasGenerating,
  required bool isGenerating,
  required bool readAloudEnabled,
}) => readAloudEnabled && wasGenerating && !isGenerating;

/// The newest assistant reply worth reading aloud, or null.
///
/// Only replies this app actually generated qualify: a placeholder such as
/// “Thinking...” carries no generation stats, while a finished or stopped run
/// carries them together with whatever the runtime produced — which is exactly
/// what the bubble shows and therefore what should be spoken. An older reply is
/// never returned, so a new turn can not trigger reading something stale.
Message? lastReadableReply(List<Message> messages) {
  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    if (message.isUser) continue;
    if (message.generationStats == null) return null;
    return message.content.trim().isEmpty ? null : message;
  }
  return null;
}
