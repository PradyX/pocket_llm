import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/storage/secure_storage.dart';

class InferenceSettingsState {
  final bool adaptiveMode;

  const InferenceSettingsState({this.adaptiveMode = false});

  InferenceSettingsState copyWith({bool? adaptiveMode}) {
    return InferenceSettingsState(
      adaptiveMode: adaptiveMode ?? this.adaptiveMode,
    );
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
      final adaptiveMode = data?['adaptiveMode'];
      if (adaptiveMode is bool) {
        state = state.copyWith(adaptiveMode: adaptiveMode);
      }
    } catch (_) {
      // Keep defaults if storage read fails.
    }
  }

  Future<void> setAdaptiveMode(bool enabled) async {
    state = state.copyWith(adaptiveMode: enabled);
    await SecureStorage.instance.write(
      key: _settingsKey,
      value: {'adaptiveMode': enabled},
    );
  }
}
