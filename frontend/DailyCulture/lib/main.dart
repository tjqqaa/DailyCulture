// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'services/notification_service.dart';
import 'views/view_login.dart';
import 'controller/accessibility_controller.dart';

// Singleton accesible desde otras vistas (import '../../main.dart' show a11y;)
late final AccessibilityController a11y;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeDateFormatting('es');
  Intl.defaultLocale = 'es';

  // Accesibilidad
  a11y = AccessibilityController();
  await a11y.load();

  // Notificaciones (demo)
  await NotificationService.init(
    onTap: (resp) => debugPrint('[Notification tapped] ${resp.payload}'),
  );
  await NotificationService.requestPermissions(askExactAlarms: false);
  await NotificationService.showNow(title: 'DailyCulture', body: 'Permisos OK (inmediata).');
  await NotificationService.scheduleIn(const Duration(seconds: 10),
      title: 'Prueba 10s', body: 'Notificación programada (inexacta).');
  await NotificationService.scheduleDaily(20, 30); // 20:30

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: a11y,
      builder: (context, _) {
        final s = a11y.settings;

        final base = ThemeData(
          useMaterial3: true,
          colorScheme: s.highContrast
              ? const ColorScheme.highContrastLight(
            primary: Color(0xFF0000A0),
            onPrimary: Colors.white,
            secondary: Color(0xFF005C00),
            onSecondary: Colors.white,
            surface: Colors.white,
            onSurface: Colors.black,
          )
              : ColorScheme.fromSeed(seedColor: const Color(0xFF5B53D6)),
          scaffoldBackgroundColor: const Color(0xFFFBF7EF),
          materialTapTargetSize:
          s.largeTapTargets ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
          pageTransitionsTheme: s.reduceMotion
              ? const PageTransitionsTheme(builders: {
            TargetPlatform.android: _NoTransitionsBuilder(),
            TargetPlatform.iOS: _NoTransitionsBuilder(),
            TargetPlatform.linux: _NoTransitionsBuilder(),
            TargetPlatform.macOS: _NoTransitionsBuilder(),
            TargetPlatform.windows: _NoTransitionsBuilder(),
          })
              : const PageTransitionsTheme(),
        );

        final themed = base.copyWith(
          // 👇 Aplica negrita a todo el TextTheme si está activo
          textTheme: s.boldText ? _boldTextTheme(base.textTheme) : base.textTheme,
          elevatedButtonTheme:
          ElevatedButtonThemeData(style: ElevatedButton.styleFrom(minimumSize: const Size(88, 48))),
          outlinedButtonTheme:
          OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(88, 48))),
          textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(88, 48))),
        );

        return MaterialApp(
          title: 'DailyCulture',
          theme: themed,
          debugShowCheckedModeBanner: false,
          locale: const Locale('es'),
          supportedLocales: const [Locale('es'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaleFactor: s.textScale.clamp(1.0, 1.6),
                boldText: s.boldText,
                // disableAnimations (si tu SDK lo soporta) podría ir aquí
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const LoginView(),
        );
      },
    );
  }
}

// ---- Helpers ----

TextTheme _boldTextTheme(TextTheme t) {
  TextStyle? b(TextStyle? s) => s?.copyWith(fontWeight: FontWeight.w700);
  return t.copyWith(
    displayLarge: b(t.displayLarge),
    displayMedium: b(t.displayMedium),
    displaySmall: b(t.displaySmall),
    headlineLarge: b(t.headlineLarge),
    headlineMedium: b(t.headlineMedium),
    headlineSmall: b(t.headlineSmall),
    titleLarge: b(t.titleLarge),
    titleMedium: b(t.titleMedium),
    titleSmall: b(t.titleSmall),
    bodyLarge: b(t.bodyLarge),
    bodyMedium: b(t.bodyMedium),
    bodySmall: b(t.bodySmall),
    labelLarge: b(t.labelLarge),
    labelMedium: b(t.labelMedium),
    labelSmall: b(t.labelSmall),
  );
}

class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
      PageRoute<T> route,
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
      ) =>
      child;
}
