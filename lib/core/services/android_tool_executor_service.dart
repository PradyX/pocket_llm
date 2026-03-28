import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class AndroidToolExecutionResult {
  final bool isSuccess;
  final String message;
  final String? toolName;

  const AndroidToolExecutionResult({
    required this.isSuccess,
    required this.message,
    this.toolName,
  });

  const AndroidToolExecutionResult.success({
    required String message,
    String? toolName,
  }) : this(isSuccess: true, message: message, toolName: toolName);

  const AndroidToolExecutionResult.error({
    required String message,
    String? toolName,
  }) : this(isSuccess: false, message: message, toolName: toolName);
}

class AndroidToolExecutorService {
  static const MethodChannel _channel = MethodChannel(
    'pocket_llm/tool_executor',
  );

  Future<AndroidToolExecutionResult> executeToolPayload(String payload) async {
    if (!Platform.isAndroid) {
      return const AndroidToolExecutionResult.error(
        message: 'Tool execution is only available on Android.',
      );
    }

    try {
      final response = await _channel.invokeMethod<String>(
        'execute_tool',
        payload,
      );
      return _parseExecutionResult(response);
    } on PlatformException catch (error) {
      return AndroidToolExecutionResult.error(
        message:
            error.message ??
            'I could not hand off that action to Android right now.',
      );
    } catch (_) {
      return const AndroidToolExecutionResult.error(
        message: 'I could not hand off that action to Android right now.',
      );
    }
  }

  AndroidToolExecutionResult _parseExecutionResult(String? rawResponse) {
    final trimmed = rawResponse?.trim() ?? '';
    if (trimmed.isEmpty) {
      return const AndroidToolExecutionResult.error(
        message: 'Android did not return a tool execution result.',
      );
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) {
        return AndroidToolExecutionResult.success(message: trimmed);
      }

      final map = Map<String, dynamic>.from(decoded);
      final message = (map['message'] as String?)?.trim();
      final toolName = (map['tool'] as String?)?.trim();
      final status = (map['status'] as String?)?.trim().toLowerCase();

      if (message == null || message.isEmpty) {
        return const AndroidToolExecutionResult.error(
          message: 'Android returned an invalid tool execution response.',
        );
      }

      return switch (status) {
        'success' => AndroidToolExecutionResult.success(
          message: message,
          toolName: toolName,
        ),
        _ => AndroidToolExecutionResult.error(
          message: message,
          toolName: toolName,
        ),
      };
    } catch (_) {
      return AndroidToolExecutionResult.success(message: trimmed);
    }
  }
}
