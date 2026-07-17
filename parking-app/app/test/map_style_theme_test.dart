import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parking_app/services/map_style_repository.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr
    show Logger, Theme, ThemeReader;

/// Les styles vectoriels sont du DATA embarqué : ce test garantit qu'ils
/// restent dans le sous-ensemble Mapbox GL réellement supporté par
/// vector_tile_renderer (chemin GPU), où toute sortie de route est
/// SILENCIEUSE à l'exécution (layer qui disparaît, pointillés ignorés)
/// ou fatale au pré-rendu de tuile (couleur invalide).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const assetPaths = {
    'dark': MapStyleRepository.darkAsset,
    'light': MapStyleRepository.lightAsset,
  };

  final styles = <String, Map<String, dynamic>>{};
  final themes = <String, vtr.Theme>{};

  setUpAll(() {
    for (final entry in assetPaths.entries) {
      // `flutter test` s'exécute à la racine du paquet : lecture directe.
      final raw = File(entry.value).readAsStringSync();
      final style =
          MapStyleRepository.normalizeStyleJson(jsonDecode(raw))
              as Map<String, dynamic>;
      styles[entry.key] = style;
      // Logger.console : chaque propriété non supportée est visible dans la
      // sortie du test au lieu d'être avalée.
      themes[entry.key] = vtr.ThemeReader(
        logger: const vtr.Logger.console(),
      ).read(style);
    }
  });

  group('styles vectoriels ParkRadar', () {
    test('les deux styles parsent avec le vrai ThemeReader', () {
      for (final mode in assetPaths.keys) {
        expect(
          themes[mode]!.layers,
          isNotEmpty,
          reason: 'style $mode : aucun layer parsé',
        );
      }
    });

    test('aucun layer perdu en route (type/filtre non supporté)', () {
      for (final mode in assetPaths.keys) {
        final declared = (styles[mode]!['layers'] as List)
            .where(
              (layer) => (layer as Map)['layout']?['visibility'] != 'none',
            )
            .length;
        expect(
          themes[mode]!.layers.length,
          declared,
          reason:
              'style $mode : ThemeReader a écarté un layer en silence '
              '(type ou filtre hors sous-ensemble supporté)',
        );
      }
    });

    test('ids distincts (ThemeRepo.themeById est un index statique global)', () {
      expect(themes['dark']!.id, 'parkradar-dark');
      expect(themes['light']!.id, 'parkradar-light');
      expect(themes['dark']!.id, isNot(themes['light']!.id));
    });

    test('source unique "openmaptiles" (= clé de TileProviders)', () {
      for (final mode in assetPaths.keys) {
        expect(
          themes[mode]!.tileSources,
          {'openmaptiles'},
          reason: 'style $mode',
        );
      }
    });

    test('couleurs au format supporté — jamais #rrggbbaa', () {
      // ColorParser (vector_tile_renderer) LÈVE sur #rrggbbaa et sur les
      // noms de couleur : le job de pré-rendu de la tuile échouerait.
      void walk(Object? node, String path, String mode) {
        if (node is Map) {
          node.forEach((key, value) => walk(value, '$path.$key', mode));
        } else if (node is List) {
          for (var i = 0; i < node.length; i++) {
            walk(node[i], '$path[$i]', mode);
          }
        } else if (node is String) {
          if (node.startsWith('#') ||
              node.startsWith('rgb') ||
              node.startsWith('hsl')) {
            expect(
              MapStyleRepository.parseStyleColor(node),
              isNotNull,
              reason:
                  'style $mode, $path : couleur "$node" hors '
                  'sous-ensemble (#rgb, #rrggbb, rgb(), rgba(), hsl(), '
                  'hsla())',
            );
          }
        }
      }

      for (final mode in assetPaths.keys) {
        walk(styles[mode], 'style', mode);
      }
    });

    test('line-dasharray typée List<num> après normalisation', () {
      // paint_factory (vector_tile_renderer) exige `dashJson is List<num>` —
      // un List<dynamic> issu de jsonDecode ferait ignorer les pointillés en
      // silence.
      void walk(Object? node, String path, String mode) {
        if (node is Map) {
          node.forEach((key, value) {
            if (key is String && key.endsWith('-dasharray')) {
              expect(value, isA<List<num>>(), reason: 'style $mode, $path.$key');
              expect(
                (value as List).length,
                greaterThanOrEqualTo(2),
                reason: 'style $mode, $path.$key',
              );
            }
            walk(value, '$path.$key', mode);
          });
        } else if (node is List) {
          for (final item in node) {
            walk(item, path, mode);
          }
        }
      }

      for (final mode in assetPaths.keys) {
        walk(styles[mode], 'style', mode);
      }
    });

    test('couleur de fond extraite du layer background', () {
      for (final mode in assetPaths.keys) {
        // Ne lève pas = un layer "background" à couleur constante existe ;
        // cette couleur alimente MapOptions.backgroundColor.
        expect(
          () => MapStyleRepository.backgroundColorOf(styles[mode]!),
          returnsNormally,
          reason: 'style $mode',
        );
      }
    });

    test('MapStyleRepository.ensureLoaded charge les assets déclarés', () async {
      await MapStyleRepository.instance.ensureLoaded();
      expect(
        MapStyleRepository.instance.isReady,
        isTrue,
        reason: 'assets non déclarés dans pubspec.yaml ou parse en échec',
      );
      expect(
        MapStyleRepository.instance.dark!.theme.id,
        isNot(MapStyleRepository.instance.light!.theme.id),
      );
    });
  });
}
