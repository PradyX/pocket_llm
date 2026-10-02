import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_controller.dart';
import 'package:pocket_llm/features/benchmark/application/model_comparison_service.dart';
import 'package:pocket_llm/features/benchmark/domain/model_comparison_export.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';

/// Runs a real comparison on this machine, against models that are really on
/// disk, and round-trips the export through the real clipboard.
///
/// Unit tests cover the comparison service and the export encoder against a
/// scripted runtime; what they cannot cover is the whole chain — installed
/// models resolved to paths, GGUF files loaded through the native runtime,
/// answers streamed back, and the platform clipboard accepting the encoded
/// text. This test drives the real providers and prints what it found, so it is
/// useful even on a machine with nothing installed.
///
/// Run on a desktop or device:
///
/// ```bash
/// flutter test integration_test/device_comparison_smoke_test.dart -d macos
/// ```
///
/// The test skips the run when fewer than two models are installed; the first
/// test still prints what the app can see, which is the useful signal on a
/// machine with an empty catalog.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('installed models are listed with a resolvable path', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(const SizedBox.shrink());
    // The catalog loads asynchronously; give it a moment to finish.
    await _waitFor(
      () => container.read(modelSelectionControllerProvider).models.isNotEmpty,
    );

    final state = container.read(modelSelectionControllerProvider);
    final downloaded = [
      for (final model in state.models)
        if (model.isDownloaded) model,
    ];
    // ignore: avoid_print
    print('installed models: ${downloaded.length} of ${state.models.length}');
    for (final model in downloaded) {
      // ignore: avoid_print
      print('  ${model.name} (${model.id})');
    }

    // Reading the state proves the catalog loaded; the comparison test below
    // reports when there is nothing installed to run.
  });

  testWidgets('a real comparison exports through the real clipboard', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(const SizedBox.shrink());
    await _waitFor(
      () => container.read(modelSelectionControllerProvider).models.isNotEmpty,
    );

    final models = _comparableModels(container);
    if (models.length < ModelComparisonService.minimumModels) {
      // ignore: avoid_print
      print(
        'skipping: ${models.length} installed model(s); a comparison needs '
        '${ModelComparisonService.minimumModels}. '
        'Set POCKET_LLM_COMPARE_PATHS to compare GGUF files directly.',
      );
      return;
    }

    final chosen = models.take(ModelComparisonService.maximumModels).toList();
    // ignore: avoid_print
    print('comparing: ${chosen.map((model) => model.name).join(', ')}');

    final controller = container.read(
      modelComparisonControllerProvider.notifier,
    );
    for (final model in chosen) {
      controller.toggleModel(model.id);
    }
    controller
      ..setPrompt('Name one difference between a list and a tuple.')
      ..setBlind(true);

    await controller.run().timeout(const Duration(minutes: 10));

    final state = container.read(modelComparisonControllerProvider);
    for (final result in state.results) {
      // ignore: avoid_print
      print(
        '${result.model.name}: success=${result.isSuccess} '
        '${result.tokensPerSecond.toStringAsFixed(1)} tok/s, '
        '${result.generatedTokens} tokens, ttft=${result.ttftMs} ms'
        '${result.errorMessage == null ? '' : ' error=${result.errorMessage}'}',
      );
      // ignore: avoid_print
      print('  answer: ${result.responsePreview}');
    }

    final successes = state.results.where((result) => result.isSuccess);
    expect(
      state.stage,
      ComparisonStage.finished,
      reason: 'the run did not finish: ${state.errorMessage}',
    );
    expect(
      successes,
      isNotEmpty,
      reason:
          'no model answered: '
          '${state.results.map((r) => r.errorMessage).toList()}',
    );

    if (state.canChoosePreferred) {
      controller.choosePreferred(successes.first.model.id);
    }
    final export = controller.buildExport();
    expect(export, isNotNull);

    // The platform clipboard is real here, so this also proves the encoded
    // text survives the channel.
    expect(
      await controller.copyExportToClipboard(ComparisonExportFormat.json),
      isTrue,
    );
    final copied = await Clipboard.getData(Clipboard.kTextPlain);
    final payload = jsonDecode(copied?.text ?? '') as Map<String, dynamic>;
    expect(payload['format'], modelComparisonExportFormat);
    expect(payload['schemaVersion'], modelComparisonExportSchemaVersion);
    expect(payload['results'], hasLength(state.results.length));

    expect(
      await controller.copyExportToClipboard(ComparisonExportFormat.markdown),
      isTrue,
    );
    final markdown =
        (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    expect(markdown, startsWith('# Model comparison'));
    expect(markdown, contains('Name one difference'));

    expect(
      await controller.copyExportToClipboard(ComparisonExportFormat.csv),
      isTrue,
    );
    final csv = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    expect(csv, startsWith(comparisonCsvColumns.join(',')));
  });
}

/// Models the comparison can run: installed, and either managed by the app or
/// referenced by an external path that still exists.
List<LlmModel> _comparableModels(ProviderContainer container) {
  final state = container.read(modelSelectionControllerProvider);
  return [
    for (final model in state.models)
      if (model.isDownloaded) model,
  ];
}

/// Waits for [condition] to hold, so async provider startup can finish.
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
