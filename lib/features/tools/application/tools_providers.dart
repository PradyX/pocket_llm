import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/tools/application/built_in_tools.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// The registry every tool call in the app goes through.
///
/// Built for the current platform once, so a tool declared for another platform
/// is never advertised or run here. The permission gate stays the registry
/// default (refuse) until the chat can ask the user, which is the next unit:
/// no sensitive tool may run unasked in the meantime.
final toolRegistryProvider = Provider<ToolRegistry>((ref) {
  return buildToolRegistry(platform: currentToolPlatform());
});
