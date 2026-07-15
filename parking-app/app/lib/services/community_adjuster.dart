import 'dart:math' as math;

import '../models/street_segment.dart';
import 'community_service.dart';

/// Correction "bayésienne" récente des probabilités : les signalements
/// communautaires récents (place libérée / place prise) ajustent le prior
/// heuristique des tronçons voisins, avec une influence qui décroît avec
/// l'âge du signalement.
class CommunityAdjuster {
  const CommunityAdjuster({
    this.maxAge = const Duration(minutes: 12),
    this.maxDistanceMeters = 120,
    this.freedBoost = 0.6,
    this.parkedPenalty = 0.35,
    this.maxAbsoluteDelta = 0.12,
  });

  /// Au-delà de cet âge, un signalement n'a plus d'effet.
  final Duration maxAge;

  /// Distance maximale cellule → tronçon pour avoir un effet. Les coordonnées
  /// publiques sont arrondies et le poids décroît continûment avec la distance.
  final double maxDistanceMeters;

  /// Poids maximal d'une place libérée toute fraîche.
  final double freedBoost;

  /// Poids maximal d'une place prise toute fraîche.
  final double parkedPenalty;

  /// Tant que les auteurs ne sont pas attestés, la communauté ne peut jamais
  /// déplacer le prior de plus de douze points, même sous une rafale.
  final double maxAbsoluteDelta;

  /// Poids d'un événement selon son âge : 1.0 à l'instant même,
  /// 0.0 à [maxAge] (décroissance linéaire).
  double ageWeight(ParkingEvent e, DateTime now) {
    final age = now.difference(e.createdAt);
    if (age.isNegative) return 1.0;
    if (age >= maxAge) return 0.0;
    return 1.0 - age.inSeconds / maxAge.inSeconds;
  }

  List<ScoredSegment> adjust(
    List<ScoredSegment> scored,
    List<ParkingEvent> events,
    DateTime now,
  ) {
    if (events.isEmpty) return scored;
    return [for (final s in scored) _adjustOne(s, events, now)];
  }

  ScoredSegment _adjustOne(
    ScoredSegment s,
    List<ParkingEvent> events,
    DateTime now,
  ) {
    final baseline = s.probabilityFree;
    var signedEvidence = 0.0;
    if (s.capacity == 0) return s; // rue interdite : aucun effet.

    for (final e in events) {
      final distance = s.segment.distanceTo(e.position);
      if (distance > maxDistanceMeters) continue;
      final corroboration = math.min(1.0, e.reportCount.clamp(1, 4) / 4);
      final spatialWeight = 1.0 - distance / maxDistanceMeters;
      final w = ageWeight(e, now) * corroboration * spatialWeight;
      if (w <= 0) continue;
      if (e.isFreed) {
        signedEvidence += (1.0 - baseline) * freedBoost * w;
      } else {
        signedEvidence -= baseline * parkedPenalty * w;
      }
    }

    if (signedEvidence == 0) return s;
    return ScoredSegment(
      segment: s.segment,
      capacity: s.capacity,
      occupancy: s.occupancy,
      // Les preuves opposées sont combinées depuis le même prior : le résultat
      // est commutatif et ne dépend donc jamais de l'ordre arbitraire renvoyé
      // par le backend. Sans observations supervisées, l'écart reste borné.
      probabilityFree: (baseline + signedEvidence)
          .clamp(baseline - maxAbsoluteDelta, baseline + maxAbsoluteDelta)
          .clamp(0.0, 0.95),
    );
  }
}
