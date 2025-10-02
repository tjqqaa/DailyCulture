// lib/views/view_login.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'view_home.dart';
import 'view_signup.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  // API base
  static const _loginUrl =
      'https://dailyculture-bpdmbwahh5axdcd0.spaincentral-01.azurewebsites.net/auth/login';

  final _formKey = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _storage = const FlutterSecureStorage();

  bool _obscure = true;
  bool _loading = false;

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _onLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      final res = await http.post(
        Uri.parse(_loginUrl),
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          // el backend acepta username o email en este campo
          'username': _userCtrl.text.trim(),
          'password': _passCtrl.text,
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final token = data['access_token'] as String?;
        final user = (data['user'] ?? {}) as Map<String, dynamic>;

        // username para el saludo en Home
        final username = (user['username'] ?? user['name'] ?? '').toString();

        if (token == null || token.isEmpty) {
          throw Exception('Respuesta sin access_token');
        }

        // 1) Guarda token
        await _storage.write(key: 'access_token', value: token);

        // 2) Normaliza y guarda el usuario en cache para ProfileView
        final normalizedUser = {
          'id':       (user['id'] ?? user['_id'] ?? user['uid'] ?? user['sub'] ?? '—').toString(),
          'email':    (user['email'] ?? '').toString(),
          'username': (user['username'] ?? user['name'] ?? _userCtrl.text.trim()).toString(),
          'full_name': user['full_name'] ?? user['fullName'] ?? user['name'],
          'is_active': (user['is_active'] ?? user['isActive'] ?? true) == true,
          'created_at': (user['created_at'] ??
              user['createdAt'] ??
              DateTime.now().toIso8601String()),
        };
        try {
          await _storage.write(key: 'user_cache', value: jsonEncode(normalizedUser));
        } catch (_) {
          // ignoramos si no se puede serializar
        }

        if (!mounted) return;
        // 3) Navega a HomeView
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => HomeView(
              username: username,
            ),
          ),
        );
        return;
      }

      // muestra mensaje de error legible
      String msg = 'Error ${res.statusCode}';
      try {
        final body = jsonDecode(res.body);
        if (body is Map && body['detail'] != null) {
          msg = body['detail'].toString();
        }
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo iniciar sesión: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);
    const bg = Color(0xFFFBF7EF);

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          const _DecorBackground(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LayoutBuilder(builder: (context, constraints) {
                        final w = constraints.maxWidth;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(width: w, child: _LogoBannerFullWidth(width: w)),
                            const SizedBox(height: 18),
                            SizedBox(
                              width: w,
                              child: Card(
                                elevation: 8,
                                shadowColor: Colors.black12,
                                color: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  side: const BorderSide(color: Color(0xFFF0ECE4)),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                                  child: Form(
                                    key: _formKey,
                                    child: Column(
                                      children: [
                                        _PrettyField(
                                          controller: _userCtrl,
                                          label: 'Username or email',
                                          icon: Icons.person_outline,
                                          textInputAction: TextInputAction.next,
                                          validator: (v) =>
                                          (v == null || v.trim().length < 3)
                                              ? 'Min. 3 characters'
                                              : null,
                                        ),
                                        const SizedBox(height: 12),
                                        _PrettyField(
                                          controller: _passCtrl,
                                          label: 'Password',
                                          icon: Icons.lock_outline,
                                          obscure: _obscure,
                                          onToggleObscure: () =>
                                              setState(() => _obscure = !_obscure),
                                          validator: (v) =>
                                          (v == null || v.length < 8)
                                              ? 'Min. 8 characters'
                                              : null,
                                        ),
                                        const SizedBox(height: 18),
                                        SizedBox(
                                          width: double.infinity,
                                          height: 52,
                                          child: ElevatedButton(
                                            onPressed: _loading ? null : _onLogin,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: primary,
                                              foregroundColor: Colors.white,
                                              elevation: 2,
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(14),
                                              ),
                                            ),
                                            child: _loading
                                                ? const SizedBox(
                                              height: 22,
                                              width: 22,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            )
                                                : const Text(
                                              'Log in',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: .2,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }),
                      const SizedBox(height: 14),
                      TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const SignUpView()),
                          );
                        },
                        child: const Text("Don't have an account?  Create one"),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------- helpers visuales (idénticos a tu código) ---------- */
class _LogoBannerFullWidth extends StatelessWidget {
  const _LogoBannerFullWidth({required this.width});
  final double width;

  @override
  Widget build(BuildContext context) {
    final logoHeight = (width * 0.22).clamp(56.0, 110.0);
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF0ECE4)),
        boxShadow: const [BoxShadow(color: Color(0x16000000), blurRadius: 18, offset: Offset(0, 8))],
      ),
      child: Center(
        child: Image.asset(
          'lib/images/dailyculture_logo.png',
          height: logoHeight,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}

class _PrettyField extends StatelessWidget {
  const _PrettyField({
    required this.controller,
    required this.label,
    required this.icon,
    this.validator,
    this.textInputAction,
    this.obscure = false,
    this.onToggleObscure,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? Function(String?)? validator;
  final TextInputAction? textInputAction;
  final bool obscure;
  final VoidCallback? onToggleObscure;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      validator: validator,
      textInputAction: textInputAction,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: Colors.black.withOpacity(.65)),
        suffixIcon: onToggleObscure == null
            ? null
            : IconButton(
          onPressed: onToggleObscure,
          icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: Color(0xFFEAE7E0)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: Color(0xFF5B53D6), width: 1.3),
        ),
      ),
    );
  }
}

class _DecorBackground extends StatelessWidget {
  const _DecorBackground();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFFDFBF6), Color(0xFFFBF7EF)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
        Positioned(top: -60, left: -40, child: _blob(const Color(0xFF7C75F0).withOpacity(.25), 180)),
        Positioned(bottom: -40, right: -30, child: _blob(const Color(0xFF5B53D6).withOpacity(.22), 160)),
      ],
    );
  }

  Widget _blob(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color, blurRadius: 80, spreadRadius: 30)],
      ),
    );
  }
}
