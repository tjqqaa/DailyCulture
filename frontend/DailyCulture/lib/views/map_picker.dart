// lib/widgets/map_picker.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Resultado que devolvemos al cerrar el selector
class MapPickResult {
  final double lat;
  final double lon;
  final String? displayName;
  const MapPickResult({
    required this.lat,
    required this.lon,
    this.displayName,
  });
}

/// Página selector de ubicación con flutter_map + Nominatim
class MapPickerPage extends StatefulWidget {
  const MapPickerPage({
    super.key,
    this.initialCenter,          // <- sin default no-const
    this.initialZoom = 14,
    this.initialQuery,
  });

  final LatLng? initialCenter;   // <- nullable
  final double initialZoom;
  final String? initialQuery;

  @override
  State<MapPickerPage> createState() => _MapPickerPageState();
}

class _MapPickerPageState extends State<MapPickerPage> {
  final _map = MapController();
  final _searchCtrl = TextEditingController();

  LatLng _center = LatLng(40.4168, -3.7038); // valor inicial interno
  double _zoom = 14;
  String? _addr;

  // Debounce para reverse geocoding
  Timer? _revDebounce;

  // Nominatim requiere un User-Agent identificable
  static const _ua = 'DailyCulture/1.0 (contact: example@example.com)';

  @override
  void initState() {
    super.initState();

    // Aplica el default aquí si initialCenter viene null
    _center = widget.initialCenter ?? LatLng(40.4168, -3.7038);
    _zoom = widget.initialZoom;

    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _searchCtrl.text = widget.initialQuery!;
      // Lanzamos una búsqueda inicial
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _geocodeAndGo(_searchCtrl.text);
      });
    } else {
      // Hacemos reverse-geocode inicial
      _reverseGeocode(_center);
    }
  }

  @override
  void dispose() {
    _revDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _geocodeAndGo(String query) async {
    if (query.trim().isEmpty) return;
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
            '?q=${Uri.encodeQueryComponent(query)}'
            '&format=json&limit=1&addressdetails=1&accept-language=es',
      );
      final res = await http.get(uri, headers: {'User-Agent': _ua});
      if (res.statusCode != 200) return;
      final list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) return;

      final first = list.first as Map<String, dynamic>;
      final lat = double.tryParse(first['lat']?.toString() ?? '');
      final lon = double.tryParse(first['lon']?.toString() ?? '');
      if (lat == null || lon == null) return;

      final p = LatLng(lat, lon);
      _addr = first['display_name']?.toString();
      setState(() {
        _center = p;
      });
      _map.move(p, 17);
    } catch (_) {
      // silencioso
    }
  }

  Future<void> _reverseGeocode(LatLng p) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
            '?lat=${p.latitude}&lon=${p.longitude}'
            '&format=json&zoom=18&accept-language=es',
      );
      final res = await http.get(uri, headers: {'User-Agent': _ua});
      if (res.statusCode != 200) return;
      final m = jsonDecode(res.body) as Map<String, dynamic>;
      setState(() {
        _addr = m['display_name']?.toString();
      });
    } catch (_) {
      // silencioso
    }
  }

  void _confirm() {
    Navigator.pop<MapPickResult>(
      context,
      MapPickResult(
        lat: _center.latitude,
        lon: _center.longitude,
        displayName: _addr,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Elegir ubicación'),
        actions: [
          IconButton(
            tooltip: 'Aceptar',
            onPressed: _confirm,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: _zoom,
              onMapEvent: (event) {
                // v6: usamos SIEMPRE event.camera.center
                _center = event.camera.center;
                _zoom = event.camera.zoom;

                // Debounce de 500 ms para reverse geocoding
                _revDebounce?.cancel();
                _revDebounce = Timer(const Duration(milliseconds: 500), () {
                  _reverseGeocode(_center);
                });

                setState(() {});
              },
            ),
            // 👇 sin 'const' porque TileLayer no es const
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.dailyculture',
              ),
            ],
          ),

          // Pin centrado (sin const para no forzar const en el árbol)
          IgnorePointer(
            child: Center(
              child: Transform.translate(
                offset: const Offset(0, -12),
                child: const Icon(Icons.location_on, size: 36, color: Colors.redAccent),
              ),
            ),
          ),

          // Caja de búsqueda arriba
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              color: Colors.white,
              child: TextField(
                controller: _searchCtrl,
                onSubmitted: _geocodeAndGo,
                decoration: InputDecoration(
                  hintText: 'Buscar dirección o lugar',
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: InputBorder.none,
                  suffixIcon: IconButton(
                    tooltip: 'Buscar',
                    onPressed: () => _geocodeAndGo(_searchCtrl.text),
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
            ),
          ),

          // Dirección mostrada
          if (_addr != null && _addr!.isNotEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 86,
              child: Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 12,
                      offset: Offset(0, 6),
                    )
                  ],
                ),
                child: Text(
                  _addr!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),

          // Botón confirmar
          Positioned(
            right: 12,
            bottom: 16,
            child: FilledButton.icon(
              onPressed: _confirm,
              icon: const Icon(Icons.check),
              label: const Text('Usar este punto'),
            ),
          ),
        ],
      ),
    );
  }
}
