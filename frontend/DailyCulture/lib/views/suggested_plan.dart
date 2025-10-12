// lib/widgets/suggested_plan.dart
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SuggestedPlanCard extends StatefulWidget {
  const SuggestedPlanCard({
    super.key,
    this.lat,
    this.lon,
    this.radiusMeters = 5000,
  });

  /// Si se pasan lat/lon, además de la actividad se buscará un sitio cultural cercano (Wikipedia ES).
  final double? lat;
  final double? lon;
  final int radiusMeters;

  @override
  State<SuggestedPlanCard> createState() => _SuggestedPlanCardState();
}

class _SuggestedPlanCardState extends State<SuggestedPlanCard> {
  bool _loading = false;
  String? _error;

  _Plan? _plan;       // actividad sugerida
  _Nearby? _nearby;   // lugar cercano opcional

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _plan = null;
      _nearby = null;
    });

    try {
      final plan = await _fetchPlan();
      if (!mounted) return;

      _Nearby? near;
      if (widget.lat != null && widget.lon != null) {
        near = await _fetchNearby(widget.lat!, widget.lon!, widget.radiusMeters);
      }

      setState(() {
        _plan = plan;
        _nearby = near;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error de red: $e';
        _loading = false;
      });
    }
  }

  /// Intenta obtener una actividad de BoredAPI con varios fallbacks.
  /// Si todo falla, devuelve una actividad offline.
  Future<_Plan> _fetchPlan() async {
    final headers = {
      'Accept': 'application/json',
      'User-Agent': 'DailyCulture/1.0 (+app)',
    };

    final candidates = <Uri>[
      Uri.https('www.boredapi.com', '/api/activity'),                        // estándar
      Uri.https('boredapi.com', '/api/activity'),                            // dominio alterno
      Uri.https('www.boredapi.com', '/api/activity', {'participants': '1'}), // fuerza participantes=1
      Uri.https('bored-api.appbrewery.com', '/random'),                      // fallback alternativo
    ];

    for (final uri in candidates) {
      try {
        final res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final m = jsonDecode(res.body);
          if (m is Map) {
            final p = _parseAnyPlan(m);
            if (p != null) return p.copyWith(source: _sourceName(uri.host));
          }
        }
      } catch (_) {
        // probamos siguiente
      }
    }

    // --- Fallback offline (si todo falló) ---
    return _offlinePlan();
  }

  String _sourceName(String host) {
    if (host.contains('boredapi')) return 'BoredAPI';
    if (host.contains('appbrewery')) return 'Bored (mirror)';
    return 'fuente';
  }

  /// Acepta distintos formatos de APIs similares.
  _Plan? _parseAnyPlan(Map m) {
    final activity = (m['activity'] ?? m['text'] ?? m['description'] ?? '').toString().trim();
    if (activity.isEmpty) return null;

    final type = (m['type'] ?? m['activity_type'] ?? 'general').toString();
    final participants = (m['participants'] as num? ?? 1).toInt();
    double? price;
    final pv = m['price'];
    if (pv is num) price = pv.toDouble();

    return _Plan(activity: activity, type: type, participants: participants, price: price, source: 'BoredAPI');
  }

  /// Fallback local con una actividad aleatoria en español.
  _Plan _offlinePlan() {
    const options = <_Plan>[
      _Plan(activity: 'Lee un artículo de historia del arte y comenta lo que más te sorprendió.', type: 'education', participants: 1),
      _Plan(activity: 'Explora un museo virtual (Prado/Met) durante 10 minutos.', type: 'recreational', participants: 1),
      _Plan(activity: 'Aprende 5 datos curiosos de tu ciudad y compártelos con un amigo.', type: 'social', participants: 1),
      _Plan(activity: 'Ve un corto de cine europeo y escribe una mini-reseña.', type: 'culture', participants: 1),
      _Plan(activity: 'Escucha una pieza clásica nueva y busca su contexto histórico.', type: 'music', participants: 1),
    ];
    final r = Random().nextInt(options.length);
    return options[r].copyWith(source: 'offline');
  }

  /// Wikipedia ES: geosearch por lat/lon.
  Future<_Nearby?> _fetchNearby(double lat, double lon, int radius) async {
    final q = {
      'action': 'query',
      'list': 'geosearch',
      'gscoord': '$lat|$lon',
      'gsradius': '$radius',
      'gslimit': '10',
      'format': 'json',
      'origin': '*', // necesario para Web
    };
    final uri = Uri.https('es.wikipedia.org', '/w/api.php', q);
    final res = await http.get(uri, headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;

    final map = jsonDecode(res.body);
    final list = (map['query']?['geosearch'] as List?)?.cast<Map>() ?? const [];
    if (list.isEmpty) return null;

    final m = Map<String, dynamic>.from(list.first);
    return _Nearby(
      title: (m['title'] ?? '').toString(),
      distMeters: (m['dist'] is num) ? (m['dist'] as num).toDouble() : null,
      pageId: (m['pageid'] ?? '').toString(),
    );
  }

  void _retry() => _load();

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);

    return Card(
      elevation: 10,
      shadowColor: Colors.black12,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFF0ECE4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // cabecera
            Row(
              children: [
                const Icon(Icons.star_rate_rounded, color: primary),
                const SizedBox(width: 8),
                const Text('Plan sugerido', style: TextStyle(fontWeight: FontWeight.w800)),
                const Spacer(),
                IconButton(
                  tooltip: 'Recargar',
                  onPressed: _loading ? null : _retry,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),

            if (_loading) ...[
              const _SkeletonRow(),
            ] else if (_error != null) ...[
              _InfoPill(icon: Icons.error_outline, text: _error!, subtle: true),
            ] else if (_plan == null) ...[
              const _InfoPill(icon: Icons.explore_outlined, text: 'Sin sugerencia ahora', subtle: true),
            ] else ...[
              _InfoPill(
                icon: Icons.lightbulb_outline,
                text: _plan!.activity,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Chip('Tipo: ${_plan!.type}'),
                  _Chip('Participantes: ${_plan!.participants}'),
                  if (_plan!.price != null) _Chip('Precio ~ ${_priceLabel(_plan!.price!)}'),
                  _Chip('Fuente: ${_plan!.source}'),
                ],
              ),
              if (_nearby != null) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                const Text('Cerca de ti', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                _InfoPill(
                  icon: Icons.place_outlined,
                  text: _nearby!.title +
                      (_nearby!.distMeters != null ? ' • ${( _nearby!.distMeters! / 1000).toStringAsFixed(1)} km' : ''),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _priceLabel(double v) {
    if (v <= 0.05) return 'gratis';
    if (v <= 0.3) return 'bajo';
    if (v <= 0.6) return 'medio';
    return 'alto';
  }
}

/* ===================== modelos y UI helpers ===================== */

class _Plan {
  final String activity;
  final String type;
  final int participants;
  final double? price;
  final String source;

  const _Plan({
    required this.activity,
    required this.type,
    required this.participants,
    this.price,
    this.source = 'BoredAPI',
  });

  _Plan copyWith({String? source}) => _Plan(
    activity: activity,
    type: type,
    participants: participants,
    price: price,
    source: source ?? this.source,
  );
}

class _Nearby {
  final String title;
  final String? pageId;
  final double? distMeters;

  _Nearby({required this.title, this.pageId, this.distMeters});
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: Colors.black12.withOpacity(.05),
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x1A5B53D6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12, color: Color(0xFF5B53D6), fontWeight: FontWeight.w700)),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.text, this.subtle = false});
  final IconData icon;
  final String text;
  final bool subtle;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: subtle ? Colors.white : const Color(0xFFF7F6FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF0ECE4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF5B53D6)),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
