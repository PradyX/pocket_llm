import 'package:flutter_base_app/core/network/api_result.dart';

/// Abstract repository for sign-up operations.
abstract class SignUpRepository {
  Future<ApiResult<void>> signUp({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
    required String password,
  });
}
