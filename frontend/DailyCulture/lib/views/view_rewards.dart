// lib/views/view_rewards.dart
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// ====== MODELOS SENCILLOS ======
class Reward {
  final String id;
  final String title;
  final String? description;
  final int cost;
  final String? icon;
  final bool isActive;

  Reward({
    required this.id,
    required this.title,
    required this.cost,
    this.description,
    this.icon,
    this.isActive = true,
  });

  factory Reward.fromJson(Map<String, dynamic> j) => Reward(
    id: j['id'] as String,
    title: (j['title'] ?? '') as String,
    description: j['description'] as String?,
    cost: (j['cost'] is int) ? j['cost'] as int : int.tryParse('${j['cost']}') ?? 0,
    icon: j['icon'] as String?,
    isActive: j['is_active'] is bool ? j['is_active'] as bool : (j['is_active']?.toString() == 'true'),
  );
}

class Redemption {
  final String id;
  final String rewardId;
  final int pointsCost;
  final String? code;
  final DateTime createdAt;

  Redemption({
    required this.id,
    required this.rewardId,
    required this.pointsCost,
    required this.createdAt,
    this.code,
  });

  factory Redemption.fromJson(Map<String, dynamic> j) => Redemption(
    id: j['id'] as String,
    rewardId: j['reward_id'] as String,
    pointsCost: (j['points_cost'] is int)
        ? j['points_cost'] as int
        : int.tryParse('${j['points_cost']}') ?? 0,
    code: j['code'] as String?,
    createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
  );
}

class RewardsView extends StatefulWidget {
  const RewardsView({super.key});

  @override
  State<RewardsView> createState() => _RewardsViewState();
}

class _RewardsViewState extends State<RewardsView> with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFFFBF7EF);
  static const _primary = Color(0xFF5B53D6);

  // ==== BASE URL (igual patrón que ActivitiesView) ====
  static const String _apiBaseOverride = String.fromEnvironment('API_BASE', defaultValue: '');
  String get _apiBase {
    if (_apiBaseOverride.isNotEmpty) return _apiBaseOverride;
    if (kIsWeb) return 'http://127.0.0.1:8000';
    try {
      if (Platform.isAndroid) return 'http://10.0.2.2:8000';
    } catch (_) {}
    return 'http://127.0.0.1:8000';
  }

  Uri _apiUri(String path, [Map<String, String>? q]) {
    final base = _apiBase.endsWith('/') ? _apiBase.substring(0, _apiBase.length - 1) : _apiBase;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p').replace(queryParameters: q);
  }

  final _storage = const FlutterSecureStorage();
  String? _token;

  late final TabController _tabs;

  bool _loadingAll = false;
  bool _loadingRewards = false;
  bool _loadingMine = false;
  bool _redeeming = false;

  int _myPoints = 0;
  List<Reward> _rewards = [];
  List<Redemption> _mine = [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _init();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loadingAll = true);
    _token = await _storage.read(key: 'access_token');
    await Future.wait([_fetchPoints(), _fetchRewards(), _fetchMyRedemptions()]);
    if (mounted) setState(() => _loadingAll = false);
  }

  Map<String, String> _headers({bool json = false}) => {
    'Accept': 'application/json',
    if (json) 'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<void> _fetchPoints() async {
    try {
      final res = await http.get(_apiUri('/points/me'), headers: _headers());
      if (res.statusCode == 200) {
        final m = jsonDecode(res.body);
        final t = m['total'] ?? m['points'] ?? 0;
        if (mounted) setState(() => _myPoints = (t is num) ? t.toInt() : int.tryParse('$t') ?? 0);
      } else if (res.statusCode == 401) {
        _snack('Sesión inválida. Inicia sesión.');
      } else {
        debugPrint('GET /points/me => ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('ERROR points: $e');
    }
  }

  Future<void> _fetchRewards() async {
    setState(() => _loadingRewards = true);
    try {
      final res = await http.get(_apiUri('/rewards'), headers: _headers());
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final list = (decoded as List).map((e) => Reward.fromJson(Map<String, dynamic>.from(e))).toList();
        if (mounted) setState(() => _rewards = list);
      } else {
        debugPrint('GET /rewards => ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('ERROR rewards: $e');
    } finally {
      if (mounted) setState(() => _loadingRewards = false);
    }
  }

  Future<void> _fetchMyRedemptions() async {
    setState(() => _loadingMine = true);
    try {
      // según tus rutas de Swagger: GET /rewards/me  (o /rewards/redemptions/me si así lo dejaste)
      final res = await http.get(_apiUri('/rewards/me'), headers: _headers());
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final list = (decoded as List)
            .map((e) => Redemption.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        if (mounted) setState(() => _mine = list);
      } else if (res.statusCode == 401) {
        _snack('Sesión inválida. Inicia sesión.');
      } else {
        debugPrint('GET /rewards/me => ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('ERROR my redemptions: $e');
    } finally {
      if (mounted) setState(() => _loadingMine = false);
    }
  }

  Future<void> _redeem(Reward r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Canjear'),
        content: Text('¿Quieres canjear "${r.title}" por ${r.cost} puntos?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Canjear')),
        ],
      ),
    ) ??
        false;
    if (!ok) return;

    if (_redeeming) return;
    if (r.cost > _myPoints) {
      _snack('No tienes puntos suficientes.');
      return;
    }

    setState(() => _redeeming = true);
    try {
      final payload = jsonEncode({'reward_id': r.id});
      final res = await http.post(
        _apiUri('/rewards/redeem'),
        headers: _headers(json: true),
        body: payload,
      );

      if (res.statusCode != 200 && res.statusCode != 201) {
        final msg = _extractMsg(res, fallback: 'No se pudo canjear (${res.statusCode}).');
        _snack(msg);
        return;
      }

      // Parse del canje
      Map<String, dynamic>? m;
      try {
        m = Map<String, dynamic>.from(jsonDecode(res.body));
      } catch (_) {}
      Redemption? red;
      if (m != null) {
        red = Redemption.fromJson(m);
      }

      // Restar puntos localmente (optimista)
      setState(() {
        _myPoints = (_myPoints - r.cost).clamp(0, 1 << 31);
        if (red != null) _mine.insert(0, red!);
      });

      _snack('¡Canje realizado!');
      // Refrescar del servidor por coherencia
      await _fetchPoints();
      await _fetchMyRedemptions();
    } catch (e) {
      _snack('Error de red: $e');
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  String _extractMsg(http.Response res, {required String fallback}) {
    try {
      final m = jsonDecode(res.body);
      if (m is Map) {
        if (m['detail'] != null) return m['detail'].toString();
        if (m['message'] != null) return m['message'].toString();
        if (m['error'] != null) return m['error'].toString();
      }
    } catch (_) {}
    return fallback;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _pretty(DateTime d) {
    final months = ['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'];
    return '${d.day.toString().padLeft(2,'0')} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          const _DecorBackground(),
          SafeArea(
            child: RefreshIndicator(
              color: _primary,
              onRefresh: () async {
                await _fetchPoints();
                await _fetchRewards();
                await _fetchMyRedemptions();
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
                        BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 10))
                      ],
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Volver',
                          style: IconButton.styleFrom(backgroundColor: Colors.white),
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back_rounded, color: Colors.black87),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.15),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white.withOpacity(.22)),
                          ),
                          child: const Icon(Icons.card_giftcard_outlined, color: Colors.white, size: 28),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Recompensas',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      height: 1.05)),
                              const SizedBox(height: 6),
                              Text('Tienes $_myPoints pts',
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_loadingAll)
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Tabs
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFF0ECE4)),
                      boxShadow: const [
                        BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 6))
                      ],
                    ),
                    child: Column(
                      children: [
                        TabBar(
                          controller: _tabs,
                          labelColor: _primary,
                          unselectedLabelColor: Colors.black87,
                          indicatorColor: _primary,
                          tabs: const [
                            Tab(icon: Icon(Icons.redeem_outlined), text: 'Canjear'),
                            Tab(icon: Icon(Icons.history_outlined), text: 'Mis canjes'),
                          ],
                        ),
                        SizedBox(
                          height: 560,
                          child: TabBarView(
                            controller: _tabs,
                            children: [
                              _buildRewardsList(),
                              _buildMyRedemptions(),
                            ],
                          ),
                        ),
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

  Widget _buildRewardsList() {
    if (_loadingRewards) {
      return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_rewards.isEmpty) {
      return Center(child: Text('No hay recompensas disponibles', style: TextStyle(color: Colors.black.withOpacity(.6))));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _rewards.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final r = _rewards[i];
        final can = r.cost <= _myPoints && r.isActive;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFF0ECE4)),
            boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 5))],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: const Color(0xFFEDEBFF),
                child: Text((r.icon ?? '🎁').characters.first, style: const TextStyle(fontSize: 20)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                    if ((r.description ?? '').isNotEmpty)
                      Text(r.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.black.withOpacity(.65))),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.stars_outlined, size: 16),
                        const SizedBox(width: 4),
                        Text('${r.cost} pts', style: TextStyle(color: Colors.black.withOpacity(.7))),
                        if (!r.isActive) ...[
                          const SizedBox(width: 10),
                          const Icon(Icons.lock_clock, size: 16),
                          const SizedBox(width: 4),
                          Text('No disponible', style: TextStyle(color: Colors.black.withOpacity(.6))),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 98, maxWidth: 140, minHeight: 40),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: can ? _primary : Colors.grey.shade400,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: (!can || _redeeming) ? null : () => _redeem(r),
                  child: _redeeming
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Canjear', overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMyRedemptions() {
    if (_loadingMine) {
      return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_mine.isEmpty) {
      return Center(child: Text('Aún no tienes canjes', style: TextStyle(color: Colors.black.withOpacity(.6))));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _mine.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final x = _mine[i];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFF0ECE4)),
            boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 5))],
          ),
          child: Row(
            children: [
              const Icon(Icons.receipt_long_outlined, color: Color(0xFF5B53D6)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Canje ${x.pointsCost} pts', style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.event_outlined, size: 16),
                        const SizedBox(width: 4),
                        Text(_pretty(x.createdAt), style: TextStyle(color: Colors.black.withOpacity(.65))),
                        if ((x.code ?? '').isNotEmpty) ...[
                          const SizedBox(width: 10),
                          const Icon(Icons.qr_code_2, size: 16),
                          const SizedBox(width: 4),
                          Flexible(child: Text('Código: ${x.code}', overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.black.withOpacity(.75)))),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/* ----------------------------- Fondo decorativo ----------------------------- */
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
