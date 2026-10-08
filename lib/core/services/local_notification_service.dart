import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class LocalNotificationService {
  LocalNotificationService._();

  static final LocalNotificationService instance = LocalNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  bool _notificationsAvailable = true;

  /// True when the plugin itself could not be set up. Kept apart from
  /// [_notificationsAvailable], which is about what the user allowed: a
  /// refused permission must not stop a later request from being made, and a
  /// failed setup must not present a prompt that cannot be answered.
  bool _initializationFailed = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open Pocket LLM',
    );
    const windowsSettings = WindowsInitializationSettings(
      appName: 'Pocket LLM',
      appUserModelId: 'com.prady.pocketllm.desktop',
      guid: '2f655744-b4fd-4d2a-9b61-d0f5f53d0cf4',
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
      linux: linuxSettings,
      windows: windowsSettings,
    );

    try {
      // The returned value is deliberately not treated as availability. On iOS
      // and macOS the plugin reports the *permission* state here, and this app
      // defers that question (the request*Permission flags above are false), so
      // the value is false until the user is asked — reading it as "not
      // available" used to skip the request and every notice after it.
      await _plugin.initialize(settings: settings);
    } catch (error, stackTrace) {
      debugPrint(
        'LocalNotificationService initialization disabled notifications: '
        '$error\n$stackTrace',
      );
      _initializationFailed = true;
      _notificationsAvailable = false;
    }

    _isInitialized = true;
  }

  /// Asks the platform for permission to show notifications.
  ///
  /// Only a setup failure cancels the question, so a permission the user
  /// refused earlier can still be asked for again after they change the setting
  /// in the system. What the platform answers decides whether notices are built
  /// at all: a notification the system would drop is not worth the work.
  Future<void> requestPermissions() async {
    await initialize();
    if (_initializationFailed) return;

    if (Platform.isAndroid) {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      _recordPermissionAnswer(
        await androidImpl?.requestNotificationsPermission(),
      );
      return;
    }

    if (Platform.isIOS) {
      final iosImpl = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      _recordPermissionAnswer(
        await iosImpl?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ),
      );
    }

    if (Platform.isMacOS) {
      final macOsImpl = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      _recordPermissionAnswer(
        await macOsImpl?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ),
      );
    }
  }

  /// Stores what the platform answered about notification permission.
  ///
  /// A null answer means the platform did not report one (older Android
  /// releases ask at install time), so the last known state is kept.
  void _recordPermissionAnswer(bool? granted) {
    if (granted == null) return;
    _notificationsAvailable = granted;
    if (granted) return;
    debugPrint(
      'LocalNotificationService: notifications are not allowed here, so '
      'download notices are skipped. Allow them in the system notification '
      'settings for Pocket LLM to get them.',
    );
  }

  Future<void> showModelDownloadComplete(String modelName) async {
    await initialize();
    if (!_notificationsAvailable) return;

    const androidDetails = AndroidNotificationDetails(
      'model_downloads',
      'Model downloads',
      channelDescription: 'Notifies when model downloads complete',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
    );
    const linuxDetails = LinuxNotificationDetails(
      category: LinuxNotificationCategory.transferComplete,
      urgency: LinuxNotificationUrgency.normal,
      defaultActionName: 'Open Pocket LLM',
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
      linux: linuxDetails,
    );

    try {
      await _plugin.show(
        id: modelName.hashCode & 0x7fffffff,
        title: 'Model downloaded',
        body: '$modelName is ready to use.',
        notificationDetails: details,
      );
    } catch (error, stackTrace) {
      debugPrint(
        'LocalNotificationService failed to show notification: '
        '$error\n$stackTrace',
      );
    }
  }
}
