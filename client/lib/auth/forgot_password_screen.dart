import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../widgets/auth_frame.dart';
import '../widgets/form_fields.dart';
import 'auth_errors.dart';
import 'auth_repository.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _sent = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _sent = false;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .sendPasswordReset(_emailController.text);
      if (!mounted) return;
      setState(() => _sent = true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthFrame(
      title: '비밀번호 찾기',
      subtitle: '가입한 이메일로 재설정 링크를 보냅니다.',
      footer: Center(
        child: TextButton.icon(
          onPressed: _loading ? null : () => context.go('/sign-in'),
          icon: const Icon(Icons.arrow_back),
          label: const Text('로그인으로 돌아가기'),
        ),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              FormNotice(
                message: _error!,
                icon: Icons.info_outline,
                color: MetaServerColors.danger,
              ),
              const SizedBox(height: 14),
            ],
            if (_sent) ...[
              const FormNotice(
                message: '재설정 메일을 보냈습니다. 메일함에서 링크를 확인해주세요.',
                icon: Icons.mark_email_read_outlined,
                color: MetaServerColors.green,
              ),
              const SizedBox(height: 14),
            ],
            AuthTextField(
              controller: _emailController,
              label: '이메일',
              icon: Icons.alternate_email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.email],
              onSubmitted: (_) => _submit(),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return '이메일을 입력해주세요.';
                if (!text.contains('@')) return '이메일 형식을 확인해주세요.';
                return null;
              },
            ),
            const SizedBox(height: 18),
            LoadingButton(
              label: '재설정 링크 보내기',
              icon: Icons.outgoing_mail,
              loading: _loading,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
