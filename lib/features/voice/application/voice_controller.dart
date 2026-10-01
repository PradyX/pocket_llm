import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/services/service_providers.dart';
import 'package:pocket_llm/core/settings/voice_settings_provider.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';
import 'package:pocket_llm/features/voice/data/voice_model_inspector.dart';
import 'package:pocket_llm/features/voice/domain/voice_model_option.dart';

/// Reads projector metadata so the catalog knows which models can hear audio.
final voiceModelInspectorProvider = Provider<VoiceModelInspector>((ref) {
  final storage = ref.watch(modelStorageServiceProvider);
  return VoiceModelInspector(
    projectorPathResolver: (model) => storage.resolveMmprojPath(model),
  );
});

/// What the voice screens show about available speech models.
class VoiceState {
  const VoiceState({
    this.options = const [],
    this.selectedModelId,
    this.isInspecting = false,
    this.errorMessage,
  });

  static const _unset = Object();

  /// Candidate models, ready ones first.
  final List<VoiceModelOption> options;

  /// Model the user chose for speech, or null.
  final String? selectedModelId;

  /// True while projector metadata is being read.
  final bool isInspecting;

  final String? errorMessage;

  List<VoiceModelOption> get readyOptions => [
    for (final option in options)
      if (option.isReady) option,
  ];

  List<VoiceModelOption> get unavailableOptions => [
    for (final option in options)
      if (!option.isReady) option,
  ];

  /// The chosen model, when it is still part of the catalog.
  VoiceModelOption? get selectedOption {
    for (final option in options) {
      if (option.model.id == selectedModelId) return option;
    }
    return null;
  }

  bool get hasReadyModel => readyOptions.isNotEmpty;

  /// True when the chosen model is installed and can hear audio. A model that
  /// was removed or replaced leaves the stored choice in place but unused.
  bool get isSelectionReady => selectedOption?.isReady ?? false;

  VoiceState copyWith({
    List<VoiceModelOption>? options,
    Object? selectedModelId = _unset,
    bool? isInspecting,
    String? errorMessage,
    bool clearError = false,
  }) {
    return VoiceState(
      options: options ?? this.options,
      selectedModelId: selectedModelId == _unset
          ? this.selectedModelId
          : selectedModelId as String?,
      isInspecting: isInspecting ?? this.isInspecting,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

final voiceControllerProvider =
    StateNotifierProvider<VoiceController, VoiceState>(
      (ref) => VoiceController(ref),
    );

/// Owns the local-speech model catalog and which model the user chose.
///
/// The catalog is read-only with respect to model files: it inspects what is
/// installed and never downloads, moves or deletes anything. Only models that
/// come with (or promise) a multimodal projector are listed, because the
/// projector is what turns audio into tokens — a text-only model can never
/// transcribe, so listing it would only add noise.
///
/// Audio itself never leaves the device: choosing a model here only records a
/// preference, and the transcription path keeps the audio local.
class VoiceController extends StateNotifier<VoiceState> {
  VoiceController(this._ref) : super(const VoiceState()) {
    state = state.copyWith(
      selectedModelId: _ref.read(voiceSettingsProvider).sttModelId,
    );
  }

  final Ref _ref;

  /// True when [model] could serve as a speech model at all.
  static bool isVoiceCandidate(LlmModel model) {
    return _hasText(model.mmprojLocalFileName) ||
        _hasText(model.externalMmprojPath) ||
        _hasText(model.mmprojDownloadUrl) ||
        model.supportsAudio;
  }

  /// Rebuilds the catalog from the installed models.
  ///
  /// Safe to call when a screen opens: results are cached per projector file,
  /// so only the first pass reads GGUF metadata.
  Future<void> refresh() async {
    if (state.isInspecting) return;

    final models = _ref.read(modelSelectionControllerProvider).models;
    final candidates = [
      for (final model in models)
        if (isVoiceCandidate(model)) model,
    ];
    state = state.copyWith(isInspecting: true, clearError: true);

    final inspector = _ref.read(voiceModelInspectorProvider);
    final options = <VoiceModelOption>[];
    for (final model in candidates) {
      if (!model.isDownloaded) {
        options.add(
          VoiceModelOption(
            model: model,
            availability: VoiceModelAvailability.notDownloaded,
          ),
        );
        continue;
      }

      final info = await inspector.inspect(model);
      options.add(
        VoiceModelOption(
          model: model,
          availability: info.availability,
          projectorType: info.projectorType,
        ),
      );
    }

    options.sort((a, b) {
      if (a.isReady != b.isReady) return a.isReady ? -1 : 1;
      return a.model.name.toLowerCase().compareTo(b.model.name.toLowerCase());
    });

    if (!mounted) return;
    state = state.copyWith(options: options, isInspecting: false);
  }

  /// Chooses the model that transcribes speech, or clears the choice.
  Future<void> select(String? modelId) async {
    await _ref.read(voiceSettingsProvider.notifier).setSttModel(modelId);
    if (!mounted) return;
    state = state.copyWith(
      selectedModelId: modelId == null || modelId.trim().isEmpty
          ? null
          : modelId,
    );
  }

  static bool _hasText(String? value) =>
      value != null && value.trim().isNotEmpty;
}
