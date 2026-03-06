import 'package:flutter_base_app/core/network/api_result.dart';
import 'package:flutter_base_app/core/state/base_state.dart';
import 'package:flutter_base_app/features/login/data/login_api.dart';
import 'package:flutter_base_app/features/login/data/login_repository_impl.dart';
import 'package:flutter_base_app/features/login/domain/auth_response.dart';
import 'package:flutter_base_app/features/login/domain/login_repository.dart';
import 'package:flutter_base_app/shared/providers.dart';
import 'package:flutter_base_app/storage/secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'login_controller.g.dart';

@riverpod
class LoginController extends _$LoginController {
  @override
  UiState<AuthResponse?> build() => const UiInitial();

  Future<bool> login(String username, String password) async {
    state = const UiLoading();

    final apiClient = ref.read(apiClientProvider);
    final api = LoginApi(apiClient);
    final LoginRepository repository = LoginRepositoryImpl(api);

    final result = await repository.login(username, password);

    switch (result) {
      case ApiSuccess<AuthResponse>(:final data):
        await SecureStorage.instance.write(
          key: 'auth_data',
          value: data.toJson(),
        );
        state = UiSuccess(data);
        return true;
      case ApiFailure(:final message):
        state = UiError(message);
        return false;
      default:
        state = const UiError('Unexpected error');
        return false;
    }
  }
}
