import 'package:flutter_base_app/core/network/api_result.dart';
import 'package:flutter_base_app/features/sign_up/data/signup_api.dart';
import 'package:flutter_base_app/features/sign_up/domain/signup_repository.dart';

class SignUpRepositoryImpl implements SignUpRepository {
  final SignUpApi api;

  SignUpRepositoryImpl(this.api);

  @override
  Future<ApiResult<void>> signUp({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
    required String password,
  }) {
    return api.signUp(
      firstName: firstName,
      lastName: lastName,
      email: email,
      username: username,
      password: password,
    );
  }
}
