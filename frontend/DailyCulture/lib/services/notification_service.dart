// lib/services/notification_service.dart
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart'; // solo usamos la clase
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Servicio de notificaciones locales (Android/iOS/macOS).
///  - Seguro con flutter_local_notifications 19.x
///  - Compatible con flutter_timezone 1.x y 5.x (maneja String/TimezoneInfo/Map)
class NotificationService {
  NotificationService._();

  static const _channelId = 'dailyculture_channel';
  static const _channelName = 'Recordatorios DailyCulture';

  static final FlutterLocalNotificationsPlugin _fln =
  FlutterLocalNotificationsPlugin();

  /* ───────────────────────── Zona horaria ───────────────────────── */

  /// Extrae un ID TZDB válido (p. ej. "Europe/Madrid") de lo que devuelva
  /// flutter_timezone (puede ser String, TimezoneInfo, Map, etc.).
  static String _extractTzString(Object tzObj) {
    // v1.x devolvía String
    if (tzObj is String && tzObj.isNotEmpty) return tzObj;

    // Intento vía dynamic con propiedades comunes
    try {
      final dyn = tzObj as dynamic;
      final candidate = (dyn.timeZoneId ??
          dyn.timezoneId ??
          dyn.name ??
          dyn.timeZone ??
          dyn.timezone ??
          dyn.id);

      if (candidate is String && candidate.isNotEmpty) return candidate;

      // Si existe toJson probamos ahí
      final json = (dyn.toJson is Function) ? dyn.toJson() : null;
      if (json is Map) {
        for (final k in ['timeZoneId', 'timezoneId', 'name', 'timeZone', 'timezone', 'id']) {
          final v = json[k];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    } catch (_) {
      // ignoramos, pasamos al fallback
    }

    // Último recurso: tratamos de extraer "Region/City" del toString()
    final s = tzObj.toString();
    final m = RegExp(r'([A-Za-z]+\/[A-Za-z_]+)').firstMatch(s);
    return m?.group(1) ?? 'UTC';
  }

  /// Llamar en `main()` antes de `runApp`.
  static Future<void> init({
    void Function(NotificationResponse)? onTap,
  }) async {
    // Zona horaria segura entre versiones
    try {
      tz.initializeTimeZones();
      final tzAny = await FlutterTimezone.getLocalTimezone(); // tipo varía según versión
      final localTz = _extractTzString(tzAny);
      tz.setLocalLocation(tz.getLocation(localTz));
    } catch (e) {
      debugPrint('TZ init fallback: $e');
      tz.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    // Inicialización por plataforma (icono por defecto del app)
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

    await _fln.initialize(
      init,
      onDidReceiveNotificationResponse: onTap,
      // Si necesitas manejar taps en segundo plano, añade aquí tu callback con @pragma('vm:entry-point')
      // onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    // Canal Android (8+)
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: 'Avisos y recordatorios diarios',
      importance: Importance.high,
    );

    final android = _fln
        .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(channel);
  }

  /* ───────────────────────── Permisos ───────────────────────── */

  /// Pide permisos de notificación. Por defecto **no** solicita Exact Alarms
  /// (eso abre la pantalla del sistema). Si de verdad lo necesitas, pasa
  /// `askExactAlarms: true` justo antes de programar algo exacto.
  static Future<bool> requestPermissions({bool askExactAlarms = false}) async {
    bool granted = true;

    if (Platform.isIOS) {
      final ios = _fln.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final ok = await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      ) ??
          true;
      granted = granted && ok;
    }

    if (Platform.isMacOS) {
      final mac = _fln.resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin>();
      final ok = await mac?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      ) ??
          true;
      granted = granted && ok;
    }

    if (Platform.isAndroid) {
      final android = _fln.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      // Android 13+: permiso para mostrar notificaciones
      final enabled = await android?.areNotificationsEnabled() ?? true;
      if (!enabled) {
        final ok = await android?.requestNotificationsPermission() ?? true;
        granted = granted && ok;
      }

      // Android 12+: Exact Alarms (puede abrir Ajustes del sistema)
      if (askExactAlarms) {
        await android?.requestExactAlarmsPermission();
      }
    }

    return granted;
  }

  /* ───────────────────────── Notificaciones ───────────────────────── */

  static NotificationDetails _details({
    String? payload,
  }) =>
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

  /// Muestra una notificación inmediata.
  static Future<void> showNow({
    required String title,
    required String body,
    String? payload,
    int id = 0,
  }) {
    return _fln.show(id, title, body, _details(payload: payload), payload: payload);
  }

  /// Programa un recordatorio **diario** (ej. 20:30 todos los días).
  static Future<void> scheduleDaily(
      int hour,
      int minute, {
        int id = 1001,
        String title = 'Tu objetivo de hoy',
        String body = 'Completa 1 actividad de cultura diaria ✨',
        String? payload,
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
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time, // repetición diaria
      payload: payload,
    );
  }

  /// Programa una **única** notificación para un `DateTime` local.
  static Future<void> scheduleAtLocal(
      DateTime when, {
        int id = 2001,
        required String title,
        required String body,
        String? payload,
      }) async {
    final target = tz.TZDateTime.from(when, tz.local);

    await _fln.zonedSchedule(
      id,
      title,
      body,
      target,
      _details(payload: payload),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: payload,
    );
  }

  /// Programa una **única** notificación dentro de un `Duration`.
  static Future<void> scheduleIn(
      Duration delay, {
        int id = 2002,
        required String title,
        required String body,
        String? payload,
      }) {
    final when = tz.TZDateTime.now(tz.local).add(delay);
    return _fln.zonedSchedule(
      id,
      title,
      body,
      when,
      _details(payload: payload),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: payload,
    );
  }

  /// Cancela todas las notificaciones.
  static Future<void> cancelAll() => _fln.cancelAll();

  /// Cancela una notificación por id.
  static Future<void> cancel(int id) => _fln.cancel(id);
}
