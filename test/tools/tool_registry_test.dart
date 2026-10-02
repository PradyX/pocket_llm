import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/tools/application/built_in_tools.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';
import 'package:pocket_llm/features/tools/data/calculator_tool.dart';
import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

/// Gate that records what it was asked and answers with a fixed decision.
class _RecordingGate implements ToolPermissionGate {
  _RecordingGate({required this.approved});

  final bool approved;
  final List<ToolApprovalRequest> requests = [];

  @override
  Future<bool> requestApproval(ToolApprovalRequest request) async {
    requests.add(request);
    return approved;
  }
}

ToolEntry _fakeTool({
  required String name,
  ToolRiskLevel risk = ToolRiskLevel.safe,
  List<ToolParameter> parameters = const [],
  Set<ToolPlatform> platforms = ToolPlatform.all,
  Duration timeout = const Duration(seconds: 1),
  Future<String> Function(Map<String, Object?> arguments)? handler,
}) {
  return ToolEntry(
    definition: ToolDefinition(
      name: name,
      description: 'Test tool $name.',
      parameters: parameters,
      risk: risk,
      platforms: platforms,
      timeout: timeout,
    ),
    handler: handler ?? (arguments) async => '$name ran',
  );
}

void main() {
  final calculator = buildCalculatorTool();

  test('runs a declared tool and hands the model a result', () async {
    final registry = ToolRegistry(
      tools: [calculator],
      platform: ToolPlatform.macOS,
    );

    final result = await registry.execute(
      const ToolCall(
        toolName: 'calculator',
        arguments: {'expression': '6 * 7'},
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(result.output, '6 * 7 = 42');
    expect(result.toModelText(), contains('Tool: calculator'));
    expect(result.toModelText(), contains('Status: success'));
    expect(result.toModelText(), contains('Result: 6 * 7 = 42'));
  });

  test('describes the contract the model receives', () {
    final registry = ToolRegistry(
      tools: builtInToolEntries(),
      platform: ToolPlatform.macOS,
    );

    final prompt = registry.describeForPrompt();

    expect(prompt, contains('Available tools:'));
    expect(prompt, contains('calculator(expression: string)'));
    expect(prompt, contains('current_datetime(timezone: string'));
    expect(prompt, contains('"type": "tool_call"'));
    expect(prompt, contains('do not wrap normal answers in JSON'));
  });

  test('supports nothing when the platform is unknown', () async {
    final registry = ToolRegistry(tools: builtInToolEntries(), platform: null);

    expect(registry.describeForPrompt(), isEmpty);
    expect(registry.supportedDefinitions, isEmpty);

    final result = await registry.execute(
      const ToolCall(toolName: 'calculator', arguments: {'expression': '1+1'}),
    );

    expect(result.status, ToolExecutionStatus.unsupported);
    expect(result.output, contains('this device'));
  });

  test('advertises the read-only tools when their sources exist', () {
    final registry = ToolRegistry(
      tools: builtInToolEntries(
        conversationHistorySearch: (query, limit) async => const [],
        installedModels: () => const [],
        documentSearch: (query, limit) async => const [],
        documentReading: (documentName) async => null,
      ),
      platform: ToolPlatform.macOS,
    );

    final prompt = registry.describeForPrompt();

    expect(prompt, contains('search_chat_history(query: string'));
    expect(prompt, contains('search_local_documents(query: string'));
    expect(prompt, contains('read_document(document: string'));
    expect(prompt, contains('list_installed_models()'));
    // Read-only tools must never look like they need approval.
    expect(prompt, isNot(contains("Needs the user's permission")));
  });

  test('describes nothing when no tool can run here', () {
    final registry = ToolRegistry(
      tools: [
        _fakeTool(
          name: 'android_only',
          platforms: const {ToolPlatform.android},
        ),
      ],
      platform: ToolPlatform.macOS,
    );

    expect(registry.describeForPrompt(), isEmpty);
    expect(registry.supportedDefinitions, isEmpty);
  });

  test('reports an unknown tool and lists the ones that exist', () async {
    final registry = ToolRegistry(
      tools: [calculator],
      platform: ToolPlatform.macOS,
    );

    final result = await registry.execute(
      const ToolCall(toolName: 'set_alarm', arguments: {'hour': 7}),
    );

    expect(result.status, ToolExecutionStatus.unknownTool);
    expect(result.toolName, 'set_alarm');
    expect(result.output, contains('calculator'));
  });

  test('rejects missing, extra and wrongly typed arguments', () async {
    final registry = ToolRegistry(
      tools: [
        _fakeTool(
          name: 'lookup',
          parameters: const [
            ToolParameter(
              name: 'query',
              type: ToolParameterType.string,
              description: 'Text to look up.',
              maxLength: 8,
              allowedValues: ['alpha', 'beta'],
            ),
            ToolParameter(
              name: 'limit',
              type: ToolParameterType.integer,
              description: 'How many results.',
              required: false,
              minimum: 1,
              maximum: 5,
            ),
          ],
        ),
      ],
      platform: ToolPlatform.macOS,
    );

    Future<ToolExecutionResult> call(Map<String, Object?> arguments) =>
        registry.execute(ToolCall(toolName: 'lookup', arguments: arguments));

    final missing = await call(const {});
    expect(missing.status, ToolExecutionStatus.invalidArguments);
    expect(missing.output, contains('needs "query"'));

    final extra = await call(const {'query': 'alpha', 'nope': 1});
    expect(extra.status, ToolExecutionStatus.invalidArguments);
    expect(extra.output, contains('does not accept "nope"'));

    final tooLong = await call(const {'query': 'alphabetically'});
    expect(tooLong.output, contains('at most 8 characters'));

    final notAllowed = await call(const {'query': 'gamma'});
    expect(notAllowed.output, contains('must be one of: alpha, beta'));

    final tooBig = await call(const {'query': 'alpha', 'limit': 9});
    expect(tooBig.output, contains('at most 5'));

    final fractional = await call(const {'query': 'alpha', 'limit': 1.5});
    expect(fractional.output, contains('whole number'));
  });

  test('coerces the argument shapes small models produce', () async {
    final received = <Map<String, Object?>>[];
    final registry = ToolRegistry(
      tools: [
        _fakeTool(
          name: 'shapes',
          parameters: const [
            ToolParameter(
              name: 'count',
              type: ToolParameterType.integer,
              description: 'A whole number.',
            ),
            ToolParameter(
              name: 'ratio',
              type: ToolParameterType.number,
              description: 'A number.',
            ),
            ToolParameter(
              name: 'flag',
              type: ToolParameterType.boolean,
              description: 'A flag.',
            ),
            ToolParameter(
              name: 'text',
              type: ToolParameterType.string,
              description: 'Text.',
            ),
          ],
          handler: (arguments) async {
            received.add(arguments);
            return 'ok';
          },
        ),
      ],
      platform: ToolPlatform.macOS,
    );

    final result = await registry.execute(
      const ToolCall(
        toolName: 'shapes',
        arguments: {'count': '7', 'ratio': '1.5', 'flag': 'TRUE', 'text': 42},
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(received.single['count'], 7);
    expect(received.single['ratio'], 1.5);
    expect(received.single['flag'], true);
    expect(received.single['text'], '42');
  });

  test('refuses a tool this platform does not support', () async {
    var ran = false;
    final registry = ToolRegistry(
      tools: [
        _fakeTool(
          name: 'android_only',
          platforms: const {ToolPlatform.android},
          handler: (arguments) async {
            ran = true;
            return 'ran';
          },
        ),
      ],
      platform: ToolPlatform.macOS,
    );

    final result = await registry.execute(
      const ToolCall(toolName: 'android_only'),
    );

    expect(result.status, ToolExecutionStatus.unsupported);
    expect(result.output, contains('macOS'));
    expect(result.output, contains('Android'));
    expect(ran, isFalse);
  });

  test('denies a sensitive tool until a gate approves it', () async {
    var ran = false;
    final entry = _fakeTool(
      name: 'act',
      risk: ToolRiskLevel.sensitive,
      handler: (arguments) async {
        ran = true;
        return 'acted';
      },
    );
    final registry = ToolRegistry(tools: [entry], platform: ToolPlatform.macOS);

    final denied = await registry.execute(const ToolCall(toolName: 'act'));

    expect(denied.status, ToolExecutionStatus.denied);
    expect(denied.needsPermission, isTrue);
    expect(denied.output, contains('did not allow'));
    expect(ran, isFalse);

    final gate = _RecordingGate(approved: true);
    final approving = ToolRegistry(
      tools: [entry],
      platform: ToolPlatform.macOS,
      permissionGate: gate,
    );

    final allowed = await approving.execute(const ToolCall(toolName: 'act'));

    expect(allowed.isSuccess, isTrue);
    expect(ran, isTrue);
    expect(gate.requests.single.summary, contains('act'));
  });

  test('asks with validated arguments, not raw model output', () async {
    final gate = _RecordingGate(approved: false);
    final registry = ToolRegistry(
      tools: [
        _fakeTool(
          name: 'act',
          risk: ToolRiskLevel.sensitive,
          parameters: const [
            ToolParameter(
              name: 'count',
              type: ToolParameterType.integer,
              description: 'How many.',
            ),
          ],
        ),
      ],
      platform: ToolPlatform.macOS,
      permissionGate: gate,
    );

    await registry.execute(
      const ToolCall(toolName: 'act', arguments: {'count': '3'}),
    );

    expect(gate.requests.single.arguments['count'], 3);
  });

  test('stops a handler that takes too long', () async {
    final registry = ToolRegistry(
      tools: [
        _fakeTool(
          name: 'slow',
          timeout: const Duration(milliseconds: 30),
          handler: (arguments) async {
            await Future<void>.delayed(const Duration(seconds: 5));
            return 'late';
          },
        ),
      ],
      platform: ToolPlatform.macOS,
    );

    final result = await registry.execute(const ToolCall(toolName: 'slow'));

    expect(result.status, ToolExecutionStatus.timedOut);
    expect(result.output, contains('did not finish within'));
  });

  test('turns a handler failure into a failed result', () async {
    final registry = ToolRegistry(
      tools: [
        _fakeTool(
          name: 'broken',
          handler: (arguments) async {
            throw Exception('the file went away');
          },
        ),
      ],
      platform: ToolPlatform.macOS,
    );

    final result = await registry.execute(const ToolCall(toolName: 'broken'));

    expect(result.status, ToolExecutionStatus.failed);
    expect(result.output, 'the file went away');
  });
}
