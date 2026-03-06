import 'package:flutter_base_app/core/network/api_client.dart';
import 'package:flutter_base_app/core/network/api_result.dart';
import 'package:flutter_base_app/features/login/domain/auth_response.dart';

class LoginApi {
  final ApiClient client;

  LoginApi(this.client);

  Future<ApiResult<AuthResponse>> login(String username, String password) {
    return client.safeCall(() async {
      final response = await client.dio.post(
        '/auth/login',
        data: {'username': username, 'password': password},
      );

      return AuthResponse.fromJson(response.data);
    });
  }
}
