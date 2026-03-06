import 'package:flutter_base_app/core/network/api_client.dart';
import 'package:flutter_base_app/core/network/dio_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  final dio = ref.read(dioProvider);
  return ApiClient(dio);
});
