import 'package:flutter/material.dart';
import 'package:flutter_base_app/storage/secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'theme_provider.g.dart';

@riverpod
class ThemeModeNotifier extends _$ThemeModeNotifier {
  static const _themeKey = 'app_theme_mode';

  @override
  ThemeMode build() {
    _loadTheme();
    return ThemeMode.system;
  }

  Future<void> _loadTheme() async {
    try {
      final data = await SecureStorage.instance.read(_themeKey);
      if (data != null && data['mode'] != null) {
        final savedMode = data['mode'] as String;
        state = ThemeMode.values.firstWhere(
          (e) => e.name == savedMode,
          orElse: () => ThemeMode.system,
        );
      }
    } catch (_) {
      // Fallback to system if read fails
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await SecureStorage.instance.write(
      key: _themeKey,
      value: {'mode': mode.name},
    );
  }
}
