import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../protocol/ble_protocol.dart';

/// Thin wrapper around flutter_local_notifications.
///
/// Provides OS-level fall-alert notifications so the caretaker is notified
/// even when the app is not in the foreground.
class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _androidChannel = AndroidNotificationChannel(
    'ican_fall_alerts',
    'Fall Alerts',
    description: 'Urgent notifications when a fall is detected by iCan Cane.',
    importance: Importance.max,
    playSound: true,
  );

  static const _caretakerChannel = AndroidNotificationChannel(
    'ican_caretaker_alerts',
    'Caretaker Alerts',
    description:
        'Voice-triggered requests from the iCan user to the caretaker.',
    importance: Importance.high,
    playSound: true,
  );

  static const _androidDetails = AndroidNotificationDetails(
    'ican_fall_alerts',
    'Fall Alerts',
    channelDescription:
        'Urgent notifications when a fall is detected by iCan Cane.',
    importance: Importance.max,
    priority: Priority.high,
    ticker: 'Fall detected',
    icon: '@mipmap/ic_launcher',
  );

  static const _caretakerAndroidDetails = AndroidNotificationDetails(
    'ican_caretaker_alerts',
    'Caretaker Alerts',
    channelDescription:
        'Voice-triggered requests from the iCan user to the caretaker.',
    importance: Importance.high,
    priority: Priority.high,
    ticker: 'Caretaker requested',
    icon: '@mipmap/ic_launcher',
  );

  static const _iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
    sound: 'default',
    interruptionLevel: InterruptionLevel.timeSensitive,
  );

  static const _caretakerIosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
    sound: 'default',
    interruptionLevel: InterruptionLevel.timeSensitive,
  );

  static const _notificationDetails = NotificationDetails(
    android: _androidDetails,
    iOS: _iosDetails,
  );

  static const _caretakerDetails = NotificationDetails(
    android: _caretakerAndroidDetails,
    iOS: _caretakerIosDetails,
  );

  // flutter_local_notifications supports Android, iOS, macOS, Linux — not Windows.
  static bool get _supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux;

  static bool get caretakerAlertsSupported => _supported;

  /// Call once in main() before runApp().
  static Future<void> init() async {
    if (!_supported) {
      debugPrint(
        '[Notifications] Skipped — not supported on ${Platform.operatingSystem}.',
      );
      return;
    }

    const initSettingsAndroid = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: initSettingsAndroid,
      iOS: initSettingsIOS,
    );

    await _plugin.initialize(initSettings);

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(_androidChannel);
    await androidPlugin?.createNotificationChannel(_caretakerChannel);

    debugPrint('[Notifications] Initialized.');
  }

  /// Show an urgent fall-detected notification.
  ///
  /// When [gps] is provided with a valid fix, the notification body includes
  /// the user's last-known coordinates so the caretaker can locate them.
  static Future<void> showFallAlert({GpsPacket? gps}) async {
    if (!_supported) {
      debugPrint(
        '[Notifications] Fall alert skipped on ${Platform.operatingSystem} — in-app dialog handles it.',
      );
      return;
    }
    final body = _fallAlertBody(gps);
    debugPrint('[Notifications] Showing fall alert notification. $body');
    await _plugin.show(0, 'Fall Detected', body, _notificationDetails);
  }

  static String _fallAlertBody(GpsPacket? gps) {
    const base =
        'iCan Cane has detected a fall. Check on the user immediately.';
    if (gps == null) return base;
    if (!gps.fixValid) {
      return '$base Location unavailable (no GPS fix).';
    }
    final lat = gps.latitude.toStringAsFixed(6);
    final lon = gps.longitude.toStringAsFixed(6);
    return '$base Last location: $lat, $lon.';
  }

  /// Cancel the active fall alert notification.
  static Future<void> cancelFallAlert() async {
    if (!_supported) return;
    await _plugin.cancel(0);
    debugPrint('[Notifications] Fall alert notification dismissed.');
  }

  /// Show a caretaker-alert notification triggered by the user's voice command.
  /// Returns true if the notification was delivered to the OS.
  static Future<bool> showCaretakerAlert({String? reason}) async {
    if (!_supported) {
      debugPrint(
        '[Notifications] Caretaker alert skipped on ${Platform.operatingSystem}.',
      );
      return false;
    }
    debugPrint('[Notifications] Showing caretaker alert notification.');
    await _plugin.show(
      1,
      'iCan user is asking for you',
      reason ?? 'The iCan user triggered a caretaker alert by voice.',
      _caretakerDetails,
    );
    return true;
  }
}
