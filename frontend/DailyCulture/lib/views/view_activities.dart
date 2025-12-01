// lib/views/view_activities.dart
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart' as geo;
import 'package:crypto/crypto.dart' show sha1;

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

  // Radio por defecto (m) si la actividad no trae radius_m
  static const double _defaultRadiusM = 1000.0;

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

  // ==== Storage / caché ====
  final _storage = const FlutterSecureStorage();
  static const _kCacheAll = 'activities_cache_all';
  static const _kCacheToday = 'activities_cache_today';
  static const _kCacheDone = 'activities_cache_done';
  static const _kCacheMyPoints = 'my_points_local';

  // Prefijo por usuario (evita contaminación entre sesiones)
  String _userScope = 'anon';
  String _ns(String base) => '$_userScope::$base';

  String? _token;

  late final TabController _tabs;
  bool _loadingAll = false;
  bool _creating = false; // bloquear doble tap

  // Datos
  bool _loadingToday = false;
  bool _loadingOpen = false; // pestaña "Todas"
  bool _loadingDone = false; // pestaña "Completadas"
  List<Activity> _today = [];
  List<Activity> _open = [];
  List<Activity> _done = [];

  // Mis puntos (local, persistente)
  int _myPoints = 0;

  // Creación (bottom sheet)
  final _titleCtrl = TextEditingController();
  final _placeCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lonCtrl = TextEditingController();
  DateTime? _dueDate;
  bool _anyTime = true; // Solo UI
  int _points = 5;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
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

    // Prefijo por usuario a partir del token (10 chars de sha1)
    if (_token != null && _token!.isNotEmpty) {
      final h = sha1.convert(utf8.encode(_token!)).toString().substring(0, 10);
      _userScope = 'u_$h';
    } else {
      _userScope = 'anon';
    }

    // Cargar contador local de puntos
    await _loadMyPoints();

    // 1) Cargar caché para no “parpadear” vacío al entrar
    await _loadCache();

    // 2) Sincronizar con servidor
    await _refreshAll();

    if (mounted) setState(() => _loadingAll = false);
  }

  Map<String, String> _headers({bool jsonBody = false}) => {
    'Accept': 'application/json',
    if (jsonBody) 'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<void> _refreshAll() async {
    await Future.wait([_fetchToday(), _fetchOpen(), _fetchDone()]);
    await _saveCache();
  }

  /* ====================== PUNTOS (LOCAL) ====================== */

  Future<void> _loadMyPoints() async {
    try {
      final s = await _storage.read(key: _ns(_kCacheMyPoints));
      _myPoints = int.tryParse(s ?? '0') ?? 0;
    } catch (_) {
      _myPoints = 0;
    }
  }

  Future<void> _setMyPoints(int v) async {
    _myPoints = v < 0 ? 0 : v;
    await _storage.write(key: _ns(_kCacheMyPoints), value: '$_myPoints');
  }

  Future<void> _addPoints(int delta) async {
    if (delta <= 0) return;
    await _setMyPoints(_myPoints + delta);
  }

  /* ====================== CACHE ====================== */

  Future<void> _loadCache() async {
    try {
      final sAll = await _storage.read(key: _ns(_kCacheAll));
      if (sAll != null && sAll.isNotEmpty) {
        final list = (jsonDecode(sAll) as List)
            .map((e) => Activity.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _open = list;
      }
      final sToday = await _storage.read(key: _ns(_kCacheToday));
      if (sToday != null && sToday.isNotEmpty) {
        final list = (jsonDecode(sToday) as List)
            .map((e) => Activity.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _today = list;
      }
      final sDone = await _storage.read(key: _ns(_kCacheDone));
      if (sDone != null && sDone.isNotEmpty) {
        final list = (jsonDecode(sDone) as List)
            .map((e) => Activity.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _done = list;
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('CACHE LOAD ERROR: $e');
    }
  }

  Future<void> _saveCache() async {
    try {
      await _storage.write(
          key: _ns(_kCacheAll),
          value: jsonEncode(_open.map((a) => a.toJson()).toList()));
      await _storage.write(
          key: _ns(_kCacheToday),
          value: jsonEncode(_today.map((a) => a.toJson()).toList()));
      await _storage.write(
          key: _ns(_kCacheDone),
          value: jsonEncode(_done.map((a) => a.toJson()).toList()));
      // Puntos ya se guardan en _setMyPoints/_addPoints
    } catch (e) {
      debugPrint('CACHE SAVE ERROR: $e');
    }
  }

  /* ====================== FETCH ====================== */

  Future<void> _fetchToday() async {
    setState(() => _loadingToday = true);
    try {
      // Con tu router: GET /activities?status=pending&date=today
      final uri = _apiUri('/activities', {
        'status': 'pending',
        'date': 'today',
        'limit': '200',
        'offset': '0',
      });
      debugPrint('[GET] $uri');
      final res = await http.get(uri, headers: _headers());
      if (res.statusCode == 401) {
        _snack('Sesión inválida. Inicia sesión.');
        return;
      }
      if (res.statusCode != 200) {
        debugPrint('Body: ${res.body}');
        throw Exception('HTTP ${res.statusCode}');
      }

      final decoded = jsonDecode(res.body);
      final items = (decoded as List)
          .map((e) => Activity.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      if (!mounted) return;
      setState(() => _today = items);
    } catch (e, st) {
      debugPrint('ERROR _fetchToday: $e\n$st');
    } finally {
      if (mounted) setState(() => _loadingToday = false);
    }
  }

  // Pendientes
  Future<void> _fetchOpen() async {
    setState(() => _loadingOpen = true);
    try {
      final uri = _apiUri('/activities', {
        'status': 'pending',
        'limit': '200',
        'offset': '0',
      });
      final res = await http.get(uri, headers: _headers());

      if (res.statusCode != 200) {
        debugPrint('Body: ${res.body}');
        throw Exception('HTTP ${res.statusCode}');
      }

      final decoded = jsonDecode(res.body);
      final result = (decoded as List)
          .map((e) => Activity.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      if (!mounted) return;
      setState(() => _open = result);
    } catch (e, st) {
      debugPrint('ERROR _fetchOpen: $e\n$st');
    } finally {
      if (mounted) setState(() => _loadingOpen = false);
    }
  }

  // Completadas
  Future<void> _fetchDone() async {
    setState(() => _loadingDone = true);
    try {
      final uri = _apiUri('/activities', {
        'status': 'done',
        'limit': '200',
        'offset': '0',
      });
      final res = await http.get(uri, headers: _headers());

      if (res.statusCode != 200) {
        debugPrint('Body: ${res.body}');
        throw Exception('HTTP ${res.statusCode}');
      }

      final decoded = jsonDecode(res.body);
      final result = (decoded as List)
          .map((e) => Activity.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      if (!mounted) return;
      setState(() => _done = result);
    } catch (e, st) {
      debugPrint('ERROR _fetchDone: $e\n$st');
    } finally {
      if (mounted) setState(() => _loadingDone = false);
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
        headers: _headers(jsonBody: true),
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
      final hasPlace = (a.placeLat != null && a.placeLon != null);

      Map<String, dynamic> body = {}; // siempre body JSON
      if (hasPlace) {
        final pos = await _currentPosition();
        if (pos == null) {
          _snack('No se pudo obtener tu ubicación.');
          return;
        }
        // El backend valida el radio. Enviamos lat/lon y verify_location=true
        body = {
          'verify_location': true,
          'lat': pos.latitude,
          'lon': pos.longitude,
        };
      }

      final uri = _apiUri('/activities/${a.id}/complete');
      debugPrint('[POST] $uri body=$body');
      final res = await http.post(
        uri,
        headers: _headers(jsonBody: true),
        body: jsonEncode(body),
      );

      if (res.statusCode == 403) {
        // Fuera de zona u otro motivo bloqueante
        final msg = _extractMsg(res, fallback: 'Fuera de la zona permitida.');
        _snack(msg);
        return;
      }

      if (res.statusCode != 200) {
        final msg = _extractMsg(res, fallback: 'No se pudo completar (${res.statusCode}).');
        _snack(msg);
        return;
      }

      // El backend devuelve ActivityOut actualizado
      final updated =
      Activity.fromJson(Map<String, dynamic>.from(jsonDecode(res.body)));

      final awarded = a.pointsOnComplete ?? 0; // server no envía awarded_points
      await _addPoints(awarded);
      _snack('Actividad completada 🎉 +$awarded pts');

      // --- Actualización optimista/servidor ---
      setState(() {
        _open.removeWhere((x) => x.id == a.id);
        _today.removeWhere((x) => x.id == a.id);
        _done.removeWhere((x) => x.id == a.id);
        _done.insert(0, updated);
      });
      await _saveCache();

      // Sincroniza con servidor (por si cambió algo más)
      await _refreshAll();

      // (Opcional) confirma y sincroniza el total del usuario si existe endpoint
      await _showMyTotalPoints();
    } catch (e) {
      _snack('Error de red: $e');
    }
  }

  /// Intenta pedir tu total de puntos y mostrarlo en un snack.
  /// Si responde, sincroniza el contador local.
  Future<void> _showMyTotalPoints() async {
    try {
      final uri = _apiUri('/points/me');
      final res = await http.get(uri, headers: _headers());
      if (res.statusCode == 200 && res.body.isNotEmpty) {
        final m = jsonDecode(res.body);
        final total =
        (m['total'] ?? m['points'] ?? m['current_points'] ?? m['balance']);
        if (total != null) {
          final t =
          (total is num) ? total.toInt() : int.tryParse(total.toString());
          if (t != null) {
            await _setMyPoints(t);
            _snack('Total: $t pts');
          }
        }
      }
    } catch (_) {
      // silencioso
    }
  }

  String _extractMsg(http.Response res, {required String fallback}) {
    try {
      final m = jsonDecode(res.body);
      if (m is Map) {
        if (m['detail'] != null) return m['detail'].toString();
        if (m['message'] != null) return m['message'].toString();
        if (m['error'] != null) return m['error'].toString();
        if (m['errors'] is List && (m['errors'] as List).isNotEmpty) {
          return (m['errors'] as List).first.toString();
        }
      }
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
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(2),
                ),
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
                      final initCenter =
                      (_latCtrl.text.isNotEmpty && _lonCtrl.text.isNotEmpty)
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
                            initialQuery: _placeCtrl.text.isNotEmpty
                                ? _placeCtrl.text
                                : null,
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

              // Fecha + any time (solo UI)
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
                  const Text('Puntos:',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: _points,
                    items: const [1, 3, 5, 10, 15, 20]
                        .map((e) =>
                        DropdownMenuItem(value: e, child: Text('$e')))
                        .toList(),
                    onChanged: (v) => setState(() => _points = v ?? 5),
                  ),
                  const Spacer(),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _primary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _creating ? null : _createActivity,
                    child: _creating
                        ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                        : const Text('Crear'),
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
    if (_creating) return; // anti doble tap
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _snack('Pon un título');
      return;
    }
    final lat = double.tryParse(_latCtrl.text.trim());
    final lon = double.tryParse(_lonCtrl.text.trim());
    final place = _placeCtrl.text.trim();

    // NO enviar any_time (tu API no lo soporta)
    final payload = <String, dynamic>{
      'title': title,
      'kind': 'visit',
      'points_on_complete': _points,
      if (_dueDate != null)
        'due_date': _dueDate!.toIso8601String().split('T').first,
      if (place.isNotEmpty) 'place_name': place,
      if (lat != null) 'place_lat': lat,
      if (lon != null) 'place_lon': lon,
      if (lat != null && lon != null) 'radius_m': _defaultRadiusM.toInt(),
    };

    try {
      setState(() => _creating = true);
      final uri = _apiUri('/activities');
      debugPrint('[POST] $uri\n$payload');
      final res = await http.post(
        uri,
        headers: _headers(jsonBody: true),
        body: jsonEncode(payload),
      );
      if (res.statusCode != 201 && res.statusCode != 200) {
        debugPrint('Create body: ${res.body}');
        _snack(_extractMsg(res, fallback: 'No se pudo crear (${res.statusCode}).'));
        return;
      }

      // Inyección optimista si devuelve el objeto
      try {
        final created =
        Activity.fromJson(Map<String, dynamic>.from(jsonDecode(res.body)));
        setState(() => _open.insert(0, created));
        await _saveCache(); // persistimos la nueva lista
      } catch (_) {}

      if (mounted) Navigator.pop(context);
      _snack('Actividad creada ✅');

      // Sincroniza con servidor por si faltan campos
      await _refreshAll();
    } catch (e) {
      _snack('Error de red: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /* ====================== UI ====================== */

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _prettyDate(DateTime? d) {
    if (d == null) return '—';
    const months = [
      'ene',
      'feb',
      'mar',
      'abr',
      'may',
      'jun',
      'jul',
      'ago',
      'sep',
      'oct',
      'nov',
      'dic'
    ];
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
                  // Header con botón de volver
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
                            offset: Offset(0, 10))
                      ],
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Volver',
                          style: IconButton.styleFrom(
                              backgroundColor: Colors.white),
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back_rounded,
                              color: Colors.black87),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.15),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: Colors.white.withOpacity(.22)),
                          ),
                          child: const Icon(Icons.flag_outlined,
                              color: Colors.white, size: 28),
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
                          style: IconButton.styleFrom(
                              backgroundColor: Colors.white),
                          onPressed: _openCreateSheet,
                          icon: const Icon(Icons.add, color: Colors.black87),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Tabs: Hoy / Todas / Completadas
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFF0ECE4)),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 12,
                            offset: Offset(0, 6))
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
                            Tab(
                                icon: Icon(Icons.today_outlined), text: 'Hoy'),
                            Tab(
                                icon: Icon(Icons.list_alt_outlined),
                                text: 'Todas'),
                            Tab(
                                icon: Icon(Icons.check_circle_outlined),
                                text: 'Completadas'),
                          ],
                        ),
                        SizedBox(
                          height: 560,
                          child: TabBarView(
                            controller: _tabs,
                            children: [
                              _buildList(_today, _loadingToday,
                                  emptyText: 'Sin objetivos para hoy.'),
                              _buildList(_open, _loadingOpen,
                                  emptyText:
                                  'No hay actividades pendientes.'),
                              _buildList(_done, _loadingDone,
                                  emptyText:
                                  'Aún no has completado actividades.',
                                  completedList: true),
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

  // ==== FIX overflow: item con Row + Expanded y límites de ancho ====
  Widget _buildList(
      List<Activity> data,
      bool loading, {
        required String emptyText,
        bool completedList = false,
      }) {
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
        child: Text(emptyText,
            style: TextStyle(color: Colors.black.withOpacity(.6))),
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFF0ECE4)),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x11000000),
                  blurRadius: 10,
                  offset: Offset(0, 5))
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(_iconFor(a), color: _primary),
              const SizedBox(width: 10),

              // Contenido que puede ocupar el espacio restante
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    if ((a.placeName ?? '').trim().isNotEmpty)
                      Text(a.placeName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.black.withOpacity(.65))),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.event_outlined, size: 16),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _prettyDate(a.dueDate),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.black.withOpacity(.65)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.stars_outlined, size: 16),
                        const SizedBox(width: 4),
                        Text('${a.pointsOnComplete ?? 0} pts',
                            style: TextStyle(
                                color: Colors.black.withOpacity(.65))),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              if (!completedList && hasPlace)
                IconButton(
                  tooltip: 'Check-in',
                  constraints:
                  const BoxConstraints(minWidth: 40, minHeight: 40),
                  onPressed: () => _checkin(a),
                  icon: const Icon(Icons.my_location_outlined),
                ),

              // Botón limitado para evitar desbordes
              ConstrainedBox(
                constraints: const BoxConstraints(
                    minHeight: 40, minWidth: 92, maxWidth: 140),
                child: completedList
                    ? OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.check_circle, size: 18),
                  label: const Text('Hecha'),
                )
                    : FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    padding:
                    const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: () => _complete(a),
                  child: const Text('Completar',
                      overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
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
