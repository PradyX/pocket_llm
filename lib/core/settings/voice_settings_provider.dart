import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/storage/secure_storage.dart';

/// Which GGUF models the user chose for voice work.
///
/// Only the choice lives here: model files remain owned by the model
/// selection store, and nothing is downloaded by picking a model.
class VoiceSettingsState {
  const VoiceSettingsState({this.sttModelId});

  /// Model that transcribes local audio, or null when none is chosen.
  final String? sttModelId;

  bool get hasSttModel => sttModelId != null && sttModelId!.trim().isNotEmpty;

  VoiceSettingsState copyWith({Object? sttModelId = _unset}) {
    return VoiceSettingsState(
      sttModelId: sttModelId == _unset
          ? this.sttModelId
          : sttModelId as String?,
    );
  }

  static const _unset = Object();
}

final voiceSettingsProvider =
    StateNotifierProvider<VoiceSettingsNotifier, VoiceSettingsState>(
      (ref) => VoiceSettingsNotifier(),
    );

class VoiceSettingsNotifier extends StateNotifier<VoiceSettingsState> {
  static const _settingsKey = 'voice_settings';

  VoiceSettingsNotifier() : super(const VoiceSettingsState()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final data = await SecureStorage.instance.read(_settingsKey);
      if (data == null) return;

      final sttModelId = data['sttModelId'];
      state = state.copyWith(
        sttModelId: sttModelId is String && sttModelId.trim().isNotEmpty
            ? sttModelId
            : null,
      );
    } catch (_) {
      // Keep defaults if storage read fails.
    }
  }

  /// Chooses the transcription model, or clears the choice with null.
  Future<void> setSttModel(String? modelId) async {
    final trimmed = modelId?.trim();
    state = state.copyWith(
      sttModelId: trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
    await _persist();
  }

  Future<void> _persist() async {
    await SecureStorage.instance.write(
      key: _settingsKey,
      value: {'sttModelId': state.sttModelId},
    );
  }
}
