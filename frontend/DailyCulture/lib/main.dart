// lib/main.dart
import 'package:flutter/material.dart';
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

  // Solo pide permiso de notificaciones; NADA de exact alarms aquí.
  await NotificationService.requestPermissions(askExactAlarms: false);
  await NotificationService.scheduleDaily(11, 25); // todos los días a las 20:30
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
