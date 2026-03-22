class LlmPromptMessage {
  final bool isUser;
  final String text;
  final String? imagePath;

  const LlmPromptMessage.user(this.text, {this.imagePath}) : isUser = true;
  const LlmPromptMessage.assistant(this.text)
    : isUser = false,
      imagePath = null;
}

class BuiltLlmPrompt {
  final String prompt;
  final List<String> imagePaths;

  const BuiltLlmPrompt({required this.prompt, this.imagePaths = const []});
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

BuiltLlmPrompt buildModelChatPrompt(
  List<LlmPromptMessage> messages, {
  String systemPrompt = 'You are a helpful and concise assistant.',
  String promptFormatId = 'chatml',
}) {
  switch (promptFormatId) {
    case 'gemma3':
      return _buildGemma3Prompt(messages, systemPrompt: systemPrompt);
    default:
      return BuiltLlmPrompt(
        prompt: buildLlmChatPrompt(messages, systemPrompt: systemPrompt),
      );
  }
}

String modelStopToken(String promptFormatId) {
  return switch (promptFormatId) {
    'gemma3' => '<end_of_turn>',
    _ => '<|im_end|>',
  };
}

BuiltLlmPrompt _buildGemma3Prompt(
  List<LlmPromptMessage> messages, {
  required String systemPrompt,
}) {
  final promptBuffer = StringBuffer();
  final imagePaths = <String>[];

  if (systemPrompt.trim().isNotEmpty) {
    promptBuffer
      ..write('<start_of_turn>user\n')
      ..write('System: ${systemPrompt.trim()}\n')
      ..write('<end_of_turn>\n');
  }

  for (final message in messages) {
    if (message.isUser) {
      promptBuffer.write('<start_of_turn>user\n');
      if (message.imagePath != null && message.imagePath!.trim().isNotEmpty) {
        promptBuffer.write('<image>\n');
        imagePaths.add(message.imagePath!);
      }
      if (message.text.trim().isNotEmpty) {
        promptBuffer.write('${message.text.trim()}\n');
      }
      promptBuffer.write('<end_of_turn>\n');
      continue;
    }

    promptBuffer
      ..write('<start_of_turn>model\n')
      ..write('${message.text.trim()}\n')
      ..write('<end_of_turn>\n');
  }

  promptBuffer.write('<start_of_turn>model\n');

  return BuiltLlmPrompt(
    prompt: promptBuffer.toString(),
    imagePaths: imagePaths,
  );
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
