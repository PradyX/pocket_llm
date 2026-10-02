import 'package:pocket_llm/core/services/android_tool_executor_service.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';

/// Runs one Android action through the platform channel and reports what
/// happened. Injected so the tools can be tested without a device.
typedef AndroidActionRunner =
    Future<AndroidToolExecutionResult> Function(
      String toolName,
      Map<String, Object?> arguments,
    );

/// The Android actions this app can ask the device to perform.
///
/// Each one opens the relevant system app with the request pre-filled; the
/// user still confirms there, so nothing acts silently. They are all
/// [ToolRiskLevel.sensitive] because they hand work to another app, which is
/// why the registry must get explicit permission before one runs.
List<ToolEntry> buildAndroidActionTools({
  required AndroidActionRunner runAction,
}) {
  return [_alarmTool(runAction), _eventTool(runAction), _smsTool(runAction)];
}

ToolEntry _alarmTool(AndroidActionRunner runAction) {
  return _sensitiveTool(
    name: 'set_alarm',
    description:
        'Opens the device alarm app pre-set to the requested time, where the '
        'user confirms it.',
    parameters: const [
      ToolParameter(
        name: 'hour',
        type: ToolParameterType.integer,
        description: 'Hour on a 24-hour clock, 0 to 23.',
        minimum: 0,
        maximum: 23,
      ),
      ToolParameter(
        name: 'minute',
        type: ToolParameterType.integer,
        description: 'Minute, 0 to 59.',
        minimum: 0,
        maximum: 59,
      ),
    ],
    runAction: runAction,
  );
}

ToolEntry _eventTool(AndroidActionRunner runAction) {
  return _sensitiveTool(
    name: 'create_event',
    description:
        'Opens the calendar app pre-filled with an event title and start time, '
        'where the user confirms it.',
    parameters: const [
      ToolParameter(
        name: 'title',
        type: ToolParameterType.string,
        description: 'Event title.',
        maxLength: 200,
      ),
      ToolParameter(
        name: 'start_time',
        type: ToolParameterType.string,
        description:
            'Start time as an ISO date (`2026-10-02`) or date and time '
            '(`2026-10-02T09:30:00`).',
        maxLength: 100,
      ),
    ],
    runAction: runAction,
  );
}

ToolEntry _smsTool(AndroidActionRunner runAction) {
  return _sensitiveTool(
    name: 'send_sms',
    description:
        'Opens the SMS app with a message and phone number pre-filled. It does '
        'not send anything; the user confirms in the app.',
    parameters: const [
      ToolParameter(
        name: 'phone',
        type: ToolParameterType.string,
        description: 'Phone number to send to.',
        maxLength: 40,
      ),
      ToolParameter(
        name: 'message',
        type: ToolParameterType.string,
        description: 'Message text.',
        maxLength: 500,
      ),
    ],
    runAction: runAction,
  );
}

ToolEntry _sensitiveTool({
  required String name,
  required String description,
  required List<ToolParameter> parameters,
  required AndroidActionRunner runAction,
}) {
  return ToolEntry(
    definition: ToolDefinition(
      name: name,
      description: description,
      risk: ToolRiskLevel.sensitive,
      platforms: const {ToolPlatform.android},
      timeout: const Duration(seconds: 20),
      parameters: parameters,
    ),
    handler: (arguments) async {
      final result = await runAction(name, arguments);
      if (!result.isSuccess) {
        // The platform explains what is missing in its own words; turning a
        // failure into an exception keeps success and failure out of one
        // ambiguous string.
        throw Exception(result.message);
      }
      return result.message;
    },
  );
}
