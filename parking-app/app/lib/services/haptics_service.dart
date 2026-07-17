import 'package:flutter/services.dart';

/// Retour haptique centralisé, avec anti-rafale : plusieurs déclenchements
/// dans la même fenêtre ne produisent qu'une seule vibration, pour éviter la
/// surcharge sensorielle (recommandation de l'étude design).
class Haptics {
  Haptics._();

  static DateTime _lastFired = DateTime.fromMillisecondsSinceEpoch(0);
  static const _minimumGap = Duration(milliseconds: 90);

  /// Coupe tout retour haptique (préférence utilisateur future).
  static bool enabled = true;

  static void _fire(Future<void> Function() feedback) {
    if (!enabled) return;
    final now = DateTime.now();
    if (now.difference(_lastFired) < _minimumGap) return;
    _lastFired = now;
    // Fire-and-forget : l'haptique ne doit jamais bloquer ni faire échouer
    // l'action qui la déclenche.
    feedback().catchError((_) {});
  }

  /// Crans discrets : snap de panneau, bascule d'option.
  static void selection() => _fire(HapticFeedback.selectionClick);

  /// Sélection d'un élément : place, suggestion.
  static void light() => _fire(HapticFeedback.lightImpact);

  /// Confirmation d'action importante : départ du guidage, place trouvée.
  static void medium() => _fire(HapticFeedback.mediumImpact);
}
