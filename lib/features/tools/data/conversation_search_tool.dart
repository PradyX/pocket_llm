import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// One message that matched a chat-history search.
class ConversationHistoryMatch {
  const ConversationHistoryMatch({
    required this.conversationTitle,
    required this.isUser,
    required this.snippet,
  });

  final String conversationTitle;

  /// True when the user wrote the message, false for an assistant reply.
  final bool isUser;

  /// Short excerpt around the match, with ellipses where text was cut.
  final String snippet;
}

/// Searches the most recent conversations for a word or phrase.
///
/// Bounded on purpose: only the newest [maxConversations] conversations are
/// opened, newest first, and at most [limit] excerpts are returned. Chat
/// history is read-only here — nothing is written, renamed or deleted.
Future<List<ConversationHistoryMatch>> searchConversationHistory({
  required List<ConversationSummary> summaries,
  required Future<List<Message>> Function(String conversationId) loadMessages,
  required String query,
  int limit = 5,
  int maxConversations = 10,
}) async {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];

  final ordered = List<ConversationSummary>.from(summaries)
    ..sort(
      (a, b) => b.conversation.updatedAt.compareTo(a.conversation.updatedAt),
    );

  final matches = <ConversationHistoryMatch>[];
  for (final summary in ordered.take(maxConversations)) {
    final messages = await loadMessages(summary.conversation.id);
    for (final message in messages) {
      if (!message.content.toLowerCase().contains(needle)) continue;
      matches.add(
        ConversationHistoryMatch(
          conversationTitle: summary.conversation.title,
          isUser: message.isUser,
          snippet: messageSnippet(message.content, needle),
        ),
      );
      if (matches.length >= limit) return matches;
    }
  }
  return matches;
}

/// Short excerpt of [text] around the first [needle], or the collapsed start
/// of the message when the match is only visible before whitespace collapsing.
String messageSnippet(String text, String needle) {
  const maxLength = 200;
  const radius = 70;

  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final index = needle.isEmpty ? -1 : collapsed.toLowerCase().indexOf(needle);
  if (index < 0) return _truncate(collapsed, maxLength);

  final start = index - radius < 0 ? 0 : index - radius;
  final end = index + needle.length + radius;
  final excerpt = collapsed.substring(
    start,
    end > collapsed.length ? collapsed.length : end,
  );
  final prefix = start > 0 ? '…' : '';
  final suffix = end < collapsed.length ? '…' : '';
  return '$prefix${_truncate(excerpt, maxLength)}$suffix';
}

String _truncate(String text, int maxLength) {
  if (text.length <= maxLength) return text;
  return '${text.substring(0, maxLength)}…';
}

/// Tool: search the user's local chat history.
ToolEntry buildConversationSearchTool({
  required Future<List<ConversationHistoryMatch>> Function(
    String query,
    int limit,
  )
  search,
}) {
  return ToolEntry(
    definition: const ToolDefinition(
      name: 'search_chat_history',
      description:
          "Searches the user's local chat history for a word or phrase and "
          'returns matching message excerpts with the conversation each came '
          'from. Read-only and offline.',
      risk: ToolRiskLevel.readOnly,
      timeout: Duration(seconds: 20),
      parameters: [
        ToolParameter(
          name: 'query',
          type: ToolParameterType.string,
          description: 'Word or phrase to look for.',
          maxLength: 100,
        ),
        ToolParameter(
          name: 'limit',
          type: ToolParameterType.integer,
          description: 'How many message excerpts to return.',
          required: false,
          minimum: 1,
          maximum: 10,
        ),
      ],
    ),
    handler: (arguments) async {
      final query = arguments['query'] as String;
      final limit = arguments['limit'] as int? ?? 5;
      final matches = await search(query, limit);

      if (matches.isEmpty) {
        return 'No messages in the recent chat history matched "$query".';
      }

      final buffer = StringBuffer()
        ..writeln(
          matches.length == 1
              ? '1 matching message:'
              : '${matches.length} matching messages:',
        );
      for (final match in matches) {
        buffer.writeln(
          '- "${match.conversationTitle}" '
          '(${match.isUser ? 'user' : 'assistant'}): ${match.snippet}',
        );
      }
      return buffer.toString().trimRight();
    },
  );
}
