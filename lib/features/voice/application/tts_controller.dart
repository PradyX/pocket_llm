import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/settings/voice_settings_provider.dart';
import 'package:pocket_llm/features/voice/data/platform_tts_service.dart';
import 'package:pocket_llm/features/voice/domain/speech_voice.dart';

/// Whether this build can speak at all, injectable so tests can describe a
/// platform without a speech engine.
final speechSynthesisSupportedProvider = Provider<bool>(
  (ref) => isSpeechSynthesisSupported,
);

/// The engine that reads text aloud.
final speechSynthesisEngineProvider = Provider<SpeechSynthesisEngine>(
  (ref) => SttsSpeechEngine(),
);

/// What the voice screen shows about reading text aloud.
class TtsState {
  const TtsState({
    this.isSupported = false,
    this.isSpeaking = false,
    this.isLoadingVoices = false,
    this.voices = const [],
    this.selectedVoice,
    this.rate = defaultSpeechRate,
    this.statusText = '',
    this.noticeMessage,
    this.errorMessage,
  });

  /// False on platforms with no local speech engine (Linux today).
  final bool isSupported;

  final bool isSpeaking;
  final bool isLoadingVoices;

  /// Voices the device reported, sorted by language then name.
  final List<SpeechVoice> voices;

  /// Chosen voice, or null for the device default.
  final SpeechVoice? selectedVoice;

  /// Speaking rate as the platform wants it (0.5 is normal speed).
  final double rate;

  /// What is happening right now: listing voices, speaking, or nothing.
  final String statusText;

  /// A lasting note about this device, such as reporting no installed
  /// voices. Kept apart from [statusText], which an utterance rewrites.
  final String? noticeMessage;

  final String? errorMessage;

  bool get hasVoices => voices.isNotEmpty;

  /// `Samantha (en-US)` or the device default.
  String get voiceLabel => selectedVoice?.label ?? 'Device default voice';

  /// True when a voice was chosen that the device no longer reports. The
  /// choice is kept (the device may still speak with it) but the screen can
  /// say it is not in the installed list.
  bool get selectedVoiceIsMissing =>
      selectedVoice != null &&
      hasVoices &&
      !voices.any((voice) => voice == selectedVoice);

  TtsState copyWith({
    bool? isSupported,
    bool? isSpeaking,
    bool? isLoadingVoices,
    List<SpeechVoice>? voices,
    Object? selectedVoice = _unset,
    double? rate,
    String? statusText,
    Object? noticeMessage = _unset,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TtsState(
      isSupported: isSupported ?? this.isSupported,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      isLoadingVoices: isLoadingVoices ?? this.isLoadingVoices,
      voices: voices ?? this.voices,
      selectedVoice: selectedVoice == _unset
          ? this.selectedVoice
          : selectedVoice as SpeechVoice?,
      rate: rate ?? this.rate,
      statusText: statusText ?? this.statusText,
      noticeMessage: noticeMessage == _unset
          ? this.noticeMessage
          : noticeMessage as String?,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }

  static const _unset = Object();
}

final ttsControllerProvider = StateNotifierProvider<TtsController, TtsState>(
  (ref) => TtsController(ref),
);

/// Reads text aloud with the device's own speech engine.
///
/// The engine is the operating system's synthesizer, so this costs no model
/// download, works offline and sends nothing anywhere. The controller owns
/// only the choice of voice and rate plus what is happening right now;
/// long-form reading (assistant replies) is added on top of the same engine.
class TtsController extends StateNotifier<TtsState> {
  TtsController(this._ref) : super(const TtsState()) {
    final settings = _ref.read(voiceSettingsProvider);
    state = state.copyWith(
      isSupported: _ref.read(speechSynthesisSupportedProvider),
      // Already migrated out of the older rate semantics by the settings
      // provider; clamping here keeps a stored value in range as well.
      rate: clampSpeechRate(settings.ttsRate),
      selectedVoice: SpeechVoice.fromId(settings.ttsVoiceId),
    );
  }

  final Ref _ref;

  /// Counts utterances so a stopped one cannot report back over a newer one.
  int _utterance = 0;

  /// Reads the installed voice list, best effort.
  ///
  /// A platform that reports nothing can still speak with its default voice,
  /// so a failure here is reported as a limitation and never blocks the
  /// speaking path.
  Future<void> loadVoices() async {
    if (!state.isSupported || state.isLoadingVoices) return;

    state = state.copyWith(
      isLoadingVoices: true,
      statusText: 'Looking for installed voices...',
      clearError: true,
    );
    try {
      final voices = await _ref.read(speechSynthesisEngineProvider).voices();
      if (!mounted) return;
      state = state.copyWith(
        voices: voices,
        isLoadingVoices: false,
        statusText: '',
        noticeMessage: voices.isEmpty
            ? 'This device reported no installed voices, so its default voice '
                  'will be used.'
            : null,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        isLoadingVoices: false,
        statusText: '',
        noticeMessage: null,
        errorMessage:
            'The installed voices could not be listed, so the device default '
            'will be used: ${_messageOf(error)}',
      );
    }
  }

  /// Speaks [text] with the chosen voice and rate.
  Future<void> speak(String text) async {
    final prepared = text.trim();
    if (prepared.isEmpty || state.isSpeaking) return;

    if (!state.isSupported) {
      state = state.copyWith(
        errorMessage:
            'This platform has no local speech engine in Pocket LLM. Reading '
            'answers aloud works on Android, iOS, macOS and Windows.',
      );
      return;
    }

    final utterance = ++_utterance;
    state = state.copyWith(
      isSpeaking: true,
      statusText: 'Speaking...',
      clearError: true,
    );
    try {
      await _ref
          .read(speechSynthesisEngineProvider)
          .speak(text: prepared, rate: state.rate, voice: state.selectedVoice);
    } catch (error) {
      if (!mounted || utterance != _utterance) return;
      state = state.copyWith(
        errorMessage:
            'The device could not read this aloud: ${_messageOf(error)}',
      );
    } finally {
      if (mounted && utterance == _utterance) {
        state = state.copyWith(isSpeaking: false, statusText: '');
      }
    }
  }

  /// Stops the current utterance immediately.
  Future<void> stop() async {
    if (!state.isSpeaking) return;
    _utterance++;
    try {
      await _ref.read(speechSynthesisEngineProvider).stop();
    } catch (_) {
      // A platform that cannot stop is still reported as stopped, so the UI
      // never gets stuck showing an utterance that is over.
    }
    if (!mounted) return;
    state = state.copyWith(isSpeaking: false, statusText: '');
  }

  /// Moves the rate while the slider is being dragged; nothing is stored yet.
  void updateRate(double rate) {
    state = state.copyWith(rate: clampSpeechRate(rate));
  }

  /// Stores the rate after a drag or a tap, so dragging writes once.
  Future<void> storeRate() async {
    await _ref.read(voiceSettingsProvider.notifier).setTtsRate(state.rate);
  }

  /// Chooses the voice to speak with, or null for the device default.
  Future<void> selectVoice(SpeechVoice? voice) async {
    state = state.copyWith(selectedVoice: voice);
    await _ref.read(voiceSettingsProvider.notifier).setTtsVoiceId(voice?.id);
  }

  /// `Exception: something` reads badly in the UI, so the prefix is dropped.
  static String _messageOf(Object error) {
    const prefix = 'Exception: ';
    final text = error.toString();
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }
}
