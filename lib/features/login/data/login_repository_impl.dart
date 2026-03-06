import 'package:flutter_base_app/core/network/api_result.dart';
import 'package:flutter_base_app/features/login/data/login_api.dart';
import 'package:flutter_base_app/features/login/domain/login_repository.dart';

class LoginRepositoryImpl implements LoginRepository {
  final LoginApi api;

  LoginRepositoryImpl(this.api);

  @override
  Future<ApiResult<void>> login(String email, String password) {
    return api.login(email, password);
  }
}
