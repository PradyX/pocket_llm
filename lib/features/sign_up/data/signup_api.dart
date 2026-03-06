import 'package:flutter_base_app/core/network/api_client.dart';
import 'package:flutter_base_app/core/network/api_result.dart';

class SignUpApi {
  final ApiClient client;

  SignUpApi(this.client);

  Future<ApiResult<void>> signUp({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
    required String password,
  }) {
    return client.safeCall(() async {
      // Note: dummyjson.com doesn't have a real signup endpoint,
      // so we simulate by using the /users/add endpoint
      await client.dio.post(
        '/users/add',
        data: {
          'firstName': firstName,
          'lastName': lastName,
          'email': email,
          'username': username,
          'password': password,
        },
      );
    });
  }
}
