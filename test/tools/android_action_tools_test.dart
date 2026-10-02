import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/services/android_tool_executor_service.dart';
import 'package:pocket_llm/features/tools/application/built_in_tools.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/android_action_tools.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

/// Gate that allows every sensitive call, like a user tapping Allow.
class _ApprovingGate implements ToolPermissionGate {
  const _ApprovingGate();

  @override
  Future<bool> requestApproval(ToolApprovalRequest request) async => true;
}

void main() {
  AndroidToolExecutionResult success(String message) =>
      AndroidToolExecutionResult.success(message: message);

  group('android action tools', () {
    test('declare themselves sensitive and Android-only', () {
      final entries = buildAndroidActionTools(
        runAction: (name, arguments) async => success('ok'),
      );

      expect(
        entries.map((entry) => entry.definition.name),
        containsAll(<String>['set_alarm', 'create_event', 'send_sms']),
      );
      for (final entry in entries) {
        expect(entry.definition.risk, ToolRiskLevel.sensitive);
        expect(entry.definition.risk.needsPermission, isTrue);
        expect(entry.definition.platforms, {ToolPlatform.android});
      }
    });

    test('are advertised on Android and not elsewhere', () {
      ToolRegistry registryFor(ToolPlatform platform) => ToolRegistry(
        tools: buildAndroidActionTools(
          runAction: (name, arguments) async => success('ok'),
        ),
        platform: platform,
      );

      expect(
        registryFor(ToolPlatform.android).describeForPrompt(),
        contains('set_alarm(hour: integer'),
      );
      expect(registryFor(ToolPlatform.macOS).describeForPrompt(), isEmpty);
    });

    test('are refused until the user allows them, then run', () async {
      var ran = false;
      Map<String, Object?>? received;
      Future<AndroidToolExecutionResult> run(
        String name,
        Map<String, Object?> arguments,
      ) async {
        ran = true;
        received = arguments;
        return success('Opening the alarm app for 7:30 AM.');
      }

      final denied =
          await ToolRegistry(
            tools: buildAndroidActionTools(runAction: run),
            platform: ToolPlatform.android,
          ).execute(
            const ToolCall(
              toolName: 'set_alarm',
              arguments: {'hour': 7, 'minute': 30},
            ),
          );

      expect(denied.status, ToolExecutionStatus.denied);
      expect(ran, isFalse);

      final allowed =
          await ToolRegistry(
            tools: buildAndroidActionTools(runAction: run),
            platform: ToolPlatform.android,
            permissionGate: const _ApprovingGate(),
          ).execute(
            const ToolCall(
              toolName: 'set_alarm',
              arguments: {'hour': '7', 'minute': '30'},
            ),
          );

      expect(allowed.isSuccess, isTrue);
      expect(allowed.output, contains('7:30 AM'));
      expect(received!['hour'], 7);
      expect(received!['minute'], 30);
    });

    test('turns a platform failure into a failed result', () async {
      final result =
          await ToolRegistry(
            tools: buildAndroidActionTools(
              runAction: (name, arguments) async =>
                  AndroidToolExecutionResult.error(
                    message: 'No SMS app is available on this Android device.',
                  ),
            ),
            platform: ToolPlatform.android,
            permissionGate: const _ApprovingGate(),
          ).execute(
            const ToolCall(
              toolName: 'send_sms',
              arguments: {'phone': '555', 'message': 'hi'},
            ),
          );

      expect(result.status, ToolExecutionStatus.failed);
      expect(result.output, contains('No SMS app is available'));
    });

    test('rejects invalid arguments before asking for permission', () async {
      var asked = false;
      final registry = ToolRegistry(
        tools: buildAndroidActionTools(
          runAction: (name, arguments) async => success('ok'),
        ),
        platform: ToolPlatform.android,
        permissionGate: _RecordingGate(onAsked: () => asked = true),
      );

      final result = await registry.execute(
        const ToolCall(
          toolName: 'set_alarm',
          arguments: {'hour': 25, 'minute': 0},
        ),
      );

      expect(result.status, ToolExecutionStatus.invalidArguments);
      expect(result.output, contains('at most 23'));
      expect(asked, isFalse);
    });
  });

  test('the built-in registry includes them when the executor exists', () {
    final registry = buildToolRegistry(
      platform: ToolPlatform.android,
      androidActions: (name, arguments) async => success('ok'),
    );
    final prompt = registry.describeForPrompt();

    expect(prompt, contains('set_alarm'));
    expect(prompt, contains("Needs the user's permission before it runs."));
  });
}

class _RecordingGate implements ToolPermissionGate {
  _RecordingGate({required this.onAsked});

  final void Function() onAsked;

  @override
  Future<bool> requestApproval(ToolApprovalRequest request) async {
    onAsked();
    return true;
  }
}
