import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/core/services/local_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // What the plugin's native side answers during the flows under test.
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final methodsCalled = <String>[];

  setUp(() {
    methodsCalled.clear();
    // The plugin picks its implementation from the target platform, and on
    // macOS it also expects its own Dart implementation to be registered —
    // which the app's generated registrant does at startup.
    MacOSFlutterLocalNotificationsPlugin.registerWith();
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methodsCalled.add(call.method);
          // On iOS and macOS the plugin reports the *permission* state from
          // `initialize`, and this app asks for permission later on purpose,
          // so the start-up value is false until the user is asked.
          return call.method == 'initialize' ? false : true;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a false start-up value does not turn notifications off', () async {
    final service = LocalNotificationService.instance;

    await service.requestPermissions();
    await service.showModelDownloadComplete('Qwen 2.5');

    expect(methodsCalled, contains('initialize'));
    if (Platform.isMacOS) {
      // Asking the platform is what gets macOS to deliver anything at all: the
      // deferred request is the only place the permission is requested.
      expect(methodsCalled, contains('requestPermissions'));
    }
    // The notice a finished download owes the user.
    expect(methodsCalled, contains('show'));
  });
}
