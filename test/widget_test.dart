import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/app.dart';
import 'package:pocket_llm/i18n/strings.g.dart';

void main() {
  testWidgets('renders the Pocket LLM home screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(child: const ProviderScope(child: MyApp())),
    );

    await tester.pump();

    expect(find.text('Pocket LLM'), findsOneWidget);
  });
}
