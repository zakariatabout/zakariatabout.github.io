# ParkRadar — le « Waze du stationnement »

Application Flutter qui guide le conducteur vers une **place de stationnement dans la rue** :
on saisit une destination, l'app colore les rues alentour selon la **probabilité d'y trouver
une place** et propose une **boucle de recherche guidée** qui maximise les chances de se garer.

L'étude de faisabilité complète est dans [ETUDE.md](ETUDE.md).

## Structure

```
parking-app/
  ETUDE.md            Étude de faisabilité (marché, algorithmes, feuille de route)
  app/                Application Flutter (web + Android)
    lib/
      models/street_segment.dart        Tronçon de rue + score
      services/probability_engine.dart  P(place libre) = 1 - occupation^capacité
      services/overpass_service.dart    Rues autour de la destination (OpenStreetMap)
      services/geocoding_service.dart   Recherche d'adresse (Nominatim)
      services/routing_service.dart     Itinéraire voiture (OSRM)
      services/search_loop_planner.dart Boucle de recherche optimale (seuil 90 %)
      screens/map_screen.dart           Carte, heatmap, panneau, guidage
    test/                               16 tests unitaires (moteur + planificateur)
```

## Données utilisées (MVP)

- **OpenStreetMap / Overpass** : géométrie des rues, sens uniques, tags `parking:lane`.
- **Nominatim** : géocodage des adresses.
- **OSRM** : calcul d'itinéraire voiture.
- **Moteur heuristique** : profils d'occupation horaires par type de rue (résidentiel/mixte),
  calibrés sur les courbes de la littérature (SFpark, Melbourne). C'est le *prior* qui sera
  remplacé progressivement par de l'historique réel et du temps réel communautaire (phase 2).

## Développement

```bash
cd parking-app/app
flutter pub get
flutter test                 # tests unitaires
flutter run -d chrome        # lancer en local
```

## Déploiement web (GitHub Pages)

```bash
cd parking-app/app
flutter build web --release --base-href /parking/
rm -rf ../../parking && cp -r build/web ../../parking
```

Le dossier `/parking` à la racine du dépôt est le build servi sur
`https://zakariatabout.github.io/parking/`.

## Android (à venir)

Le projet cible aussi Android (`flutter build apk`). Les permissions de localisation sont
déjà déclarées dans le manifest.
