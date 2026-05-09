import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../widgets/auth_frame.dart';
import '../widgets/form_fields.dart';
import '../widgets/social_buttons.dart';
import 'auth_errors.dart';
import 'auth_repository.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _agree = false;
  bool _obscure = true;
  bool _loading = false;
  String? _message;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || !_agree) {
      if (!_agree) {
        setState(() => _message = '필수 약관 동의가 필요합니다.');
      }
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      await ref.read(authRepositoryProvider).createAccount(
            name: _nameController.text,
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

  int get _passwordScore {
    final value = _passwordController.text;
    var score = 0;
    if (value.length >= 8) score++;
    if (RegExp(r'[A-Z]').hasMatch(value)) score++;
    if (RegExp(r'[0-9]').hasMatch(value)) score++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(value)) score++;
    return score;
  }

  @override
  Widget build(BuildContext context) {
    return AuthFrame(
      title: '회원가입',
      subtitle: '기본 정보만 입력하면 MetaServer 계정이 생성됩니다.',
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '이미 계정이 있나요?',
            style:
                TextStyle(color: MetaServerColors.ink.withValues(alpha: 0.62)),
          ),
          TextButton(
            onPressed: _loading ? null : () => context.go('/sign-in'),
            child: const Text('로그인'),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        onChanged: () => setState(() {}),
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
              controller: _nameController,
              label: '이름',
              icon: Icons.badge_outlined,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.name],
              validator: (value) {
                if ((value ?? '').trim().length < 2) return '이름을 2자 이상 입력해주세요.';
                return null;
              },
            ),
            const SizedBox(height: 14),
            AuthTextField(
              controller: _emailController,
              label: '이메일',
              icon: Icons.alternate_email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
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
              obscureText: _obscure,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.newPassword],
              suffixIcon: IconButton(
                tooltip: _obscure ? '비밀번호 보기' : '비밀번호 숨기기',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(_obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
              ),
              validator: (value) {
                final text = value ?? '';
                if (text.length < 8) return '비밀번호는 8자 이상이어야 합니다.';
                return null;
              },
            ),
            const SizedBox(height: 10),
            _PasswordMeter(score: _passwordScore),
            const SizedBox(height: 14),
            AuthTextField(
              controller: _confirmController,
              label: '비밀번호 확인',
              icon: Icons.verified_user_outlined,
              obscureText: true,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _submit(),
              validator: (value) {
                if (value != _passwordController.text) {
                  return '비밀번호가 일치하지 않습니다.';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              value: _agree,
              onChanged: _loading
                  ? null
                  : (value) => setState(() => _agree = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('필수 약관과 개인정보 처리방침에 동의합니다.'),
            ),
            const SizedBox(height: 12),
            LoadingButton(
              label: '계정 만들기',
              icon: Icons.person_add_alt_1,
              loading: _loading,
              onPressed: _submit,
            ),
            const SizedBox(height: 22),
            const DividerLabel(label: '빠른 시작'),
            const SizedBox(height: 18),
            SocialButton(
              label: 'Google로 가입하기',
              icon: Icons.g_mobiledata,
              loading: _loading,
              onPressed: () async {
                setState(() => _loading = true);
                try {
                  await ref.read(authRepositoryProvider).signInWithGoogle();
                  if (!context.mounted) return;
                  context.go('/account');
                } catch (error) {
                  if (mounted) {
                    setState(() => _message = authErrorMessage(error));
                  }
                } finally {
                  if (mounted) setState(() => _loading = false);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PasswordMeter extends StatelessWidget {
  const _PasswordMeter({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    final color = switch (score) {
      >= 4 => MetaServerColors.green,
      3 => MetaServerColors.cyan,
      2 => MetaServerColors.amber,
      _ => MetaServerColors.danger,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: score / 4,
            minHeight: 6,
            backgroundColor: MetaServerColors.line,
            color: color,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '8자 이상, 숫자와 특수문자를 함께 사용하면 더 안전합니다.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: MetaServerColors.ink.withValues(alpha: 0.58),
              ),
        ),
      ],
    );
  }
}
