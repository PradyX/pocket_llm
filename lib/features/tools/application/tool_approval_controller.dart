import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/features/tools/application/tool_registry.dart';

/// How long a permission question waits before it is treated as refused.
///
/// The registry's own timeout only starts after permission, so a question the
/// user never answers would otherwise stall the whole turn. Two minutes is long
/// enough to read the prompt and answer it, short enough not to hang chat.
const Duration toolApprovalTimeout = Duration(minutes: 2);

/// The permission question the chat is currently asking, if any.
///
/// Kept as state rather than a callback so the chat can render the question,
/// tests can answer it, and the registry stays free of Navigator or widget
/// dependencies.
final toolApprovalControllerProvider =
    NotifierProvider<ToolApprovalController, ToolApprovalRequest?>(
      ToolApprovalController.new,
    );

/// Asks the user whether one sensitive tool may run and waits for the answer.
class ToolApprovalController extends Notifier<ToolApprovalRequest?> {
  Completer<bool>? _pending;

  @override
  ToolApprovalRequest? build() {
    ref.onDispose(() {
      final pending = _pending;
      _pending = null;
      if (pending != null && !pending.isCompleted) pending.complete(false);
    });
    return null;
  }

  /// Asks the user and waits. A second question while one is pending is refused
  /// outright: two permission prompts at once could not be told apart.
  Future<bool> requestApproval(ToolApprovalRequest request) {
    if (_pending != null) return Future.value(false);

    final completer = Completer<bool>();
    _pending = completer;
    state = request;

    return completer.future.timeout(
      toolApprovalTimeout,
      onTimeout: () {
        if (identical(_pending, completer)) {
          _pending = null;
          state = null;
        }
        return false;
      },
    );
  }

  /// The user allowed this call.
  void approve() => _complete(true);

  /// The user refused this call, or the question went unanswered.
  void deny() => _complete(false);

  void _complete(bool approved) {
    final completer = _pending;
    _pending = null;
    state = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
  }
}

/// Permission gate the registry asks: the chat's approval prompt.
class ChatToolPermissionGate implements ToolPermissionGate {
  const ChatToolPermissionGate(this._controller);

  final ToolApprovalController _controller;

  @override
  Future<bool> requestApproval(ToolApprovalRequest request) =>
      _controller.requestApproval(request);
}
