import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'views/view_login.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializa datos de formato de fechas/números para español
  await initializeDateFormatting('es');
  Intl.defaultLocale = 'es';

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

      // 👇 Soporte de localización (Material, Widgets y Cupertino)
      locale: const Locale('es'),
      supportedLocales: const [
        Locale('es'), // español
        Locale('en'), // inglés (fallback)
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
