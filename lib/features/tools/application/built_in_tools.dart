import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/android_action_tools.dart';
import 'package:pocket_llm/features/tools/data/calculator_tool.dart';
import 'package:pocket_llm/features/tools/data/conversation_search_tool.dart';
import 'package:pocket_llm/features/tools/data/current_datetime_tool.dart';
import 'package:pocket_llm/features/tools/data/document_search_tool.dart';
import 'package:pocket_llm/features/tools/data/installed_models_tool.dart';
import 'package:pocket_llm/features/tools/data/read_document_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Tools that ship with the app.
///
/// The deterministic pair runs anywhere; each read-only tool is added only
/// when the app supplies its source, so a tool that cannot answer on this
/// platform is never advertised. The Android actions are added when the
/// platform executor exists; they are sensitive, so the registry refuses them
/// until the user answers the approval prompt.
List<ToolEntry> builtInToolEntries({
  Clock? clock,
  Future<List<ConversationHistoryMatch>> Function(String query, int limit)?
  conversationHistorySearch,
  List<InstalledModelSummary> Function()? installedModels,
  Future<List<LocalDocumentMatch>> Function(String query, int limit)?
  documentSearch,
  Future<LocalDocumentRead?> Function(String documentName)? documentReading,
  AndroidActionRunner? androidActions,
}) {
  return [
    buildCalculatorTool(),
    buildCurrentDateTimeTool(clock: clock),
    if (conversationHistorySearch != null)
      buildConversationSearchTool(search: conversationHistorySearch),
    if (installedModels != null)
      buildInstalledModelsTool(readModels: installedModels),
    if (documentSearch != null) buildDocumentSearchTool(search: documentSearch),
    if (documentReading != null) buildReadDocumentTool(read: documentReading),
    if (androidActions != null)
      ...buildAndroidActionTools(runAction: androidActions),
  ];
}

/// The registry the app runs tool calls through.
///
/// [platform] is null on a platform the app does not target; every tool is
/// then unsupported rather than assumed to work.
ToolRegistry buildToolRegistry({
  required ToolPlatform? platform,
  ToolPermissionGate permissionGate = const DenySensitiveTools(),
  Clock? clock,
  Future<List<ConversationHistoryMatch>> Function(String query, int limit)?
  conversationHistorySearch,
  List<InstalledModelSummary> Function()? installedModels,
  Future<List<LocalDocumentMatch>> Function(String query, int limit)?
  documentSearch,
  Future<LocalDocumentRead?> Function(String documentName)? documentReading,
  AndroidActionRunner? androidActions,
}) {
  return ToolRegistry(
    tools: builtInToolEntries(
      clock: clock,
      conversationHistorySearch: conversationHistorySearch,
      installedModels: installedModels,
      documentSearch: documentSearch,
      documentReading: documentReading,
      androidActions: androidActions,
    ),
    platform: platform,
    permissionGate: permissionGate,
  );
}
