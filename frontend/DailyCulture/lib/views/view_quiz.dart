// lib/views/view_quiz.dart
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/points.dart'; // <<< Modelo para parsear /points/add

class QuizView extends StatefulWidget {
  const QuizView({
    super.key,
    this.amount = 10,
    this.categoryId,     // ej. 18 = Science: Computers
    this.difficulty,     // 'easy' | 'medium' | 'hard'
  });

  final int amount;
  final int? categoryId;
  final String? difficulty;

  @override
  State<QuizView> createState() => _QuizViewState();
}

class _QuizViewState extends State<QuizView> {
  static const _bg = Color(0xFFFBF7EF);
  static const _primary = Color(0xFF5B53D6);

  // --- API base (tu despliegue en Azure) ---
  static const _base =
      'https://dailyculture-bpdmbwahh5axdcd0.spaincentral-01.azurewebsites.net';

  final _storage = const FlutterSecureStorage();

  bool _loading = false;
  String? _error;
  int _index = 0;
  int _score = 0;
  int? _selected;   // índice elegido en la pregunta actual
  bool _revealed = false;

  late List<_Q> _qs;

  // ---------- categorías (filtro) ----------
  bool _loadingCats = false;
  List<_Cat> _cats = [];
  int? _selectedCategoryId; // null = todas

  // Para evitar doble bono si se relanza la hoja de resultados
  bool _bonusSent = false;

  @override
  void initState() {
    super.initState();
    _selectedCategoryId = widget.categoryId;
    _fetchCategories();
    _fetchQuestions();
  }

  /* ========================= DATA ========================= */

  Future<void> _fetchCategories() async {
    setState(() => _loadingCats = true);
    try {
      final uri = Uri.https('opentdb.com', '/api_category.php');
      final res = await http.get(uri, headers: {'Accept': 'application/json'});
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (body['trivia_categories'] as List).cast<Map>().toList();
      final cats = list
          .map((m) => _Cat(id: m['id'] as int, name: m['name'] as String))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() => _cats = cats);
    } catch (_) {
      // silencioso: el quiz funciona sin el filtro
    } finally {
      if (mounted) setState(() => _loadingCats = false);
    }
  }

  Future<void> _fetchQuestions() async {
    setState(() {
      _loading = true;
      _error = null;
      _qs = <_Q>[];
      _index = 0;
      _score = 0;
      _selected = null;
      _revealed = false;
      _bonusSent = false;
    });

    try {
      final params = <String, String>{
        'amount': widget.amount.toString(),
        'type': 'multiple',
        'encode': 'url3986', // luego decodificamos
      };

      final effectiveCat = _selectedCategoryId ?? widget.categoryId;
      if (effectiveCat != null) params['category'] = effectiveCat.toString();

      if (widget.difficulty != null && widget.difficulty!.isNotEmpty) {
        params['difficulty'] = widget.difficulty!;
      }

      final uri = Uri.https('opentdb.com', '/api.php', params);
      final res = await http.get(uri, headers: {'Accept': 'application/json'});
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final code = (body['response_code'] ?? 1) as int;
      if (code != 0) throw Exception('OpenTDB devolvió response_code=$code');

      final results = (body['results'] as List).cast<Map>().toList();
      final rng = Random();
      final parsed = <_Q>[];

      for (final raw in results) {
        final q = Uri.decodeComponent(raw['question'] as String);
        final correct = Uri.decodeComponent(raw['correct_answer'] as String);
        final incorrect = (raw['incorrect_answers'] as List)
            .map((e) => Uri.decodeComponent(e as String))
            .toList();

        final options = List<String>.from(incorrect)..add(correct);
        options.shuffle(rng);
        final correctIdx = options.indexOf(correct);
        parsed.add(_Q(
          question: q,
          options: options,
          correctIndex: correctIdx,
          category: Uri.decodeComponent(raw['category'] as String),
          difficulty: (raw['difficulty'] as String?)?.toLowerCase(),
        ));
      }

      if (!mounted) return;
      setState(() => _qs = parsed);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'No se pudieron cargar preguntas. $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /* ======================= PUNTOS (API) ====================== */

  Future<Points?> _sendPoints(int amount) async {
    try {
      final token = await _storage.read(key: 'access_token');
      if (token == null || token.isEmpty) return null;

      final uri = Uri.parse('$_base/points/add');
      final res = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'amount': amount}),
      );

      if (res.statusCode == 200) {
        final map = jsonDecode(res.body) as Map<String, dynamic>;
        return Points.fromJson(map);
      } else {
        // Puedes mostrar un snackbar si quieres ver el error:
        // ScaffoldMessenger.of(context).showSnackBar(
        //   SnackBar(content: Text('No se pudieron registrar puntos (HTTP ${res.statusCode}).')),
        // );
      }
    } catch (_) {
      // Silencioso; evita romper UX si no hay red
    }
    return null;
  }

  /* ======================= QUIZ FLOWS ====================== */

  // Ahora solo marca la opción; el score y puntos se deciden al confirmar
  void _onPick(int i) {
    if (_revealed) return;
    setState(() => _selected = i);
  }

  // Botón principal SIEMPRE habilitado (maneja confirmar/siguiente/saltar)
  void _onPrimaryPressed() {
    if (_qs.isEmpty) return;

    if (!_revealed) {
      if (_selected == null) {
        // saltar sin contestar
        _next();
      } else {
        // confirmar y revelar
        final isCorrect = _selected == _qs[_index].correctIndex;
        setState(() {
          _revealed = true;
          if (isCorrect) _score++;
        });
        if (isCorrect) {
          // 1 punto por acierto
          _sendPoints(1);
        }
      }
    } else {
      _next();
    }
  }

  String _primaryLabel() {
    if (_qs.isEmpty) return '...';
    if (!_revealed) {
      return _selected == null ? 'Saltar' : 'Confirmar';
    }
    return (_index + 1 == _qs.length) ? 'Ver resultados' : 'Siguiente';
  }

  void _next() {
    if (_index + 1 < _qs.length) {
      setState(() {
        _index++;
        _selected = null;
        _revealed = false;
      });
    } else {
      _showResults();
    }
  }

  void _showResults() {
    // Bonus de 5 puntos por completar las 10 preguntas (una sola vez)
    if (!_bonusSent && _qs.length >= 10) {
      _bonusSent = true;
      _sendPoints(5);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final total = _qs.length;
        final pct = (_score / total * 100).round();
        return Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 16,
            bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 4, width: 44, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(2)),
              ),
              const Text('Resultados', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('Has acertado $_score de $total • $pct%', style: TextStyle(color: Colors.black.withOpacity(.7))),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        Navigator.pop(context); // ← volver a Home
                      },
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Volver'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _fetchQuestions();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Jugar otra vez'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /* =========================== UI =========================== */

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
              onRefresh: _fetchQuestions,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  // ---------- Header con botón de volver ----------
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
                          child: const Icon(Icons.quiz_rounded, color: Colors.white, size: 28),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Trivia (OpenTDB)',
                                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, height: 1.05)),
                              const SizedBox(height: 6),
                              Text(
                                _loading
                                    ? 'Cargando preguntas…'
                                    : _error != null
                                    ? 'Sin preguntas'
                                    : 'Pregunta ${_index + 1} de ${_qs.length}',
                                style: TextStyle(color: Colors.white.withOpacity(.95), fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Reiniciar',
                          style: IconButton.styleFrom(backgroundColor: Colors.white),
                          onPressed: _fetchQuestions,
                          icon: const Icon(Icons.refresh_rounded, color: Colors.black87),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ---------- Filtro de categoría ----------
                  if (_cats.isNotEmpty || _loadingCats)
                    Card(
                      elevation: 10,
                      shadowColor: Colors.black12,
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: const BorderSide(color: Color(0xFFF0ECE4)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Filtrar por categoría',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: Colors.black.withOpacity(.85),
                                )),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int?>(
                                    value: _selectedCategoryId,
                                    isExpanded: true,
                                    decoration: InputDecoration(
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                      enabledBorder: const OutlineInputBorder(
                                        borderSide: BorderSide(color: Color(0xFFEAE7E0)),
                                      ),
                                    ),
                                    items: [
                                      const DropdownMenuItem<int?>(
                                        value: null,
                                        child: Text('Todas las categorías'),
                                      ),
                                      ..._cats.map((c) => DropdownMenuItem<int?>(
                                        value: c.id,
                                        child: Text(c.name),
                                      )),
                                    ],
                                    onChanged: (v) {
                                      setState(() => _selectedCategoryId = v);
                                      _fetchQuestions();
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 12),

                  // ---------- Contenido del quiz ----------
                  if (_error != null) ...[
                    _ErrorCard(message: _error!, onRetry: _fetchQuestions),
                  ] else if (_loading) ...[
                    const _SkeletonQuestionCard(),
                  ] else if (_qs.isEmpty) ...[
                    _ErrorCard(message: 'No llegaron preguntas.', onRetry: _fetchQuestions),
                  ] else ...[
                    _QuestionCard(
                      q: _qs[_index],
                      index: _index,
                      total: _qs.length,
                      selected: _selected,
                      revealed: _revealed,
                      onPick: _onPick,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _qs.isEmpty ? null : _onPrimaryPressed,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primary,
                              minimumSize: const Size(0, 50),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            child: Text(_primaryLabel()),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------- Modelos y widgets -------------------------- */

class _Q {
  final String question;
  final List<String> options;
  final int correctIndex;
  final String category;
  final String? difficulty;

  _Q({
    required this.question,
    required this.options,
    required this.correctIndex,
    required this.category,
    required this.difficulty,
  });
}

class _Cat {
  final int id;
  final String name;
  _Cat({required this.id, required this.name});
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.q,
    required this.index,
    required this.total,
    required this.selected,
    required this.revealed,
    required this.onPick,
  });

  final _Q q;
  final int index;
  final int total;
  final int? selected;
  final bool revealed;
  final void Function(int i) onPick;

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);

    Color _colorFor(int i) {
      if (!revealed && selected == i) return const Color(0xFFEDEBFF); // preselección
      if (revealed && i == q.correctIndex) return const Color(0xFFDFF5E2);   // correcto
      if (revealed && selected == i && i != q.correctIndex) return const Color(0xFFFFE5E5); // incorrecto
      return Colors.white;
    }

    Color _borderFor(int i) {
      if (!revealed && selected == i) return primary.withOpacity(.6); // borde en preselección
      if (revealed && i == q.correctIndex) return const Color(0xFF5DBB63);
      if (revealed && selected == i && i != q.correctIndex) return const Color(0xFFE57373);
      return const Color(0xFFF0ECE4);
    }

    IconData? _iconFor(int i) {
      if (!revealed) return null;
      if (i == q.correctIndex) return Icons.check_circle_rounded;
      if (selected == i && i != q.correctIndex) return Icons.cancel_rounded;
      return null;
    }

    return Card(
      elevation: 10,
      shadowColor: Colors.black12,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFF0ECE4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // meta (categoría/dificultad)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: primary.withOpacity(.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(q.category, style: const TextStyle(fontSize: 12, color: primary, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                if (q.difficulty != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.06),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(q.difficulty!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                const Spacer(),
                Text('${index + 1}/$total', style: TextStyle(color: Colors.black.withOpacity(.6), fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            Text(q.question, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            ...List.generate(q.options.length, (i) {
              final opt = q.options[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: revealed ? null : () => onPick(i),
                  borderRadius: BorderRadius.circular(14),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: _colorFor(i),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _borderFor(i)),
                      boxShadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 12, offset: Offset(0, 6))],
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(child: Text(opt, style: const TextStyle(fontWeight: FontWeight.w600))),
                        if (_iconFor(i) != null) ...[
                          const SizedBox(width: 10),
                          Icon(_iconFor(i), color: i == q.correctIndex ? const Color(0xFF5DBB63) : const Color(0xFFE57373)),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

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
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        child: Column(
          children: [
            const Icon(Icons.error_outline, size: 40, color: primary),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonQuestionCard extends StatelessWidget {
  const _SkeletonQuestionCard();
  @override
  Widget build(BuildContext context) {
    Widget bar([double w = 200]) => Container(
      width: w,
      height: 14,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: Colors.black12.withOpacity(.08), borderRadius: BorderRadius.circular(6)),
    );
    return Card(
      elevation: 10,
      shadowColor: Colors.black12,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFF0ECE4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar(240), bar(180), bar(220), bar(200), bar(160)]),
      ),
    );
  }
}

/* ------------------------------- Fondo ------------------------------- */
class _DecorBackground extends StatelessWidget {
  const _DecorBackground();
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _BgPainter(), child: Container());
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
