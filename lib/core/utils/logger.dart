import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Global application logger instance.
///
/// Usage:
/// ```dart
/// AppLogger.info('User logged in');
/// AppLogger.error('Something went wrong', error, stackTrace);
/// AppLogger.navigator;    // Use as NavigatorObserver for GoRouter
/// AppLogger.dioLogger;    // Use as Dio Interceptor
/// ```
class AppLogger {
  AppLogger._();

  static final Talker _talker = TalkerFlutter.init(
    settings: TalkerSettings(useConsoleLogs: !kReleaseMode),
  );

  /// Access the raw Talker instance (e.g. for TalkerScreen)
  static Talker get instance => _talker;

  /// Log an informational message
  static void info(String message) => _talker.info(message);

  /// Log a debug message (only visible in debug mode)
  static void debug(String message) => _talker.debug(message);

  /// Log a warning
  static void warning(String message) => _talker.warning(message);

  /// Log an error with optional exception and stack trace.
  /// In release mode, also reports to Firebase Crashlytics.
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    _talker.error(message, error, stackTrace);
    if (kReleaseMode && error != null) {
      FirebaseCrashlytics.instance.recordError(
        error,
        stackTrace,
        reason: message,
      );
    }
  }

  /// Log a critical/fatal error.
  /// Always reports to Firebase Crashlytics in release mode.
  static void fatal(String message, Object error, StackTrace stackTrace) {
    _talker.critical(message, error, stackTrace);
    if (kReleaseMode) {
      FirebaseCrashlytics.instance.recordError(
        error,
        stackTrace,
        fatal: true,
        reason: message,
      );
    }
  }

  /// Initialize Flutter error handlers to route uncaught errors to Crashlytics.
  /// Call this once in main() after Firebase initialization.
  static void initCrashlytics() {
    // Pass all uncaught Flutter errors to Crashlytics
    FlutterError.onError = (details) {
      _talker.error('Flutter Error', details.exception, details.stack);
      if (kReleaseMode) {
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      }
    };

    // Pass all uncaught async errors to Crashlytics
    PlatformDispatcher.instance.onError = (error, stack) {
      _talker.error('Async Error', error, stack);
      if (kReleaseMode) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      }
      return true;
    };
  }
}
