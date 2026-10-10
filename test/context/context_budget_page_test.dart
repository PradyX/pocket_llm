import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/context/application/context_budget_controller.dart';
import 'package:pocket_llm/features/context/data/context_budget_store.dart';
import 'package:pocket_llm/features/context/presentation/context_budget_page.dart';
import 'package:pocket_llm/features/home/presentation/home_controller.dart';
import 'package:pocket_llm/features/inference_profiles/domain/inference_profile_resolver.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/personas/domain/persona.dart';

void main() {
  late Directory tempDir;
  late File file;
  late ContextBudgetStore store;

  final model = LlmModel(
    id: 'm-1',
    name: 'Test model',
    parameterSize: '1B',
    description: 'test model',
    capabilities: const [],
    isDownloaded: true,
  );

  /// A platform-default window with the answer reservation a request would use.
  const resolvedConfig = ResolvedInferenceConfig(
    profileId: 'profile-builtin-balanced',
    profileName: 'Balanced',
    contextTokens: 4096,
    batchTokens: 4096,
    temperature: 0.7,
    topP: 0.9,
    topK: 40,
    maxOutputTokens: 512,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocketllm_budget_page');
    file = File(p.join(tempDir.path, 'context', 'budget.json'));
    store = ContextBudgetStore(file);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> pump(WidgetTester tester, {bool hasModel = true}) async {
    // The screen is a list; a viewport tall enough for all of it keeps every
    // statement in the tree instead of testing only what fits on a phone.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contextBudgetStoreProvider.overrideWith((ref) async => store),
          selectedContextWindowProvider.overrideWithValue(
            hasModel
                ? SelectedContextWindow(
                    model: model,
                    persona: BuiltInPersonas.general,
                    resolvedConfig: resolvedConfig,
                  )
                : null,
          ),
        ],
        child: const MaterialApp(home: ContextBudgetPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('automatic budget reports the window a request would use', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('Automatic (recommended)'), findsOneWidget);
    expect(find.text('Manual limit'), findsOneWidget);
    // No cap in automatic mode, so there is nothing to slide.
    expect(find.byType(Slider), findsNothing);

    expect(find.text('Current budget'), findsOneWidget);
    expect(find.text('Model maximum'), findsOneWidget);
    // Automatic caps nothing, so the budget is the model's own window, and the
    // screen says so in both rows instead of implying a limit.
    expect(find.text('4.1K tokens'), findsNWidgets(2));
    expect(find.text('Reserved for the answer'), findsOneWidget);
    expect(find.text('512 tokens'), findsOneWidget);
    expect(
      find.textContaining('Test model with the Balanced profile'),
      findsOneWidget,
    );
  });

  testWidgets('a manual limit is stored and can be removed again', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('Manual limit'));
    await tester.pumpAndSettle();

    // The starting cap is stated in words, not just on the slider.
    expect(find.byType(Slider), findsOneWidget);
    expect(
      find.text(
        '${ContextBudgetNotifier.defaultManualContextTokens ~/ 1024}.0K tokens '
        'of prompt may be sent.',
      ),
      findsOneWidget,
    );
    expect((jsonDecode(file.readAsStringSync()) as Map)['mode'], 'manual');

    await tester.tap(find.text('Remove the limit and use Automatic'));
    await tester.pumpAndSettle();

    expect(find.byType(Slider), findsNothing);
    final written = jsonDecode(file.readAsStringSync()) as Map;
    expect(written['mode'], 'auto');
    expect(written['maxContextTokens'], isNull);
  });

  testWidgets('says so when no model is selected yet', (tester) async {
    await pump(tester, hasModel: false);

    expect(find.text('No model selected'), findsOneWidget);
    // The choice is still available and still stored.
    await tester.tap(find.text('Manual limit'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect((jsonDecode(file.readAsStringSync()) as Map)['mode'], 'manual');
  });
}
