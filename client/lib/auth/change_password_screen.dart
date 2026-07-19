import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../widgets/auth_frame.dart';
import '../widgets/form_fields.dart';
import 'auth_errors.dart';
import 'auth_repository.dart';

class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _loading = false;
  String? _message;
  bool _success = false;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _message = null;
      _success = false;
    });
    try {
      await ref.read(authRepositoryProvider).changePassword(
            currentPassword: _currentController.text,
            newPassword: _newController.text,
          );
      if (!mounted) return;
      setState(() {
        _success = true;
        _message = '비밀번호가 변경되었습니다.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _success = false;
        _message = authErrorMessage(error);
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthFrame(
      title: '비밀번호 변경',
      subtitle: '계정 보호를 위해 현재 비밀번호를 한 번 더 확인합니다.',
      footer: Center(
        child: TextButton.icon(
          onPressed: _loading ? null : () => context.go('/account'),
          icon: const Icon(Icons.arrow_back),
          label: const Text('계정으로 돌아가기'),
        ),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_message != null) ...[
              FormNotice(
                message: _message!,
                icon:
                    _success ? Icons.check_circle_outline : Icons.info_outline,
                color:
                    _success ? MetaServerColors.green : MetaServerColors.danger,
              ),
              const SizedBox(height: 14),
            ],
            AuthTextField(
              controller: _currentController,
              label: '현재 비밀번호',
              icon: Icons.lock_clock_outlined,
              obscureText: true,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.password],
              validator: (value) {
                if ((value ?? '').isEmpty) return '현재 비밀번호를 입력해주세요.';
                return null;
              },
            ),
            const SizedBox(height: 14),
            AuthTextField(
              controller: _newController,
              label: '새 비밀번호',
              icon: Icons.lock_reset,
              obscureText: true,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.newPassword],
              validator: (value) {
                if ((value ?? '').length < 8) return '새 비밀번호는 8자 이상이어야 합니다.';
                if (value == _currentController.text) {
                  return '기존 비밀번호와 다른 값을 사용해주세요.';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            AuthTextField(
              controller: _confirmController,
              label: '새 비밀번호 확인',
              icon: Icons.verified_user_outlined,
              obscureText: true,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _submit(),
              validator: (value) {
                if (value != _newController.text) return '새 비밀번호가 일치하지 않습니다.';
                return null;
              },
            ),
            const SizedBox(height: 18),
            LoadingButton(
              label: '비밀번호 변경',
              icon: Icons.security,
              loading: _loading,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
