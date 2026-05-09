import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../widgets/auth_frame.dart';
import '../widgets/form_fields.dart';
import '../widgets/social_buttons.dart';
import 'auth_errors.dart';
import 'auth_repository.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _loading = false;
  String? _message;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      await ref.read(authRepositoryProvider).signInWithEmail(
            email: _emailController.text,
            password: _passwordController.text,
          );
      if (mounted) context.go('/account');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _social(Future<void> Function() action) async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      await action();
      if (mounted) context.go('/account');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(authRepositoryProvider);

    return AuthFrame(
      title: '로그인',
      subtitle: 'MetaServer 계정으로 서비스와 알림을 이어서 사용할 수 있습니다.',
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '아직 계정이 없나요?',
            style:
                TextStyle(color: MetaServerColors.ink.withValues(alpha: 0.62)),
          ),
          TextButton(
            onPressed: _loading ? null : () => context.go('/sign-up'),
            child: const Text('회원가입'),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_message != null) ...[
              FormNotice(
                message: _message!,
                icon: Icons.info_outline,
                color: MetaServerColors.danger,
              ),
              const SizedBox(height: 14),
            ],
            AuthTextField(
              controller: _emailController,
              label: '이메일',
              icon: Icons.alternate_email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [
                AutofillHints.username,
                AutofillHints.email
              ],
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return '이메일을 입력해주세요.';
                if (!text.contains('@')) return '이메일 형식을 확인해주세요.';
                return null;
              },
            ),
            const SizedBox(height: 14),
            AuthTextField(
              controller: _passwordController,
              label: '비밀번호',
              icon: Icons.lock_outline,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _submit(),
              suffixIcon: IconButton(
                tooltip: _obscurePassword ? '비밀번호 보기' : '비밀번호 숨기기',
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(_obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
              ),
              validator: (value) {
                if ((value ?? '').isEmpty) return '비밀번호를 입력해주세요.';
                return null;
              },
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed:
                    _loading ? null : () => context.go('/forgot-password'),
                child: const Text('비밀번호 찾기'),
              ),
            ),
            const SizedBox(height: 10),
            LoadingButton(
              label: '로그인',
              icon: Icons.login,
              loading: _loading,
              onPressed: _submit,
            ),
            const SizedBox(height: 22),
            const DividerLabel(label: '또는'),
            const SizedBox(height: 18),
            SocialButton(
              label: 'Google로 계속하기',
              icon: Icons.g_mobiledata,
              loading: _loading,
              onPressed: () => _social(repo.signInWithGoogle),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: SocialButton(
                    label: 'Apple',
                    icon: Icons.apple,
                    loading: _loading,
                    onPressed: () => _social(repo.signInWithApple),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SocialButton(
                    label: 'Facebook',
                    icon: Icons.facebook,
                    loading: _loading,
                    onPressed: () => _social(repo.signInWithFacebook),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
