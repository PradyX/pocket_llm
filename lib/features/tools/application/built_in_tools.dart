import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/calculator_tool.dart';
import 'package:pocket_llm/features/tools/data/current_datetime_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Tools that ship with the app.
///
/// Every one of them is deterministic and offline: nothing here reads a file,
/// touches the network or changes state, so the first tool set cannot surprise
/// the user. Read-only tools are added next; anything sensitive has to go
/// through the permission gate.
List<ToolEntry> builtInToolEntries({Clock? clock}) {
  return [buildCalculatorTool(), buildCurrentDateTimeTool(clock: clock)];
}

/// The registry the app runs tool calls through.
ToolRegistry buildToolRegistry({
  required ToolPlatform platform,
  ToolPermissionGate permissionGate = const DenySensitiveTools(),
  Clock? clock,
}) {
  return ToolRegistry(
    tools: builtInToolEntries(clock: clock),
    platform: platform,
    permissionGate: permissionGate,
  );
}
