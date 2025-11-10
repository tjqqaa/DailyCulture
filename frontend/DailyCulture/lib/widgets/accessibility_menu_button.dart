// lib/widgets/accessibility_menu_button.dart
import 'package:flutter/material.dart';

// 👇 Usa ruta relativa a lib/widgets → lib/controller
import '../controller/accessibility_controller.dart';

class AccessibilityMenuButton extends StatelessWidget {
  final AccessibilityController controller;
  const AccessibilityMenuButton({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Accesibilidad',
      child: IconButton(
        tooltip: 'Accesibilidad',
        onPressed: () => _openSheet(context),
        icon: const Icon(Icons.accessibility_new_rounded),
      ),
    );
  }

  void _openSheet(BuildContext context) {
    final s = controller.settings;
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        double textScale = s.textScale;
        bool highContrast = s.highContrast;
        bool boldText = s.boldText;
        bool largeTap = s.largeTapTargets;
        bool reduceMotion = s.reduceMotion;

        return StatefulBuilder(builder: (context, setState) {
          Future<void> _save() async {
            await controller.update(AccessibilitySettings(
              textScale: textScale,
              highContrast: highContrast,
              boldText: boldText,
              largeTapTargets: largeTap,
              reduceMotion: reduceMotion,
            ));
            if (context.mounted) Navigator.pop(context);
          }

          return Padding(
            padding: EdgeInsets.only(
              left: 16, right: 16, top: 8,
              bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Accesibilidad',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Tamaño de texto', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Slider(
                        value: textScale,
                        onChanged: (v) => setState(() => textScale = v),
                        min: 1.0, max: 1.6, divisions: 6,
                        label: '${(textScale * 100).round()}%',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: highContrast,
                  onChanged: (v) => setState(() => highContrast = v),
                  title: const Text('Alto contraste'),
                  subtitle: const Text('Mejora la legibilidad de colores'),
                ),
                SwitchListTile(
                  value: boldText,
                  onChanged: (v) => setState(() => boldText = v),
                  title: const Text('Texto en negrita'),
                ),
                SwitchListTile(
                  value: largeTap,
                  onChanged: (v) => setState(() => largeTap = v),
                  title: const Text('Botones grandes (48dp)'),
                ),
                SwitchListTile(
                  value: reduceMotion,
                  onChanged: (v) => setState(() => reduceMotion = v),
                  title: const Text('Reducir animaciones'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancelar'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('Aplicar'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        });
      },
    );
  }
}
