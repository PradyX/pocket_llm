import 'package:dio/dio.dart';
import 'package:pocket_llm/core/network/api_result.dart';

class ApiClient {
  final Dio dio;

  ApiClient(this.dio);

  Future<ApiResult<T>> safeCall<T>(Future<T> Function() request) async {
    try {
      final response = await request();
      return ApiSuccess(response);
    } on DioException catch (e) {
      final data = e.response?.data;
      final message = data is Map && data['message'] != null
          ? data['message'].toString()
          : 'Something went wrong';

      return ApiFailure(message);
    } catch (_) {
      return const ApiFailure('Unexpected error occurred');
    }
  }
}
