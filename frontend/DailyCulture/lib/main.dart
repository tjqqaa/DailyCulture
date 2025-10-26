// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'services/notification_service.dart';
import 'views/view_login.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeDateFormatting('es');
  Intl.defaultLocale = 'es';

  await NotificationService.init(
    onTap: (resp) => debugPrint('[Notification tapped] ${resp.payload}'),
  );

  // Pide permisos básicos (sin exact alarms para empezar)
  await NotificationService.requestPermissions(askExactAlarms: false);

  // 1) Inmediata para confirmar permisos/sonido (canal dc_now)
  await NotificationService.showNow(
    title: 'DailyCulture',
    body: 'Permisos OK (inmediata).',
  );

  // 2) Prueba en 10 seg (canal dc_reminders)
  await NotificationService.scheduleIn(
    const Duration(seconds: 10),
    title: 'Prueba 10s',
    body: 'Notificación programada (inexacta).',
  );

  // 3) Diario a una hora concreta (p. ej. 20:30)
  await NotificationService.scheduleDaily(12, 46);

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DailyCulture',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF5B53D6),
        scaffoldBackgroundColor: const Color(0xFFFBF7EF),
      ),
      home: const LoginView(),
      debugShowCheckedModeBanner: false,
      locale: const Locale('es'),
      supportedLocales: const [Locale('es'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
