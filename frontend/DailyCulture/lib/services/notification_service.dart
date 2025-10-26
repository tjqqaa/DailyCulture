// lib/services/notification_service.dart
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  NotificationService._();

  static const _channelId = 'dailyculture_channel';
  static const _channelName = 'Recordatorios DailyCulture';

  static final _fln = FlutterLocalNotificationsPlugin();

  static String _extractTzString(Object tzObj) {
    if (tzObj is String && tzObj.isNotEmpty) return tzObj;
    try {
      final dyn = tzObj as dynamic;
      final c = (dyn.timeZoneId ?? dyn.timezoneId ?? dyn.name ?? dyn.timeZone ?? dyn.timezone ?? dyn.id);
      if (c is String && c.isNotEmpty) return c;
      final json = (dyn.toJson is Function) ? dyn.toJson() : null;
      if (json is Map) {
        for (final k in ['timeZoneId','timezoneId','name','timeZone','timezone','id']) {
          final v = json[k];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    } catch (_) {}
    final s = tzObj.toString();
    final m = RegExp(r'([A-Za-z]+\/[A-Za-z_]+)').firstMatch(s);
    return m?.group(1) ?? 'UTC';
  }

  static Future<void> init({void Function(NotificationResponse)? onTap}) async {
    try {
      tz.initializeTimeZones();
      final anyTz = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(_extractTzString(anyTz)));
    } catch (e) {
      debugPrint('TZ init fallback: $e');
      tz.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const init = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
      macOS: darwinInit,
    );

    await _fln.initialize(init, onDidReceiveNotificationResponse: onTap);

    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: 'Avisos y recordatorios diarios',
      importance: Importance.high,
    );
    final android = _fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(channel);
  }

  static Future<bool> requestPermissions({bool askExactAlarms = false}) async {
    bool granted = true;

    final ios = _fln.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final mac = _fln.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    final android = _fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    if (Platform.isIOS) {
      final ok = await ios?.requestPermissions(alert: true, badge: true, sound: true) ?? true;
      granted = granted && ok;
    }
    if (Platform.isMacOS) {
      final ok = await mac?.requestPermissions(alert: true, badge: true, sound: true) ?? true;
      granted = granted && ok;
    }
    if (Platform.isAndroid) {
      final enabled = await android?.areNotificationsEnabled() ?? true;
      if (!enabled) {
        final ok = await android?.requestNotificationsPermission() ?? true;
        granted = granted && ok;
      }
      if (askExactAlarms) {
        // Esto abre la pantalla del sistema; el usuario debe activarlo allí.
        await android?.requestExactAlarmsPermission();
      }
    }
    return granted;
  }

  static NotificationDetails _details({String? payload}) =>
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      );

  // ─────────── Helper: elige modo exacto/inexacto según lo que pidas ───────────
  static AndroidScheduleMode _mode({required bool exact}) {
    // Si exact = true y el usuario activó la permisión, será EXACT;
    // si exact = false (fallback), será INEXACT (no requiere permiso).
    return exact ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
  }

  // Inmediata (para probar permisos)
  static Future<void> showNow({
    required String title,
    required String body,
    String? payload,
    int id = 0,
  }) {
    return _fln.show(id, title, body, _details(payload: payload), payload: payload);
  }

  // Programar una sola vez en una fecha/hora local
  static Future<void> scheduleAtLocal(
      DateTime when, {
        int id = 2001,
        required String title,
        required String body,
        String? payload,
        bool exact = false,
      }) async {
    final target = tz.TZDateTime.from(when, tz.local);
    await _fln.zonedSchedule(
      id,
      title,
      body,
      target,
      _details(payload: payload),
      androidScheduleMode: _mode(exact: exact),
      payload: payload,
    );
  }

  // Programar dentro de un Duration
  static Future<void> scheduleIn(
      Duration delay, {
        int id = 2002,
        required String title,
        required String body,
        String? payload,
        bool exact = false,
      }) async {
    final when = tz.TZDateTime.now(tz.local).add(delay);
    await _fln.zonedSchedule(
      id,
      title,
      body,
      when,
      _details(payload: payload),
      androidScheduleMode: _mode(exact: exact),
      payload: payload,
    );
  }

  // Diario a una hora (HH:mm)
  static Future<void> scheduleDaily(
      int hour,
      int minute, {
        int id = 1001,
        String title = 'Tu objetivo de hoy',
        String body = 'Completa 1 actividad de cultura diaria ✨',
        String? payload,
        bool exact = false,
      }) async {
    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (next.isBefore(now)) next = next.add(const Duration(days: 1));

    await _fln.zonedSchedule(
      id,
      title,
      body,
      next,
      _details(payload: payload),
      androidScheduleMode: _mode(exact: exact),
      matchDateTimeComponents: DateTimeComponents.time, // repetición diaria
      payload: payload,
    );
  }

  static Future<void> cancelAll() => _fln.cancelAll();
  static Future<void> cancel(int id) => _fln.cancel(id);
}
