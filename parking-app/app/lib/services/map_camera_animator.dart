import 'package:flutter/animation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Anime les mouvements de caméra de flutter_map (centre, zoom, rotation)
/// au lieu des sauts secs de `MapController.move`.
///
/// Écrit maison car flutter_map_animations est incompatible avec
/// latlong2 ^0.10. La rotation interpole toujours par le chemin le plus
/// court (l'aiguille ne fait jamais un tour complet pour 10° d'écart).
class MapCameraAnimator {
  MapCameraAnimator({required TickerProvider vsync, required this.controller})
    : _animation = AnimationController(vsync: vsync);

  final MapController controller;
  final AnimationController _animation;

  static const defaultDuration = Duration(milliseconds: 600);

  /// Vrai quand l'utilisateur préfère les animations réduites : les
  /// déplacements redeviennent instantanés.
  bool reduceMotion = false;

  void animateTo({
    LatLng? center,
    double? zoom,
    double? rotation,
    Duration duration = defaultDuration,
    Curve curve = Curves.easeOutCubic,
  }) {
    final camera = controller.camera;
    final fromCenter = camera.center;
    final fromZoom = camera.zoom;
    final fromRotation = camera.rotation;
    final toCenter = center ?? fromCenter;
    final toZoom = zoom ?? fromZoom;
    final toRotation = rotation ?? fromRotation;

    if (reduceMotion || duration == Duration.zero) {
      _animation.stop();
      controller.moveAndRotate(toCenter, toZoom, toRotation);
      return;
    }

    // Chemin de rotation le plus court, normalisé dans [-180, 180].
    var rotationDelta = (toRotation - fromRotation) % 360;
    if (rotationDelta > 180) rotationDelta -= 360;
    if (rotationDelta < -180) rotationDelta += 360;

    _animation
      ..stop()
      ..duration = duration;
    final tween = CurveTween(curve: curve);

    void tick() {
      final t = tween.transform(_animation.value);
      controller.moveAndRotate(
        LatLng(
          fromCenter.latitude + (toCenter.latitude - fromCenter.latitude) * t,
          fromCenter.longitude +
              (toCenter.longitude - fromCenter.longitude) * t,
        ),
        fromZoom + (toZoom - fromZoom) * t,
        fromRotation + rotationDelta * t,
      );
    }

    _animation
      ..removeListener(_lastListener ?? () {})
      ..addListener(_lastListener = tick)
      ..forward(from: 0);
  }

  /// Cadre un ensemble de points avec une transition animée : la cible est
  /// calculée par [CameraFit] puis rejointe en douceur.
  void animateFit(CameraFit fit, {Duration duration = defaultDuration}) {
    final target = fit.fit(controller.camera);
    animateTo(
      center: target.center,
      zoom: target.zoom,
      rotation: 0,
      duration: duration,
    );
  }

  void stop() => _animation.stop();

  VoidCallback? _lastListener;

  void dispose() => _animation.dispose();
}
