import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// True on the desktop platforms this app targets, where Return is a send key.
///
/// Android and iOS send through their own keyboard action, so Return stays a
/// line break there and only the desktop shortcut is installed.
bool get sendsMessageOnEnter =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Lets a desktop Return key send what has been typed while Shift+Return keeps
/// making a new line.
///
/// The platform's text editing shortcuts deliberately leave Return to the text
/// input connection, which is why a multi-line message field only ever grew a
/// line. Installing this mapping closer to the field takes Return first: plain
/// Return becomes a [SendMessageIntent] that is handled here, while Shift+Return
/// does not match the activator and falls through to the usual line break.
///
/// [child] is returned untouched when [sendsOnEnter] is false, so a mobile
/// build — or a field that cannot be composed in yet — keeps the default keys.
class ComposerSendOnEnter extends StatelessWidget {
  const ComposerSendOnEnter({
    super.key,
    required this.sendsOnEnter,
    required this.onSend,
    required this.child,
  });

  /// Whether Return currently sends the message.
  final bool sendsOnEnter;

  /// Sends the message the field holds. Ignored while [sendsOnEnter] is false.
  final Future<void> Function() onSend;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!sendsOnEnter) return child;

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        // Both Return keys a full keyboard has: the main one and the one on
        // the numeric keypad. Repeats are off so holding the key sends once.
        SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
            SendMessageIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter, includeRepeats: false):
            SendMessageIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          SendMessageIntent: CallbackAction<SendMessageIntent>(
            onInvoke: (intent) {
              unawaited(onSend());
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

/// Asks the composer to send the message that has been typed.
class SendMessageIntent extends Intent {
  const SendMessageIntent();
}
