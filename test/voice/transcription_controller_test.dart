import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/voice/application/transcription_controller.dart';
import 'package:pocket_llm/features/voice/data/speech_to_text_service.dart';

/// Speech runtime whose output the test controls token by token, so streaming,
/// stopping and failures can be observed without a model on disk.
class _ControllableRuntime implements SpeechRuntime {
  _ControllableRuntime({this.failure});

  /// When set, transcription fails with this message instead of streaming.
  final String? failure;

  final StreamController<String> _tokens = StreamController<String>();

  int transcribeCalls = 0;
  bool cancelled = false;
  String? audioPath;

  @override
  bool isGenerating = false;

  @override
  Future<void> load({
    required String modelPath,
    required String projectorPath,
    required int contextTokens,
  }) async {}

  @override
  Stream<String> transcribe(
    String prompt, {
    required String audioPath,
    required int maxTokens,
  }) {
    transcribeCalls++;
    this.audioPath = audioPath;
    final failure = this.failure;
    if (failure != null) return Stream<String>.error(Exception(failure));
    return _tokens.stream;
  }

  @override
  void cancel() => cancelled = true;

  void emit(String token) => _tokens.add(token);

  Future<void> finish() async {
    // A controller nobody listened to never completes its close future.
    if (!_tokens.hasListener) return;
    await _tokens.close();
  }
}

/// Pumps the event loop until [condition] holds.
///
/// A run checks the clip on disk, resolves the model paths and starts the
/// engine, so a single event-loop turn is not enough to reach the runtime.
Future<void> pumpUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was never met');
}

void main() {
  late Directory tempDir;
  late String clip;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocket_llm_stt_run');
    final file = File(p.join(tempDir.path, 'note.wav'));
    await file.writeAsBytes(const [0, 1, 2, 3]);
    clip = file.path;
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  LlmModel speechModel() => const LlmModel(
    id: 'speech-model',
    name: 'Speech Model',
    parameterSize: '3B',
    description: 'test speech model',
    capabilities: [ModelCapability.audio],
  );

  ProviderContainer containerFor({
    required SpeechRuntime runtime,
    LlmModel? model,
    Future<String?> Function()? picker,
    bool modelReady = true,
  }) {
    return ProviderContainer(
      overrides: [
        transcriptionModelProvider.overrideWithValue(modelReady ? model : null),
        voiceAudioPickerProvider.overrideWithValue(picker ?? () async => clip),
        speechToTextServiceProvider.overrideWithValue(
          SpeechToTextService(
            runtime: runtime,
            resolveModelPath: (_) async => '/models/speech.gguf',
            resolveProjectorPath: (_) async => '/models/speech-mmproj.gguf',
            isFileReady: (_) async => true,
          ),
        ),
      ],
    );
  }

  test('transcribes the picked clip and keeps the transcript', () async {
    final runtime = _ControllableRuntime();
    final container = containerFor(runtime: runtime, model: speechModel());
    addTearDown(container.dispose);
    final controller = container.read(transcriptionControllerProvider.notifier);

    final run = controller.start();
    await pumpUntil(() => runtime.transcribeCalls == 1);
    runtime.emit('Hello');
    runtime.emit(' world');
    await pumpUntil(
      () => container.read(transcriptionControllerProvider).hasTranscript,
    );
    await runtime.finish();
    await run;

    final state = container.read(transcriptionControllerProvider);
    expect(state.stage, TranscriptionStage.finished);
    expect(state.transcript, 'Hello world');
    expect(state.audioPath, clip);
    expect(state.audioLabel, 'note.wav');
    expect(state.modelName, 'Speech Model');
    expect(state.generatedTokens, 2);
    expect(state.wasStopped, isFalse);
    expect(state.errorMessage, isNull);
    expect(runtime.audioPath, clip);
  });

  test('keeps the words decoded before a stop', () async {
    final runtime = _ControllableRuntime();
    final container = containerFor(runtime: runtime, model: speechModel());
    addTearDown(container.dispose);
    final controller = container.read(transcriptionControllerProvider.notifier);

    final run = controller.start();
    await pumpUntil(() => runtime.transcribeCalls == 1);
    runtime.emit('Partial words');
    await pumpUntil(
      () => container.read(transcriptionControllerProvider).hasTranscript,
    );

    controller.cancel();
    expect(runtime.cancelled, isTrue);
    expect(
      container.read(transcriptionControllerProvider).statusText,
      'Stopping...',
    );

    await runtime.finish();
    await run;

    final state = container.read(transcriptionControllerProvider);
    expect(state.stage, TranscriptionStage.finished);
    expect(state.wasStopped, isTrue);
    expect(state.transcript, 'Partial words');
    expect(state.errorMessage, isNull);
  });

  test('leaves the screen alone when the picker is dismissed', () async {
    final runtime = _ControllableRuntime();
    final container = containerFor(
      runtime: runtime,
      model: speechModel(),
      picker: () async => null,
    );
    addTearDown(container.dispose);

    await container.read(transcriptionControllerProvider.notifier).start();

    final state = container.read(transcriptionControllerProvider);
    expect(state.stage, TranscriptionStage.idle);
    expect(state.transcript, isEmpty);
    expect(runtime.transcribeCalls, 0);
  });

  test('explains that a speech model has to be chosen first', () async {
    final runtime = _ControllableRuntime();
    final container = containerFor(runtime: runtime, modelReady: false);
    addTearDown(container.dispose);

    await container.read(transcriptionControllerProvider.notifier).start();

    final state = container.read(transcriptionControllerProvider);
    expect(state.stage, TranscriptionStage.failed);
    expect(state.errorMessage, contains('Choose a speech model'));
    expect(runtime.transcribeCalls, 0);
  });

  test('runs one clip at a time', () async {
    final runtime = _ControllableRuntime();
    final container = containerFor(runtime: runtime, model: speechModel());
    addTearDown(container.dispose);
    final controller = container.read(transcriptionControllerProvider.notifier);

    final run = controller.start();
    await pumpUntil(() => runtime.transcribeCalls == 1);
    await controller.start();

    expect(runtime.transcribeCalls, 1);

    await runtime.finish();
    await run;
  });

  test('reports a runtime failure without the exception prefix', () async {
    final runtime = _ControllableRuntime(failure: 'the clip was unreadable');
    final container = containerFor(runtime: runtime, model: speechModel());
    addTearDown(container.dispose);

    await container.read(transcriptionControllerProvider.notifier).start();

    final state = container.read(transcriptionControllerProvider);
    expect(state.stage, TranscriptionStage.failed);
    expect(state.errorMessage, 'the clip was unreadable');
  });

  test('clears the transcript and any error', () async {
    final runtime = _ControllableRuntime();
    final container = containerFor(runtime: runtime, model: speechModel());
    addTearDown(container.dispose);
    final controller = container.read(transcriptionControllerProvider.notifier);

    final run = controller.start();
    await pumpUntil(() => runtime.transcribeCalls == 1);
    runtime.emit('Done');
    await pumpUntil(
      () => container.read(transcriptionControllerProvider).hasTranscript,
    );
    await runtime.finish();
    await run;
    expect(
      container.read(transcriptionControllerProvider).hasTranscript,
      isTrue,
    );

    controller.clear();

    final state = container.read(transcriptionControllerProvider);
    expect(state.stage, TranscriptionStage.idle);
    expect(state.transcript, isEmpty);
    expect(state.audioLabel, isNull);
  });
}
