import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

/// Why an installed model can or cannot run local speech.
///
/// Vision and audio both come from a model's multimodal projector (`mmproj`),
/// and only that file decides what the model can receive. Keeping the reason
/// as data means the UI can explain a refusal instead of hiding the model.
enum VoiceModelAvailability {
  /// The model and its audio-capable projector are on this device.
  ready,

  /// The model file is still downloading, or was registered but never fetched.
  notDownloaded,

  /// No multimodal projector is attached, so audio could never be decoded.
  projectorMissing,

  /// The projector exists but carries only an image encoder.
  audioEncoderMissing,

  /// The projector exists but could not be read as a GGUF file.
  unreadable,
}

/// One model the voice picker offers, with the reason behind its state.
class VoiceModelOption {
  const VoiceModelOption({
    required this.model,
    required this.availability,
    this.projectorType,
  });

  final LlmModel model;
  final VoiceModelAvailability availability;

  /// Projector type reported by the mmproj GGUF, when it could be read.
  final String? projectorType;

  bool get isReady => availability == VoiceModelAvailability.ready;

  /// Short line for the picker, e.g. `Ready for local speech`.
  String get availabilityLabel => switch (availability) {
    VoiceModelAvailability.ready => 'Ready for local speech',
    VoiceModelAvailability.notDownloaded => 'Not downloaded yet',
    VoiceModelAvailability.projectorMissing =>
      'No multimodal projector attached',
    VoiceModelAvailability.audioEncoderMissing =>
      'Its projector handles images only',
    VoiceModelAvailability.unreadable => 'The projector could not be read',
  };

  /// Secondary line: projector type when known, or what to do about it.
  String? get detailLabel {
    if (isReady) return projectorType;
    return switch (availability) {
      VoiceModelAvailability.notDownloaded => 'Finish the download to use it',
      VoiceModelAvailability.projectorMissing =>
        'Import its mmproj file in Model Selection',
      VoiceModelAvailability.audioEncoderMissing =>
        'This model cannot hear audio',
      VoiceModelAvailability.unreadable => 'Re-import the projector file',
      VoiceModelAvailability.ready => null,
    };
  }
}
