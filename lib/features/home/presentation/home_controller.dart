import 'package:flutter_base_app/core/state/base_state.dart';
import 'package:flutter_base_app/features/login/domain/auth_response.dart';
import 'package:flutter_base_app/storage/secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'home_controller.g.dart';

@riverpod
class HomeController extends _$HomeController {
  @override
  UiState<AuthResponse?> build() {
    _loadUser();
    return const UiLoading();
  }

  Future<void> _loadUser() async {
    try {
      final data = await SecureStorage.instance.read('auth_data');
      if (data != null) {
        final user = AuthResponse.fromJson(data);
        state = UiSuccess(user);
      } else {
        state = const UiSuccess(null);
      }
    } catch (e) {
      state = UiError(e.toString());
    }
  }

  Future<void> logout() async {
    await SecureStorage.instance.delete('auth_data');
    state = const UiSuccess(null);
  }
}
