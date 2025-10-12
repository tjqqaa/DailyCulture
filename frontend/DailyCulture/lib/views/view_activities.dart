// lib/views/view_activities.dart
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart' as geo;

// Modelo
import 'package:dailyculture/models/activity.dart';
// Picker de mapa + LatLng
import 'package:dailyculture/views/map_picker.dart';
import 'package:latlong2/latlong.dart';

class ActivitiesView extends StatefulWidget {
  const ActivitiesView({super.key});

  @override
  State<ActivitiesView> createState() => _ActivitiesViewState();
}

class _ActivitiesViewState extends State<ActivitiesView>
    with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFFFBF7EF);
  static const _primary = Color(0xFF5B53D6);

  // ==== BASE URL estilo FriendsView ====
  static const String _apiBaseOverride =
  String.fromEnvironment('API_BASE', defaultValue: '');
  String get _apiBase {
    if (_apiBaseOverride.isNotEmpty) return _apiBaseOverride;
    if (kIsWeb) return 'http://127.0.0.1:8000';
    try {
      if (Platform.isAndroid) return 'http://10.0.2.2:8000';
    } catch (_) {}
    return 'http://127.0.0.1:8000';
  }

  Uri _apiUri(String path, [Map<String, String>? q]) {
    final base =
    _apiBase.endsWith('/') ? _apiBase.substring(0, _apiBase.length - 1) : _apiBase;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p').replace(queryParameters: q);
  }

  final _storage = const FlutterSecureStorage();
  String? _token;

  late final TabController _tabs;
  bool _loadingAll = false;

  // Datos
  bool _loadingToday = false;
  bool _loadingOpen = false;
  List<Activity> _today = [];
  List<Activity> _open = [];

  // Creación (bottom sheet)
  final _titleCtrl = TextEditingController();
  final _placeCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lonCtrl = TextEditingController();
  DateTime? _dueDate;
  bool _anyTime = true;
  int _points = 5;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _init();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _titleCtrl.dispose();
    _placeCtrl.dispose();
    _latCtrl.dispose();
    _lonCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loadingAll = true);
    _token = await _storage.read(key: 'access_token');
    await _refreshAll();
    if (mounted) setState(() => _loadingAll = false);
  }

  Map<String, String> _headers() => {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<void> _refreshAll() async {
    await Future.wait([_fetchToday(), _fetchOpen()]);
  }

  /* ====================== FETCH ====================== */

  Future<void> _fetchToday() async {
    setState(() => _loadingToday = true);
    try {
      final res = await http.get(_apiUri('/activities/today'), headers: _headers());
      if (res.statusCode == 401) {
        _snack('Sesión inválida. Inicia sesión.');
        return;
      }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final list = (jsonDecode(res.body) as List).cast<Map>().toList();
      final items =
      list.map((m) => Activity.fromJson(Map<String, dynamic>.from(m))).toList();
      if (!mounted) return;
      setState(() => _today = items);
    } catch (_) {
      // silencio en UI
    } finally {
      if (mounted) setState(() => _loadingToday = false);
    }
  }

  Future<void> _fetchOpen() async {
    setState(() => _loadingOpen = true);
    try {
      final res =
      await http.get(_apiUri('/activities', {'status': 'open'}), headers: _headers());
      if (res.statusCode == 401) {
        _snack('Sesión inválida. Inicia sesión.');
        return;
      }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final list = (jsonDecode(res.body) as List).cast<Map>().toList();
      final items =
      list.map((m) => Activity.fromJson(Map<String, dynamic>.from(m))).toList();
      if (!mounted) return;
      setState(() => _open = items);
    } catch (_) {
      // silencio
    } finally {
      if (mounted) setState(() => _loadingOpen = false);
    }
  }

  /* ====================== ACTIONS ====================== */

  Future<geo.Position?> _currentPosition() async {
    try {
      var perm = await geo.Geolocator.checkPermission();
      if (perm == geo.LocationPermission.denied) {
        perm = await geo.Geolocator.requestPermission();
      }
      if (perm == geo.LocationPermission.denied ||
          perm == geo.LocationPermission.deniedForever) {
        _snack('Permiso de ubicación denegado.');
        return null;
      }
      return await geo.Geolocator.getCurrentPosition(
        desiredAccuracy: geo.LocationAccuracy.high,
      );
    } catch (e) {
      _snack('No se pudo obtener la ubicación: $e');
      return null;
    }
  }

  Future<void> _checkin(Activity a) async {
    try {
      final pos = await _currentPosition();
      if (pos == null) return;
      final body = jsonEncode({'lat': pos.latitude, 'lon': pos.longitude});
      final res = await http.post(
        _apiUri('/activities/${a.id}/checkin'),
        headers: _headers(),
        body: body,
      );
      if (res.statusCode != 200) {
        final msg = _extractMsg(res, fallback: 'Check-in falló (${res.statusCode}).');
        _snack(msg);
        return;
      }
      _snack('Check-in enviado ✅');
      await _refreshAll();
    } catch (e) {
      _snack('Error de red: $e');
    }
  }

  Future<void> _complete(Activity a) async {
    try {
      String path = '/activities/${a.id}/complete';
      Map<String, String>? q;

      // Si la actividad tiene geocerca, intentamos verificar ubicación
      if (a.placeLat != null && a.placeLon != null) {
        final pos = await _currentPosition();
        if (pos != null) {
          q = {
            'verify_location': 'true',
            'lat': pos.latitude.toString(),
            'lon': pos.longitude.toString(),
          };
        }
      }

      final res = await http.post(_apiUri(path, q), headers: _headers());
      if (res.statusCode != 200) {
        final msg =
        _extractMsg(res, fallback: 'No se pudo completar (${res.statusCode}).');
        _snack(msg);
        return;
      }
      _snack('Actividad completada 🎉 +${a.pointsOnComplete ?? 0} pts');
      await _refreshAll();
    } catch (e) {
      _snack('Error de red: $e');
    }
  }

  String _extractMsg(http.Response res, {required String fallback}) {
    try {
      final m = jsonDecode(res.body);
      if (m is Map && m['detail'] != null) return m['detail'].toString();
    } catch (_) {}
    return fallback;
  }

  /* ====================== CREATE ====================== */

  Future<void> _openCreateSheet() async {
    _titleCtrl.clear();
    _placeCtrl.clear();
    _latCtrl.clear();
    _lonCtrl.clear();
    _dueDate = null;
    _anyTime = true;
    _points = 5;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 4,
                width: 44,
                margin: const EdgeInsets.only(bottom: 14),
                decoration:
                BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(2)),
              ),
              const Text('Nueva actividad',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              const SizedBox(height: 12),
              TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Título',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),

              // Lugar + mi ubicación + mapa
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _placeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Lugar (opcional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Usar mi ubicación',
                    onPressed: () async {
                      final pos = await _currentPosition();
                      if (pos != null) {
                        _latCtrl.text = pos.latitude.toStringAsFixed(6);
                        _lonCtrl.text = pos.longitude.toStringAsFixed(6);
                        setState(() {});
                      }
                    },
                    icon: const Icon(Icons.my_location_rounded),
                  ),
                  IconButton(
                    tooltip: 'Elegir en mapa',
                    onPressed: () async {
                      final initCenter = (_latCtrl.text.isNotEmpty && _lonCtrl.text.isNotEmpty)
                          ? LatLng(
                        double.tryParse(_latCtrl.text) ?? 40.4168,
                        double.tryParse(_lonCtrl.text) ?? -3.7038,
                      )
                          : null;

                      final res = await Navigator.push<MapPickResult>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MapPickerPage(
                            initialCenter: initCenter,
                            initialQuery:
                            _placeCtrl.text.isNotEmpty ? _placeCtrl.text : null,
                          ),
                        ),
                      );

                      if (res != null) {
                        _latCtrl.text = res.lat.toStringAsFixed(6);
                        _lonCtrl.text = res.lon.toStringAsFixed(6);
                        if ((res.displayName ?? '').isNotEmpty) {
                          _placeCtrl.text = res.displayName!;
                        }
                        setState(() {});
                      }
                    },
                    icon: const Icon(Icons.map_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Lat / Lon manual
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _latCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      decoration: const InputDecoration(
                        labelText: 'Lat (opcional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _lonCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      decoration: const InputDecoration(
                        labelText: 'Lon (opcional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Fecha + any time
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final now = DateTime.now();
                        final picked = await showDatePicker(
                          context: ctx,
                          firstDate: DateTime(now.year - 1),
                          lastDate: DateTime(now.year + 3),
                          initialDate: _dueDate ?? now,
                        );
                        if (picked != null) {
                          setState(() => _dueDate = picked);
                        }
                      },
                      icon: const Icon(Icons.event_outlined),
                      label: Text(
                        _dueDate == null
                            ? 'Fecha (opcional)'
                            : '${_dueDate!.day.toString().padLeft(2, '0')}/'
                            '${_dueDate!.month.toString().padLeft(2, '0')}/'
                            '${_dueDate!.year}',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Cualquier hora'),
                      Switch(
                        value: _anyTime,
                        onChanged: (v) => setState(() => _anyTime = v),
                        activeColor: _primary,
                      ),
                    ],
                  )
                ],
              ),
              const SizedBox(height: 10),

              // Puntos + Crear
              Row(
                children: [
                  const Text('Puntos:', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: _points,
                    items: const [1, 3, 5, 10, 15, 20]
                        .map((e) => DropdownMenuItem(value: e, child: Text('$e')))
                        .toList(),
                    onChanged: (v) => setState(() => _points = v ?? 5),
                  ),
                  const Spacer(),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _primary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _createActivity,
                    child: const Text('Crear'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _createActivity() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _snack('Pon un título');
      return;
    }
    final lat = double.tryParse(_latCtrl.text.trim());
    final lon = double.tryParse(_lonCtrl.text.trim());
    final place = _placeCtrl.text.trim();

    final payload = <String, dynamic>{
      'title': title,
      'kind': 'visit', // o 'read', 'watch', etc.
      'any_time': _anyTime,
      'points_on_complete': _points,
      if (_dueDate != null) 'due_date': _dueDate!.toIso8601String().split('T').first,
      if (place.isNotEmpty) 'place_name': place,
      if (lat != null) 'place_lat': lat,
      if (lon != null) 'place_lon': lon,
    };

    // Solo añadir radius si hay lat y lon
    if (lat != null && lon != null) {
      payload['radius_m'] = 200;
    }

    try {
      final res = await http.post(
        _apiUri('/activities'),
        headers: _headers(),
        body: jsonEncode(payload),
      );
      if (res.statusCode != 201 && res.statusCode != 200) {
        _snack(_extractMsg(res, fallback: 'No se pudo crear (${res.statusCode}).'));
        return;
      }
      if (mounted) Navigator.pop(context); // cerrar sheet
      _snack('Actividad creada ✅');
      await _refreshAll();
    } catch (e) {
      _snack('Error de red: $e');
    }
  }

  /* ====================== UI ====================== */

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _prettyDate(DateTime? d) {
    if (d == null) return '—';
    const months = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]} ${d.year}';
  }

  IconData _iconFor(Activity a) {
    final k = (a.kind ?? '').toLowerCase();
    if (k.contains('visit')) return Icons.place_outlined;
    if (k.contains('read')) return Icons.menu_book_outlined;
    if (k.contains('watch')) return Icons.ondemand_video_outlined;
    if (k.contains('listen')) return Icons.headphones_outlined;
    return Icons.task_alt_outlined;
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
              onRefresh: _refreshAll,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  // Header (sin cards)
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
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.15),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white.withOpacity(.22)),
                          ),
                          child: const Icon(Icons.flag_outlined, color: Colors.white, size: 28),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Actividades',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      height: 1.05)),
                              SizedBox(height: 6),
                              Text('Tu lista diaria y próximas tareas',
                                  style: TextStyle(
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Nueva actividad',
                          style: IconButton.styleFrom(backgroundColor: Colors.white),
                          onPressed: _openCreateSheet,
                          icon: const Icon(Icons.add, color: Colors.black87),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Tabs minimalistas
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
                            Tab(icon: Icon(Icons.today_outlined), text: 'Hoy'),
                            Tab(icon: Icon(Icons.list_alt_outlined), text: 'Todas'),
                          ],
                        ),
                        SizedBox(
                          height: 560,
                          child: TabBarView(
                            controller: _tabs,
                            children: [
                              _buildList(_today, _loadingToday, emptyText: 'Sin objetivos para hoy.'),
                              _buildList(_open, _loadingOpen, emptyText: 'No hay actividades pendientes.'),
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

  Widget _buildList(List<Activity> data, bool loading, {required String emptyText}) {
    if (loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (data.isEmpty) {
      return Center(
        child: Text(emptyText, style: TextStyle(color: Colors.black.withOpacity(.6))),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: data.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final a = data[i];
        final hasPlace = (a.placeLat != null && a.placeLon != null);
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFF0ECE4)),
            boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 5))],
          ),
          child: ListTile(
            leading: Icon(_iconFor(a), color: _primary),
            title: Text(a.title, style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (a.placeName != null && a.placeName!.trim().isNotEmpty)
                  Text(a.placeName!, style: TextStyle(color: Colors.black.withOpacity(.65))),
                Row(
                  children: [
                    const Icon(Icons.event_outlined, size: 16),
                    const SizedBox(width: 4),
                    Text(_prettyDate(a.dueDate),
                        style: TextStyle(color: Colors.black.withOpacity(.65))),
                    const SizedBox(width: 12),
                    const Icon(Icons.stars_outlined, size: 16),
                    const SizedBox(width: 4),
                    Text('${a.pointsOnComplete ?? 0} pts',
                        style: TextStyle(color: Colors.black.withOpacity(.65))),
                  ],
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasPlace)
                  IconButton(
                    tooltip: 'Check-in',
                    onPressed: () => _checkin(a),
                    icon: const Icon(Icons.my_location_outlined),
                  ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => _complete(a),
                  child: const Text('Completar'),
                ),
              ],
            ),
          ),
        );
      },
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
