import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  const configuredBaseUrl = String.fromEnvironment('API_BASE_URL');
  final baseUrl =
      configuredBaseUrl.isNotEmpty ? configuredBaseUrl : defaultApiBaseUrl;
  return ApiClient(
    auth: FirebaseAuth.instance,
    baseUrl: _normalizeBaseUrl(baseUrl),
  );
});

String get defaultApiBaseUrl {
  if (kIsWeb) {
    final host = Uri.base.host;
    if (host == 'localhost' || host == '127.0.0.1') {
      return 'http://localhost:8000/api/v1';
    }
    // Use the current host's proxy path so apex/www deployments never cross CORS.
    return '/bridge/v1';
  }

  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'http://10.0.2.2:8000/api/v1',
    _ => 'http://localhost:8000/api/v1',
  };
}

String _normalizeBaseUrl(String baseUrl) {
  return baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
}

String _normalizePath(String path) {
  return path.replaceFirst(RegExp(r'^/+'), '');
}

bool isRecoverableApiFailure(Object error) {
  return error is DioException;
}

String? apiFailureMessage(Object error) {
  if (error is! DioException) return null;
  if (error.type == DioExceptionType.connectionError) {
    return '서버에 연결하지 못했습니다. 네트워크 또는 도메인 연결 설정을 확인해 주세요.';
  }
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout) {
    return '서버 응답이 지연되고 있습니다. 잠시 후 다시 시도해 주세요.';
  }
  final data = error.response?.data;
  if (data is Map) {
    final detail = data['detail'];
    if (detail is Map) {
      final message = detail['message'] ?? detail['msg1'];
      final code = detail['error_code'] ?? detail['msg_cd'];
      if (message != null && message.toString().isNotEmpty) {
        return code == null
            ? message.toString()
            : '${message.toString()} ($code)';
      }
    }
    if (detail is String && detail.isNotEmpty) {
      if (detail == 'Invalid or expired Firebase token.') {
        return '로그인 세션이 만료되었습니다. 다시 로그인한 뒤 진행해주세요.';
      }
      return detail;
    }
    final message = data['message'] ?? data['msg1'];
    if (message != null && message.toString().isNotEmpty) {
      return message.toString();
    }
  }
  final message = error.message;
  return message == null || message.isEmpty ? null : message;
}

class ApiClient {
  ApiClient({
    required FirebaseAuth auth,
    required String baseUrl,
  })  : _auth = auth,
        _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 20),
            headers: {'Content-Type': 'application/json'},
          ),
        ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _auth.currentUser?.getIdToken();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          final shouldRetry = error.response?.statusCode == 401 &&
              error.requestOptions.extra['auth_retry'] != true;
          final user = _auth.currentUser;
          if (shouldRetry && user != null) {
            try {
              final freshToken = await user.getIdToken(true);
              if (freshToken != null) {
                final options = error.requestOptions;
                options.extra['auth_retry'] = true;
                options.headers['Authorization'] = 'Bearer $freshToken';
                final response = await _dio.fetch<dynamic>(options);
                handler.resolve(response);
                return;
              }
            } catch (_) {
              // Keep the Firebase session intact; the UI will surface the API error.
            }
          }
          handler.next(error);
        },
      ),
    );
  }

  final FirebaseAuth _auth;
  final Dio _dio;

  Future<Map<String, dynamic>> postJson(
    String path, {
    Map<String, dynamic>? data,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      _normalizePath(path),
      data: data,
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final response = await _dio.get<Map<String, dynamic>>(
      _normalizePath(path),
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> patchJson(
    String path, {
    Map<String, dynamic>? data,
  }) async {
    final response = await _dio.patch<Map<String, dynamic>>(
      _normalizePath(path),
      data: data,
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> putJson(
    String path, {
    Map<String, dynamic>? data,
  }) async {
    final response = await _dio.put<Map<String, dynamic>>(
      _normalizePath(path),
      data: data,
    );
    return response.data ?? <String, dynamic>{};
  }
}
