// lib/views/view_profile.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/user.dart';
import '../models/points.dart';
import 'view_login.dart';

// <<< Lee la base de la API desde --dart-define=API_BASE=...
const String kApiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://127.0.0.1:8000',
);

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
  // Endpoints compatibles con tu backend FastAPI local
  static const _candidateMePaths = <String>['/auth/me'];

  final _storage = const FlutterSecureStorage();

  bool _loading = false;
  User? _user;

  // --- puntos ---
  bool _loadingPoints = false;
  Points? _points;

  @override
  void initState() {
    super.initState();
    _hydrateFromCacheOrClaims();
    _fetchProfile();
    _fetchPoints();
  }

  /* ======================= Hydration local ======================= */

  Future<void> _hydrateFromCacheOrClaims() async {
    final cached = await _storage.read(key: 'user_cache');
    if (cached != null) {
      try {
        final m = jsonDecode(cached);
        if (m is Map<String, dynamic>) setState(() => _user = User.fromMap(m));
      } catch (_) {}
    }

    if (_user == null || _isIncomplete(_user!)) {
      final token = await _storage.read(key: 'access_token');
      if (token != null && token.isNotEmpty) {
        final claims = _decodeJwtClaims(token);
        if (claims.isNotEmpty) {
          final normalized = _normalizeToUserMapFromAny(claims);
          final u = _safeBuildUser(
            normalized,
            usernameFallback: widget.username ?? _user?.username ?? 'usuario',
          );
          setState(() => _user = u);
        }
      }
    }

    if (_user == null && (widget.username?.isNotEmpty ?? false)) {
      setState(() {
        _user = User(
          id: '—',
          email: '—',
          username: widget.username!,
          fullName: null,
          isActive: true,
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        );
      });
    }
  }

  /* ======================== Fetch remoto ========================= */

  Uri _apiUri(String path) {
    final base = kApiBase.endsWith('/') ? kApiBase.substring(0, kApiBase.length - 1) : kApiBase;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p');
  }

  Future<void> _fetchProfile() async {
    setState(() => _loading = true);
    try {
      final token = await _storage.read(key: 'access_token');
      if (token == null || token.isEmpty) {
        await _doLogout();
        return;
      }
      http.Response? ok;
      for (final path in _candidateMePaths) {
        final res = await http.get(
          _apiUri(path),
          headers: {
            HttpHeaders.acceptHeader: 'application/json',
            HttpHeaders.authorizationHeader: 'Bearer $token',
          },
        );
        if (res.statusCode == 200) { ok = res; break; }
        if (res.statusCode == 401) { await _doLogout(); return; }
      }
      if (ok != null) {
        final body = jsonDecode(ok.body);
        Map<String, dynamic> rawUser = {};
        if (body is Map<String, dynamic>) {
          if (body['user'] is Map) {
            rawUser = (body['user'] as Map).cast<String, dynamic>();
          } else if (body['data'] is Map && (body['data'] as Map)['user'] is Map) {
            rawUser = ((body['data'] as Map)['user'] as Map).cast<String, dynamic>();
          } else {
            rawUser = body;
          }
        }
        final normalized = _normalizeToUserMapFromAny(rawUser);
        final fresh = _safeBuildUser(
          normalized,
          usernameFallback: _user?.username ?? widget.username ?? 'usuario',
        );
        setState(() => _user = fresh);
        await _storage.write(key: 'user_cache', value: jsonEncode(fresh.toMap()));
      }
    } catch (_) {
      // silencio
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // --- GET /points/me ---
  Future<void> _fetchPoints() async {
    setState(() => _loadingPoints = true);
    try {
      final token = await _storage.read(key: 'access_token');
      if (token == null || token.isEmpty) {
        await _doLogout();
        return;
      }
      final res = await http.get(
        _apiUri('/points/me'),
        headers: {
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
      );

      if (res.statusCode == 200) {
        final map = jsonDecode(res.body);
        if (map is Map<String, dynamic>) {
          setState(() => _points = Points.fromJson(map));
        }
      } else if (res.statusCode == 401) {
        await _doLogout();
        return;
      }
    } catch (_) {
      // silencio
    } finally {
      if (mounted) setState(() => _loadingPoints = false);
    }
  }

  /* ===================== Normalización modelo ==================== */

  bool _isIncomplete(User u) =>
      u.email == '—' || u.createdAt.millisecondsSinceEpoch == 0;

  Map<String, dynamic> _normalizeToUserMapFromAny(Map<String, dynamic> any) {
    String? pickStr(List keys) {
      for (final k in keys) {
        final v = any[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString();
      }
      return null;
    }
    String? pickDate(List keys) {
      for (final k in keys) {
        final v = any[k];
        if (v == null) continue;
        try {
          if (v is int) return DateTime.fromMillisecondsSinceEpoch(v).toIso8601String();
          final d = DateTime.tryParse(v.toString());
          if (d != null) return d.toIso8601String();
        } catch (_) {}
      }
      return null;
    }

    final id = pickStr(['id','_id','uid','sub','user_id']);
    final email = pickStr(['email','mail']);
    final username = pickStr(['username','user_name','name','preferred_username']);
    final fullName = pickStr(['full_name','fullName','name','given_name']) ?? _joinNames(any);
    final createdAt = pickDate(['created_at','createdAt','created','joined_at','iat']);
    final isActive = (any['is_active'] ?? any['isActive']) ?? true;

    return {
      'id': id ?? '—',
      'email': email ?? '—',
      'username': (username ?? 'usuario').toString(),
      'full_name': fullName,
      'is_active': isActive is bool ? isActive : true,
      'created_at': createdAt ?? DateTime.fromMillisecondsSinceEpoch(0).toIso8601String(),
    };
  }

  String? _joinNames(Map<String, dynamic> m) {
    final f = m['first_name'] ?? m['firstName'];
    final l = m['last_name'] ?? m['lastName'];
    final parts = [f, l].whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(' ');
  }

  User _safeBuildUser(Map<String, dynamic> map, {required String usernameFallback}) {
    map['id'] = map['id'] ?? '—';
    map['email'] = map['email'] ?? '—';
    map['username'] = (map['username'] ?? usernameFallback).toString();
    map['created_at'] = map['created_at'] ?? DateTime.fromMillisecondsSinceEpoch(0).toIso8601String();
    map['is_active'] = (map['is_active'] is bool) ? map['is_active'] : true;
    return User.fromMap(map);
  }

  Map<String, dynamic> _decodeJwtClaims(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final payload = _base64UrlDecode(parts[1]);
      final map = jsonDecode(payload);
      return map is Map<String, dynamic> ? map : {};
    } catch (_) { return {}; }
  }

  String _base64UrlDecode(String input) {
    var out = input.replaceAll('-', '+').replaceAll('_', '/');
    while (out.length % 4 != 0) { out += '='; }
    return utf8.decode(base64.decode(out));
  }

  /* =========================== Logout ========================== */

  Future<void> _doLogout() async {
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'user_cache');
    if (widget.onSignOut != null) { widget.onSignOut!.call(); return; }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginView()),
          (_) => false,
    );
  }

  /* ============================ UI ============================ */

  String _displayName(User u) =>
      (u.fullName != null && u.fullName!.trim().isNotEmpty)
          ? u.fullName!.trim()
          : '@${u.username}';

  String _initials(String display) {
    final p = display.trim().replaceAll('@', '').split(RegExp(r'\s+'));
    final a = p.isNotEmpty && p.first.isNotEmpty ? p.first[0] : '';
    final b = p.length > 1 && p.last.isNotEmpty ? p.last[0] : '';
    final s = (a + b).toUpperCase();
    return s.isEmpty ? 'U' : s;
  }

  String _prettyDate(DateTime d) {
    if (d.millisecondsSinceEpoch == 0) return '—';
    const months = ['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]} ${d.year}';
  }

  Future<void> _refreshAll() async {
    await Future.wait([_fetchProfile(), _fetchPoints()]);
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);
    const bg = Color(0xFFFBF7EF);
    final u = _user;

    final pointsText = _points == null
        ? (_loadingPoints ? 'Cargando…' : '—')
        : '${_points!.total}';

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          const _DecorBackground(),
          SafeArea(
            child: RefreshIndicator(
              color: primary,
              onRefresh: _refreshAll,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 860),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // -------- Header --------
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF7C75F0), Color(0xFF5B53D6)],
                              begin: Alignment.topLeft, end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 10))],
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(.15),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: Colors.white.withOpacity(.22)),
                                ),
                                child: const Icon(Icons.person_rounded, color: Colors.white, size: 28),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Perfil',
                                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                          color: Colors.white, fontWeight: FontWeight.w900, height: 1.05, letterSpacing: .2,
                                        )),
                                    const SizedBox(height: 6),
                                    Text(
                                      u == null ? 'Cargando…' : _displayName(u),
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: Colors.white.withOpacity(.95), fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Cerrar sesión',
                                style: IconButton.styleFrom(backgroundColor: Colors.white),
                                onPressed: _doLogout,
                                icon: const Icon(Icons.logout_rounded, color: Colors.black87),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),

                        // -------- Card info (incluye Puntos) --------
                        Card(
                          elevation: 10,
                          shadowColor: Colors.black12,
                          color: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: const BorderSide(color: Color(0xFFF0ECE4)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            child: u == null
                                ? const _SkeletonProfile()
                                : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 30,
                                      backgroundColor: primary.withOpacity(.12),
                                      child: Text(_initials(_displayName(u)),
                                          style: const TextStyle(fontWeight: FontWeight.w800)),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(_displayName(u),
                                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                                          Text('@${u.username}',
                                              style: TextStyle(color: Colors.black.withOpacity(.5))),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                _InfoRow(label: 'Email', value: u.email),
                                _InfoRow(label: 'Puntos', value: pointsText),
                                _InfoRow(label: 'Creado el', value: _prettyDate(u.createdAt), isLast: true),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),

                        // -------- Logout --------
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton.icon(
                            onPressed: _doLogout,
                            icon: const Icon(Icons.logout_rounded),
                            label: const Text('Cerrar sesión', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: .2)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primary, foregroundColor: Colors.white,
                              elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                          ),
                        ),

                        if (_loading || _loadingPoints) ...[
                          const SizedBox(height: 14),
                          const Center(child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))),
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

/* --------------------------- UI helpers --------------------------- */
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
        border: isLast ? null : const Border(bottom: BorderSide(color: Color(0xFFF0ECE4), width: 1)),
      ),
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(label, style: TextStyle(fontSize: 12, color: Colors.black.withOpacity(.6)))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

class _SkeletonProfile extends StatelessWidget {
  const _SkeletonProfile();
  @override
  Widget build(BuildContext context) {
    Widget bar([double w = 120]) => Container(
      width: w, height: 12, margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: Colors.black12.withOpacity(.08), borderRadius: BorderRadius.circular(6)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(width: 60, height: 60, decoration: BoxDecoration(color: Colors.black12.withOpacity(.08), shape: BoxShape.circle)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar(160), bar(90)])),
        ]),
        const SizedBox(height: 16),
        bar(180), bar(160),
      ],
    );
  }
}

/* ----------------------------- Fondo ----------------------------- */
class _DecorBackground extends StatelessWidget {
  const _DecorBackground();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _BgPainter(), child: Container());
  }
}
class _BgPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFFFDFBF6), Color(0xFFFBF7EF)],
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
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
