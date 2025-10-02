// lib/views/view_profile.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'view_login.dart'; // fallback si no te pasan onSignOut

class ProfileView extends StatefulWidget {
  const ProfileView({
    super.key,
    this.username,
    this.onSignOut,
  });

  final String? username;
  final VoidCallback? onSignOut;

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  // Si tu backend expone /auth/me lo usamos para completar datos
  static const _meUrl =
      'https://dailyculture-bpdmbwahh5axdcd0.spaincentral-01.azurewebsites.net/auth/me';

  final _storage = const FlutterSecureStorage();

  bool _loading = false;
  String? _name;
  String? _email;
  String? _username;
  String? _country;

  @override
  void initState() {
    super.initState();
    _username = widget.username;
    _fetchProfile();
  }

  Future<void> _fetchProfile() async {
    setState(() => _loading = true);
    try {
      final token = await _storage.read(key: 'access_token');
      if (token == null) {
        // No hay sesión: salimos
        await _doLogout();
        return;
      }

      final res = await http.get(
        Uri.parse(_meUrl),
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic>) {
          setState(() {
            _name = (data['name'] ?? data['full_name'] ?? '') as String?;
            _email = (data['email'] ?? '') as String?;
            _username = (data['username'] ?? _username ?? '') as String?;
            _country = (data['country'] ?? data['locale'] ?? '') as String?;
          });
        }
      }
      // si no es 200, simplemente mostramos lo que tengamos (username)
    } catch (_) {
      // ignoramos errores de red para no romper la UI
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _doLogout() async {
    await _storage.delete(key: 'access_token');
    if (widget.onSignOut != null) {
      widget.onSignOut!.call();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginView()),
          (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);
    const bg = Color(0xFFFBF7EF);

    final titleName = _name?.isNotEmpty == true
        ? _name!
        : (_username?.isNotEmpty == true ? _username! : 'Usuario');

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          const _DecorBackground(),
          SafeArea(
            child: RefreshIndicator(
              color: primary,
              onRefresh: _fetchProfile,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 860),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Header
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF7C75F0), Color(0xFF5B53D6)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x22000000),
                                blurRadius: 18,
                                offset: Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(.15),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(.22),
                                  ),
                                ),
                                child: const Icon(Icons.person_rounded,
                                    color: Colors.white, size: 28),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Perfil',
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall
                                            ?.copyWith(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w900,
                                          height: 1.05,
                                          letterSpacing: .2,
                                        )),
                                    const SizedBox(height: 6),
                                    Text(
                                      titleName,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                        color:
                                        Colors.white.withOpacity(.95),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Cerrar sesión',
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.white,
                                ),
                                onPressed: _doLogout,
                                icon: const Icon(Icons.logout_rounded,
                                    color: Colors.black87),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),

                        // Card con datos
                        Card(
                          elevation: 10,
                          shadowColor: Colors.black12,
                          color: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: const BorderSide(color: Color(0xFFF0ECE4)),
                          ),
                          child: Padding(
                            padding:
                            const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 30,
                                      backgroundColor:
                                      primary.withOpacity(.12),
                                      child: const Icon(Icons.person,
                                          color: primary, size: 28),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                        children: [
                                          Text(titleName,
                                              style: const TextStyle(
                                                  fontSize: 18,
                                                  fontWeight:
                                                  FontWeight.w800)),
                                          if (_email?.isNotEmpty == true)
                                            Text(_email!,
                                                style: TextStyle(
                                                    color: Colors.black
                                                        .withOpacity(.6))),
                                          if (_username?.isNotEmpty == true)
                                            Text('@$_username',
                                                style: TextStyle(
                                                    color: Colors.black
                                                        .withOpacity(.5))),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                _InfoRow(label: 'País', value: _country),
                                _InfoRow(
                                    label: 'Email',
                                    value: _email,
                                    isLast: true),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),

                        // Logout grande
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton.icon(
                            onPressed: _doLogout,
                            icon: const Icon(Icons.logout_rounded),
                            label: const Text(
                              'Cerrar sesión',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                letterSpacing: .2,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primary,
                              foregroundColor: Colors.white,
                              elevation: 2,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),

                        if (_loading) ...[
                          const SizedBox(height: 14),
                          const Center(
                            child: SizedBox(
                              height: 22,
                              width: 22,
                              child:
                              CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------- mini componentes y fondo ---------- */
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, this.value, this.isLast = false});
  final String label;
  final String? value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final v = (value == null || value!.isEmpty) ? '—' : value!;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
          bottom: BorderSide(color: Color(0xFFF0ECE4), width: 1),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.black.withOpacity(.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _DecorBackground extends StatelessWidget {
  const _DecorBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BgPainter(),
      child: Container(),
    );
  }
}

class _BgPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFFFDFBF6), Color(0xFFFBF7EF)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(rect);
    canvas.drawRect(rect, paint);

    void blob(Offset c, double r, Color color) {
      final p = Paint()..color = color.withOpacity(.18);
      canvas.drawCircle(c, r, p);
    }

    blob(Offset(size.width * .15, -60), 140, const Color(0xFF7C75F0));
    blob(Offset(size.width * .92, size.height * .90), 120, const Color(0xFF5B53D6));
    blob(Offset(size.width * .8, 100), 80, const Color(0xFF7C75F0));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
