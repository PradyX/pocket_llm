import 'dart:async';

import 'package:pocket_llm/features/tools/domain/tool_call.dart';
import 'package:pocket_llm/features/tools/domain/tool_definition.dart';
import 'package:pocket_llm/features/tools/domain/tool_execution_result.dart';

/// Runs one validated tool call and returns what the tool produced.
///
/// Handlers receive coerced arguments, so each implementation can trust its
/// inputs and focus on the work.
typedef ToolHandler = Future<String> Function(Map<String, Object?> arguments);

/// One tool: what it declares and what it does.
class ToolEntry {
  const ToolEntry({required this.definition, required this.handler});

  final ToolDefinition definition;
  final ToolHandler handler;
}

/// A request to run a sensitive tool, for the user to decide on.
class ToolApprovalRequest {
  const ToolApprovalRequest({required this.tool, required this.arguments});

  final ToolDefinition tool;

  /// Validated arguments, so the user sees exactly what would run.
  final Map<String, Object?> arguments;

  /// One line describing the call, used by permission prompts and logs.
  String get summary => '${tool.name}(${renderToolArguments(arguments)})';
}

/// `expression: (2 + 3) * 4` — how a call's arguments read in a prompt, a
/// permission message or a conversation record.
String renderToolArguments(Map<String, Object?> arguments) =>
    arguments.entries.map((entry) => '${entry.key}: ${entry.value}').join(', ');

/// Decides whether a sensitive tool may run.
///
/// Kept as an interface so the registry can be tested without a UI and so the
/// question is asked in one place; a gate that cannot ask returns false.
abstract class ToolPermissionGate {
  Future<bool> requestApproval(ToolApprovalRequest request);
}

/// Refuses every sensitive tool.
///
/// This is the safe default until the chat can show an approval prompt: a
/// sensitive tool that silently ran because no one could be asked would break
/// the rule that acting outside the app needs an explicit decision.
class DenySensitiveTools implements ToolPermissionGate {
  const DenySensitiveTools();

  @override
  Future<bool> requestApproval(ToolApprovalRequest request) async => false;
}

/// Why a call could not run, or the coerced arguments when it can.
class ToolArgumentValidation {
  const ToolArgumentValidation._({required this.arguments, this.errorMessage});

  const ToolArgumentValidation.valid(Map<String, Object?> arguments)
    : this._(arguments: arguments);

  const ToolArgumentValidation.invalid(String message)
    : this._(arguments: const {}, errorMessage: message);

  final Map<String, Object?> arguments;
  final String? errorMessage;

  bool get isValid => errorMessage == null;
}

/// The tools this app offers, and the only way any of them runs.
///
/// The registry owns the whole path: it looks the tool up, checks the platform,
/// validates and coerces the arguments, asks for permission when the tool is
/// sensitive, runs the handler under a timeout and turns every outcome into a
/// [ToolExecutionResult]. A model can therefore never execute anything by
/// itself — it can only ask, and the registry decides.
class ToolRegistry {
  ToolRegistry({
    required Iterable<ToolEntry> tools,
    required ToolPlatform? platform,
    ToolPermissionGate permissionGate = const DenySensitiveTools(),
  }) : _platform = platform,
       _permissionGate = permissionGate,
       _entries = {for (final entry in tools) entry.definition.name: entry};

  final Map<String, ToolEntry> _entries;

  /// Null on a platform the app does not target; every tool is then treated as
  /// unsupported instead of guessing a runtime that is not there.
  final ToolPlatform? _platform;
  final ToolPermissionGate _permissionGate;

  /// Every declared tool, in declaration order.
  List<ToolDefinition> get definitions =>
      _entries.values.map((entry) => entry.definition).toList(growable: false);

  /// Tools that actually run on this platform.
  List<ToolDefinition> get supportedDefinitions => definitions
      .where((definition) => definition.isSupportedOn(_platform))
      .toList(growable: false);

  ToolDefinition? definitionFor(String name) => _entries[name]?.definition;

  /// The contract sent to the model: what exists, how to call it and what not
  /// to do. Empty when nothing can run here, so no prompt is sent about tools
  /// that do not exist on the device.
  String describeForPrompt() {
    final supported = supportedDefinitions;
    if (supported.isEmpty) return '';

    final buffer = StringBuffer()
      ..writeln(
        'You can call local tools on this device. They run here, and '
        'nothing is uploaded.',
      )
      ..writeln()
      ..writeln('Available tools:');
    for (final tool in supported) {
      final permissionNote = tool.risk.needsPermission
          ? " Needs the user's permission before it runs."
          : '';
      buffer.writeln('- ${tool.signature}: ${tool.description}$permissionNote');
      for (final parameter in tool.parameters) {
        buffer.writeln(
          '    ${parameter.name} '
          '(${parameter.type.jsonName}, '
          '${parameter.required ? 'required' : 'optional'}): '
          '${parameter.description}',
        );
      }
    }

    buffer
      ..writeln()
      ..writeln('To use a tool, reply with only this JSON object:')
      ..writeln('{"type": "tool_call", "tool": "<name>", "arguments": {...}}')
      ..writeln(
        'When no tool is needed, answer normally in plain text; do not wrap '
        'normal answers in JSON.',
      )
      ..writeln(
        'Never invent a tool or a parameter, and never repeat a call whose '
        'result you already have.',
      );
    return buffer.toString().trimRight();
  }

  /// Checks a call against the tool's declaration.
  ///
  /// Returns the arguments coerced to their declared types, so a handler never
  /// has to re-parse model output.
  ToolArgumentValidation validate(ToolCall call) {
    final entry = _entries[call.toolName];
    if (entry == null) {
      return ToolArgumentValidation.invalid(
        'There is no tool named "${call.toolName}". Available tools: '
        '${_availableNames()}.',
      );
    }

    final definition = entry.definition;
    if (!definition.isSupportedOn(_platform)) {
      return ToolArgumentValidation.invalid(
        '${definition.name} is not available on ${_platformLabel()}.',
      );
    }

    final accepted = {
      for (final parameter in definition.parameters) parameter.name: parameter,
    };
    final unknown =
        call.arguments.keys
            .where((name) => !accepted.containsKey(name))
            .toList()
          ..sort();
    if (unknown.isNotEmpty) {
      return ToolArgumentValidation.invalid(
        '${definition.name} does not accept '
        '${unknown.map((name) => '"$name"').join(', ')}. Accepted parameters: '
        '${accepted.keys.isEmpty ? 'none' : accepted.keys.join(', ')}.',
      );
    }

    final resolved = <String, Object?>{};
    for (final parameter in definition.parameters) {
      final provided = call.arguments[parameter.name];
      if (provided == null) {
        if (parameter.required) {
          return ToolArgumentValidation.invalid(
            '${definition.name} needs "${parameter.name}" '
            '(${parameter.type.jsonName}): ${parameter.description}',
          );
        }
        continue;
      }

      try {
        resolved[parameter.name] = _coerce(parameter, provided);
      } on _ToolArgumentProblem catch (problem) {
        return ToolArgumentValidation.invalid(problem.message);
      }
    }

    return ToolArgumentValidation.valid(resolved);
  }

  /// Runs one call through the whole path: lookup, platform, validation,
  /// permission, handler and timeout.
  Future<ToolExecutionResult> execute(ToolCall call) async {
    final entry = _entries[call.toolName];
    if (entry == null) {
      return ToolExecutionResult(
        toolName: call.toolName,
        status: ToolExecutionStatus.unknownTool,
        output:
            'There is no tool named "${call.toolName}". Available tools: '
            '${_availableNames()}.',
      );
    }

    final definition = entry.definition;
    if (!definition.isSupportedOn(_platform)) {
      return ToolExecutionResult(
        toolName: definition.name,
        status: ToolExecutionStatus.unsupported,
        output:
            '${definition.name} is not available on ${_platformLabel()}. '
            '${_platformFallback(definition)}',
      );
    }

    final validation = validate(call);
    if (!validation.isValid) {
      return ToolExecutionResult(
        toolName: definition.name,
        status: ToolExecutionStatus.invalidArguments,
        output: validation.errorMessage!,
      );
    }

    if (definition.risk.needsPermission) {
      final approved = await _permissionGate.requestApproval(
        ToolApprovalRequest(tool: definition, arguments: validation.arguments),
      );
      if (!approved) {
        return ToolExecutionResult(
          toolName: definition.name,
          status: ToolExecutionStatus.denied,
          output:
              'The user did not allow ${definition.name} to run, so nothing '
              'happened.',
        );
      }
    }

    final stopwatch = Stopwatch()..start();
    try {
      final output = await entry
          .handler(validation.arguments)
          .timeout(definition.timeout);
      stopwatch.stop();
      return ToolExecutionResult(
        toolName: definition.name,
        status: ToolExecutionStatus.success,
        output: output,
        duration: stopwatch.elapsed,
      );
    } on TimeoutException {
      stopwatch.stop();
      return ToolExecutionResult(
        toolName: definition.name,
        status: ToolExecutionStatus.timedOut,
        output:
            '${definition.name} did not finish within '
            '${definition.timeout.inSeconds}s and was stopped.',
        duration: stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      return ToolExecutionResult(
        toolName: definition.name,
        status: ToolExecutionStatus.failed,
        output: _messageOf(error),
        duration: stopwatch.elapsed,
      );
    }
  }

  /// `macOS`, or `this device` when the platform is unknown.
  String _platformLabel() => _platform?.label ?? 'this device';

  String _availableNames() {
    final supported = supportedDefinitions;
    if (supported.isEmpty) return 'none on this device';
    return supported.map((definition) => definition.name).join(', ');
  }

  String _platformFallback(ToolDefinition definition) {
    final others = ToolPlatform.values
        .where(
          (platform) =>
              platform != _platform && definition.isSupportedOn(platform),
        )
        .map((platform) => platform.label);
    if (others.isEmpty) return '';
    return 'It exists on ${others.join(', ')}.';
  }

  /// Accepts the shapes small models actually produce (`7`, `"7"`, `7.0`) and
  /// rejects everything else with the parameter name in the message, so the
  /// model can correct itself on the next turn.
  Object _coerce(ToolParameter parameter, Object provided) {
    switch (parameter.type) {
      case ToolParameterType.string:
        final text = provided is String ? provided : provided.toString();
        final maxLength = parameter.maxLength;
        if (maxLength != null && text.length > maxLength) {
          throw _ToolArgumentProblem(
            '"${parameter.name}" must be at most $maxLength characters.',
          );
        }
        if (parameter.allowedValues.isNotEmpty &&
            !parameter.allowedValues.contains(text)) {
          throw _ToolArgumentProblem(
            '"${parameter.name}" must be one of: '
            '${parameter.allowedValues.join(', ')}.',
          );
        }
        return text;

      case ToolParameterType.integer:
        final number = _number(parameter, provided);
        if (number % 1 != 0) {
          throw _ToolArgumentProblem(
            '"${parameter.name}" must be a whole number.',
          );
        }
        return number.toInt();

      case ToolParameterType.number:
        return _number(parameter, provided);

      case ToolParameterType.boolean:
        if (provided is bool) return provided;
        if (provided is String) {
          final normalized = provided.trim().toLowerCase();
          if (normalized == 'true') return true;
          if (normalized == 'false') return false;
        }
        throw _ToolArgumentProblem(
          '"${parameter.name}" must be true or false.',
        );
    }
  }

  num _number(ToolParameter parameter, Object provided) {
    final num? parsed = provided is num
        ? provided
        : provided is String
        ? num.tryParse(provided.trim())
        : null;
    if (parsed == null) {
      throw _ToolArgumentProblem(
        '"${parameter.name}" must be a ${parameter.type.jsonName}.',
      );
    }

    final minimum = parameter.minimum;
    if (minimum != null && parsed < minimum) {
      throw _ToolArgumentProblem(
        '"${parameter.name}" must be at least $minimum.',
      );
    }
    final maximum = parameter.maximum;
    if (maximum != null && parsed > maximum) {
      throw _ToolArgumentProblem(
        '"${parameter.name}" must be at most $maximum.',
      );
    }
    return parsed;
  }

  /// `Exception: something` reads badly in the UI, so the prefix is dropped.
  static String _messageOf(Object error) {
    const prefix = 'Exception: ';
    final text = error.toString();
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }
}

/// Thrown while coercing a parameter; carries the message the model should see.
class _ToolArgumentProblem implements Exception {
  const _ToolArgumentProblem(this.message);

  final String message;
}
