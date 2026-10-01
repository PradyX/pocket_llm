import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/storage/secure_storage.dart';

/// Which GGUF models and voices the user chose for voice work.
///
/// Only the choices live here: model files remain owned by the model
/// selection store, platform voices belong to the operating system, and
/// nothing is downloaded by picking either of them.
class VoiceSettingsState {
  const VoiceSettingsState({
    this.sttModelId,
    this.ttsVoiceId,
    this.ttsRate,
    this.readRepliesAloud = false,
  });

  /// Model that transcribes local audio, or null when none is chosen.
  final String? sttModelId;

  /// Voice used for reading text aloud, as `name|locale`, or null for the
  /// device default. Stored as text so a voice that is no longer installed
  /// simply resolves to nothing instead of breaking the settings.
  final String? ttsVoiceId;

  /// Speaking rate, or null when the user never changed it.
  final double? ttsRate;

  /// Whether a finished reply is read out on its own. Off by default: speech
  /// is something the user turns on, never something the app decides to do.
  final bool readRepliesAloud;

  bool get hasSttModel => sttModelId != null && sttModelId!.trim().isNotEmpty;

  bool get hasCustomTtsVoice =>
      ttsVoiceId != null && ttsVoiceId!.trim().isNotEmpty;
  VoiceSettingsState copyWith({
    Object? sttModelId = _unset,
    Object? ttsVoiceId = _unset,
    Object? ttsRate = _unset,
    bool? readRepliesAloud,
  }) {
    return VoiceSettingsState(
      sttModelId: sttModelId == _unset
          ? this.sttModelId
          : sttModelId as String?,
      ttsVoiceId: ttsVoiceId == _unset
          ? this.ttsVoiceId
          : ttsVoiceId as String?,
      ttsRate: ttsRate == _unset ? this.ttsRate : ttsRate as double?,
      readRepliesAloud: readRepliesAloud ?? this.readRepliesAloud,
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
      final ttsVoiceId = data['ttsVoiceId'];
      final ttsRate = data['ttsRate'];
      final readRepliesAloud = data['readRepliesAloud'];
      state = state.copyWith(
        sttModelId: sttModelId is String && sttModelId.trim().isNotEmpty
            ? sttModelId
            : null,
        // Keys added after speech to text existed simply stay unset in a
        // document written by an older build.
        ttsVoiceId: ttsVoiceId is String && ttsVoiceId.trim().isNotEmpty
            ? ttsVoiceId
            : null,
        ttsRate: ttsRate is num ? ttsRate.toDouble() : null,
        readRepliesAloud: readRepliesAloud is bool
            ? readRepliesAloud
            : state.readRepliesAloud,
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

  /// Chooses the voice used to read text aloud, or null for the device one.
  Future<void> setTtsVoiceId(String? voiceId) async {
    final trimmed = voiceId?.trim();
    state = state.copyWith(
      ttsVoiceId: trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
    await _persist();
  }

  /// Stores the speaking rate exactly as given; the caller clamps it.
  Future<void> setTtsRate(double? rate) async {
    state = state.copyWith(ttsRate: rate);
    await _persist();
  }

  /// Turns automatic reading of finished replies on or off.
  Future<void> setReadRepliesAloud(bool value) async {
    state = state.copyWith(readRepliesAloud: value);
    await _persist();
  }

  Future<void> _persist() async {
    await SecureStorage.instance.write(
      key: _settingsKey,
      value: {
        'sttModelId': state.sttModelId,
        'ttsVoiceId': state.ttsVoiceId,
        'ttsRate': state.ttsRate,
        'readRepliesAloud': state.readRepliesAloud,
      },
    );
  }
}
