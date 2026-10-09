import 'package:pocket_llm/features/conversations/domain/message.dart';

/// Placeholder text a turn can leave behind, which is never worth reading out.
///
/// These are the messages the chat writes when a run produced nothing to show.
/// Reading one aloud would be reading the app's own bookkeeping, so the loop
/// treats them as "nothing to say" and listens again instead.
const Set<String> _unspokenTexts = {
  'Thinking...',
  'No response generated.',
  'Generation stopped.',
};

/// True when an assistant message reports a generation failure rather than an
/// answer, so the loop can say what went wrong instead of reading it out.
bool isAssistantFailureReply(String text) =>
    text.trimLeft().startsWith('Error generating response');

/// The reply a just-finished spoken turn produced, or null when there is
/// nothing to read.
///
/// The loop reads the message its own turn added, which is the last one in the
/// chat: a placeholder, an empty message, a failure or a turn that added no
/// assistant message at all means the loop should listen again rather than
/// speak something the user has already seen.
String? speakableAssistantReply(List<Message> messages) {
  if (messages.isEmpty) return null;

  final last = messages.last;
  if (last.isUser) return null;

  final text = last.content.trim();
  if (text.isEmpty) return null;
  if (_unspokenTexts.contains(text)) return null;
  if (isAssistantFailureReply(text)) return null;
  return text;
}
