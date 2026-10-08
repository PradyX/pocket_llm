import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/conversations/domain/context_policy.dart';
import 'package:pocket_llm/features/home/presentation/context_usage_indicator.dart';

void main() {
  /// A request that would use half of the model's input budget.
  ContextUsage usage({
    int usedTokens = 600,
    int droppedMessages = 0,
    int truncatedMessages = 0,
    int retrievedSources = 0,
    int retrievalTokens = 0,
  }) {
    return ContextUsage(
      usedTokens: usedTokens,
      limitTokens: 1200,
      contextTokens: 2048,
      reservedOutputTokens: 512,
      includedMessages: 3,
      droppedMessages: droppedMessages,
      truncatedMessages: truncatedMessages,
      retrievedSources: retrievedSources,
      retrievalTokens: retrievalTokens,
    );
  }

  /// The dial lives in the chat's app bar, so it is pumped there: that is what
  /// decides which side of it the panel opens on.
  Future<void> pump(WidgetTester tester, ContextUsageIndicator indicator) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Pocket LLM'), actions: [indicator]),
          body: const SizedBox.expand(),
        ),
      ),
    );
  }

  ColorScheme schemeOf(WidgetTester tester) {
    return Theme.of(
      tester.element(find.byType(ContextUsageIndicator)),
    ).colorScheme;
  }

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byType(ContextUsageIndicator));
    await tester.pumpAndSettle();
  }

  testWidgets('the ring shows the share and keeps the figures for the panel', (
    tester,
  ) async {
    await pump(
      tester,
      ContextUsageIndicator(
        usage: usage(),
        fixedSystemTokens: 518,
        toolContractIncluded: true,
      ),
    );

    // What stays in the composer: one dial, filled to the share already used.
    final ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ring.value, 0.5);
    expect(ring.color, schemeOf(tester).primary);
    expect(find.text('50%'), findsOneWidget);

    // None of the figures are in the composer any more.
    expect(find.text('Context'), findsNothing);
    expect(find.textContaining('600 / 1.2K'), findsNothing);
    expect(find.textContaining('fixed: system prompt'), findsNothing);
  });

  testWidgets('clicking the ring opens the panel under the app bar', (
    tester,
  ) async {
    await pump(
      tester,
      ContextUsageIndicator(
        usage: usage(),
        fixedSystemTokens: 518,
        toolContractIncluded: true,
      ),
    );
    await openPanel(tester);

    // The header the reference panel shows: the dial's figure as text, then
    // the bar, then the window it was measured against.
    expect(find.text('Context'), findsOneWidget);
    expect(find.text('600 / 1.2K · 50%'), findsOneWidget);
    expect(
      find.text('2.0K context · 512 reserved for the answer'),
      findsOneWidget,
    );

    // What fills the budget, one row per part.
    expect(find.text('Prompt usage'), findsOneWidget);
    expect(find.text('System prompt and tools'), findsOneWidget);
    expect(find.text('518'), findsOneWidget);
    expect(find.text('Conversation history'), findsOneWidget);
    expect(find.text('82'), findsOneWidget);
    expect(
      find.text(
        'What the next message from this conversation would cost. Retrieval '
        'from your knowledge collection is added when you send it.',
      ),
      findsOneWidget,
    );

    // What the conversation itself costs.
    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('Included'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Retrieved documents'), findsNothing);

    // It opens under the app bar, which is where the dial is.
    expect(
      tester.getRect(find.byType(LinearProgressIndicator)).top,
      greaterThanOrEqualTo(
        tester.getRect(find.byType(ContextUsageIndicator)).bottom,
      ),
    );
  });

  testWidgets('the dial closes the panel it opened', (tester) async {
    await pump(tester, ContextUsageIndicator(usage: usage()));
    await openPanel(tester);
    expect(find.text('Context'), findsOneWidget);

    await tester.tap(find.byType(ContextUsageIndicator));
    await tester.pumpAndSettle();

    expect(find.text('Context'), findsNothing);
  });

  testWidgets('a request trimmed to fit says so and warns on the ring', (
    tester,
  ) async {
    await pump(
      tester,
      ContextUsageIndicator(
        usage: usage(
          droppedMessages: 2,
          truncatedMessages: 1,
          retrievedSources: 2,
          retrievalTokens: 180,
        ),
        fixedSystemTokens: 16,
        toolContractIncluded: false,
        isGenerating: true,
      ),
    );

    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .color,
      schemeOf(tester).error,
    );

    await openPanel(tester);

    expect(find.text('System prompt'), findsOneWidget);
    expect(find.text('16'), findsOneWidget);
    expect(find.text('404'), findsOneWidget);
    expect(find.text('Retrieved documents'), findsOneWidget);
    expect(find.text('180 · 2 chunks'), findsOneWidget);
    expect(find.text('Dropped (older)'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Shortened'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(
      find.text(
        'Budget for the request now running. This model cannot call tools, so '
        'no tool contract is sent.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a percentage wider than the ring is scaled into its hole', (
    tester,
  ) async {
    await pump(tester, ContextUsageIndicator(usage: usage(usedTokens: 1200)));

    // The test font is one em per glyph, so '100%' is wider than the hole the
    // number sits in -- the same situation as a wide glyph or a large
    // accessibility text size on a real device. The fitted box is what keeps it
    // inside the dial instead of spilling over the ring.
    final hole = tester.getSize(
      find.descendant(
        of: find.byType(ContextUsageIndicator),
        matching: find.byType(FittedBox),
      ),
    );
    expect(hole.width, lessThanOrEqualTo(19));
    expect(hole.height, lessThanOrEqualTo(19));
    expect(tester.getSize(find.text('100%')).width, greaterThan(hole.width));
  });
}
