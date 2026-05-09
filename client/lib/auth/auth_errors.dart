import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

String authErrorMessage(Object error) {
  if (error is DioException) {
    final detail =
        error.response?.data is Map ? error.response?.data['detail'] : null;
    if (detail is String && detail.isNotEmpty) return detail;
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout) {
      return '서버에 연결할 수 없습니다. 백엔드가 실행 중인지 확인해 주세요.';
    }
    return '서버와 통신하는 중 문제가 발생했습니다.';
  }

  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-email':
        return '이메일 형식을 확인해 주세요.';
      case 'user-disabled':
        return '정지된 계정입니다. 고객지원으로 문의해 주세요.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return '이메일 또는 비밀번호가 올바르지 않습니다.';
      case 'email-already-in-use':
        return '이미 가입된 이메일입니다.';
      case 'weak-password':
        return '비밀번호를 조금 더 강하게 설정해 주세요.';
      case 'requires-recent-login':
        return '보안을 위해 다시 로그인한 뒤 진행해 주세요.';
      case 'popup-closed-by-user':
        return '로그인 창이 닫혔습니다.';
      default:
        return error.message ?? '인증 처리 중 문제가 발생했습니다.';
    }
  }
  return error.toString().replaceFirst('Exception: ', '');
}
