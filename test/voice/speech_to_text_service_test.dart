import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/voice/data/speech_to_text_service.dart';

/// Speech runtime that records what it was asked to do instead of loading a
/// real model, so the service's own decisions are what the tests check.
class _RecordingRuntime implements SpeechRuntime {
  _RecordingRuntime({this.isGenerating = false, this.tokens = const ['Hello']});

  @override
  bool isGenerating;

  final List<String> tokens;

  bool cancelled = false;
  String? loadModelPath;
  String? loadProjectorPath;
  int? loadContextTokens;
  String? transcribePrompt;
  String? transcribeAudioPath;
  int? transcribeMaxTokens;

  @override
  Future<void> load({
    required String modelPath,
    required String projectorPath,
    required int contextTokens,
  }) async {
    loadModelPath = modelPath;
    loadProjectorPath = projectorPath;
    loadContextTokens = contextTokens;
  }

  @override
  Stream<String> transcribe(
    String prompt, {
    required String audioPath,
    required int maxTokens,
  }) {
    transcribePrompt = prompt;
    transcribeAudioPath = audioPath;
    transcribeMaxTokens = maxTokens;
    return Stream<String>.fromIterable(tokens);
  }

  @override
  void cancel() => cancelled = true;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pocket_llm_stt');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<String> writeClip(String name) async {
    final file = File(p.join(tempDir.path, name));
    await file.writeAsBytes(const [0, 1, 2, 3]);
    return file.path;
  }

  LlmModel speechModel({int? contextLength}) {
    return LlmModel(
      id: 'speech-model',
      name: 'Speech Model',
      parameterSize: '3B',
      description: 'test speech model',
      capabilities: const [ModelCapability.audio],
      ggufMetadata: contextLength == null
          ? null
          : GgufMetadata(
              architecture: 'voxtral',
              name: 'speech-model',
              version: 3,
              kvCount: 10,
              tensorCount: 10,
              fileSizeBytes: 1024,
              parameterCount: 1000,
              quantization: 'Q4_K_M',
              contextLength: contextLength,
            ),
    );
  }

  SpeechToTextService serviceFor(
    SpeechRuntime runtime, {
    String? modelPath = '/models/speech.gguf',
    String? projectorPath = '/models/speech-mmproj.gguf',
    Future<bool> Function(String? path)? isFileReady,
  }) {
    return SpeechToTextService(
      runtime: runtime,
      resolveModelPath: (_) async => modelPath,
      resolveProjectorPath: (_) async => projectorPath,
      isFileReady: isFileReady ?? (_) async => true,
    );
  }

  test('loads the projector and streams the transcript of a clip', () async {
    final runtime = _RecordingRuntime(tokens: const ['Hallo', ' Welt']);
    final service = serviceFor(runtime);
    final clip = await writeClip('note.wav');

    final parts = await service
        .transcribe(model: speechModel(contextLength: 4096), audioPath: clip)
        .toList();

    expect(parts, ['Hallo', ' Welt']);
    expect(runtime.loadModelPath, '/models/speech.gguf');
    expect(runtime.loadProjectorPath, '/models/speech-mmproj.gguf');
    // The declared window is used, with half of it reserved for the words.
    expect(runtime.loadContextTokens, 4096);
    expect(runtime.transcribeMaxTokens, 2048);
    expect(runtime.transcribeAudioPath, clip);
    expect(runtime.transcribePrompt, defaultTranscriptionPrompt);
  });

  test('caps a declared window that is meant for text', () async {
    final runtime = _RecordingRuntime();
    final service = serviceFor(runtime);

    await service
        .transcribe(
          model: speechModel(contextLength: 131072),
          audioPath: await writeClip('note.wav'),
        )
        .toList();

    expect(runtime.loadContextTokens, 8192);
    expect(runtime.transcribeMaxTokens, 4096);
  });

  test('falls back to a small window when the model declares none', () async {
    final runtime = _RecordingRuntime();
    final service = serviceFor(runtime);

    await service
        .transcribe(
          model: speechModel(),
          audioPath: await writeClip('note.mp3'),
        )
        .toList();

    expect(runtime.loadContextTokens, 2048);
    expect(runtime.transcribeMaxTokens, 1024);
  });

  test('refuses a format the bundled runtime cannot decode', () async {
    final service = serviceFor(_RecordingRuntime());
    final clip = await writeClip('memo.m4a');

    await expectLater(
      service.transcribe(model: speechModel(), audioPath: clip).toList(),
      throwsA(
        predicate(
          (error) => error.toString().contains('wav, mp3 or flac'),
          'mentions the readable formats',
        ),
      ),
    );
  });

  test('reports a clip that is not there', () async {
    final service = serviceFor(_RecordingRuntime());

    await expectLater(
      service
          .transcribe(
            model: speechModel(),
            audioPath: p.join(tempDir.path, 'gone.wav'),
          )
          .toList(),
      throwsA(
        predicate(
          (error) => error.toString().contains('could not be found'),
          'explains the clip is missing',
        ),
      ),
    );
  });

  test('refuses to interrupt a running generation', () async {
    final runtime = _RecordingRuntime(isGenerating: true);
    final service = serviceFor(runtime);
    final clip = await writeClip('note.wav');

    await expectLater(
      service.transcribe(model: speechModel(), audioPath: clip).toList(),
      throwsA(
        predicate(
          (error) => error.toString().contains('Wait for the current answer'),
          'asks for the running answer to finish',
        ),
      ),
    );
    expect(runtime.loadModelPath, isNull);
  });

  test('reports a missing voice model file', () async {
    final service = serviceFor(_RecordingRuntime(), modelPath: null);
    final clip = await writeClip('note.wav');

    await expectLater(
      service.transcribe(model: speechModel(), audioPath: clip).toList(),
      throwsA(
        predicate(
          (error) => error.toString().contains('voice model file is missing'),
          'names the missing model file',
        ),
      ),
    );
  });

  test('reports an incomplete voice model file', () async {
    final service = serviceFor(
      _RecordingRuntime(),
      isFileReady: (path) async => path != '/models/speech.gguf',
    );
    final clip = await writeClip('note.wav');

    await expectLater(
      service.transcribe(model: speechModel(), audioPath: clip).toList(),
      throwsA(
        predicate(
          (error) =>
              error.toString().contains('voice model file is incomplete'),
          'names the incomplete model file',
        ),
      ),
    );
  });

  test('reports a model without an audio projector', () async {
    final service = serviceFor(_RecordingRuntime(), projectorPath: null);
    final clip = await writeClip('note.wav');

    await expectLater(
      service.transcribe(model: speechModel(), audioPath: clip).toList(),
      throwsA(
        predicate(
          (error) => error.toString().contains('no audio projector'),
          'explains the model cannot hear audio',
        ),
      ),
    );
  });

  test('reports an incomplete projector', () async {
    final service = serviceFor(
      _RecordingRuntime(),
      isFileReady: (path) async => path != '/models/speech-mmproj.gguf',
    );
    final clip = await writeClip('note.wav');

    await expectLater(
      service.transcribe(model: speechModel(), audioPath: clip).toList(),
      throwsA(
        predicate(
          (error) => error.toString().contains('audio projector'),
          'names the incomplete projector',
        ),
      ),
    );
  });

  test('forwards a stop to the runtime', () {
    final runtime = _RecordingRuntime();
    serviceFor(runtime).cancel();

    expect(runtime.cancelled, isTrue);
  });
}
