import 'package:flutter_base_app/core/network/api_result.dart';
import 'package:flutter_base_app/core/state/base_state.dart';
import 'package:flutter_base_app/features/sign_up/data/signup_api.dart';
import 'package:flutter_base_app/features/sign_up/data/signup_repository_impl.dart';
import 'package:flutter_base_app/features/sign_up/domain/signup_repository.dart';
import 'package:flutter_base_app/shared/providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'signup_controller.g.dart';

@riverpod
class SignUpController extends _$SignUpController {
  @override
  UiState<void> build() => const UiInitial();

  Future<bool> signUp({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
    required String password,
  }) async {
    state = const UiLoading();

    final apiClient = ref.read(apiClientProvider);
    final api = SignUpApi(apiClient);
    final SignUpRepository repository = SignUpRepositoryImpl(api);

    final result = await repository.signUp(
      firstName: firstName,
      lastName: lastName,
      email: email,
      username: username,
      password: password,
    );

    switch (result) {
      case ApiSuccess():
        state = const UiSuccess(null);
        return true;
      case ApiFailure(:final message):
        state = UiError(message);
        return false;
    }
  }
}
