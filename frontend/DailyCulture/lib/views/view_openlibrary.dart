// lib/views/view_openlibrary.dart
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

const _primary = Color(0xFF5B53D6);
const _bg = Color(0xFFFBF7EF);

/* ======================= Modelo ======================= */

class OLBook {
  final String key; // /works/OL123W
  final String title;
  final List<String> authors;
  final int? year;
  final int? coverId;
  final String? languageCode;

  OLBook({
    required this.key,
    required this.title,
    required this.authors,
    this.year,
    this.coverId,
    this.languageCode,
  });

  String get openUrl => 'https://openlibrary.org$key';
  String? get coverUrl =>
      coverId != null ? 'https://covers.openlibrary.org/b/id/$coverId-M.jpg' : null;

  factory OLBook.fromJson(Map<String, dynamic> m) {
    return OLBook(
      key: (m['key'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      authors: (m['author_name'] as List? ?? []).map((e) => e.toString()).toList(),
      year: (m['first_publish_year'] as num?)?.toInt(),
      coverId: (m['cover_i'] as num?)?.toInt(),
      languageCode: (m['language'] as List?)?.first?.toString(),
    );
  }
}

/* ======================= Vista ======================= */

class OpenLibraryView extends StatefulWidget {
  const OpenLibraryView({super.key});
  @override
  State<OpenLibraryView> createState() => _OpenLibraryViewState();
}

class _OpenLibraryViewState extends State<OpenLibraryView> {
  // Backend propio para "guardar como actividad"
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

  // Filtros
  final _qCtrl = TextEditingController(text: 'museo');
  final _onlyCovers = ValueNotifier<bool>(true);

  final Map<String, String> _languages = const {
    '': 'Cualquier idioma',
    'spa': 'Español',
    'eng': 'Inglés',
    'fra': 'Francés',
    'ita': 'Italiano',
    'deu': 'Alemán',
    'por': 'Portugués',
  };

  String _lang = '';

  // Estado
  bool _loading = false;
  int _page = 1;
  int _total = 0;
  final List<OLBook> _items = [];
  String? _error;
  String? _authToken;

  @override
  void initState() {
    super.initState();
    _loadMyToken();
    _fetch(reset: true);
  }

  Future<void> _loadMyToken() async {
    _authToken = await _storage.read(key: 'access_token');
    setState(() {});
  }

  Map<String, String> _myHeaders({bool json = false}) => {
    'Accept': 'application/json',
    if (json) 'Content-Type': 'application/json',
    if (_authToken != null) 'Authorization': 'Bearer $_authToken',
  };

  Future<void> _fetch({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _page = 1;
        _items.clear();
        _total = 0;
      }
    });

    try {
      final safeLang = _languages.containsKey(_lang) ? _lang : '';

      final params = <String, String>{
        'q': _qCtrl.text.trim().isEmpty ? 'book' : _qCtrl.text.trim(),
        'page': '$_page',
        'fields': 'key,title,author_name,first_publish_year,cover_i,language',
      };
      if (safeLang.isNotEmpty) params['language'] = safeLang;

      final uri = Uri.https('openlibrary.org', '/search.json', params);
      debugPrint('[GET] $uri');

      final res = await http.get(uri);
      if (res.statusCode != 200) {
        setState(() => _error = 'Error ${res.statusCode}');
        return;
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final docs = (body['docs'] as List? ?? [])
          .map((e) => OLBook.fromJson(Map<String, dynamic>.from(e)))
          .where((b) => !_onlyCovers.value || b.coverId != null)
          .toList();

      setState(() {
        _items.addAll(docs);
        _total = (body['numFound'] as num?)?.toInt() ?? _total;
        _page += 1;
      });
    } catch (e) {
      setState(() => _error = 'No se pudo cargar. $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _snack('No se pudo abrir el enlace');
    }
  }

  Future<void> _saveAsActivity(OLBook b) async {
    if (_authToken == null) {
      _snack('Inicia sesión para guardar actividades.');
      return;
    }
    final payload = {
      'title': b.title,
      'kind': 'read',
      'points_on_complete': 5,
      'url': b.openUrl,
    };
    try {
      final res = await http.post(
        _apiUri('/activities'),
        headers: _myHeaders(json: true),
        body: jsonEncode(payload),
      );
      if (res.statusCode != 200 && res.statusCode != 201) {
        debugPrint('Create body: ${res.body}');
        _snack('No se pudo guardar (${res.statusCode}).');
        return;
      }
      _snack('Guardado en tus actividades ✅');
    } catch (e) {
      _snack('Error: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      // Quitamos AppBar nativo y ponemos un header bonito personalizado
      body: SafeArea(
        child: Column(
          children: [
            _OpenLibHeader(
              title: 'Open Library',
              onBack: () => Navigator.pop(context),
              onRefresh: () => _fetch(reset: true),
            ),
            _PrettyFilters(
              qCtrl: _qCtrl,
              onlyCovers: _onlyCovers,
              languages: _languages,
              lang: _lang,
              onLangChanged: (v) => setState(() => _lang = v ?? ''),
              loading: _loading,
              onSearch: () => _fetch(reset: true),
            ),
            const Divider(height: 1),

            // Lista
            Expanded(
              child: RefreshIndicator(
                color: _primary,
                onRefresh: () => _fetch(reset: true),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: _items.length +
                      (_loading ? 1 : 0) +
                      (_error != null && _items.isEmpty ? 1 : 0) +
                      (_items.length < _total ? 1 : 0),
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (ctx, i) {
                    if (_error != null && _items.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_error!, style: const TextStyle(color: Colors.red)),
                      );
                    }

                    if (i < _items.length) {
                      final b = _items[i];
                      return _BookTile(
                        book: b,
                        onOpen: () => _openUrl(b.openUrl),
                        onSave: () => _saveAsActivity(b),
                      );
                    }

                    if (_loading) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    if (_items.length < _total) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          child: OutlinedButton(
                            onPressed: _fetch,
                            child: const Text('Cargar más'),
                          ),
                        ),
                      );
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Resultados: ${_items.length}/$_total',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.black.withOpacity(.55),
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* =================== Header bonito (cambia lo marcado en rojo) =================== */

class _OpenLibHeader extends StatelessWidget {
  const _OpenLibHeader({
    required this.title,
    required this.onBack,
    required this.onRefresh,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF7C75F0), Color(0xFF5B53D6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [
            BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 10)),
          ],
        ),
        child: Row(
          children: [
            _CircleIconButton(icon: Icons.arrow_back_rounded, onTap: onBack),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  height: 1.0,
                ),
              ),
            ),
            _CircleIconButton(icon: Icons.refresh_rounded, onTap: onRefresh),
          ],
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: _primary, size: 20),
        ),
      ),
    );
  }
}

/* =========== Tarjeta superior de filtros (estilo purple) =========== */

class _PrettyFilters extends StatelessWidget {
  const _PrettyFilters({
    required this.qCtrl,
    required this.onlyCovers,
    required this.languages,
    required this.lang,
    required this.onLangChanged,
    required this.loading,
    required this.onSearch,
  });

  final TextEditingController qCtrl;
  final ValueNotifier<bool> onlyCovers;
  final Map<String, String> languages;
  final String lang;
  final ValueChanged<String?> onLangChanged;
  final bool loading;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width - 32; // padding horizontal total
    final twoCols = w >= 520;
    final itemW = twoCols ? (w - 12) / 2 : w;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(14),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Encabezado
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.15),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withOpacity(.22)),
                  ),
                  child: const Icon(Icons.menu_book_rounded, color: Colors.white),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Busca libros, autores y ediciones',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Inputs (Wrap responsivo)
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                // Búsqueda
                SizedBox(
                  width: itemW,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _fieldLabel('Búsqueda'),
                      TextField(
                        controller: qCtrl,
                        style: const TextStyle(color: Colors.black87),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          hintText: 'museo, picasso, historia…',
                          prefixIcon: const Icon(Icons.search),
                          border: _roundBorder(),
                          enabledBorder: _roundBorder(),
                          focusedBorder: _roundBorder(focused: true),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 14),
                        ),
                      ),
                    ],
                  ),
                ),

                // Idioma
                SizedBox(
                  width: itemW,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _fieldLabel('Idioma'),
                      DropdownButtonFormField<String>(
                        value: languages.containsKey(lang) ? lang : languages.keys.first,
                        items: languages.entries
                            .map((e) =>
                            DropdownMenuItem(value: e.key, child: Text(e.value)))
                            .toList(),
                        onChanged: onLangChanged,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          prefixIcon: const Icon(Icons.translate_rounded),
                          border: _roundBorder(),
                          enabledBorder: _roundBorder(),
                          focusedBorder: _roundBorder(focused: true),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 14),
                        ),
                      ),
                    ],
                  ),
                ),

                // Switch + botón Buscar (morado)
                SizedBox(
                  width: itemW,
                  child: Row(
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: onlyCovers,
                        builder: (_, v, __) => Row(
                          children: [
                            const Text('Sólo con portada',
                                style: TextStyle(color: Colors.white)),
                            const SizedBox(width: 8),
                            Switch.adaptive(
                              value: v,
                              onChanged: (nv) => onlyCovers.value = nv,
                              activeColor: Colors.white,
                              activeTrackColor: Colors.white24,
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: loading ? null : onSearch,
                        icon: const Icon(Icons.search),
                        label: const Text('Buscar'),
                        style: FilledButton.styleFrom(
                          backgroundColor: _primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Widget _fieldLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  static OutlineInputBorder _roundBorder({bool focused = false}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: focused ? Colors.black12 : Colors.transparent,
          width: 1,
        ),
      );
}

/* =================== Tile de libro (anti-overflow) =================== */

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.onOpen,
    required this.onSave,
  });

  final OLBook book;
  final VoidCallback onOpen;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final authorLine = book.authors.isNotEmpty ? book.authors.join(', ') : '';
    final yearLine = book.year != null ? 'Año: ${book.year}' : '';
    final subtitleText = [authorLine, yearLine].where((s) => s.isNotEmpty).join('\n');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF0ECE4)),
        boxShadow: const [
          BoxShadow(color: Color(0x11000000), blurRadius: 10, offset: Offset(0, 5)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Cover(coverUrl: book.coverUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    if (subtitleText.isNotEmpty)
                      Text(
                        subtitleText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.black.withOpacity(.70),
                          height: 1.12,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MiniAction(icon: Icons.open_in_new, tooltip: 'Abrir', onTap: onOpen),
                  const SizedBox(height: 6),
                  _MiniAction(
                    icon: Icons.add_task,
                    tooltip: 'Guardar en Actividades',
                    onTap: onSave,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Center(child: Icon(icon, size: 18, color: Colors.black87)),
          ),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({this.coverUrl});
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 44,
        height: 60,
        color: const Color(0xFFF2F2F2),
        child: (coverUrl == null)
            ? const Icon(Icons.menu_book_outlined, color: Colors.black45, size: 22)
            : Image.network(coverUrl!, fit: BoxFit.cover),
      ),
    );
  }
}
