import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/street_segment.dart';
import '../services/geocoding_service.dart';
import '../services/overpass_service.dart';
import '../services/probability_engine.dart';
import '../services/routing_service.dart';
import '../services/search_loop_planner.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _mapController = MapController();
  final _searchController = TextEditingController();
  final _geocoding = GeocodingService();
  final _overpass = OverpassService();
  final _routing = RoutingService();
  final _engine = const ProbabilityEngine();
  final _planner = const SearchLoopPlanner();

  static final _parisCenter = const LatLng(48.8566, 2.3522);

  Timer? _searchDebounce;
  List<GeocodingResult> _suggestions = [];
  bool _searching = false;

  LatLng? _destination;
  List<StreetSegment> _rawSegments = [];
  List<ScoredSegment> _scored = [];
  SearchLoop? _loop;
  DrivingRoute? _route;
  LatLng? _myPosition;
  bool _loadingZone = false;
  bool _loadingRoute = false;
  String? _error;

  /// Heure d'arrivée simulée (curseur) ; null = maintenant.
  int? _simulatedHour;

  DateTime get _arrivalTime {
    final now = DateTime.now();
    if (_simulatedHour == null) return now;
    return DateTime(now.year, now.month, now.day, _simulatedHour!);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ── Recherche d'adresse ────────────────────────────────────────────────

  void _onQueryChanged(String q) {
    _searchDebounce?.cancel();
    if (q.trim().length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() => _searching = true);
      try {
        final results = await _geocoding.search(q);
        if (!mounted) return;
        setState(() => _suggestions = results);
      } catch (_) {
        if (!mounted) return;
        setState(() => _error = 'Recherche d’adresse indisponible');
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  Future<void> _selectDestination(GeocodingResult r) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _suggestions = [];
      _searchController.text = r.displayName.split(',').first;
      _destination = r.location;
      _rawSegments = [];
      _scored = [];
      _loop = null;
      _route = null;
      _error = null;
      _loadingZone = true;
    });
    _mapController.move(r.location, 16);

    try {
      final segments = await _overpass.fetchSegments(r.location);
      if (!mounted) return;
      setState(() => _rawSegments = segments);
      _recompute();
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _error = 'Impossible de charger les rues (réessayez)');
    } finally {
      if (mounted) setState(() => _loadingZone = false);
    }
  }

  /// Recalcule probabilités + boucle (appelé après chargement et quand
  /// l'heure simulée change).
  void _recompute() {
    final dest = _destination;
    if (dest == null || _rawSegments.isEmpty) return;
    final scored = _engine.scoreAll(_rawSegments, _arrivalTime);
    final loop = _planner.plan(scored, dest);
    setState(() {
      _scored = scored;
      _loop = loop;
      _route = null;
    });
  }

  // ── Guidage ────────────────────────────────────────────────────────────

  Future<void> _startGuidance() async {
    final loop = _loop;
    if (loop == null || loop.orderedSegments.isEmpty) return;
    setState(() {
      _loadingRoute = true;
      _error = null;
    });
    try {
      LatLng? start = _myPosition ?? await _locateMe(moveCamera: false);
      // Sans GPS, la boucle démarre à la destination.
      start ??= _destination;
      final waypoints = <LatLng>[
        ?start,
        for (final s in loop.orderedSegments.take(6)) s.segment.midpoint,
      ];
      final route = await _routing.route(waypoints);
      if (!mounted) return;
      if (route == null) {
        setState(() => _error = 'Itinéraire indisponible');
      } else {
        setState(() => _route = route);
        _fitCameraTo(route.points);
      }
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<LatLng?> _locateMe({bool moveCamera = true}) async {
    try {
      var permission = await Geolocator.checkPermission()
          .timeout(const Duration(seconds: 5));
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission()
            .timeout(const Duration(seconds: 30));
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final latLng = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return latLng;
      setState(() => _myPosition = latLng);
      if (moveCamera) _mapController.move(latLng, 16);
      return latLng;
    } catch (_) {
      return null;
    }
  }

  void _fitCameraTo(List<LatLng> points) {
    if (points.isEmpty) return;
    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: points,
        padding: const EdgeInsets.fromLTRB(40, 120, 40, 220),
      ),
    );
  }

  // ── Rendu ──────────────────────────────────────────────────────────────

  Color _probColor(double p) {
    if (p >= 0.6) return const Color(0xFF2E7D32);
    if (p >= 0.3) return const Color(0xFFF9A825);
    return const Color(0xFFC62828);
  }

  @override
  Widget build(BuildContext context) {
    final loop = _loop;
    final loopIds = {
      if (loop != null)
        for (final s in loop.orderedSegments) s.segment.id,
    };

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _parisCenter,
              initialZoom: 13,
              onTap: (_, _) => setState(() => _suggestions = []),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'fr.zakariatabout.parking_app',
              ),
              // Carte de chaleur des probabilités.
              PolylineLayer(
                polylines: [
                  for (final s in _scored)
                    Polyline(
                      points: s.segment.points,
                      strokeWidth: loopIds.contains(s.segment.id) ? 7 : 4,
                      color: _probColor(s.probabilityFree).withValues(
                        alpha: loopIds.contains(s.segment.id) ? 0.95 : 0.55,
                      ),
                    ),
                ],
              ),
              // Itinéraire de guidage.
              if (_route != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _route!.points,
                      strokeWidth: 5,
                      color: const Color(0xFF1565C0).withValues(alpha: 0.9),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_destination != null)
                    Marker(
                      point: _destination!,
                      width: 44,
                      height: 44,
                      alignment: Alignment.topCenter,
                      child: const Icon(Icons.location_pin,
                          size: 44, color: Color(0xFF1565C0)),
                    ),
                  if (_myPosition != null)
                    Marker(
                      point: _myPosition!,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF1565C0),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                      ),
                    ),
                  // Numéros d'ordre de la boucle de recherche.
                  if (loop != null)
                    for (final (i, s) in loop.orderedSegments.indexed)
                      Marker(
                        point: s.segment.midpoint,
                        width: 26,
                        height: 26,
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _probColor(s.probabilityFree),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ],
          ),

          // Barre de recherche + suggestions.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(28),
                    child: TextField(
                      controller: _searchController,
                      onChanged: _onQueryChanged,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Où allez-vous ?',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                      ),
                    ),
                  ),
                  if (_suggestions.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      constraints: const BoxConstraints(maxHeight: 260),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: const [
                          BoxShadow(blurRadius: 8, color: Colors.black26),
                        ],
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _suggestions.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final s = _suggestions[i];
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.place_outlined),
                            title: Text(
                              s.displayName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _selectDestination(s),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Bouton "ma position".
          Positioned(
            right: 12,
            bottom: loop != null ? 235 : 40,
            child: FloatingActionButton.small(
              heroTag: 'locate',
              backgroundColor: Colors.white,
              onPressed: _locateMe,
              child: const Icon(Icons.my_location, color: Color(0xFF1565C0)),
            ),
          ),

          if (_loadingZone)
            const Center(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Analyse des rues autour de la destination…'),
                    ],
                  ),
                ),
              ),
            ),

          if (_error != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: loop != null ? 235 : 40,
              child: Card(
                color: Colors.red.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(_error!,
                      style: TextStyle(color: Colors.red.shade900)),
                ),
              ),
            ),

          // Panneau d'information de la boucle.
          if (loop != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildLoopPanel(loop),
            ),
        ],
      ),
    );
  }

  Widget _buildLoopPanel(SearchLoop loop) {
    final pct = (loop.cumulativeProbability * 100).round();
    final minutes = _planner.expectedSearchMinutes(loop);
    final best = loop.orderedSegments.isEmpty ? null : loop.orderedSegments.first;

    return Card(
      margin: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: _probColor(loop.cumulativeProbability),
                  child: Text('$pct%',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Chances de trouver une place sur la boucle',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        'Recherche estimée : ~${minutes.ceil()} min'
                        '${best == null ? '' : ' · commencez par ${best.segment.name}'}',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.schedule, size: 18),
                const SizedBox(width: 6),
                Text(_simulatedHour == null
                    ? 'Maintenant'
                    : 'Arrivée à ${_simulatedHour}h'),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: 23,
                    divisions: 23,
                    value: (_simulatedHour ?? DateTime.now().hour).toDouble(),
                    onChanged: (v) {
                      _simulatedHour = v.round();
                      _recompute();
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Revenir à maintenant',
                  icon: const Icon(Icons.restart_alt, size: 20),
                  onPressed: _simulatedHour == null
                      ? null
                      : () {
                          _simulatedHour = null;
                          _recompute();
                        },
                ),
              ],
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loadingRoute ? null : _startGuidance,
                icon: _loadingRoute
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.navigation),
                label: Text(_route == null
                    ? 'Lancer le guidage vers la boucle'
                    : 'Recalculer l’itinéraire'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
