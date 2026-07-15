import '../models/street_segment.dart';
import 'paris_parking_service.dart';

enum VehicleKind { car, motorcycle, bicycle, coach }

class ParkingUserProfile {
  const ParkingUserProfile({
    this.vehicleKind = VehicleKind.car,
    this.hasResidentPermit = false,
    this.hasPmrPermit = false,
  });

  final VehicleKind vehicleKind;
  final bool hasResidentPermit;
  final bool hasPmrPermit;
}

enum EligibilityStatus { eligible, ineligible, unknown }

class SegmentEligibility {
  const SegmentEligibility({
    required this.status,
    required this.regimes,
    required this.reason,
    required this.nearestDataMeters,
  });

  final EligibilityStatus status;
  final Set<ParkingRegime> regimes;
  final String reason;
  final double? nearestDataMeters;

  bool get canRecommend => status == EligibilityStatus.eligible;
}

/// Rapproche les unités candidates de l'inventaire des régimes Paris Data.
///
/// Cette jointure locale est volontairement conservative : l'absence de
/// donnée devient `unknown`, jamais une autorisation implicite. Le futur
/// pipeline PostGIS remplacera cette étape par une association côté de rue et
/// un moteur de règles temporelles versionnés. Ce garde-fou exclut dès
/// maintenant les régimes manifestement inéligibles, sans prétendre constituer
/// une validation juridique complète.
class ParkingEligibilityService {
  const ParkingEligibilityService({this.maxMatchDistanceMeters = 24});

  final double maxMatchDistanceMeters;

  /// Construit les unités de décision à partir de Paris Data. Un enregistrement
  /// représente un emplacement ou une rangée inventoriée et conserve sa
  /// capacité déclarée lorsqu'elle existe ; sinon une occasion minimale est
  /// retenue. Les points deviennent de courts segments techniques destinés au
  /// rendu et au routage, pas des emprises de bordure officielles.
  List<StreetSegment> segmentsFromSpots(Iterable<ParkingSpot> spots) {
    final segments = <StreetSegment>[];
    var index = 0;
    for (final spot in spots) {
      if (spot.points.length < 2) continue;
      final sourceKey = _spotSourceKey(spot);
      segments.add(
        StreetSegment(
          id: _stableNegativeId('$sourceKey-$index'),
          name: spot.streetName ?? 'Emplacement réglementé',
          highwayType: 'residential',
          points: spot.points,
          parkingSides: 1,
          knownCapacity: spot.capacity ?? 1,
          parkingSourceKey: sourceKey,
        ),
      );
      index++;
    }
    return segments;
  }

  String _spotSourceKey(ParkingSpot spot) {
    final coordinates = spot.points
        .map(
          (point) =>
              '${point.latitude.toStringAsFixed(7)},'
              '${point.longitude.toStringAsFixed(7)}',
        )
        .join(';');
    return <String>[
      spot.sourceId ?? '',
      spot.regime.name,
      spot.streetName ?? '',
      spot.rawLabel ?? '',
      spot.capacity?.toString() ?? '',
      coordinates,
    ].join('|');
  }

  int _stableNegativeId(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return -(hash == 0 ? 1 : hash);
  }

  SegmentEligibility assess(
    StreetSegment segment,
    Iterable<ParkingSpot> spots,
    ParkingUserProfile profile,
  ) {
    if (segment.parkingForbidden || segment.parkingSides == 0) {
      return const SegmentEligibility(
        status: EligibilityStatus.ineligible,
        regimes: {ParkingRegime.interdit},
        reason: 'Stationnement interdit par la voirie',
        nearestDataMeters: 0,
      );
    }

    final matched = <ParkingSpot>[];
    var nearest = double.infinity;
    final sourceKey = segment.parkingSourceKey;
    if (sourceKey != null) {
      // Les unités créées depuis Paris Data restent liées à leur propre
      // régime. Un emplacement deux-roues ou livraison ne doit jamais hériter
      // du régime payant d'un voisin situé à quelques mètres.
      for (final spot in spots) {
        if (_spotSourceKey(spot) == sourceKey) {
          matched.add(spot);
          nearest = 0;
          break;
        }
      }
    } else {
      // Compatibilité pour d'éventuels segments externes : la proximité reste
      // conservative et l'absence de correspondance échoue fermée.
      for (final spot in spots) {
        for (final point in spot.points) {
          final distance = segment.distanceTo(point);
          if (distance < nearest) nearest = distance;
          if (distance <= maxMatchDistanceMeters) {
            matched.add(spot);
            break;
          }
        }
      }
    }

    if (matched.isEmpty) {
      return SegmentEligibility(
        status: EligibilityStatus.unknown,
        regimes: const {},
        reason: sourceKey == null
            ? 'Régime de bordure non rapproché'
            : 'Enregistrement source introuvable',
        nearestDataMeters: nearest.isFinite ? nearest : null,
      );
    }

    final regimes = matched.map((spot) => spot.regime).toSet();
    if (regimes.any((regime) => _isEligible(regime, profile))) {
      return SegmentEligibility(
        status: EligibilityStatus.eligible,
        regimes: regimes,
        reason: 'Emplacement compatible avec le profil',
        nearestDataMeters: nearest,
      );
    }
    if (regimes.contains(ParkingRegime.autre)) {
      return SegmentEligibility(
        status: EligibilityStatus.unknown,
        regimes: regimes,
        reason: 'Régime non interprété',
        nearestDataMeters: nearest,
      );
    }
    return SegmentEligibility(
      status: EligibilityStatus.ineligible,
      regimes: regimes,
      reason: 'Emplacements réservés ou interdits pour ce profil',
      nearestDataMeters: nearest,
    );
  }

  Map<int, SegmentEligibility> assessAll(
    Iterable<StreetSegment> segments,
    Iterable<ParkingSpot> spots,
    ParkingUserProfile profile,
  ) {
    return {
      for (final segment in segments)
        segment.id: assess(segment, spots, profile),
    };
  }

  List<ScoredSegment> applyToScores(
    Iterable<ScoredSegment> scores,
    Map<int, SegmentEligibility> assessments, {
    bool failClosed = true,
  }) {
    return [
      for (final score in scores)
        if (_mayKeep(score, assessments[score.segment.id], failClosed))
          score
        else
          ScoredSegment(
            segment: score.segment,
            capacity: 0,
            occupancy: score.occupancy,
            probabilityFree: 0,
          ),
    ];
  }

  bool _mayKeep(
    ScoredSegment score,
    SegmentEligibility? assessment,
    bool failClosed,
  ) {
    if (score.capacity == 0) return false;
    if (assessment == null || assessment.status == EligibilityStatus.unknown) {
      return !failClosed;
    }
    return assessment.status == EligibilityStatus.eligible;
  }

  bool _isEligible(ParkingRegime regime, ParkingUserProfile profile) {
    return switch (profile.vehicleKind) {
      VehicleKind.car => switch (regime) {
        ParkingRegime.payant || ParkingRegime.gratuit => true,
        ParkingRegime.resident => profile.hasResidentPermit,
        ParkingRegime.handicap => profile.hasPmrPermit,
        _ => false,
      },
      VehicleKind.motorcycle => regime == ParkingRegime.moto,
      VehicleKind.bicycle => regime == ParkingRegime.velo,
      VehicleKind.coach => regime == ParkingRegime.autocar,
    };
  }
}
