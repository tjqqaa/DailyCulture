// lib/views/view_objectives.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Pantalla de Objetivos (metas diarias/semanales con progreso)
class ObjectivesView extends StatefulWidget {
  const ObjectivesView({super.key});

  @override
  State<ObjectivesView> createState() => _ObjectivesViewState();
}

class _ObjectivesViewState extends State<ObjectivesView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _bg = Color(0xFFFBF7EF);
  static const _primary = Color(0xFF5B53D6);

  // ==== BASE URL (igual estilo que otras vistas) ====
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

  // ==== Storage claves ====
  final _storage = const FlutterSecureStorage();
  static const _kGoalDailyActivities = 'goal_daily_activities';
  static const _kGoalWeeklyActivities = 'goal_weekly_activities'; // ✅ nuevo
  static const _kGoalWeeklyPoints = 'goal_weekly_points';
  static const _kReminderDaily = 'goal_reminder_daily';
  String? _token;

  // Estado
  bool _loading = false;

  // Puntos totales (saldo)
  int _myPoints = 0;

  // ---- Diario ----
  int _todayCompleted = 0;
  int _todayPoints = 0;

  // ---- Semanal ----
  int _weekCompleted = 0;
  int _weekPoints = 0;

  // Metas guardadas localmente
  int _goalDailyActivities = 1;
  int _goalWeeklyActivities = 7; // ✅ nuevo
  int _goalWeeklyPoints = 100;
  bool _reminderDaily = true;

  late final TabController _tabs;

  // Timers para reset automático
  Timer? _midnightTimer;
  Timer? _weekTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabs = TabController(length: 2, vsync: this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    _midnightTimer?.cancel();
    _weekTimer?.cancel();
    super.dispose();
  }

  // Refresca cuando la app vuelve al primer plano
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    _token = await _storage.read(key: 'access_token');
    await _loadLocalGoals();
    await _refresh();
    _scheduleMidnightRefresh();
    _scheduleWeekRefresh();
    if (mounted) setState(() => _loading = false);
  }

  Map<String, String> _headers({bool jsonBody = false}) => {
    'Accept': 'application/json',
    if (jsonBody) 'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<void> _refresh() async {
    await Future.wait([
      _fetchPointsBalance(),
      _fetchTodayProgress(),
      _fetchWeeklyProgress(),
    ]);
  }

  Future<void> _fetchPointsBalance() async {
    try {
      final res = await http.get(_apiUri('/points/me'), headers: _headers());
      if (res.statusCode == 200) {
        final m = jsonDecode(res.body);
        setState(() => _myPoints = (m['total'] ?? m['points'] ?? 0) as int);
      } else if (res.statusCode == 401) {
        _snack('Sesión inválida. Inicia sesión.');
      }
    } catch (e) {
      debugPrint('POINTS BALANCE ERR: $e');
    }
  }

  /// --- Progreso diario: actividades y puntos de HOY ---
  Future<void> _fetchTodayProgress() async {
    try {
      final res = await http.get(
        _apiUri('/activities', {
          'status': 'done',
          'limit': '300',
        }),
        headers: _headers(),
      );

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final list = (decoded is List ? decoded : (decoded['items'] ?? [])) as List;

        final now = DateTime.now();
        int doneToday = 0;
        int ptsToday = 0;

        for (final it in list) {
          final m = Map<String, dynamic>.from(it as Map);
          final isDone = (m['is_done'] ?? m['isDone'] ?? false) == true;
          if (!isDone) continue;

          final doneAtStr = (m['done_at'] ?? m['doneAt']) as String?;
          if (doneAtStr == null) continue;

          final doneAt = DateTime.tryParse(doneAtStr)?.toLocal();
          if (doneAt != null && _isSameDay(doneAt, now)) {
            doneToday++;
            ptsToday += (m['points_on_complete'] ?? m['pointsOnComplete'] ?? 0) as int;
          }
        }

        setState(() {
          _todayCompleted = doneToday;
          _todayPoints = ptsToday;
        });
      }
    } catch (e) {
      debugPrint('TODAY ERR: $e');
    }
  }

  /// --- Progreso semanal: actividades y puntos de ESTA SEMANA ---
  Future<void> _fetchWeeklyProgress() async {
    try {
      final res = await http.get(
        _apiUri('/activities', {
          'status': 'done',
          'limit': '600',
        }),
        headers: _headers(),
      );

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final list = (decoded is List ? decoded : (decoded['items'] ?? [])) as List;

        final now = DateTime.now();
        final start = _startOfWeek(now); // Lunes 00:00
        final end = _endOfWeek(now); // Próximo lunes 00:00

        int completed = 0;
        int points = 0;

        for (final it in list) {
          final m = Map<String, dynamic>.from(it as Map);
          final isDone = (m['is_done'] ?? m['isDone'] ?? false) == true;
          if (!isDone) continue;

          final doneAtStr = (m['done_at'] ?? m['doneAt']) as String?;
          if (doneAtStr == null) continue;

          final doneAt = DateTime.tryParse(doneAtStr)?.toLocal();
          if (doneAt == null) continue;

          if (!doneAt.isBefore(start) && doneAt.isBefore(end)) {
            completed++;
            points += (m['points_on_complete'] ?? m['pointsOnComplete'] ?? 0) as int;
          }
        }

        setState(() {
          _weekCompleted = completed;
          _weekPoints = points;
        });
      }
    } catch (e) {
      debugPrint('WEEK ERR: $e');
    }
  }

  // Helpers de fechas
  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  DateTime _startOfWeek(DateTime d) {
    final local = d;
    final weekday = local.weekday; // 1=lunes ... 7=domingo
    final diff = weekday - DateTime.monday;
    final start = DateTime(local.year, local.month, local.day).subtract(Duration(days: diff));
    return DateTime(start.year, start.month, start.day); // 00:00
  }

  DateTime _endOfWeek(DateTime d) {
    final start = _startOfWeek(d);
    return start.add(const Duration(days: 7)); // lunes siguiente 00:00
  }

  // Timers
  Duration _timeUntilMidnight() {
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    return nextMidnight.difference(now);
  }

  void _scheduleMidnightRefresh() {
    _midnightTimer?.cancel();
    _midnightTimer = Timer(_timeUntilMidnight(), () async {
      if (mounted) {
        setState(() {
          _todayCompleted = 0;
          _todayPoints = 0;
        });
      }
      await _refresh();
      _scheduleMidnightRefresh();
    });
  }

  Duration _timeUntilNextWeek() {
    final now = DateTime.now();
    final end = _endOfWeek(now); // próximo lunes 00:00
    return end.difference(now);
  }

  void _scheduleWeekRefresh() {
    _weekTimer?.cancel();
    _weekTimer = Timer(_timeUntilNextWeek(), () async {
      if (mounted) {
        setState(() {
          _weekCompleted = 0;
          _weekPoints = 0;
        });
      }
      await _refresh();
      _scheduleWeekRefresh();
    });
  }

  Future<void> _loadLocalGoals() async {
    try {
      _goalDailyActivities =
          int.tryParse(await _storage.read(key: _kGoalDailyActivities) ?? '') ??
              _goalDailyActivities;

      _goalWeeklyActivities =
          int.tryParse(await _storage.read(key: _kGoalWeeklyActivities) ?? '') ??
              _goalWeeklyActivities; // ✅ nuevo

      _goalWeeklyPoints =
          int.tryParse(await _storage.read(key: _kGoalWeeklyPoints) ?? '') ??
              _goalWeeklyPoints;

      _reminderDaily =
          (await _storage.read(key: _kReminderDaily)) != 'false'; // por defecto true
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _saveGoals() async {
    await _storage.write(key: _kGoalDailyActivities, value: '$_goalDailyActivities');
    await _storage.write(key: _kGoalWeeklyActivities, value: '$_goalWeeklyActivities'); // ✅
    await _storage.write(key: _kGoalWeeklyPoints, value: '$_goalWeeklyPoints');
    await _storage.write(key: _kReminderDaily, value: '$_reminderDaily');
    _snack('Metas guardadas');
  }

  // Progresos (0..1)
  double get _dailyProgress =>
      _goalDailyActivities <= 0
          ? 0
          : (_todayCompleted / _goalDailyActivities).clamp(0, 1).toDouble();

  double get _weeklyActivitiesProgress =>
      _goalWeeklyActivities <= 0
          ? 0
          : (_weekCompleted / _goalWeeklyActivities).clamp(0, 1).toDouble(); // ✅ nuevo

  double get _weeklyPointsProgress =>
      _goalWeeklyPoints <= 0 ? 0 : (_weekPoints / _goalWeeklyPoints).clamp(0, 1).toDouble();

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
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  _Header(onBack: () => Navigator.pop(context), points: _myPoints),
                  const SizedBox(height: 12),
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
                            Tab(icon: Icon(Icons.insights_outlined), text: 'Resumen'),
                            Tab(icon: Icon(Icons.flag_outlined), text: 'Metas'),
                          ],
                        ),
                        SizedBox(
                          height: 700,
                          child: _loading
                              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                              : TabBarView(
                            controller: _tabs,
                            children: [
                              _buildSummary(),
                              _buildGoals(),
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

  Widget _buildSummary() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      children: [
        // ---------- Diario ----------
        _Card(
          child: Row(
            children: [
              const _IconBox(icon: Icons.today_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Resumen diario', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _dailyProgress,
                      minHeight: 10,
                      backgroundColor: Colors.black12.withOpacity(.06),
                      valueColor: const AlwaysStoppedAnimation(_primary),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    const SizedBox(height: 6),
                    Text('$_todayCompleted / $_goalDailyActivities actividades'),
                    const SizedBox(height: 2),
                    Text('$_todayPoints puntos ganados hoy',
                        style: TextStyle(color: Colors.black.withOpacity(.7))),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ---------- Semanal (como el diario) ----------
        _Card(
          child: Row(
            children: [
              const _IconBox(icon: Icons.calendar_month_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Resumen semanal', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _weeklyActivitiesProgress, // ✅ por actividades
                      minHeight: 10,
                      backgroundColor: Colors.black12.withOpacity(.06),
                      valueColor: const AlwaysStoppedAnimation(_primary),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    const SizedBox(height: 6),
                    Text('$_weekCompleted / $_goalWeeklyActivities actividades'),
                    const SizedBox(height: 2),
                    Text('$_weekPoints puntos ganados esta semana',
                        style: TextStyle(color: Colors.black.withOpacity(.7))),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ---------- Puntos totales ----------
        _Card(
          child: Row(
            children: [
              const _IconBox(icon: Icons.stars_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Tus puntos', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text('$_myPoints pts',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text('Meta semanal: $_goalWeeklyPoints pts'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        _TipsCard(goalDaily: _goalDailyActivities),
      ],
    );
  }

  Widget _buildGoals() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      children: [
        _Card(
          child: Row(
            children: [
              const _IconBox(icon: Icons.flag_circle_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Meta diaria (actividades)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _Stepper(
                          value: _goalDailyActivities,
                          min: 1,
                          max: 10,
                          onChanged: (v) => setState(() {
                            _goalDailyActivities = v;
                            // Opcional: sincroniza la semanal de actividades
                            // con la diaria × 7
                            // _goalWeeklyActivities = v * 7;
                          }),
                        ),
                        const SizedBox(width: 8),
                        Text('$_goalDailyActivities / día'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ✅ Nueva meta: semanal de actividades
        _Card(
          child: Row(
            children: [
              const _IconBox(icon: Icons.event_available_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Meta semanal (actividades)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _Stepper(
                          value: _goalWeeklyActivities,
                          min: 1,
                          max: 70,
                          onChanged: (v) => setState(() => _goalWeeklyActivities = v),
                        ),
                        const SizedBox(width: 8),
                        Text('$_goalWeeklyActivities / semana'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        _Card(
          child: Row(
            children: [
              const _IconBox(icon: Icons.stacked_line_chart_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Meta semanal (puntos)',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _Stepper(
                          value: _goalWeeklyPoints,
                          step: 10,
                          min: 20,
                          max: 2000,
                          onChanged: (v) => setState(() => _goalWeeklyPoints = v),
                        ),
                        const SizedBox(width: 8),
                        Text('$_goalWeeklyPoints pts/semana'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        _Card(
          child: Row(
            children: [
              const _IconBox(icon: Icons.notifications_active_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('Recordatorio diario', style: TextStyle(fontWeight: FontWeight.w800)),
                    SizedBox(height: 6),
                    Text('Recibe un aviso para cumplir tu meta diaria.'),
                  ],
                ),
              ),
              Switch(
                value: _reminderDaily,
                activeColor: _primary,
                onChanged: (v) => setState(() => _reminderDaily = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: _primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: _saveGoals,
          icon: const Icon(Icons.save_outlined),
          label: const Text('Guardar'),
        ),
      ],
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// ----------------- Widgets de apoyo -----------------
class _Header extends StatelessWidget {
  const _Header({required this.onBack, required this.points});
  final VoidCallback onBack;
  final int points;

  @override
  Widget build(BuildContext context) {
    return Container(
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
            onPressed: onBack,
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
            child: const Icon(Icons.flag_outlined, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Objetivos',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        height: 1.05)),
                SizedBox(height: 6),
                Text('Define tus metas y mide tu progreso',
                    style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Row(
              children: [
                const Icon(Icons.stars_rounded, color: Color(0xFF5B53D6), size: 18),
                const SizedBox(width: 6),
                Text('$points pts',
                    style: const TextStyle(color: Color(0xFF5B53D6), fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF0ECE4)),
        boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 5))],
      ),
      child: child,
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      width: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF5B53D6).withOpacity(.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: const Color(0xFF5B53D6)),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.value,
    required this.onChanged,
    this.step = 1,
    this.min = 0,
    this.max = 9999,
  });

  final int value;
  final int step;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton.filledTonal(
          onPressed: value - step >= min ? () => onChanged(value - step) : null,
          icon: const Icon(Icons.remove),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text('$value', style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
        IconButton.filled(
          onPressed: value + step <= max ? () => onChanged(value + step) : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

class _TipsCard extends StatelessWidget {
  const _TipsCard({required this.goalDaily});
  final int goalDaily;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _IconBox(icon: Icons.lightbulb_outline_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Consejo', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(
                  goalDaily <= 2
                      ? 'Empieza con metas pequeñas para crear hábito y luego súbelas.'
                      : '¡Vas fuerte! Mantén la racha con descansos estratégicos.',
                  style: TextStyle(color: Colors.black.withOpacity(.75)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Fondo decorativo (igual estilo que otras vistas)
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
