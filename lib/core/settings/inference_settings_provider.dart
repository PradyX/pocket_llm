import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/storage/secure_storage.dart';

enum SamplingPreset { precise, balanced, creative }

class InferenceSampling {
  final double temperature;
  final double topP;

  const InferenceSampling({required this.temperature, required this.topP});
}

class InferenceSettingsState {
  final bool adaptiveMode;
  final SamplingPreset samplingPreset;
  final bool advancedSamplingOverride;
  final double customTemperature;
  final double customTopP;

  const InferenceSettingsState({
    this.adaptiveMode = false,
    this.samplingPreset = SamplingPreset.balanced,
    this.advancedSamplingOverride = false,
    this.customTemperature = 0.7,
    this.customTopP = 0.9,
  });

  InferenceSettingsState copyWith({
    bool? adaptiveMode,
    SamplingPreset? samplingPreset,
    bool? advancedSamplingOverride,
    double? customTemperature,
    double? customTopP,
  }) {
    return InferenceSettingsState(
      adaptiveMode: adaptiveMode ?? this.adaptiveMode,
      samplingPreset: samplingPreset ?? this.samplingPreset,
      advancedSamplingOverride:
          advancedSamplingOverride ?? this.advancedSamplingOverride,
      customTemperature: customTemperature ?? this.customTemperature,
      customTopP: customTopP ?? this.customTopP,
    );
  }

  InferenceSampling get resolvedSampling {
    if (advancedSamplingOverride) {
      return InferenceSampling(
        temperature: customTemperature,
        topP: customTopP,
      );
    }

    return switch (samplingPreset) {
      SamplingPreset.precise => const InferenceSampling(
        temperature: 0.2,
        topP: 0.8,
      ),
      SamplingPreset.balanced => const InferenceSampling(
        temperature: 0.7,
        topP: 0.9,
      ),
      SamplingPreset.creative => const InferenceSampling(
        temperature: 1.1,
        topP: 0.98,
      ),
    };
  }
}

final inferenceSettingsProvider =
    StateNotifierProvider<InferenceSettingsNotifier, InferenceSettingsState>(
      (ref) => InferenceSettingsNotifier(),
    );

class InferenceSettingsNotifier extends StateNotifier<InferenceSettingsState> {
  static const _settingsKey = 'inference_settings';

  InferenceSettingsNotifier() : super(const InferenceSettingsState()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final data = await SecureStorage.instance.read(_settingsKey);
      if (data == null) return;

      final adaptiveMode = data['adaptiveMode'];
      final presetRaw = data['samplingPreset'];
      final advancedSamplingOverride = data['advancedSamplingOverride'];
      final customTemperature = data['customTemperature'];
      final customTopP = data['customTopP'];

      state = state.copyWith(
        adaptiveMode: adaptiveMode is bool ? adaptiveMode : null,
        samplingPreset: _parsePreset(presetRaw),
        advancedSamplingOverride: advancedSamplingOverride is bool
            ? advancedSamplingOverride
            : null,
        customTemperature: customTemperature is num
            ? customTemperature.toDouble().clamp(0.0, 2.0)
            : null,
        customTopP: customTopP is num
            ? customTopP.toDouble().clamp(0.1, 1.0)
            : null,
      );
    } catch (_) {
      // Keep defaults if storage read fails.
    }
  }

  Future<void> setAdaptiveMode(bool enabled) async {
    state = state.copyWith(adaptiveMode: enabled);
    await _persist();
  }

  Future<void> setSamplingPreset(SamplingPreset preset) async {
    state = state.copyWith(samplingPreset: preset);
    await _persist();
  }

  Future<void> setAdvancedSamplingOverride(bool enabled) async {
    state = state.copyWith(advancedSamplingOverride: enabled);
    await _persist();
  }

  Future<void> setCustomTemperature(double value) async {
    state = state.copyWith(customTemperature: value.clamp(0.0, 2.0));
    await _persist();
  }

  Future<void> setCustomTopP(double value) async {
    state = state.copyWith(customTopP: value.clamp(0.1, 1.0));
    await _persist();
  }

  Future<void> _persist() async {
    await SecureStorage.instance.write(
      key: _settingsKey,
      value: {
        'adaptiveMode': state.adaptiveMode,
        'samplingPreset': state.samplingPreset.name,
        'advancedSamplingOverride': state.advancedSamplingOverride,
        'customTemperature': state.customTemperature,
        'customTopP': state.customTopP,
      },
    );
  }

  SamplingPreset _parsePreset(Object? raw) {
    if (raw is! String) return state.samplingPreset;
    for (final preset in SamplingPreset.values) {
      if (preset.name == raw) return preset;
    }
    return state.samplingPreset;
  }
}
