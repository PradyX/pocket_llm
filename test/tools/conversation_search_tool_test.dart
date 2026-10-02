import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/conversation.dart';
import 'package:pocket_llm/features/conversations/domain/message.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/conversation_search_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

void main() {
  ConversationSummary summary(
    String id,
    String title, {
    required DateTime updatedAt,
  }) {
    return ConversationSummary(
      conversation: Conversation.create(
        id: id,
        title: title,
      ).copyWith(updatedAt: updatedAt),
      messageCount: 1,
      lastMessagePreview: '',
      lastMessageAt: updatedAt,
    );
  }

  Message message(String content, {bool isUser = true}) => Message(
    id: 'm-${content.hashCode}',
    conversationId: 'c-1',
    role: isUser ? MessageRole.user : MessageRole.assistant,
    content: content,
    createdAt: DateTime(2026, 1, 1),
  );

  group('searchConversationHistory', () {
    test('searches newest conversations first and keeps the author', () async {
      final matches = await searchConversationHistory(
        summaries: [
          summary('c-1', 'Old chat', updatedAt: DateTime(2026, 1, 1)),
          summary('c-2', 'Recent chat', updatedAt: DateTime(2026, 3, 1)),
        ],
        loadMessages: (id) async => id == 'c-2'
            ? [message('The docker engine is local.', isUser: false)]
            : [message('docker docker docker')],
        query: 'docker',
      );

      expect(matches, hasLength(2));
      expect(matches.first.conversationTitle, 'Recent chat');
      expect(matches.first.isUser, isFalse);
      expect(matches.first.snippet, contains('docker engine'));
      expect(matches.last.conversationTitle, 'Old chat');
      expect(matches.last.isUser, isTrue);
    });

    test('caps the conversations opened and the excerpts returned', () async {
      var opened = 0;
      final matches = await searchConversationHistory(
        summaries: [
          for (var index = 0; index < 15; index++)
            summary(
              'c-$index',
              'Chat $index',
              updatedAt: DateTime(2026, 1, 1).add(Duration(days: index)),
            ),
        ],
        loadMessages: (id) async {
          opened++;
          return [message('match here'), message('match again')];
        },
        query: 'match',
        limit: 3,
        maxConversations: 2,
      );

      expect(matches, hasLength(3));
      expect(opened, 2);
    });

    test('returns nothing for an empty or unmatched query', () async {
      Future<List<ConversationHistoryMatch>> search(String query) =>
          searchConversationHistory(
            summaries: [
              summary('c-1', 'Chat', updatedAt: DateTime(2026, 1, 1)),
            ],
            loadMessages: (id) async => [message('nothing to see')],
            query: query,
          );

      expect(await search('   '), isEmpty);
      expect(await search('missing'), isEmpty);
    });

    test('makes a short excerpt around the match inside a long message', () {
      final long = '${'background ' * 40}the needle is here ${'context ' * 40}';
      final snippet = messageSnippet(long, 'needle');

      expect(snippet, contains('needle'));
      expect(snippet, startsWith('…'));
      expect(snippet, endsWith('…'));
      expect(snippet.length, lessThan(260));
    });
  });

  group('search_chat_history tool', () {
    ToolRegistry registryWith(
      Future<List<ConversationHistoryMatch>> Function(String query, int limit)
      search,
    ) => ToolRegistry(
      tools: [buildConversationSearchTool(search: search)],
      platform: ToolPlatform.macOS,
    );

    test('is read-only and needs no permission', () {
      final entry = buildConversationSearchTool(
        search: (query, limit) async => const [],
      );

      expect(entry.definition.risk, ToolRiskLevel.readOnly);
      expect(entry.definition.risk.needsPermission, isFalse);
    });

    test('reports the excerpts it found', () async {
      final registry = registryWith(
        (query, limit) async => query == 'docker'
            ? const [
                ConversationHistoryMatch(
                  conversationTitle: 'Infra chat',
                  isUser: true,
                  snippet: 'about docker',
                ),
              ]
            : const [],
      );

      final found = await registry.execute(
        const ToolCall(
          toolName: 'search_chat_history',
          arguments: {'query': 'docker'},
        ),
      );

      expect(found.isSuccess, isTrue);
      expect(found.output, contains('1 matching message'));
      expect(found.output, contains('"Infra chat" (user): about docker'));

      final none = await registry.execute(
        const ToolCall(
          toolName: 'search_chat_history',
          arguments: {'query': 'nothing'},
        ),
      );
      expect(none.isSuccess, isTrue);
      expect(none.output, contains('No messages in the recent chat history'));
    });

    test('rejects an out-of-range limit before searching', () async {
      var searched = false;
      final registry = registryWith((query, limit) async {
        searched = true;
        return const [];
      });

      final result = await registry.execute(
        const ToolCall(
          toolName: 'search_chat_history',
          arguments: {'query': 'x', 'limit': 99},
        ),
      );

      expect(result.status, ToolExecutionStatus.invalidArguments);
      expect(searched, isFalse);
    });
  });
}
