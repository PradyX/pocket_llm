class LlmPromptMessage {
  final bool isUser;
  final String text;

  const LlmPromptMessage.user(this.text) : isUser = true;
  const LlmPromptMessage.assistant(this.text) : isUser = false;
}

String buildLlmChatPrompt(
  List<LlmPromptMessage> messages, {
  String systemPrompt = 'You are a helpful and concise assistant.',
}) {
  final promptBuffer = StringBuffer();
  promptBuffer.writeln('<|im_start|>system\n$systemPrompt<|im_end|>');

  for (final message in messages) {
    final role = message.isUser ? 'user' : 'assistant';
    promptBuffer.writeln('<|im_start|>$role\n${message.text}<|im_end|>');
  }

  promptBuffer.write('<|im_start|>assistant\n');
  return promptBuffer.toString();
}

String buildStreamingResponseText(String raw) {
  if (raw.isEmpty) return '';

  final thinkStart = raw.indexOf('<think>');
  if (thinkStart == -1) return raw;

  final thinkContentStart = thinkStart + '<think>'.length;
  final thinkEnd = raw.indexOf('</think>', thinkContentStart);

  if (thinkEnd == -1) {
    final thinking = raw.substring(thinkContentStart).trimLeft();
    if (thinking.isEmpty) return 'Thinking...';
    return 'Thinking...\n$thinking';
  }

  final thinking = raw.substring(thinkContentStart, thinkEnd).trim();
  final answerStart = thinkEnd + '</think>'.length;
  final answer = raw.substring(answerStart).trimLeft();

  if (answer.isEmpty) {
    return thinking.isEmpty ? 'Thinking...' : 'Thinking...\n$thinking';
  }

  if (thinking.isEmpty) return answer;
  return 'Thinking...\n$thinking\n\n$answer';
}

String buildFinalResponseText(String raw) {
  final withoutThinking = raw.replaceAll(
    RegExp(r'<think>[\s\S]*?</think>'),
    '',
  );
  final normalized = withoutThinking.trim();
  if (normalized.isNotEmpty) return normalized;

  final fallback = raw
      .replaceAll('<think>', '')
      .replaceAll('</think>', '')
      .trim();
  return fallback.isEmpty ? 'No response generated.' : fallback;
}
