import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';
import '../auth/auth_errors.dart';
import '../auth/auth_repository.dart';
import '../core/api_client.dart';
import '../widgets/brand_mark.dart';
import '../widgets/form_fields.dart';

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  late Future<Map<String, dynamic>> _profileFuture;
  String? _message;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _profileFuture = _loadProfile();
  }

  Future<Map<String, dynamic>> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    try {
      await ref.read(authRepositoryProvider).syncSession(required: false);
      return await ref.read(apiClientProvider).getJson('/auth/me');
    } catch (error) {
      if (isRecoverableApiFailure(error)) {
        return _profileFromFirebase(user);
      }
      rethrow;
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _syncing = true;
      _message = null;
    });
    try {
      final future = _loadProfile();
      setState(() => _profileFuture = future);
      await future;
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _sendVerification() async {
    setState(() => _message = null);
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      if (!mounted) return;
      setState(() => _message = '인증 메일을 보냈습니다.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = authErrorMessage(error));
    }
  }

  Future<void> _signOut() async {
    await ref.read(authRepositoryProvider).signOut();
    if (mounted) context.go('/sign-in');
  }

  void _goBack() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
      return;
    }
    context.go('/trading');
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: MetaServerColors.canvas,
      appBar: AppBar(
        toolbarHeight: 70,
        backgroundColor: MetaServerColors.canvas,
        surfaceTintColor: Colors.transparent,
        leadingWidth: 60,
        leading: Padding(
          padding: const EdgeInsets.only(left: 14),
          child: IconButton(
            tooltip: '뒤로가기',
            onPressed: _goBack,
            icon: const Icon(Icons.arrow_back_rounded),
            style: IconButton.styleFrom(
              fixedSize: const Size(44, 44),
              backgroundColor: Colors.white,
              foregroundColor: MetaServerColors.ink,
              side: const BorderSide(color: MetaServerColors.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        title: const BrandMark(size: 40),
        centerTitle: false,
        actions: [
          _ToolbarIconButton(
            tooltip: '새로고침',
            onPressed: _syncing ? null : _refresh,
            icon: Icons.refresh_rounded,
          ),
          const SizedBox(width: 8),
          _ToolbarIconButton(
            tooltip: '로그아웃',
            onPressed: _signOut,
            icon: Icons.logout_rounded,
          ),
          const SizedBox(width: 14),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<Map<String, dynamic>>(
          future: _profileFuture,
          builder: (context, snapshot) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_message != null) ...[
                        FormNotice(
                          message: _message!,
                          icon: Icons.info_outline,
                          color: _message!.contains('보냈')
                              ? MetaServerColors.green
                              : MetaServerColors.danger,
                        ),
                        const SizedBox(height: 16),
                      ],
                      _Header(user: user),
                      const SizedBox(height: 18),
                      if (snapshot.connectionState == ConnectionState.waiting)
                        const LinearProgressIndicator(minHeight: 3)
                      else if (snapshot.hasError)
                        FormNotice(
                          message: authErrorMessage(snapshot.error!),
                          icon: Icons.cloud_off_outlined,
                          color: MetaServerColors.danger,
                        )
                      else
                        _AccountGrid(
                          firebaseUser: user,
                          profile: snapshot.data ?? const {},
                          onChangePassword: () =>
                              context.go('/change-password'),
                          onVerifyEmail: _sendVerification,
                          onRefresh: _refresh,
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

Map<String, dynamic> _profileFromFirebase(User? user) {
  final displayName = user?.displayName;
  final email = user?.email;
  final provider = user?.providerData.isNotEmpty == true
      ? user!.providerData.first.providerId
      : 'firebase';

  return {
    'id': user?.uid ?? 'firebase-local',
    'user_no': null,
    'firebase_uid': user?.uid ?? '',
    'login_id': email,
    'email': email,
    'email_verified': user?.emailVerified ?? false,
    'display_name': displayName,
    'user_name': displayName ?? email ?? 'MetaServer Member',
    'photo_url': user?.photoURL,
    'user_type': 'member',
    'auth_provider': provider,
    'mfa_enabled': false,
    'locked_at': null,
    'is_active': true,
    'status': 'active',
    'last_login_at': null,
  };
}

class _Header extends StatelessWidget {
  const _Header({required this.user});

  final User? user;

  @override
  Widget build(BuildContext context) {
    final photoUrl = user?.photoURL;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: MetaServerColors.ink,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: MetaServerColors.ink.withValues(alpha: 0.16),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: MetaServerColors.cyan,
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
              boxShadow: [
                BoxShadow(
                  color: MetaServerColors.cyan.withValues(alpha: 0.3),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipOval(
              child: photoUrl != null
                  ? Image.network(
                      photoUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _AvatarFallback(user: user),
                    )
                  : _AvatarFallback(user: user),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user?.displayName ?? 'MetaServer Member',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  user?.email ?? '이메일 정보 없음',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.74),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    const _StatusPill(
                      icon: Icons.verified_user_outlined,
                      label: '활성 계정',
                      color: MetaServerColors.green,
                    ),
                    _StatusPill(
                      icon: user?.emailVerified == true
                          ? Icons.mark_email_read_outlined
                          : Icons.mark_email_unread_outlined,
                      label: user?.emailVerified == true ? '이메일 인증됨' : '인증 필요',
                      color: user?.emailVerified == true
                          ? MetaServerColors.green
                          : MetaServerColors.amber,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.user});

  final User? user;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        _initialFor(user),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 30,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

String _initialFor(User? user) {
  final value = user?.displayName ?? user?.email ?? 'M';
  if (value.isEmpty) return 'M';
  return String.fromCharCode(value.runes.first).toUpperCase();
}

class _AccountGrid extends StatelessWidget {
  const _AccountGrid({
    required this.firebaseUser,
    required this.profile,
    required this.onChangePassword,
    required this.onVerifyEmail,
    required this.onRefresh,
  });

  final User? firebaseUser;
  final Map<String, dynamic> profile;
  final VoidCallback onChangePassword;
  final VoidCallback onVerifyEmail;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 820;
        final panels = [
          _InfoPanel(
            title: '계정 정보',
            icon: Icons.manage_accounts_outlined,
            rows: [
              _InfoRow('회원번호', '${profile['user_no'] ?? '-'}'),
              _InfoRow('로그인 ID', '${profile['login_id'] ?? '-'}'),
              _InfoRow('상태', '${profile['status'] ?? '-'}'),
              _InfoRow('인증 제공자', '${profile['auth_provider'] ?? '-'}'),
            ],
          ),
          _ActionPanel(
            title: '보안',
            icon: Icons.shield_outlined,
            actions: [
              _AccountAction(
                icon: Icons.lock_reset_rounded,
                label: '비밀번호 변경',
                color: MetaServerColors.cyan,
                onTap: onChangePassword,
              ),
              _AccountAction(
                icon: firebaseUser?.emailVerified == true
                    ? Icons.verified_outlined
                    : Icons.mark_email_unread_outlined,
                label: firebaseUser?.emailVerified == true
                    ? '이메일 인증 완료'
                    : '이메일 인증 보내기',
                color: firebaseUser?.emailVerified == true
                    ? MetaServerColors.green
                    : MetaServerColors.amber,
                onTap:
                    firebaseUser?.emailVerified == true ? null : onVerifyEmail,
              ),
              _AccountAction(
                icon: Icons.sync_rounded,
                label: '계정 동기화',
                color: MetaServerColors.cyan,
                onTap: onRefresh,
              ),
            ],
          ),
        ];

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: panels[0]),
              const SizedBox(width: 18),
              Expanded(child: panels[1]),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            panels[0],
            const SizedBox(height: 16),
            panels[1],
          ],
        );
      },
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<_InfoRow> rows;

  @override
  Widget build(BuildContext context) {
    return _PanelShell(
      title: title,
      icon: icon,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            _InfoRowTile(row: rows[i]),
            if (i != rows.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _ActionPanel extends StatelessWidget {
  const _ActionPanel({
    required this.title,
    required this.icon,
    required this.actions,
  });

  final String title;
  final IconData icon;
  final List<_AccountAction> actions;

  @override
  Widget build(BuildContext context) {
    return _PanelShell(
      title: title,
      icon: icon,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            _AccountActionTile(action: actions[i]),
            if (i != actions.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _PanelShell extends StatelessWidget {
  const _PanelShell({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
        boxShadow: [
          BoxShadow(
            color: MetaServerColors.ink.withValues(alpha: 0.06),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: MetaServerColors.cyan.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: MetaServerColors.cyan.withValues(alpha: 0.18),
                  ),
                ),
                child: Icon(icon, color: MetaServerColors.cyan, size: 25),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 23),
      style: IconButton.styleFrom(
        fixedSize: const Size(44, 44),
        backgroundColor: Colors.white,
        foregroundColor: MetaServerColors.ink,
        disabledBackgroundColor: MetaServerColors.line.withValues(alpha: 0.5),
        disabledForegroundColor: MetaServerColors.ink.withValues(alpha: 0.32),
        side: const BorderSide(color: MetaServerColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRowTile extends StatelessWidget {
  const _InfoRowTile({required this.row});

  final _InfoRow row;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: MetaServerColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MetaServerColors.line),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              row.label,
              style: TextStyle(
                color: MetaServerColors.ink.withValues(alpha: 0.58),
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              row.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: MetaServerColors.ink,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountActionTile extends StatelessWidget {
  const _AccountActionTile({required this.action});

  final _AccountAction action;

  @override
  Widget build(BuildContext context) {
    final enabled = action.onTap != null;
    final color = enabled ? action.color : MetaServerColors.green;

    return Material(
      color: enabled
          ? MetaServerColors.canvas
          : MetaServerColors.green.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: enabled
              ? MetaServerColors.line
              : MetaServerColors.green.withValues(alpha: 0.22),
        ),
      ),
      child: InkWell(
        onTap: action.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(action.icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: enabled
                        ? MetaServerColors.ink
                        : MetaServerColors.ink.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Icon(
                enabled
                    ? Icons.chevron_right_rounded
                    : Icons.check_circle_outline_rounded,
                color: color,
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;
}

class _AccountAction {
  const _AccountAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
}
