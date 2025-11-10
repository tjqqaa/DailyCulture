// lib/views/view_friends.dart
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'view_login.dart';
import 'view_home.dart'; // ✅ NUEVO: para volver al Home

class FriendsView extends StatefulWidget {
  const FriendsView({super.key});

  @override
  State<FriendsView> createState() => _FriendsViewState();
}

class _FriendsViewState extends State<FriendsView> with SingleTickerProviderStateMixin {
  // ==== BASE URL sin archivo externo ====
  static const String _apiBaseOverride = String.fromEnvironment('API_BASE', defaultValue: '');
  String get _apiBase {
    if (_apiBaseOverride.isNotEmpty) return _apiBaseOverride;
    if (kIsWeb) return 'http://127.0.0.1:8000';
    try {
      if (Platform.isAndroid) return 'http://10.0.2.2:8000';
    } catch (_) {}
    return 'http://127.0.0.1:8000';
  }
  Uri _apiUri(String path) {
    final base = _apiBase.endsWith('/') ? _apiBase.substring(0, _apiBase.length - 1) : _apiBase;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p');
  }

  static const _bg = Color(0xFFFBF7EF);
  static const _primary = Color(0xFF5B53D6);

  final _storage = const FlutterSecureStorage();
  final _userCtrl = TextEditingController();

  String? _token;
  String? _myId;

  bool _loadingAll = false;
  bool _loadingFriends = false;
  bool _loadingReqs = false;
  bool _loadingLeader = false;

  List<_UserBrief> _friends = [];
  List<_FriendItem> _incoming = [];
  List<_FriendItem> _outgoing = [];
  List<_LeaderRow> _leader = [];

  /// Cache para mapear id -> usuario (username/fullName)
  final Map<String, _UserBrief> _userCache = {};

  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _init();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _userCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loadingAll = true);
    final t = await _storage.read(key: 'access_token');
    if (t == null || t.isEmpty) {
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginView()), (_) => false,
      );
      return;
    }
    _token = t;
    _myId = _decodeSub(t);
    await _refreshAll();
    if (mounted) setState(() => _loadingAll = false);
  }

  String? _decodeSub(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      String _pad(String s) {
        var out = s.replaceAll('-', '+').replaceAll('_', '/');
        while (out.length % 4 != 0) { out += '='; }
        return out;
      }
      final payload = utf8.decode(base64.decode(_pad(parts[1])));
      final map = jsonDecode(payload);
      return (map is Map && map['sub'] != null) ? map['sub'].toString() : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _authHeaders() => {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<void> _refreshAll() async {
    await Future.wait([
      _fetchFriends(),
      _fetchRequests(),
      _fetchLeaderboard(),
    ]);
  }

  /* ===================== Navegación a Home (ARREGLO) ===================== */

  void _goHome() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop(); // si se llegó con push, volvemos con pop
    } else {
      // si no hay nada que hacer pop, reemplazamos con Home
      nav.pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeView()),
      );
    }
  }

  Future<bool> _onWillPop() async {
    _goHome();
    return false; // ya gestionado
  }

  /* ===================== API calls ===================== */

  Future<void> _fetchFriends() async {
    setState(() => _loadingFriends = true);
    try {
      final res = await http.get(_apiUri('/friends'), headers: _authHeaders());
      if (res.statusCode == 401) { _toLogin(); return; }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final list = (jsonDecode(res.body) as List).cast<Map>().toList();
      final friends = list.map((m) => _UserBrief.fromJson(Map<String, dynamic>.from(m))).toList();

      setState(() {
        _friends = friends;
        for (final u in friends) {
          _userCache[u.id] = u;
        }
      });
    } catch (_) {
      // silencio UI
    } finally {
      if (mounted) setState(() => _loadingFriends = false);
    }
  }

  Future<void> _fetchRequests() async {
    setState(() => _loadingReqs = true);
    try {
      final res = await http.get(_apiUri('/friends/requests'), headers: _authHeaders());
      if (res.statusCode == 401) { _toLogin(); return; }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final incoming = ((body['incoming'] ?? []) as List)
          .map((e) => _FriendItem.fromJson(Map<String, dynamic>.from(e))).toList();
      final outgoing = ((body['outgoing'] ?? []) as List)
          .map((e) => _FriendItem.fromJson(Map<String, dynamic>.from(e))).toList();

      setState(() {
        _incoming = incoming;
        _outgoing = outgoing;
      });

      // --- Resolver ids desconocidos a username via /users/{id} ---
      final ids = <String>{};
      for (final r in incoming) {
        ids.addAll([r.userAId, r.userBId, r.requestedById]);
      }
      for (final r in outgoing) {
        ids.addAll([r.userAId, r.userBId, r.requestedById]);
      }
      await _ensureUsersLoaded(ids);
    } catch (_) {
      // silencio
    } finally {
      if (mounted) setState(() => _loadingReqs = false);
    }
  }

  Future<void> _fetchLeaderboard() async {
    setState(() => _loadingLeader = true);
    try {
      final res = await http.get(_apiUri('/points/leaderboard/friends?limit=100'), headers: _authHeaders());
      if (res.statusCode == 401) { _toLogin(); return; }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final list = (jsonDecode(res.body) as List).cast<Map>().toList();
      final rows = list.map((m) => _LeaderRow.fromJson(Map<String, dynamic>.from(m))).toList();

      for (final r in rows) {
        _userCache.putIfAbsent(
          r.userId,
              () => _UserBrief(id: r.userId, email: '', username: r.username, fullName: r.fullName),
        );
      }

      setState(() => _leader = rows);
    } catch (_) {
      // silencio
    } finally {
      if (mounted) setState(() => _loadingLeader = false);
    }
  }

  Future<void> _sendRequest() async {
    final uname = _userCtrl.text.trim();
    if (uname.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Escribe un username válido')));
      return;
    }
    try {
      final res = await http.post(
        _apiUri('/friends/request'),
        headers: _authHeaders(),
        body: jsonEncode({'to_username': uname}),
      );
      if (res.statusCode == 401) { _toLogin(); return; }
      if (res.statusCode != 201 && res.statusCode != 200) {
        String msg = 'Error ${res.statusCode}';
        try {
          final b = jsonDecode(res.body);
          if (b is Map && b['detail'] != null) msg = b['detail'].toString();
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        return;
      }
      _userCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Solicitud enviada')));
      await _fetchRequests();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo enviar: $e')));
    }
  }

  Future<void> _accept(String otherUserId) async {
    try {
      final res = await http.post(_apiUri('/friends/$otherUserId/accept'), headers: _authHeaders());
      if (res.statusCode == 401) { _toLogin(); return; }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Solicitud aceptada')));
      await _refreshAll();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al aceptar: $e')));
    }
  }

  Future<void> _decline(String otherUserId) async {
    try {
      final res = await http.post(_apiUri('/friends/$otherUserId/decline'), headers: _authHeaders());
      if (res.statusCode == 401) { _toLogin(); return; }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Solicitud rechazada')));
      await _refreshAll();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al rechazar: $e')));
    }
  }

  Future<void> _remove(String otherUserId) async {
    try {
      final res = await http.delete(_apiUri('/friends/$otherUserId'), headers: _authHeaders());
      if (res.statusCode == 401) { _toLogin(); return; }
      if (res.statusCode != 204 && res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Amistad eliminada')));
      await _refreshAll();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al eliminar: $e')));
    }
  }

  /// Carga en paralelo los usuarios cuyos ids no están en cache
  Future<void> _ensureUsersLoaded(Set<String> ids) async {
    ids.removeWhere((id) => id.isEmpty);
    ids.removeWhere((id) => id == _myId);
    ids.removeWhere((id) => _userCache.containsKey(id));
    if (ids.isEmpty) return;

    try {
      await Future.wait(ids.map((id) async {
        final res = await http.get(_apiUri('/users/$id'), headers: _authHeaders());
        if (res.statusCode == 200) {
          final m = jsonDecode(res.body) as Map<String, dynamic>;
          final u = _UserBrief.fromJson(m);
          _userCache[id] = u;
        }
      }));
      if (mounted) setState(() {}); // refresca nombres en UI
    } catch (_) {
      // ignoramos
    }
  }

  void _toLogin() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginView()), (_) => false,
    );
  }

  String _nameForId(String? id) {
    if (id == null) return 'desconocido';
    if (id == _myId) return 'Tú';
    final u = _userCache[id];
    if (u != null) {
      return u.displayName.startsWith('@') ? u.displayName : '@${u.username}';
    }
    return id;
  }

  /* =========================== UI =========================== */

  @override
  Widget build(BuildContext context) {
    return WillPopScope( // ✅ NUEVO: captura botón físico “atrás”
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          children: [
            const _DecorBackground(),
            SafeArea(
              child: RefreshIndicator(
                color: _primary,
                onRefresh: _refreshAll,
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
                        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 10))],
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Volver',
                            style: IconButton.styleFrom(backgroundColor: Colors.white),
                            onPressed: _goHome, // ✅ antes: Navigator.pop(context)
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
                            child: const Icon(Icons.group_rounded, color: Colors.white, size: 28),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Amigos',
                                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, height: 1.05)),
                                const SizedBox(height: 6),
                                Text(
                                  _loadingAll ? 'Cargando…' : 'Gestiona solicitudes y ranking',
                                  style: TextStyle(color: Colors.white.withOpacity(.95), fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Recargar',
                            style: IconButton.styleFrom(backgroundColor: Colors.white),
                            onPressed: _refreshAll,
                            icon: const Icon(Icons.refresh_rounded, color: Colors.black87),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Tabs
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFF0ECE4)),
                        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 6))],
                      ),
                      child: Column(
                        children: [
                          TabBar(
                            controller: _tabs,
                            labelColor: _primary,
                            unselectedLabelColor: Colors.black87,
                            indicatorColor: _primary,
                            tabs: const [
                              Tab(icon: Icon(Icons.people_alt_rounded), text: 'Amigos'),
                              Tab(icon: Icon(Icons.inbox_rounded), text: 'Solicitudes'),
                              Tab(icon: Icon(Icons.emoji_events_rounded), text: 'Ranking'),
                            ],
                          ),
                          SizedBox(
                            height: 560,
                            child: TabBarView(
                              controller: _tabs,
                              children: [
                                _buildFriendsTab(),
                                _buildRequestsTab(),
                                _buildLeaderboardTab(),
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
      ),
    );
  }

  /* -------------------- Tabs builders -------------------- */

  Widget _buildFriendsTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // enviar solicitud
          Text('Añadir amigo por username', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black.withOpacity(.85))),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _userCtrl,
                  decoration: InputDecoration(
                    hintText: 'p. ej. juan23',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    enabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFFEAE7E0)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _sendRequest,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white70,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Enviar'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Tus amigos', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black.withOpacity(.85))),
          const SizedBox(height: 10),
          if (_loadingFriends)
            const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_friends.isEmpty)
            Text('Aún no tienes amigos.', style: TextStyle(color: Colors.black.withOpacity(.6)))
          else
            Expanded(
              child: ListView.separated(
                itemCount: _friends.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final f = _friends[i];
                  return _FriendCard(
                    title: f.displayName,
                    subtitle: '@${f.username}',
                    trailing: IconButton(
                      tooltip: 'Eliminar amistad',
                      onPressed: () => _remove(f.id),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRequestsTab() {
    final myId = _myId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Entrantes', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black.withOpacity(.85))),
            const SizedBox(height: 10),

            if (_loadingReqs) ...[
              const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2))),
            ] else ...[
              if (_incoming.isEmpty) ...[
                Text('No tienes solicitudes entrantes.', style: TextStyle(color: Colors.black.withOpacity(.6))),
              ] else ...[
                for (final r in _incoming)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _FriendCard(
                      title: 'Solicitud de amistad',
                      subtitle: 'De: ${_nameForId(r.requestedById)}',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Aceptar',
                            onPressed: () => _accept(r.otherUserId(myId)),
                            icon: const Icon(Icons.check_circle_rounded, color: Color(0xFF4CAF50)),
                          ),
                          IconButton(
                            tooltip: 'Rechazar',
                            onPressed: () => _decline(r.otherUserId(myId)),
                            icon: const Icon(Icons.cancel_rounded, color: Color(0xFFE57373)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ],

            const SizedBox(height: 14),
            Text('Enviadas', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black.withOpacity(.85))),
            const SizedBox(height: 10),

            if (_loadingReqs) ...[
              const SizedBox.shrink(),
            ] else ...[
              if (_outgoing.isEmpty) ...[
                Text('No has enviado solicitudes pendientes.', style: TextStyle(color: Colors.black.withOpacity(.6))),
              ] else ...[
                for (final r in _outgoing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _FriendCard(
                      title: 'Solicitud enviada',
                      subtitle: 'A: ${_nameForId(r.otherUserId(myId))}',
                      trailing: TextButton(
                        onPressed: () => _remove(r.otherUserId(myId)),
                        child: const Text('Cancelar'),
                      ),
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLeaderboardTab() {
    final myId = _myId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: _loadingLeader
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _leader.isEmpty
          ? Text('Sin datos de ranking.', style: TextStyle(color: Colors.black.withOpacity(.6)))
          : ListView.separated(
        itemCount: _leader.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final row = _leader[i];
          final isMe = row.userId == myId;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isMe ? const Color(0xFFEDEBFF) : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFF0ECE4)),
              boxShadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 10, offset: Offset(0, 5))],
            ),
            child: Row(
              children: [
                _RankIcon(rank: i + 1),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.displayName, style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text('@${row.username}', style: TextStyle(color: Colors.black.withOpacity(.6))),
                    ],
                  ),
                ),
                Text('${row.points} pts', style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/* -------------------- modelos & widgets internos -------------------- */

class _UserBrief {
  final String id;
  final String email;
  final String username;
  final String? fullName;

  _UserBrief({required this.id, required this.email, required this.username, this.fullName});

  factory _UserBrief.fromJson(Map<String, dynamic> m) => _UserBrief(
    id: m['id'] as String,
    email: m['email'] as String? ?? '',
    username: m['username'] as String,
    fullName: m['full_name'] as String?,
  );

  String get displayName => (fullName != null && fullName!.trim().isNotEmpty) ? fullName! : '@$username';
}

class _FriendItem {
  final String id;
  final String userAId;
  final String userBId;
  final String requestedById;
  final String status;

  _FriendItem({
    required this.id,
    required this.userAId,
    required this.userBId,
    required this.requestedById,
    required this.status,
  });

  factory _FriendItem.fromJson(Map<String, dynamic> m) => _FriendItem(
    id: m['id'] as String,
    userAId: m['user_a_id'] as String,
    userBId: m['user_b_id'] as String,
    requestedById: m['requested_by_id'] as String,
    status: m['status'] as String,
  );

  String otherUserId(String? myId) {
    if (myId == null) return userAId; // fallback
    return userAId == myId ? userBId : userAId;
  }
}

class _LeaderRow {
  final String userId;
  final String username;
  final String? fullName;
  final int points;

  _LeaderRow({required this.userId, required this.username, this.fullName, required this.points});

  factory _LeaderRow.fromJson(Map<String, dynamic> m) => _LeaderRow(
    userId: m['user_id'] as String,
    username: m['username'] as String,
    fullName: m['full_name'] as String?,
    points: (m['points'] as num).toInt(),
  );

  String get displayName => (fullName != null && fullName!.trim().isNotEmpty) ? fullName! : '@$username';
}

class _FriendCard extends StatelessWidget {
  const _FriendCard({required this.title, required this.subtitle, this.trailing});

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF0ECE4)),
        boxShadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 10, offset: Offset(0, 5))],
      ),
      child: Row(
        children: [
          const CircleAvatar(child: Icon(Icons.person)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(subtitle, style: TextStyle(color: Colors.black.withOpacity(.6))),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _RankIcon extends StatelessWidget {
  const _RankIcon({required this.rank});
  final int rank;

  @override
  Widget build(BuildContext context) {
    IconData icon = Icons.emoji_events_rounded;
    Color color;
    switch (rank) {
      case 1: color = const Color(0xFFFFD700); break; // oro
      case 2: color = const Color(0xFFC0C0C0); break; // plata
      case 3: color = const Color(0xFFCD7F32); break; // bronce
      default:
        icon = Icons.tag_rounded;
        color = Colors.black54;
    }
    return Icon(icon, color: color);
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
