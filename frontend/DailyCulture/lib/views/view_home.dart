// lib/views/view_home.dart
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'view_login.dart';     // para navegar al login al hacer logout
import 'view_profile.dart';   // tab de Perfil
import 'view_quiz.dart';      // vista de Trivia
import 'view_friends.dart';   // << NUEVO: vista de Amigos

class HomeView extends StatefulWidget {
  const HomeView({
    super.key,
    this.username,
    this.onSignOut, // (opcional, ya no lo usamos)
  });

  final String? username;
  final VoidCallback? onSignOut;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> with SingleTickerProviderStateMixin {
  int _tab = 0;
  late final AnimationController _ac;

  // storage local para borrar token y navegar
  final _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..forward();
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  // logout seguro usando ESTE context (no el de LoginView)
  Future<void> _handleLogout() async {
    await _storage.delete(key: 'access_token');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginView()),
          (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);
    const bg = Color(0xFFFBF7EF);

    final hello = (widget.username?.trim().isNotEmpty ?? false)
        ? 'Hola, ${widget.username} 👋'
        : 'Bienvenido 👋';
    final today = _prettyDate(DateTime.now());

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          const _DecorBackground(),
          SafeArea(child: _buildTabContent(primary, hello, today)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: Colors.white,
        indicatorColor: primary.withOpacity(.10),
        surfaceTintColor: Colors.transparent,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Inicio'),
          NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: 'Explorar'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Perfil'),
        ],
      ),
    );
  }

  Widget _buildTabContent(Color primary, String hello, String today) {
    switch (_tab) {
      case 0:
        return RefreshIndicator(
          onRefresh: () async => Future<void>.delayed(const Duration(milliseconds: 600)),
          color: primary,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 860),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _HeaderFancy(
                          title: 'DailyCulture',
                          subtitle: hello,
                          date: today,
                          onAvatarTap: _handleLogout, // ahora llama al logout local
                        ),
                        const SizedBox(height: 18),
                        const _SectionTitle(text: 'Hoy'),
                        const SizedBox(height: 10),
                        FadeTransition(
                          opacity: CurvedAnimation(parent: _ac, curve: Curves.easeOutCubic),
                          child: const _TodayCard(),
                        ),
                        const SizedBox(height: 18),

                        // --------- Jugar Trivia ----------
                        _OpenTriviaCard(onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const QuizView()),
                          );
                        }),
                        const SizedBox(height: 12),

                        // --------- NUEVO: Amigos (botón abajo) ----------
                        _FriendsCard(onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const FriendsView()),
                          );
                        }),

                        const SizedBox(height: 18),
                        const _SectionTitle(text: 'Explorar'),
                        const SizedBox(height: 10),
                        const _ExploreCard(),
                        const SizedBox(height: 24),
                        const _SectionTitle(text: 'Sugerencias para ti'),
                        const SizedBox(height: 10),
                        const _SuggestionsRow(),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

      case 1:
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          children: const [
            _SectionTitle(text: 'Explorar'),
            SizedBox(height: 12),
            _ExploreCard(),
          ],
        );

      case 2:
      // Tab de perfil — recibe el logout local
        return ProfileView(
          username: widget.username,
          onSignOut: _handleLogout,
        );

      default:
        return const SizedBox.shrink();
    }
  }

  String _prettyDate(DateTime d) {
    const months = [
      'enero','febrero','marzo','abril','mayo','junio',
      'julio','agosto','septiembre','octubre','noviembre','diciembre'
    ];
    return '${d.day} de ${months[d.month - 1]} de ${d.year}';
  }
}

/// ---------- Header ----------
class _HeaderFancy extends StatelessWidget {
  const _HeaderFancy({
    required this.title,
    required this.subtitle,
    required this.date,
    this.onAvatarTap,
  });

  final String title;
  final String subtitle;
  final String date;
  final VoidCallback? onAvatarTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const primary = Color(0xFF5B53D6);

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
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.15),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(.22)),
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: text.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                      letterSpacing: .2,
                    )),
                const SizedBox(height: 6),
                Text(subtitle,
                    style: text.bodyMedium?.copyWith(
                      color: Colors.white.withOpacity(.95),
                      fontWeight: FontWeight.w600,
                    )),
                const SizedBox(height: 4),
                Text(date,
                    style: text.bodySmall?.copyWith(
                      color: Colors.white.withOpacity(.85),
                    )),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onAvatarTap,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.logout_rounded, color: primary),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w800,
        color: Colors.black.withOpacity(.85),
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard();

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
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Row(
          children: [
            Container(
              height: 46,
              width: 46,
              decoration: BoxDecoration(
                color: primary.withOpacity(.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.checklist_rounded, color: primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Tu objetivo de hoy',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
                  const SizedBox(height: 4),
                  Text(
                    'Completa 1 actividad de cultura diaria.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.black.withOpacity(.6),
                    ),
                  ),
                ],
              ),
            ),
            FilledButton(
              onPressed: () {},
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF5B53D6),
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Empezar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OpenTriviaCard extends StatelessWidget {
  const _OpenTriviaCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF0ECE4)),
        gradient: const LinearGradient(
          colors: [Color(0xFFEEE9FF), Color(0xFFFFFFFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 6))],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        leading: Container(
          height: 44,
          width: 44,
          decoration: BoxDecoration(
            color: primary.withOpacity(.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.quiz_rounded, color: primary),
        ),
        title: const Text('Jugar Trivia (OpenTDB)'),
        subtitle: Text(
          'Preguntas de cultura general en 4 opciones.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black.withOpacity(.6)),
        ),
        trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 18, color: primary),
        onTap: onTap,
      ),
    );
  }
}

class _FriendsCard extends StatelessWidget {
  const _FriendsCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF0ECE4)),
        gradient: const LinearGradient(
          colors: [Color(0xFFEFF7FF), Color(0xFFFFFFFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 6))],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        leading: Container(
          height: 44,
          width: 44,
          decoration: BoxDecoration(
            color: primary.withOpacity(.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.group_rounded, color: primary),
        ),
        title: const Text('Amigos'),
        subtitle: Text(
          'Gestiona solicitudes y compara puntos.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black.withOpacity(.6)),
        ),
        trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 18, color: primary),
        onTap: onTap,
      ),
    );
  }
}

class _ExploreCard extends StatelessWidget {
  const _ExploreCard();

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF5B53D6);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF0ECE4)),
        gradient: const LinearGradient(
          colors: [Color(0xFFEEE9FF), Color(0xFFFFFFFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 6))],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        leading: Container(
          height: 44,
          width: 44,
          decoration: BoxDecoration(
            color: primary.withOpacity(.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.search, color: primary),
        ),
        title: const Text('Descubre contenido nuevo'),
        subtitle: Text(
          'Cursos, artículos y actividades para tu cultura diaria.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black.withOpacity(.6)),
        ),
        trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 18, color: primary),
        onTap: () {},
      ),
    );
  }
}

class _SuggestionsRow extends StatelessWidget {
  const _SuggestionsRow();

  @override
  Widget build(BuildContext context) {
    final items = [
      ('Micro-reto de 5 min', Icons.timer_outlined, const Color(0xFF7C75F0)),
      ('Artículo destacado', Icons.article_outlined, const Color(0xFF5B53D6)),
      ('Vídeo recomendado', Icons.ondemand_video_outlined, const Color(0xFF5B53D6)),
      ('Evento cercano', Icons.event_available_outlined, const Color(0xFF7C75F0)),
    ];

    return SizedBox(
      height: 130,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final (title, icon, color) = items[i];
          return _SuggestionCard(title: title, icon: icon, color: color);
        },
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.title, required this.icon, required this.color});

  final String title;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF0ECE4)),
        boxShadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 12, offset: Offset(0, 6))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              height: 40,
              width: 40,
              decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ---------- Fondo (degradado + blobs) ----------
class _DecorBackground extends StatelessWidget {
  const _DecorBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BgPainter(),
      child: Container(),
    );
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
