import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/home/presentation/composer_shortcuts.dart';

void main() {
  /// Mounts the wrapper around a multi-line field, the way the composer does,
  /// and focuses the field so key events travel the real dispatch path.
  Future<void> pumpComposer(
    WidgetTester tester, {
    required bool sendsOnEnter,
    required VoidCallback onSend,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComposerSendOnEnter(
            sendsOnEnter: sendsOnEnter,
            onSend: () async => onSend(),
            child: const TextField(maxLines: 5),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  testWidgets('Return sends the message on a desktop keyboard', (tester) async {
    var sends = 0;
    await pumpComposer(tester, sendsOnEnter: true, onSend: () => sends++);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 1);

    // The numeric keypad's Return is the same key to the user.
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    expect(sends, 2);
  });

  testWidgets('Shift+Return stays a line break instead of sending', (
    tester,
  ) async {
    var sends = 0;
    await pumpComposer(tester, sendsOnEnter: true, onSend: () => sends++);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(sends, 0);
  });

  testWidgets('a mobile keyboard keeps its own send action', (tester) async {
    var sends = 0;
    await pumpComposer(tester, sendsOnEnter: false, onSend: () => sends++);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(sends, 0);
  });
}
