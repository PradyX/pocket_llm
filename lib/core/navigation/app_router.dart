import 'package:flutter_base_app/features/home/presentation/home_page.dart';
import 'package:flutter_base_app/features/home/presentation/settings_page.dart';
import 'package:flutter_base_app/features/login/presentation/forgot_password_page.dart';
import 'package:flutter_base_app/features/login/presentation/login_page.dart';
import 'package:flutter_base_app/features/login/presentation/otp_login_page.dart';
import 'package:flutter_base_app/features/sign_up/presentation/signup_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_router.g.dart';

/// Route path constants for type-safe navigation.
abstract class AppRoutes {
  static const login = '/login';
  static const signUp = '/signup';
  static const home = '/home';
  static const settings = '/settings';
  static const forgotPassword = '/forgot-password';
  static const loginOtp = '/login-otp';
}

@riverpod
GoRouter appRouter(Ref ref) {
  return GoRouter(
    initialLocation: AppRoutes.login,
    routes: [
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: AppRoutes.signUp,
        builder: (context, state) => const SignUpPage(),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsPage(),
      ),
      GoRoute(
        path: AppRoutes.forgotPassword,
        builder: (context, state) => const ForgotPasswordPage(),
      ),
      GoRoute(
        path: AppRoutes.loginOtp,
        builder: (context, state) =>
            OtpLoginPage(initialPhone: state.extra as String?),
      ),
    ],
  );
}
