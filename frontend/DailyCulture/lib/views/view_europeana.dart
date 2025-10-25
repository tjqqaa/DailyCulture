// lib/views/view_europeana.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class EuropeanaSearchView extends StatefulWidget {
  const EuropeanaSearchView({super.key, this.initialQuery = 'arte museo'});

  final String initialQuery;

  @override
  State<EuropeanaSearchView> createState() => _EuropeanaSearchViewState();
}

class _EuropeanaSearchViewState extends State<EuropeanaSearchView> {
  // Tu PUBLIC API KEY (no secreta). Europeana recomienda header X-Api-Key
  static const _apiKey = 'dringtit';
  static const _ua = 'DailyCulture/1.0 (contact: antonio@example.com)';

  final _searchCtrl = TextEditingController();
  final _scroll = ScrollController();

  bool _loading = false;
  bool _loadingMore = false;
  String _query = '';
  final int _rows = 20;
  int _page = 1; // página actual (1..N), Europeana usa start 1-based

  final List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery;
    _searchCtrl.text = widget.initialQuery;
    _fetch(reset: true);

    _scroll.addListener(() {
      final threshold = _scroll.position.maxScrollExtent - 200;
      if (_scroll.position.pixels >= threshold &&
          !_loadingMore &&
          !_loading &&
          _items.isNotEmpty) {
        _page += 1;
        _fetch();
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool reset = false}) async {
    final q = _query.trim();
    if (q.isEmpty) return;

    if (reset) {
      setState(() {
        _loading = true;
        _page = 1;
        _items.clear();
      });
    } else {
      setState(() => _loadingMore = true);
    }

    try {
      // Europeana usa start 1-based: 1, 21, 41...
      final start = ((_page - 1) * _rows) + 1;

      final uri = Uri.https(
        'api.europeana.eu',
        '/record/v2/search.json',
        {
          'query': q,
          'media': 'true',
          'thumbnail': 'true',
          'reusability': 'open',
          'rows': _rows.toString(),
          'start': start.toString(),
          'profile': 'minimal', // puedes cambiar a 'rich' si quieres más campos
          'qf': 'LANGUAGE:es',   // pequeño sesgo a español (opcional)
        },
      );

      final res = await http.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'X-Api-Key': _apiKey,
          'User-Agent': _ua,
        },
      );

      if (res.statusCode != 200) {
        throw Exception('Europeana HTTP ${res.statusCode}: ${res.body}');
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;

      // Si viene success=false, muestra el mensaje del servidor
      if (data['success'] == false) {
        final msg = data['message']?.toString() ??
            data['error']?.toString() ??
            'Error en la búsqueda';
        throw Exception(msg);
      }

      final fetched = (data['items'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      setState(() {
        _items.addAll(fetched);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al cargar: $e')),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  String _firstString(dynamic v) {
    if (v == null) return '';
    if (v is String) return v;
    if (v is List && v.isNotEmpty) return v.first.toString();
    return v.toString();
  }

  String? _thumbnailOf(Map<String, dynamic> it) {
    final prev = _firstString(it['edmPreview']);
    final shown = _firstString(it['edmIsShownBy']);
    final thumb = prev.isNotEmpty ? prev : shown;
    return thumb.isEmpty ? null : thumb;
  }

  String _titleOf(Map<String, dynamic> it) {
    final t = _firstString(it['title']);
    return t.isEmpty ? '(Sin título)' : t;
  }

  String? _yearOf(Map<String, dynamic> it) {
    final y = _firstString(it['year']);
    return y.isEmpty ? null : y;
  }

  String? _providerOf(Map<String, dynamic> it) {
    final p = _firstString(it['dataProvider']);
    return p.isNotEmpty ? p : _firstString(it['provider']);
  }

  Uri? _recordLink(Map<String, dynamic> it) {
    final g = _firstString(it['guid']);
    if (g.isNotEmpty) return Uri.tryParse(g);
    final link = _firstString(it['link']);
    return link.isNotEmpty ? Uri.tryParse(link) : null;
  }

  Future<void> _openUrl(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el enlace')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Europeana – Buscar'),
        actions: [
          IconButton(
            tooltip: 'Buscar',
            onPressed: () {
              _query = _searchCtrl.text.trim();
              _fetch(reset: true);
            },
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: Column(
        children: [
          // Barra de búsqueda
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Material(
              color: Colors.white,
              elevation: 2,
              borderRadius: BorderRadius.circular(12),
              child: TextField(
                controller: _searchCtrl,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  _query = _searchCtrl.text.trim();
                  _fetch(reset: true);
                },
                decoration: const InputDecoration(
                  hintText: 'Buscar obras, artistas, temas…',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ),
          ),

          if (_loading && _items.isEmpty)
            const Expanded(
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => _fetch(reset: true),
                child: _items.isEmpty
                    ? ListView(
                  children: const [
                    SizedBox(height: 120),
                    Center(child: Text('Sin resultados')),
                  ],
                )
                    : ListView.separated(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                  itemCount: _items.length + (_loadingMore ? 1 : 0),
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    if (i >= _items.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      );
                    }
                    final it = _items[i];
                    final thumb = _thumbnailOf(it);
                    final title = _titleOf(it);
                    final provider = _providerOf(it);
                    final year = _yearOf(it);
                    final url = _recordLink(it);

                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFF0ECE4)),
                        boxShadow: const [
                          BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 5))
                        ],
                      ),
                      child: ListTile(
                        onTap: url != null ? () => _openUrl(url) : null,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 56,
                            height: 56,
                            child: thumb != null
                                ? Image.network(
                              thumb,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.image_not_supported),
                            )
                                : const Icon(Icons.image_outlined, size: 28),
                          ),
                        ),
                        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Row(
                          children: [
                            if (provider != null && provider.isNotEmpty) ...[
                              const Icon(Icons.account_balance_outlined, size: 14),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  provider,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: Colors.black.withOpacity(.65)),
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            if (year != null && year.isNotEmpty) ...[
                              const Icon(Icons.event_outlined, size: 14),
                              const SizedBox(width: 4),
                              Text(year, style: TextStyle(color: Colors.black.withOpacity(.65))),
                            ],
                          ],
                        ),
                        trailing: IconButton(
                          tooltip: 'Abrir en Europeana',
                          icon: const Icon(Icons.open_in_new, color: primary),
                          onPressed: url != null ? () => _openUrl(url) : null,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
