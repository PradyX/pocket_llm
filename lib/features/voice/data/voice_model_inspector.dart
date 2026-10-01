import 'dart:io';

import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/voice/domain/voice_model_option.dart';

/// Resolves the projector file paired with [model], or null when there is none.
typedef ProjectorPathResolver = Future<String?> Function(LlmModel model);

/// What inspecting a projector found.
class VoiceProjectorInfo {
  const VoiceProjectorInfo({required this.availability, this.projectorType});

  final VoiceModelAvailability availability;

  /// `clip.projector_type` from the mmproj file, when present.
  final String? projectorType;
}

/// Reads whether a model's projector can decode audio.
///
/// Only the projector's own GGUF metadata knows whether it carries an audio
/// encoder, so the mmproj file is opened and its metadata read — never its
/// weights. Results are cached per file plus size and timestamp, so opening the
/// picker again does not re-read the same projector, while a re-downloaded
/// projector is inspected afresh.
class VoiceModelInspector {
  VoiceModelInspector({
    required ProjectorPathResolver projectorPathResolver,
    GgufReader? reader,
  }) : _projectorPathResolver = projectorPathResolver,
       _reader = reader ?? const GgufReader();

  final ProjectorPathResolver _projectorPathResolver;
  final GgufReader _reader;
  final Map<String, VoiceProjectorInfo> _cache = {};

  /// Classifies [model] for local speech.
  Future<VoiceProjectorInfo> inspect(LlmModel model) async {
    final String? path;
    try {
      path = await _projectorPathResolver(model);
    } catch (_) {
      return const VoiceProjectorInfo(
        availability: VoiceModelAvailability.unreadable,
      );
    }
    if (path == null || path.trim().isEmpty) {
      return const VoiceProjectorInfo(
        availability: VoiceModelAvailability.projectorMissing,
      );
    }

    final String cacheKey;
    try {
      final file = File(path);
      if (!file.existsSync()) {
        return const VoiceProjectorInfo(
          availability: VoiceModelAvailability.projectorMissing,
        );
      }
      final stat = file.statSync();
      cacheKey = '$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } on FileSystemException {
      return const VoiceProjectorInfo(
        availability: VoiceModelAvailability.projectorMissing,
      );
    }

    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    final info = await _readProjector(path);
    _cache[cacheKey] = info;
    return info;
  }

  Future<VoiceProjectorInfo> _readProjector(String path) async {
    try {
      final metadata = await _reader.info(path);
      return VoiceProjectorInfo(
        availability: metadata.hasAudioEncoder
            ? VoiceModelAvailability.ready
            : VoiceModelAvailability.audioEncoderMissing,
        projectorType: metadata.projectorType,
      );
    } on GgufFormatException {
      return const VoiceProjectorInfo(
        availability: VoiceModelAvailability.unreadable,
      );
    } catch (_) {
      return const VoiceProjectorInfo(
        availability: VoiceModelAvailability.unreadable,
      );
    }
  }
}
