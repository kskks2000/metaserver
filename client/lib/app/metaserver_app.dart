import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../account/account_screen.dart';
import '../auto_trading/auto_trading_screen.dart';
import '../auth/change_password_screen.dart';
import '../auth/forgot_password_screen.dart';
import '../auth/sign_in_screen.dart';
import '../auth/sign_up_screen.dart';
import '../trading/trading_screen.dart';
import 'theme.dart';

class MetaServerApp extends StatefulWidget {
  const MetaServerApp({super.key});

  @override
  State<MetaServerApp> createState() => _MetaServerAppState();
}

class _MetaServerAppState extends State<MetaServerApp> {
  late final GoRouter _router;
  late final _AuthRefreshListenable _authRefresh;

  @override
  void initState() {
    super.initState();
    _authRefresh =
        _AuthRefreshListenable(FirebaseAuth.instance.authStateChanges());
    _router = GoRouter(
      initialLocation: '/sign-in',
      refreshListenable: _authRefresh,
      redirect: (context, state) {
        final loggedIn = FirebaseAuth.instance.currentUser != null;
        final publicRoute = {
          '/sign-in',
          '/sign-up',
          '/forgot-password',
        }.contains(state.uri.path);

        if (!loggedIn && !publicRoute) {
          return '/sign-in';
        }
        if (loggedIn && publicRoute) {
          return '/trading';
        }
        return null;
      },
      routes: [
        GoRoute(
          path: '/sign-in',
          builder: (context, state) => const SignInScreen(),
        ),
        GoRoute(
          path: '/sign-up',
          builder: (context, state) => const SignUpScreen(),
        ),
        GoRoute(
          path: '/forgot-password',
          builder: (context, state) => const ForgotPasswordScreen(),
        ),
        GoRoute(
          path: '/change-password',
          builder: (context, state) => const ChangePasswordScreen(),
        ),
        GoRoute(
          path: '/account',
          builder: (context, state) => const AccountScreen(),
        ),
        GoRoute(
          path: '/trading',
          builder: (context, state) => const TradingScreen(),
        ),
        GoRoute(
          path: '/auto-trading',
          builder: (context, state) => const AutoTradingScreen(),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _authRefresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'MetaServer',
      debugShowCheckedModeBanner: false,
      theme: buildMetaServerTheme(),
      routerConfig: _router,
    );
  }
}

class _AuthRefreshListenable extends ChangeNotifier {
  _AuthRefreshListenable(Stream<User?> stream) {
    _subscription = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<User?> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
