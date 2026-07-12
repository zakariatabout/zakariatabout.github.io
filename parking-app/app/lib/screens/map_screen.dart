import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/street_segment.dart';
import '../services/community_adjuster.dart';
import '../services/community_service.dart';
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
  final _community = CommunityService();
  final _adjuster = const CommunityAdjuster();

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
  List<ParkingEvent> _communityEvents = [];
  bool _reporting = false;

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
      _refreshCommunityEvents();
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _error = 'Impossible de charger les rues (réessayez)');
    } finally {
      if (mounted) setState(() => _loadingZone = false);
    }
  }

  /// Recalcule probabilités + boucle (appelé après chargement, quand l'heure
  /// simulée change et quand des signalements arrivent).
  void _recompute() {
    final dest = _destination;
    if (dest == null || _rawSegments.isEmpty) return;
    var scored = _engine.scoreAll(_rawSegments, _arrivalTime);
    // Correction temps réel : uniquement pour une arrivée "maintenant".
    if (_simulatedHour == null && _communityEvents.isNotEmpty) {
      scored = _adjuster.adjust(scored, _communityEvents, DateTime.now());
    }
    final loop = _planner.plan(scored, dest);
    setState(() {
      _scored = scored;
      _loop = loop;
      _route = null;
    });
  }

  Future<void> _refreshCommunityEvents() async {
    final dest = _destination;
    if (dest == null) return;
    try {
      final events = await _community.recentEventsNear(dest);
      if (!mounted) return;
      _communityEvents = events;
      _recompute();
    } catch (_) {
      // Couche temps réel optionnelle : on ignore les échecs réseau.
    }
  }

  /// Signale « je me gare » (type 'parked') ou « je libère » (type 'freed')
  /// à la position GPS actuelle.
  Future<void> _reportEvent(String type) async {
    setState(() => _reporting = true);
    try {
      final pos = await _locateMe(moveCamera: false);
      if (pos == null) {
        _showSnack('Position GPS indisponible');
        return;
      }
      final ok = await _community.report(type, pos);
      _showSnack(ok
          ? (type == 'freed'
              ? 'Merci ! Place signalée aux autres conducteurs'
              : 'Bien garé ! Rue mise à jour')
          : 'Signalement impossible (réessayez)');
      if (ok) await _refreshCommunityEvents();
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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

  /// Couleur en dégradé continu rouge → orange → vert selon la probabilité.
  /// Le dégradé (plutôt que 3 paliers) fait ressortir les rues « les moins
  /// pires » même quand tout le quartier est chargé.
  Color _probColor(double p) {
    // On étale [0 .. 0.65] sur la teinte rouge(0°) → vert(120°).
    final t = (p / 0.65).clamp(0.0, 1.0);
    return HSVColor.fromAHSV(1.0, t * 120.0, 0.72, 0.82).toColor();
  }

  /// Formulation honnête du niveau de chances cumulé (évite le « 100 % »
  /// trompeur au-dessus d'un quartier plein).
  ({String label, IconData icon}) _qualitative(double cumulative) {
    if (cumulative >= 0.85) {
      return (label: 'Très bonnes chances', icon: Icons.sentiment_very_satisfied);
    }
    if (cumulative >= 0.6) {
      return (label: 'Bonnes chances', icon: Icons.sentiment_satisfied);
    }
    if (cumulative >= 0.35) {
      return (label: 'Chances moyennes', icon: Icons.sentiment_neutral);
    }
    return (label: 'Stationnement difficile', icon: Icons.sentiment_dissatisfied);
  }

  Widget _legend() {
    Widget item(double p, String txt) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 11,
              height: 11,
              decoration:
                  BoxDecoration(color: _probColor(p), shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(txt, style: const TextStyle(fontSize: 11)),
          ],
        );
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            item(0.1, 'Peu'),
            const SizedBox(width: 10),
            item(0.4, 'Moyen'),
            const SizedBox(width: 10),
            item(0.65, 'Bonnes'),
          ],
        ),
      ),
    );
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
                  // Places libérées récemment par la communauté.
                  for (final e in _communityEvents.where((e) => e.isFreed))
                    Marker(
                      point: e.position,
                      width: 24,
                      height: 24,
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00897B),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Text(
                          'P',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
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

          // Légende des couleurs.
          if (_scored.isNotEmpty && _suggestions.isEmpty)
            Positioned(
              top: 74,
              left: 12,
              child: SafeArea(child: _legend()),
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
    final minutes = _planner.expectedSearchMinutes(loop);
    // Chiffre honnête : la probabilité de la MEILLEURE rue (une chance réelle
    // sur une rue), pas le cumul gonflé qui atteint vite 100 %.
    final ranked = [...loop.orderedSegments]
      ..sort((a, b) => b.probabilityFree.compareTo(a.probabilityFree));
    final best = ranked.isEmpty ? null : ranked.first;
    final bestPct = best == null ? 0 : (best.probabilityFree * 100).round();
    final qual = _qualitative(loop.cumulativeProbability);

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
                  backgroundColor:
                      best == null ? Colors.grey : _probColor(best.probabilityFree),
                  child: Text('$bestPct%',
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
                      Row(
                        children: [
                          Icon(qual.icon, size: 18, color: Colors.black54),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '${qual.label} en parcourant '
                              '${loop.orderedSegments.length} rue'
                              '${loop.orderedSegments.length > 1 ? 's' : ''}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        best == null
                            ? 'Recherche estimée : ~${minutes.ceil()} min'
                            : 'Visez ${best.segment.name} · recherche ~${minutes.ceil()} min',
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
            if (_community.isEnabled) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _reporting ? null : () => _reportEvent('parked'),
                      icon: const Icon(Icons.local_parking, size: 18),
                      label: const Text('Je me gare'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _reporting ? null : () => _reportEvent('freed'),
                      icon: const Icon(Icons.time_to_leave, size: 18),
                      label: const Text('Je libère'),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _community.isRemote ? Icons.groups : Icons.phone_android,
                      size: 13,
                      color: Colors.black45,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _community.isRemote
                          ? 'En direct avec la communauté'
                          : 'Mode démo (signalements sur cet appareil)',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.black45),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
