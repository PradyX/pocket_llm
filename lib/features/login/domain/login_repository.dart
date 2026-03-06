import 'package:flutter_base_app/core/network/api_result.dart';

abstract class LoginRepository {
  Future<ApiResult<void>> login(String email, String password);
}
