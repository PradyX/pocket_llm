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
      final initialized = await _plugin.initialize(settings: settings);
      _notificationsAvailable = initialized ?? true;
    } catch (error, stackTrace) {
      debugPrint(
        'LocalNotificationService initialization disabled notifications: '
        '$error\n$stackTrace',
      );
      _notificationsAvailable = false;
    }

    _isInitialized = true;
  }

  Future<void> requestPermissions() async {
    await initialize();
    if (!_notificationsAvailable) return;

    if (Platform.isAndroid) {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImpl?.requestNotificationsPermission();
      return;
    }

    if (Platform.isIOS) {
      final iosImpl = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      await iosImpl?.requestPermissions(alert: true, badge: true, sound: true);
    }

    if (Platform.isMacOS) {
      final macOsImpl = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      await macOsImpl?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    }
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
