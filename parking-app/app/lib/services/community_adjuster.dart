import '../models/street_segment.dart';
import 'community_service.dart';

/// Correction "bayésienne" temps réel des probabilités : les signalements
/// communautaires récents (place libérée / place prise) ajustent le prior
/// heuristique des tronçons voisins, avec une influence qui décroît avec
/// l'âge du signalement.
class CommunityAdjuster {
  const CommunityAdjuster({
    this.maxAge = const Duration(minutes: 12),
    this.maxDistanceMeters = 60,
    this.freedBoost = 0.6,
    this.parkedPenalty = 0.35,
  });

  /// Au-delà de cet âge, un signalement n'a plus d'effet.
  final Duration maxAge;

  /// Distance maximale signalement → tronçon pour avoir un effet.
  final double maxDistanceMeters;

  /// Poids maximal d'une place libérée toute fraîche.
  final double freedBoost;

  /// Poids maximal d'une place prise toute fraîche.
  final double parkedPenalty;

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
    return [
      for (final s in scored) _adjustOne(s, events, now),
    ];
  }

  ScoredSegment _adjustOne(
    ScoredSegment s,
    List<ParkingEvent> events,
    DateTime now,
  ) {
    var p = s.probabilityFree;
    if (s.capacity == 0) return s; // rue interdite : aucun effet.

    for (final e in events) {
      final w = ageWeight(e, now);
      if (w <= 0) continue;
      if (s.segment.distanceTo(e.position) > maxDistanceMeters) continue;
      if (e.isFreed) {
        // Une place vient de se libérer à côté : forte hausse.
        p = p + (1.0 - p) * freedBoost * w;
      } else {
        // Quelqu'un vient de se garer : la rue se remplit.
        p = p * (1.0 - parkedPenalty * w);
      }
    }

    if (p == s.probabilityFree) return s;
    return ScoredSegment(
      segment: s.segment,
      capacity: s.capacity,
      occupancy: s.occupancy,
      probabilityFree: p.clamp(0.0, 1.0),
    );
  }
}
