import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:pocket_llm/core/services/llm_service.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

/// Audio containers the bundled multimodal runtime can decode.
///
/// libmtmd reads audio through miniaudio, so these are the formats that
/// actually open on every platform. Offering more would promise a clip the
/// runtime cannot hear, which is worse than saying so up front.
const List<String> supportedAudioExtensions = ['wav', 'mp3', 'flac'];

/// Instruction sent with a clip.
///
/// Speech models are generative: the prompt decides whether the answer is a
/// transcript or a comment about the recording, so the task is stated plainly
/// and extra chatter is ruled out.
const String defaultTranscriptionPrompt =
    'Transcribe the speech in the attached audio. Reply with the transcript '
    'only, in the language that is spoken, without commentary, translation or '
    'speaker labels.';

/// The engine operations transcription needs.
///
/// Kept behind an interface so the transcription path can be tested without
/// loading a GGUF model: tests supply a fake runtime, the app supplies
/// [LlmSpeechRuntime].
abstract class SpeechRuntime {
  /// True while the engine is already generating something else.
  bool get isGenerating;

  /// Loads [modelPath] together with [projectorPath] so audio can be decoded.
  Future<void> load({
    required String modelPath,
    required String projectorPath,
    required int contextTokens,
  });

  /// Streams the answer to [prompt] for the clip at [audioPath].
  Stream<String> transcribe(
    String prompt, {
    required String audioPath,
    required int maxTokens,
  });

  /// Asks the running transcription to stop; text produced so far is kept.
  void cancel();
}

/// Runs speech models on the app's shared local engine.
///
/// Pocket LLM keeps one model in memory at a time, so loading a speech model
/// releases the chat model and the next chat message loads that one again.
/// Keeping transcription on the shared engine is what makes that guarantee
/// hold: a second engine would leave both models resident.
class LlmSpeechRuntime implements SpeechRuntime {
  LlmSpeechRuntime(this._llmService);

  final LlmService _llmService;

  @override
  bool get isGenerating => _llmService.isGenerating;

  @override
  Future<void> load({
    required String modelPath,
    required String projectorPath,
    required int contextTokens,
  }) {
    return _llmService.ensureModelLoaded(
      modelPath,
      nCtx: contextTokens,
      mmprojPath: projectorPath,
      // Transcription is a factual pass, so the sampler is made
      // deterministic: the same clip should not come back as different words
      // from one run to the next.
      temperature: 0,
      topP: 1,
      topK: 1,
    );
  }

  @override
  Stream<String> transcribe(
    String prompt, {
    required String audioPath,
    required int maxTokens,
  }) {
    return _llmService.generateAudioResponse(
      prompt,
      audioPath: audioPath,
      maxTokens: maxTokens,
    );
  }

  @override
  void cancel() => _llmService.stopGeneration();
}

/// Turns one local audio file into text with a local speech model.
///
/// Everything happens on this device: the clip is handed to the bundled
/// runtime as bytes, the words come from the model, and nothing is uploaded.
/// The service owns the whole path — checking the clip, resolving the model
/// and projector files, starting the engine, streaming the transcript — so the
/// UI only decides when to run it.
class SpeechToTextService {
  const SpeechToTextService({
    required SpeechRuntime runtime,
    required this.resolveModelPath,
    required this.resolveProjectorPath,
    required this.isFileReady,
  }) : _runtime = runtime;

  final SpeechRuntime _runtime;

  /// Absolute path of a model's main GGUF file.
  final Future<String?> Function(LlmModel model) resolveModelPath;

  /// Absolute path of a model's multimodal projector.
  final Future<String?> Function(LlmModel model) resolveProjectorPath;

  /// Whether a model file exists, is complete and carries GGUF bytes.
  final Future<bool> Function(String? path) isFileReady;

  /// Window a speech model is loaded with when its GGUF declares nothing.
  static const int defaultContextTokens = 2048;

  /// Smallest window that still fits a short recording plus its transcript.
  static const int minimumContextTokens = 512;

  /// Ceiling for the window, so a huge declaration cannot reserve gigabytes
  /// of KV cache on a phone for a single clip.
  static const int maximumContextTokens = 8192;

  /// Context the model is loaded with.
  ///
  /// Audio tokens are long — a minute of speech is thousands of them — so the
  /// window declared by the GGUF is preferred and then capped, instead of
  /// trusting a declaration that may have been written for text.
  static int contextTokensFor(LlmModel model) {
    final declared = model.ggufMetadata?.contextLength;
    if (declared == null || declared <= 0) return defaultContextTokens;
    return declared.clamp(minimumContextTokens, maximumContextTokens);
  }

  /// Output reservation for one clip: half the window, so a long recording
  /// cannot overflow the KV cache while the transcript is being written.
  static int outputTokensFor(int contextTokens) =>
      math.max(64, contextTokens ~/ 2);

  /// Streams the transcript of [audioPath].
  ///
  /// Errors are thrown before the engine is touched where possible, so a
  /// missing file or a model without an audio projector reports what to fix
  /// instead of failing halfway through a load.
  Stream<String> transcribe({
    required LlmModel model,
    required String audioPath,
    String prompt = defaultTranscriptionPrompt,
  }) async* {
    final extension = p
        .extension(audioPath)
        .replaceFirst('.', '')
        .toLowerCase();
    if (!supportedAudioExtensions.contains(extension)) {
      throw Exception(
        'Speech models here read ${_formatFormats(supportedAudioExtensions)} '
        'clips only.',
      );
    }
    if (!await File(audioPath).exists()) {
      throw Exception('The audio file could not be found. Choose it again.');
    }
    if (_runtime.isGenerating) {
      throw Exception(
        'Wait for the current answer to finish, or stop it, before '
        'transcribing.',
      );
    }

    final modelPath = await resolveModelPath(model);
    if (modelPath == null || modelPath.trim().isEmpty) {
      throw Exception(
        'The voice model file is missing. Download ${model.name} again or '
        'choose another speech model.',
      );
    }
    if (!await isFileReady(modelPath)) {
      throw Exception(
        'The voice model file is incomplete. Download ${model.name} again '
        'before transcribing.',
      );
    }

    final projectorPath = await resolveProjectorPath(model);
    if (projectorPath == null || projectorPath.trim().isEmpty) {
      throw Exception(
        '${model.name} has no audio projector, so it cannot hear a clip. '
        'Choose a voice model whose projector carries an audio encoder.',
      );
    }
    if (!await isFileReady(projectorPath)) {
      throw Exception(
        'The audio projector for ${model.name} is incomplete. Import its '
        'mmproj file again.',
      );
    }

    final contextTokens = contextTokensFor(model);
    await _runtime.load(
      modelPath: modelPath,
      projectorPath: projectorPath,
      contextTokens: contextTokens,
    );
    yield* _runtime.transcribe(
      prompt,
      audioPath: audioPath,
      maxTokens: outputTokensFor(contextTokens),
    );
  }

  /// Stops the running transcription, keeping the words decoded so far.
  void cancel() => _runtime.cancel();

  /// `wav, mp3 or flac`.
  static String _formatFormats(List<String> formats) {
    if (formats.length <= 1) return formats.join();
    return '${formats.sublist(0, formats.length - 1).join(', ')} or '
        '${formats.last}';
  }
}
