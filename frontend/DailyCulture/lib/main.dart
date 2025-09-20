import 'package:flutter/material.dart';
import 'views/view_login.dart';

void main() => runApp(const App());

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
    );
  }
}
