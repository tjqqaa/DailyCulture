import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AccessibilitySettings {
  final double textScale;      // 1.0 - 1.6
  final bool highContrast;     // Colores con más contraste
  final bool boldText;         // Forzar negrita
  final bool largeTapTargets;  // Botones >= 48dp
  final bool reduceMotion;     // Transiciones sin animación

  const AccessibilitySettings({
    this.textScale = 1.0,
    this.highContrast = false,
    this.boldText = false,
    this.largeTapTargets = true,
    this.reduceMotion = false,
  });

  AccessibilitySettings copyWith({
    double? textScale,
    bool? highContrast,
    bool? boldText,
    bool? largeTapTargets,
    bool? reduceMotion,
  }) => AccessibilitySettings(
    textScale: textScale ?? this.textScale,
    highContrast: highContrast ?? this.highContrast,
    boldText: boldText ?? this.boldText,
    largeTapTargets: largeTapTargets ?? this.largeTapTargets,
    reduceMotion: reduceMotion ?? this.reduceMotion,
  );

  Map<String, String> toStorage() => {
    'textScale': textScale.toString(),
    'highContrast': highContrast.toString(),
    'boldText': boldText.toString(),
    'largeTapTargets': largeTapTargets.toString(),
    'reduceMotion': reduceMotion.toString(),
  };

  static AccessibilitySettings fromStorage(Map<String, String> m) {
    double parseD(String k, double d) => double.tryParse(m[k] ?? '') ?? d;
    bool parseB(String k, bool d) => (m[k] ?? d.toString()) == 'true';
    return AccessibilitySettings(
      textScale: parseD('textScale', 1.0).clamp(1.0, 1.6),
      highContrast: parseB('highContrast', false),
      boldText: parseB('boldText', false),
      largeTapTargets: parseB('largeTapTargets', true),
      reduceMotion: parseB('reduceMotion', false),
    );
  }
}

class AccessibilityController extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  AccessibilitySettings _settings = const AccessibilitySettings();
  AccessibilitySettings get settings => _settings;

  Future<void> load() async {
    final all = <String, String>{};
    for (final k in ['textScale','highContrast','boldText','largeTapTargets','reduceMotion']) {
      all[k] = await _storage.read(key: 'a11y_$k') ?? '';
    }
    _settings = AccessibilitySettings.fromStorage(all);
    notifyListeners();
  }

  Future<void> update(AccessibilitySettings s) async {
    _settings = s;
    for (final e in s.toStorage().entries) {
      await _storage.write(key: 'a11y_${e.key}', value: e.value);
    }
    notifyListeners();
  }
}
