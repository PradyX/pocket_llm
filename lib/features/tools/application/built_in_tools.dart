import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/calculator_tool.dart';
import 'package:pocket_llm/features/tools/data/conversation_search_tool.dart';
import 'package:pocket_llm/features/tools/data/current_datetime_tool.dart';
import 'package:pocket_llm/features/tools/data/document_search_tool.dart';
import 'package:pocket_llm/features/tools/data/installed_models_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Tools that ship with the app.
///
/// The deterministic pair runs anywhere; each read-only tool is added only
/// when the app supplies its source, so a tool that cannot answer on this
/// platform is never advertised. Nothing here writes anything — anything
/// sensitive has to go through the permission gate.
List<ToolEntry> builtInToolEntries({
  Clock? clock,
  Future<List<ConversationHistoryMatch>> Function(String query, int limit)?
  conversationHistorySearch,
  List<InstalledModelSummary> Function()? installedModels,
  Future<List<LocalDocumentMatch>> Function(String query, int limit)?
  documentSearch,
}) {
  return [
    buildCalculatorTool(),
    buildCurrentDateTimeTool(clock: clock),
    if (conversationHistorySearch != null)
      buildConversationSearchTool(search: conversationHistorySearch),
    if (installedModels != null)
      buildInstalledModelsTool(readModels: installedModels),
    if (documentSearch != null) buildDocumentSearchTool(search: documentSearch),
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
}) {
  return ToolRegistry(
    tools: builtInToolEntries(
      clock: clock,
      conversationHistorySearch: conversationHistorySearch,
      installedModels: installedModels,
      documentSearch: documentSearch,
    ),
    platform: platform,
    permissionGate: permissionGate,
  );
}
