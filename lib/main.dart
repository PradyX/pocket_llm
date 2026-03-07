import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocket_llm/app.dart';
import 'package:pocket_llm/core/utils/logger.dart';
import 'package:pocket_llm/i18n/strings.g.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'firebase_initializer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables
  await dotenv.load(fileName: ".env");

  // Enable Edge-to-Edge UI for Android 15+
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarColor: Colors.transparent,
    ),
  );

  await FirebaseInitializer.init();

  // Initialize Crashlytics error handlers
  AppLogger.initCrashlytics();

  // Initialize i18n
  LocaleSettings.useDeviceLocale();

  AppLogger.info('App started successfully');
  runApp(TranslationProvider(child: const ProviderScope(child: MyApp())));
}
