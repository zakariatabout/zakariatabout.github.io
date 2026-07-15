import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/street_segment.dart';

class SearchLoop {
  SearchLoop({
    required this.orderedSegments,
    required this.cumulativeProbability,
    this.isCalibrated = false,
  });

  /// Tronçons à parcourir, dans l'ordre conseillé.
  final List<ScoredSegment> orderedSegments;

  /// Estimation prudente du succès de la stratégie.
  ///
  /// Les rues proches ne sont pas considérées comme indépendantes : la
  /// contribution des rues supplémentaires est décotée selon leur proximité.
  /// Tant qu'aucun modèle terrain n'est chargé, [isCalibrated] reste faux et
  /// l'UI ne doit pas afficher cette valeur comme un pourcentage certain.
  final double cumulativeProbability;
  final bool isCalibrated;
}

/// Construit la boucle de recherche : la séquence de rues qui maximise les
/// chances de se garer sans s'éloigner de la destination.
class SearchLoopPlanner {
  const SearchLoopPlanner({
    this.targetProbability = 0.90,
    this.maxSegments = 6,
    this.maxWalkMeters = 500,
  });

  /// On ajoute des rues à la boucle jusqu'à atteindre cette probabilité cumulée.
  final double targetProbability;
  final int maxSegments;

  /// Distance de marche maximale acceptée entre la place et la destination.
  final double maxWalkMeters;

  static const Distance _distance = Distance();

  /// Score d'attractivité d'un tronçon : probabilité de place pondérée par la
  /// proximité de la destination (une place à 400 m vaut moins qu'à 100 m).
  double attractiveness(ScoredSegment s, LatLng destination) {
    final walk = s.segment.distanceTo(destination);
    if (walk > maxWalkMeters) return 0;
    // Pénalité de marche douce : 1.0 à 0 m, ~0.5 à maxWalk.
    final walkFactor = 1.0 / (1.0 + walk / maxWalkMeters);
    return s.probabilityFree * walkFactor;
  }

  SearchLoop plan(List<ScoredSegment> scored, LatLng destination) {
    // Candidats triés par attractivité.
    final candidates =
        scored
            .where((s) => s.probabilityFree > 0.01)
            .map((s) => (seg: s, score: attractiveness(s, destination)))
            .where((c) => c.score > 0)
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));

    // Sélection gloutonne avec décote de corrélation spatiale. Deux rues
    // voisines partagent souvent la même pression de stationnement ; les
    // traiter comme deux essais indépendants gonfle fortement le score.
    final selected = <ScoredSegment>[];
    var failAll = 1.0;
    for (final c in candidates) {
      if (selected.length >= maxSegments) break;
      selected.add(c.seg);
      final incremental =
          c.seg.probabilityFree *
          _correlationDiscount(c.seg, selected.take(selected.length - 1));
      failAll *= 1.0 - incremental.clamp(0.0, 0.95);
      if (1.0 - failAll >= targetProbability) break;
    }

    // Ordonnancement en tournée : plus proche voisin depuis la destination,
    // pour minimiser les zigzags entre les rues retenues.
    final ordered = _nearestNeighborOrder(selected, destination);

    return SearchLoop(
      orderedSegments: ordered,
      cumulativeProbability: 1.0 - failAll,
      isCalibrated: false,
    );
  }

  double _correlationDiscount(
    ScoredSegment candidate,
    Iterable<ScoredSegment> alreadySelected,
  ) {
    if (alreadySelected.isEmpty) return 1.0;
    var nearest = double.infinity;
    for (final selected in alreadySelected) {
      nearest = math.min(
        nearest,
        _distance(candidate.segment.midpoint, selected.segment.midpoint),
      );
    }
    if (nearest < 75) return 0.25;
    if (nearest < 150) return 0.40;
    if (nearest < 300) return 0.65;
    return 0.85;
  }

  List<ScoredSegment> _nearestNeighborOrder(
    List<ScoredSegment> segments,
    LatLng start,
  ) {
    final remaining = [...segments];
    final ordered = <ScoredSegment>[];
    var current = start;
    while (remaining.isNotEmpty) {
      var bestIdx = 0;
      var bestDist = double.infinity;
      for (var i = 0; i < remaining.length; i++) {
        final d = _distance(remaining[i].segment.midpoint, current);
        // Les rues les plus prometteuses sont légèrement favorisées pour
        // être visitées en premier.
        final adjusted = d / (0.5 + remaining[i].probabilityFree);
        if (adjusted < bestDist) {
          bestDist = adjusted;
          bestIdx = i;
        }
      }
      final next = remaining.removeAt(bestIdx);
      ordered.add(next);
      current = next.segment.midpoint;
    }
    return ordered;
  }

  /// Temps de recherche espéré (minutes) le long de la boucle, en supposant
  /// ~20 km/h de vitesse de croisière en recherche.
  double expectedSearchMinutes(SearchLoop loop) {
    const cruiseSpeedMs = 15 * 1000 / 3600;
    var expected = 0.0;
    var probStillSearching = 1.0;
    var elapsed = 0.0;
    LatLng? previous;
    for (final s in loop.orderedSegments) {
      final linkMeters = previous == null
          ? 0.0
          : _distance(previous, s.segment.midpoint).toDouble();
      final t = (linkMeters + s.segment.lengthMeters) / cruiseSpeedMs;
      elapsed += t;
      // Probabilité de se garer précisément sur ce tronçon.
      final pHere = probStillSearching * s.probabilityFree;
      expected += pHere * elapsed;
      probStillSearching *= 1.0 - s.probabilityFree;
      previous = s.segment.midpoint;
    }
    // Les échecs comptent pour la durée totale de la boucle.
    expected += probStillSearching * elapsed;
    return math.max(expected / 60.0, 0);
  }
}
