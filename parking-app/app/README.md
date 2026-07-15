# Application Flutter ParkRadar

Ce dossier contient les cibles web, iOS et Android de ParkRadar. La
documentation d'architecture, de configuration Supabase et de déploiement est
dans le [README du projet](../README.md).

## Démarrage local

```bash
flutter pub get
flutter analyze --fatal-infos
flutter test
flutter run -d chrome
```

Le projet utilise par défaut :

- IGN Géoplateforme pour la recherche d'adresses et de lieux parisiens ;
- Overpass/OpenStreetMap pour les rues ;
- Paris Data pour un garde-fou conservateur sur les régimes en voirie ;
- OSRM pour les itinéraires ;
- Supabase pour des signalements communautaires agrégés et interrogés par
  polling.

Ces services et le fond de carte peuvent être remplacés par `dart-define`,
notamment `GEOCODING_SEARCH_URL`, `PARIS_DATA_BASE_URL`, `OVERPASS_URL`,
`OVERPASS_FALLBACK_URL`, `OSRM_DRIVING_BASE_URL`, `MAP_TILE_URL_TEMPLATE` et
`MAP_TILE_ATTRIBUTION`. Voir la liste complète dans
[`lib/config.dart`](lib/config.dart).

## Contrats produit à préserver

- Le score initial est un prior heuristique non calibré : ne pas l'afficher
  comme une certitude ou comme une précision mesurée.
- La confiance, la fraîcheur métier, l'intervalle et les versions de prédiction
  doivent rester visibles ; un inventaire ancien n'est jamais qualifié de frais.
- Un régime Paris absent ou ambigu bloque la recommandation et le guidage de
  l'unité concernée ; l'inventaire ne remplace jamais les arrêtés sur place.
- Un signalement communautaire est un signal temporaire, pas la garantie qu'une
  place reste libre.
- La communauté repose sur un polling agrégé, pas sur du « vrai temps réel ».
- Le stationnement est mémorisé localement avant tout partage ; ce partage de
  zone est un choix explicite et ne doit jamais bloquer la fin du guidage.
- `COMMUNITY_LEGACY_FALLBACK` reste à `false` en fonctionnement normal.
- La clé Supabase embarquée doit être publishable ; ne jamais inclure de clé
  `service_role`.

## Supabase

Avant de valider la communauté, suivre
[`../supabase/ROLLOUT.md`](../supabase/ROLLOUT.md) : cron, schéma, secret HMAC et
Edge Function sont indissociables. La RPC d'écriture est privée au
`service_role`; l'app appelle l'Edge Function avec sa seule clé publishable.
La présence des valeurs Supabase par défaut ne prouve pas que le backend
distant est à jour. `../verify_backend.sh` exige un secret de monitoring non
embarqué, traverse un véritable `INSERT` de sonde puis le supprime dans la même
transaction.

## Build web publié

Depuis le dossier parent :

```bash
./build_web.sh
```

Le script valide l'application, compile avec `--base-href /parking/` et copie
le résultat dans le dossier `/parking` du dépôt. Le build doit être vérifié sur
une branche de travail avant toute fusion dans `main`.
