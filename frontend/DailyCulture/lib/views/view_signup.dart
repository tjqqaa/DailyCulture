import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SignUpView extends StatefulWidget {
  const SignUpView({super.key});

  @override
  State<SignUpView> createState() => _SignUpViewState();
}

class _SignUpViewState extends State<SignUpView> {
  final _formKey = GlobalKey<FormState>();

  final _emailCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _fullNameCtrl = TextEditingController();
  final _passCtrl = TextEditingController(); // (solo UI; tu API no guarda contraseñas)

  bool _obscurePass = true;
  bool _loading = false;

  // Cambia el host si usas otro.
  static const String _baseUrl =
  String.fromEnvironment('API_BASE_URL',
      defaultValue:
      'https://dailyculture-bpdmbwahh5axdcd0.spaincentral-01.azurewebsites.net');

  @override
  void dispose() {
    _emailCtrl.dispose();
    _userCtrl.dispose();
    _fullNameCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  static const _usernameRegex = r'^[a-zA-Z0-9._-]{3,30}$';

  Future<void> _onSignUp() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      final uri = Uri.parse('$_baseUrl/users');
      final body = jsonEncode({
        'email': _emailCtrl.text.trim(),
        'username': _userCtrl.text.trim(),
        if (_fullNameCtrl.text.trim().isNotEmpty)
          'full_name': _fullNameCtrl.text.trim(),
        'is_active': true,
      });

      final res = await http
          .post(
        uri,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: body,
      )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode == 201) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Account created! Welcome ${data['username']}')),
        );
        Navigator.pop(context); // volver a Login
        return;
      }

      // Extraer mensaje de error de FastAPI
      String msg;
      try {
        final m = jsonDecode(res.body) as Map<String, dynamic>;
        msg = (m['detail']?.toString()) ?? res.reasonPhrase ?? 'Unknown error';
      } catch (_) {
        msg = res.reasonPhrase ?? 'Unknown error';
      }
      throw Exception('HTTP ${res.statusCode}: $msg');
    } catch (e) {
      if (!mounted) return;
      final text = e.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
                padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final w = constraints.maxWidth;
                          return Column(
                            children: [
                              SizedBox(
                                  width: w,
                                  child: _LogoBannerFullWidth(width: w)),
                              const SizedBox(height: 18),
                              SizedBox(
                                width: w,
                                child: Card(
                                  elevation: 8,
                                  shadowColor: Colors.black12,
                                  color: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                    side: const BorderSide(
                                        color: Color(0xFFF0ECE4)),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        18, 20, 18, 18),
                                    child: Form(
                                      key: _formKey,
                                      child: Column(
                                        children: [
                                          _PrettyField(
                                            controller: _emailCtrl,
                                            label: 'Email',
                                            icon: Icons.email_outlined,
                                            textInputAction:
                                            TextInputAction.next,
                                            validator: (v) {
                                              final text = v?.trim() ?? '';
                                              if (text.isEmpty) {
                                                return 'Email is required';
                                              }
                                              final ok = RegExp(
                                                  r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                                  .hasMatch(text);
                                              return ok
                                                  ? null
                                                  : 'Enter a valid email';
                                            },
                                          ),
                                          const SizedBox(height: 12),
                                          _PrettyField(
                                            controller: _userCtrl,
                                            label: 'Username',
                                            icon: Icons.person_outline,
                                            textInputAction:
                                            TextInputAction.next,
                                            validator: (v) {
                                              final t = v?.trim() ?? '';
                                              if (t.isEmpty) {
                                                return 'Username is required';
                                              }
                                              return RegExp(_usernameRegex)
                                                  .hasMatch(t)
                                                  ? null
                                                  : '3–30 chars: letters, numbers, . _ -';
                                            },
                                          ),
                                          const SizedBox(height: 12),
                                          _PrettyField(
                                            controller: _fullNameCtrl,
                                            label: 'Full name (optional)',
                                            icon: Icons.badge_outlined,
                                            textInputAction:
                                            TextInputAction.next,
                                          ),
                                          const SizedBox(height: 12),
                                          _PrettyField(
                                            controller: _passCtrl,
                                            label: 'Password',
                                            icon: Icons.lock_outline,
                                            obscure: _obscurePass,
                                            onToggleObscure: () => setState(
                                                    () => _obscurePass =
                                                !_obscurePass),
                                            textInputAction:
                                            TextInputAction.done,
                                            // Tu API no guarda contraseñas, esto es solo validación visual
                                            validator: (v) => (v == null ||
                                                v.length < 8)
                                                ? 'Min. 8 characters'
                                                : null,
                                          ),
                                          const SizedBox(height: 18),
                                          SizedBox(
                                            width: double.infinity,
                                            height: 52,
                                            child: ElevatedButton(
                                              onPressed:
                                              _loading ? null : _onSignUp,
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: primary,
                                                foregroundColor: Colors.white,
                                                elevation: 2,
                                                shape:
                                                RoundedRectangleBorder(
                                                  borderRadius:
                                                  BorderRadius.circular(14),
                                                ),
                                              ),
                                              child: _loading
                                                  ? const SizedBox(
                                                width: 22,
                                                height: 22,
                                                child:
                                                CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.white,
                                                ),
                                              )
                                                  : const Text(
                                                'Create account',
                                                style: TextStyle(
                                                  fontWeight:
                                                  FontWeight.w700,
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
                        },
                      ),
                      const SizedBox(height: 14),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                            'Already have an account?  Log in'),
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

// ---- UI helpers (igual que tu Login) ----

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
        boxShadow: const [
          BoxShadow(
            color: Color(0x16000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
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
        contentPadding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
        ),
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
        Positioned(
          top: -60,
          left: -40,
          child: _blob(const Color(0xFF7C75F0).withOpacity(.25), 180),
        ),
        Positioned(
          bottom: -40,
          right: -30,
          child: _blob(const Color(0xFF5B53D6).withOpacity(.22), 160),
        ),
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
        boxShadow: [
          BoxShadow(color: color, blurRadius: 80, spreadRadius: 30),
        ],
      ),
    );
  }
}
