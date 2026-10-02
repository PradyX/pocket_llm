import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/features/conversations/presentation/conversation_controller.dart';
import 'package:pocket_llm/features/documents/application/documents_controller.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/tools/application/built_in_tools.dart';
import 'package:pocket_llm/features/tools/application/tool_approval_controller.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/conversation_search_tool.dart';
import 'package:pocket_llm/features/tools/data/document_search_tool.dart';
import 'package:pocket_llm/features/tools/data/installed_models_tool.dart';
import 'package:pocket_llm/features/tools/data/read_document_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// The registry every tool call in the app goes through.
///
/// Built for the current platform once, so a tool declared for another platform
/// is never advertised or run here. Read-only tools read the same local data
/// the screens show — chat history, the active knowledge collection and
/// installed models — and never change it. Sensitive tools (the Android
/// actions) run only after the user answers the chat's approval prompt.
final toolRegistryProvider = Provider<ToolRegistry>((ref) {
  return buildToolRegistry(
    platform: currentToolPlatform(),
    permissionGate: ChatToolPermissionGate(
      ref.read(toolApprovalControllerProvider.notifier),
    ),
    androidActions: (toolName, arguments) => ref
        .read(androidToolExecutorServiceProvider)
        .executeAction(toolName: toolName, arguments: arguments),
    conversationHistorySearch: (query, limit) => searchConversationHistory(
      summaries: ref.read(conversationControllerProvider).summaries,
      loadMessages: ref.read(conversationRepositoryProvider).loadMessages,
      query: query,
      limit: limit,
    ),
    installedModels: () => installedModelSummaries(
      ref.read(modelSelectionControllerProvider).models,
    ),
    documentSearch: (query, limit) async {
      final library = await ref.read(documentLibraryProvider.future);
      final collectionId = library.activeCollectionId;
      if (library.chunkCountIn(collectionId) == 0) {
        return const <LocalDocumentMatch>[];
      }
      return searchLocalDocuments(
        retriever: library.retriever,
        query: query,
        collectionId: collectionId,
        limit: limit,
      );
    },
    documentReading: (documentName) async {
      final library = await ref.read(documentLibraryProvider.future);
      return readLocalDocument(
        documents: library.documentsIn(library.activeCollectionId),
        documentName: documentName,
      );
    },
  );
});
