import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      // Load Base URL from .env, fallback to dummyjson if not set
      baseUrl: dotenv.env['API_BASE_URL'] ?? 'https://dummyjson.com/auth',
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  // 1. Pretty Logger Interceptor
  dio.interceptors.add(
    PrettyDioLogger(
      requestHeader: true,
      requestBody: true,
      responseBody: true,
      responseHeader: false,
      error: true,
      compact: true,
      maxWidth: 90,
    ),
  );

  // 2. Auth / Refresh Token Interceptor
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        // TODO: Get token from Secure Storage and inject here
        // final token = await secureStorage.read('token');
        // if (token != null) options.headers['Authorization'] = 'Bearer $token';
        return handler.next(options);
      },
      onError: (DioException error, handler) async {
        if (error.response?.statusCode == 401) {
          // TODO: Handle Token Refresh Logic Here
          // 1. Lock Dio
          // 2. Refresh Token via separate Dio instance
          // 3. Save new token
          // 4. Retry failed request
          // 5. Unlock Dio if successful, otherwise logout user
        }
        return handler.next(error);
      },
    ),
  );

  return dio;
});
