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
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    _talker.error(message, error, stackTrace);
  }

  /// Log a critical/fatal error.
  static void fatal(String message, Object error, StackTrace stackTrace) {
    _talker.critical(message, error, stackTrace);
  }

  /// Initialize global error handlers so uncaught errors are logged.
  static void initErrorHandlers() {
    FlutterError.onError = (details) {
      _talker.error('Flutter Error', details.exception, details.stack);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      _talker.error('Async Error', error, stack);
      return true;
    };
  }
}
