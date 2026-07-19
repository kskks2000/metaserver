import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/api_client.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    auth: FirebaseAuth.instance,
    apiClient: ref.read(apiClientProvider),
  );
});

final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

class AuthRepository {
  AuthRepository({
    required FirebaseAuth auth,
    required ApiClient apiClient,
  })  : _auth = auth,
        _apiClient = apiClient;

  final FirebaseAuth _auth;
  final ApiClient _apiClient;

  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await syncSession();
  }

  Future<void> createAccount({
    required String name,
    required String email,
    required String password,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await credential.user?.updateDisplayName(name.trim());
    await credential.user?.sendEmailVerification();
    await credential.user?.reload();
    await syncSession(displayName: name.trim());
  }

  Future<void> signInWithGoogle() async {
    if (kIsWeb) {
      final provider = GoogleAuthProvider();
      provider.addScope('email');
      await _auth.signInWithPopup(provider);
    } else {
      final googleUser = await GoogleSignIn(scopes: ['email']).signIn();
      if (googleUser == null) {
        throw const AuthFlowException('로그인이 취소되었습니다.');
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await _auth.signInWithCredential(credential);
    }
    await syncSession();
  }

  Future<void> signInWithFacebook() async {
    if (!kIsWeb) {
      throw const AuthFlowException('모바일 Facebook 로그인은 SDK 설정 후 활성화됩니다.');
    }
    final provider = FacebookAuthProvider();
    provider.addScope('email');
    provider.setCustomParameters({'display': 'popup'});
    await _auth.signInWithPopup(provider);
    await syncSession();
  }

  Future<void> signInWithApple() async {
    final provider = OAuthProvider('apple.com');
    provider.addScope('email');
    provider.addScope('name');
    if (kIsWeb) {
      await _auth.signInWithPopup(provider);
    } else {
      await _auth.signInWithProvider(provider);
    }
    await syncSession();
  }

  Future<void> sendPasswordReset(String email) async {
    final normalized = email.trim();
    await _auth.sendPasswordResetEmail(email: normalized);
    try {
      await _apiClient.postJson(
        '/auth/password/reset-requested',
        data: {'email': normalized},
      );
    } catch (error) {
      if (!isRecoverableApiFailure(error)) rethrow;
    }
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      throw const AuthFlowException('다시 로그인한 뒤 진행해주세요.');
    }
    final credential = EmailAuthProvider.credential(
      email: email,
      password: currentPassword,
    );
    await user.reauthenticateWithCredential(credential);
    await user.updatePassword(newPassword);
    try {
      await _apiClient.postJson(
        '/auth/password/change-complete',
        data: {'provider': 'password'},
      );
    } catch (error) {
      if (!isRecoverableApiFailure(error)) rethrow;
    }
  }

  Future<void> syncSession({
    String? displayName,
    bool required = true,
  }) async {
    await _auth.currentUser?.getIdToken(true);
    try {
      await _apiClient.postJson(
        '/auth/session',
        data: {
          if (displayName != null) 'display_name': displayName,
          'device_platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        },
      );
    } catch (error) {
      if (required || !isRecoverableApiFailure(error)) rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      await _apiClient.postJson('/auth/logout');
    } finally {
      await _auth.signOut();
      if (!kIsWeb) {
        await GoogleSignIn().signOut();
      }
    }
  }
}

class AuthFlowException implements Exception {
  const AuthFlowException(this.message);

  final String message;

  @override
  String toString() => message;
}
