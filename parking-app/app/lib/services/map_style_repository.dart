import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr
    show Logger, Theme, ThemeReader;

/// Style vectoriel prêt à l'emploi : thème parsé + couleur du layer
/// "background" du style. Cette couleur DOIT être recopiée dans
/// MapOptions.backgroundColor : c'est elle qui transparaît pendant le
/// chargement des tuiles et en cas d'erreur réseau (pas de fade-in en GPU).
class MapVectorStyle {
  const MapVectorStyle({required this.theme, required this.backgroundColor});
  final vtr.Theme theme;
  final Color backgroundColor;
}

/// Charge et parse UNE SEULE FOIS les styles ParkRadar depuis les assets.
///
/// Identité stable obligatoire : MapLayerState (vector_map_tiles) compare le
/// Theme PAR IDENTITÉ dans didUpdateWidget et détruit/reconstruit tout le
/// renderer GPU quand l'objet change. Ne jamais parser dans un build().
class MapStyleRepository {
  MapStyleRepository._();
  static final MapStyleRepository instance = MapStyleRepository._();

  static const darkAsset = 'assets/map_styles/parkradar_dark.json';
  static const lightAsset = 'assets/map_styles/parkradar_light.json';

  MapVectorStyle? _dark;
  MapVectorStyle? _light;
  Future<void>? _loading;

  MapVectorStyle? get dark => _dark;
  MapVectorStyle? get light => _light;
  bool get isReady => _dark != null && _light != null;

  /// Idempotent et n'échoue jamais : en cas d'asset manquant ou de JSON
  /// invalide, [isReady] reste false et l'app garde le fond raster CARTO.
  Future<void> ensureLoaded({AssetBundle? bundle}) =>
      _loading ??= _load(bundle ?? rootBundle);

  Future<void> _load(AssetBundle bundle) async {
    try {
      final styles = await Future.wait([
        _loadStyle(bundle, darkAsset),
        _loadStyle(bundle, lightAsset),
      ]);
      assert(
        styles[0].theme.id != styles[1].theme.id,
        'Styles dark et light : "id" DISTINCTS obligatoires — '
        'ThemeRepo.themeById (vector_map_tiles) est un index statique global.',
      );
      _dark = styles[0];
      _light = styles[1];
    } catch (error, stack) {
      // Repli raster silencieux en release, visible en dev.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'MapStyleRepository',
          context: ErrorDescription('chargement des styles vectoriels'),
        ),
      );
    }
  }

  Future<MapVectorStyle> _loadStyle(AssetBundle bundle, String asset) async {
    final raw = await bundle.loadString(asset);
    final style = normalizeStyleJson(jsonDecode(raw)) as Map<String, dynamic>;
    final theme = vtr.ThemeReader(
      // En dev, chaque propriété/expression non supportée émet un warn
      // explicite au lieu de faire disparaître le layer en silence.
      logger: kDebugMode ? const vtr.Logger.console() : const vtr.Logger.noop(),
    ).read(style);
    return MapVectorStyle(
      theme: theme,
      backgroundColor: backgroundColorOf(style),
    );
  }

  /// jsonDecode produit des listes dynamiques ; or paint_factory.dart (l.120
  /// de vector_tile_renderer) exige `is List<num>` pour line-dasharray, sinon
  /// les pointillés sont IGNORÉS en silence. On retype récursivement toute
  /// liste 100 % numérique (sans effet de bord : `List<num>` est un List).
  @visibleForTesting
  static Object? normalizeStyleJson(Object? node) {
    if (node is Map) {
      return <String, dynamic>{
        for (final entry in node.entries)
          entry.key as String: normalizeStyleJson(entry.value),
      };
    }
    if (node is List) {
      final items = node.map(normalizeStyleJson).toList(growable: false);
      if (items.isNotEmpty && items.every((item) => item is num)) {
        return List<num>.unmodifiable(items.cast<num>());
      }
      return items;
    }
    return node;
  }

  /// Couleur du layer "background" — source de vérité unique du fond.
  @visibleForTesting
  static Color backgroundColorOf(Map<String, dynamic> style) {
    final layers = style['layers'];
    if (layers is List) {
      for (final layer in layers) {
        if (layer is Map && layer['type'] == 'background') {
          final paint = layer['paint'];
          final color = parseStyleColor(
            paint is Map ? paint['background-color'] : null,
          );
          if (color != null) return color;
        }
      }
    }
    throw const FormatException(
      'style sans layer "background" à couleur constante',
    );
  }

  /// Sous-ensemble accepté par ColorParser (vector_tile_renderer) : #rgb,
  /// #rrggbb, rgb(), rgba(), hsl(), hsla(). PAS de #rrggbbaa ni de noms de
  /// couleur (ColorParser lèverait pendant le pré-rendu de tuile).
  @visibleForTesting
  static Color? parseStyleColor(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    if (text.startsWith('#')) {
      var hex = text.substring(1);
      if (hex.length == 3) {
        hex = hex.split('').map((c) => '$c$c').join();
      }
      if (hex.length != 6) return null;
      final rgb = int.tryParse(hex, radix: 16);
      return rgb == null ? null : Color(0xFF000000 | rgb);
    }
    final match = RegExp(r'^(rgba?|hsla?)\(([^)]+)\)$').firstMatch(text);
    if (match == null) return null;
    final parts = match
        .group(2)!
        .split(',')
        .map((p) => p.trim())
        .toList(growable: false);
    if (parts.length < 3) return null;
    final alpha = parts.length > 3 ? (double.tryParse(parts[3]) ?? 1.0) : 1.0;
    if (match.group(1)!.startsWith('rgb')) {
      final r = int.tryParse(parts[0]);
      final g = int.tryParse(parts[1]);
      final b = int.tryParse(parts[2]);
      if (r == null || g == null || b == null) return null;
      return Color.fromRGBO(r, g, b, alpha);
    }
    final h = double.tryParse(parts[0]);
    final s = double.tryParse(parts[1].replaceAll('%', ''));
    final l = double.tryParse(parts[2].replaceAll('%', ''));
    if (h == null || s == null || l == null) return null;
    return HSLColor.fromAHSL(
      alpha.clamp(0.0, 1.0),
      h % 360,
      s / 100,
      l / 100,
    ).toColor();
  }
}
