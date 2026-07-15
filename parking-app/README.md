# ParkRadar

ParkRadar est une application Flutter d'aide à la recherche de stationnement en
voirie à Paris. L'utilisateur saisit une destination, consulte les rues
candidates et peut lancer une boucle de recherche guidée.

Le produit manipule des **estimations**, pas des places garanties : le moteur
actuel est un prior heuristique non calibré sur une vérité terrain
représentative. Il expose l'incertitude, la fraîcheur et les versions du modèle,
mais sa valeur ne doit pas être présentée comme un pourcentage fiable tant
qu'une calibration supervisée locale n'a pas été validée.

L'étude de faisabilité initiale est dans [ETUDE.md](ETUDE.md). L'audit
stratégique et technique 2026 est dans
[ETUDE_FIABILITE_PRODUIT_2026.md](ETUDE_FIABILITE_PRODUIT_2026.md).

> **État du backend public au 15 juillet 2026 : non conforme au nouveau
> contrat.** Le contrôle `verify_backend.sh` échoue tant que le schéma, le cron,
> les secrets et l'Edge Function décrits ci-dessous ne sont pas déployés. Le
> client conserve toutes ses fonctions locales mais la communauté distante ne
> doit pas être présentée comme opérationnelle avant un contrôle vert.

## Comportement actuellement implémenté

- **Destinations** : recherche IGN Géoplateforme combinant adresses et lieux
  d'intérêt, limitée à Paris.
- **Réseau viaire** : géométrie contextuelle OpenStreetMap interrogée par
  Overpass. Les décisions utilisent des unités dérivées de Paris Data ; un way
  OSM contextuel ne peut pas étendre une autorisation à toute une rue.
- **Réglementation** : inventaire Paris Data paginé, régime interprété comme
  garde-fou conservateur et capacité déclarée utilisée lorsqu'elle existe. Un
  point est converti en court segment technique : ce n'est ni une emprise de
  bordure officielle ni un moteur complet de règles temporelles ou d'arrêtés.
  Une donnée absente ou ambiguë devient `unknown`, jamais une autorisation.
  La couche carte distingue payant, gratuit, résident, réservé et interdit par
  couleur et motif ; toucher une ligne ouvre régime, voie, capacité, provenance
  de capacité et date métier de la source.
- **Prédiction** : prior horaire conservateur, intervalle d'incertitude,
  confiance, fraîcheur et versions. Le calibrateur par défaut est l'identité et
  déclare zéro observation supervisée. Les heures sont évaluées dans le fuseau
  IANA `Europe/Paris`, changements été/hiver compris.
- **Boucle de recherche** : sélection plafonnée de rues proches avec décote de
  corrélation spatiale. Son score cumulé reste une estimation non calibrée, pas
  une certitude d'obtenir une place.
- **Itinéraire** : route OSRM, étapes de manœuvre structurées et reroutage
  seulement après un écart réel à la polyligne.
- **Communauté** : signalements `parked` / `freed` récupérés par polling,
  agrégés par cellule de 70–110 m, effet maximal de 12 points et TTL. Le flux
  public tronque l'horodatage à la minute ; la ligne privée garde son heure
  technique jusqu'à sa purge après environ 24 h (moins d'une minute de
  dépassement planifié). Le partage explicite passe par une
  Edge Function limitée par IP ; le mode local reste disponible. Ce n'est ni
  un WebSocket ni une disponibilité « en vrai temps réel ».
- **Session garée** : mémorisation locale indépendante du réseau, position
  arrondie et expiration après 24 heures.
- **Carte** : fournisseur de tuiles et attribution configurables. L'attribution
  doit rester visible et conforme à la licence du fournisseur choisi.

Un inventaire chargé mais ancien ou partiellement non daté reste visible comme
inventaire, avec avertissement explicite et sans devenir « frais ». Seule une
absence de couverture bloque le guidage ; dans tous les cas la signalisation
sur place prévaut.

Le garde-fou Paris Data est **fail-closed** : si l'inventaire est indisponible,
vide ou ambigu, les unités concernées ne peuvent pas être recommandées et le
guidage reste désactivé. Ce choix réduit les faux positifs mais ne certifie pas
la légalité ; la signalisation et les arrêtés sur place prévalent toujours.

## Structure

```text
parking-app/
  ETUDE.md
  ETUDE_FIABILITE_PRODUIT_2026.md
  build_web.sh                    validation + build GitHub Pages
  supabase/schema.sql             RPC, RLS, agrégation, TTL et limites
  supabase/functions/             porte d'écriture Edge sans secret client
  app/
    lib/
      config.dart                 dart-define et valeurs par défaut
      controllers/                état et orchestration de la carte
      models/                     tronçons et estimations auditables
      services/                   données, prédiction, routage, communauté
      screens/                    écrans Flutter
      widgets/                    composants UI accessibles
    test/                         tests unitaires et widgets
```

## Sources et limites

| Source | Usage | Limite à conserver dans le produit |
|---|---|---|
| IGN Géoplateforme | Recherche d'adresses et de lieux | Service distant soumis à quota ; l'UI doit conserver son debounce |
| OpenStreetMap / Overpass | Rues, sens uniques, tags de stationnement | Données contributives et non exhaustives |
| Paris Data | Inventaire de régimes et capacités déclarées | Garde-fou incomplet et évolutif ; absence de donnée ≠ stationnement autorisé |
| OSRM | Itinéraire et manœuvres | Le serveur public n'est pas un SLA de production |
| Supabase | Signalements communautaires | Signal indirect et temporaire, jamais preuve qu'une place attend l'utilisateur |

## Configuration de compilation

Toutes les valeurs sont remplaçables sans modifier le code. Les valeurs
ci-dessous sont celles de `app/lib/config.dart`.

| `dart-define` | Valeur par défaut | Rôle |
|---|---|---|
| `GEOCODING_SEARCH_URL` | `https://data.geopf.fr/geocodage/search` | Recherche IGN adresse + lieu |
| `PARIS_DATA_BASE_URL` | `https://opendata.paris.fr/api/explore/v2.1/catalog/datasets` | Réglementation Paris |
| `OVERPASS_URL` | `https://overpass-api.de/api/interpreter` | Réseau viaire OSM |
| `OVERPASS_FALLBACK_URL` | vide | Secours désactivé ; n'injecter qu'un service contractuel ou autohébergé |
| `OSRM_DRIVING_BASE_URL` | `https://router.project-osrm.org/route/v1/driving` | Routage voiture |
| `MAP_TILE_URL_TEMPLATE` | `https://tile.openstreetmap.org/{z}/{x}/{y}.png` | Fond cartographique |
| `MAP_TILE_ATTRIBUTION` | `© contributeurs OpenStreetMap` | Attribution visible |
| `SUPABASE_URL` | `https://xkhsvwqzuzmrvdrghshv.supabase.co` | API communautaire |
| `SUPABASE_ANON_KEY` | clé publishable ParkRadar | Authentification PostgREST publique |
| `COMMUNITY_LEGACY_FALLBACK` | `false` | Repli temporaire vers l'ancienne table brute ; interdit en fonctionnement normal |
| `COMMUNITY_REPORT_URL` | dérivé de `SUPABASE_URL` | Edge Function d'écriture communautaire |
| `NETWORK_TIMEOUT_SECONDS` | `30` | Timeout des données publiques |
| `OVERPASS_TIMEOUT_SECONDS` | `18` | Timeout par endpoint Overpass ; l'orchestrateur bascule sur Paris Data après son propre budget court |
| `COMMUNITY_TIMEOUT_SECONDS` | `12` | Timeout Supabase |
| `COMMUNITY_EVENT_TTL_MINUTES` | `15` | Âge maximal lu par l'app |
| `COMMUNITY_RETENTION_HOURS` | `24` | Rétention locale ; le serveur purge après 24 h avec un cron chaque minute |
| `COMMUNITY_POLL_INTERVAL_SECONDS` | `20` | Intervalle de polling |
| `PARIS_DATA_MAX_PAGES` | `100` | Garde-fou de pagination |

`NOMINATIM_SEARCH_URL` n'est conservé que pour une migration contrôlée d'un
ancien build. Il ne doit pas être défini pour le build normal : l'API publique
Nominatim n'autorise pas l'autocomplétion intensive.

Le template de tuiles OSM par défaut convient au développement et aux faibles
volumes, pas à une montée en charge sans accord. En production, fournir un
endpoint contractuel ou autohébergé via `MAP_TILE_URL_TEMPLATE`, avec
`MAP_TILE_ATTRIBUTION` correspondant exactement à sa licence.

## Développement et validation

```bash
cd parking-app/app
flutter pub get
flutter analyze --fatal-infos
flutter test
flutter run -d chrome
```

Le build de livraison requiert aussi Deno pour tester l'Edge Function et
parser la migration PostgreSQL.

Les erreurs, avertissements et remarques d'analyse sont bloquants.
Le nombre de tests n'est volontairement pas figé dans ce document.

Pour vérifier un build identique au site publié :

```bash
cd parking-app
./build_web.sh
```

Le script exécute `flutter pub get`, l'analyse et toute la suite de tests avant
de compiler. Il remplace ensuite le dossier `/parking` à la racine du dépôt par
`app/build/web`. Il ne commit, ne fusionne et ne pousse rien.

## Couche communautaire Supabase

Le schéma sécurisé est un **prérequis**, même si une URL et une clé publishable
sont déjà fournies par défaut :

1. Activer Supabase Cron puis ouvrir le SQL Editor du projet ciblé.
2. Exécuter intégralement [supabase/schema.sql](supabase/schema.sql).
3. Déployer l'Edge Function `report-parking-event` avec son sel HMAC serveur.
4. Vérifier que RLS est active et que `anon` / `authenticated` ne peuvent ni
   lire ni écrire directement `parking_events`.
5. Vérifier que `report_parking_event` est réservée à `service_role`, détenue
   uniquement par l'Edge Function, et que `recent_parking_events` reste lisible
   avec la clé publishable.
6. Conserver `COMMUNITY_LEGACY_FALLBACK=false` pour tous les builds normaux.
7. Exécuter `PARKRADAR_HEALTHCHECK_TOKEN='<secret-monitoring>' \
   ./parking-app/verify_backend.sh` et exiger un résultat vert avant la
   publication. Ce secret de santé n'est jamais compilé dans l'application.
   L'ordre détaillé est documenté dans
   [supabase/ROLLOUT.md](supabase/ROLLOUT.md).

Le SQL quantifie les coordonnées, hache le jeton d'installation, limite les
rafales par installation/IP/cellule, déduplique les auteurs, expose uniquement
des cellules agrégées récentes et planifie chaque minute la purge des lignes de
plus de 24 heures. Le polling applicatif est non chevauchant et ses requêtes
sont annulables. La clé publishable identifie le client mais n'est pas un
secret : limitation au gateway, détection d'anomalies, reçus de session et
attestation d'application restent nécessaires contre les attaques Sybil à
grande échelle.

La CI parse `schema.sql` avec le parseur PostgreSQL et teste l'Edge Function,
mais elle ne remplace pas une exécution Supabase réelle avec `pg_cron`, RLS et
PostgREST. `verify_backend.sh` reste donc une porte de publication obligatoire.

Si l'Edge Function, les RPC, le cron ou les politiques RLS ne sont pas
déployés, la couche communautaire doit échouer proprement ; elle ne doit pas
revenir à la lecture publique de la table brute. Les boutons ne dépendent pas
de la présence de variables de build, car des valeurs publishables sont déjà
configurées par défaut.

## Déploiement GitHub Pages

GitHub Pages sert le dossier racine `/parking` sur
[zakariatabout.github.io/parking](https://zakariatabout.github.io/parking/).
Le workflow attendu est :

1. Créer ou utiliser une branche de travail ; ne pas développer directement
   sur `main`.
2. Implémenter et vérifier localement `flutter analyze --fatal-infos`,
   `flutter test`, puis `./parking-app/build_web.sh` depuis la racine.
3. Tester le dossier généré `/parking` sur la branche de travail, y compris la
   recherche IGN, le fail-closed légal, l'attribution de carte et les RPC
   Supabase.
4. Pour une publication, relancer le build avec
   `PARKRADAR_HEALTHCHECK_TOKEN='<secret-monitoring>' \
   VERIFY_REMOTE_BACKEND=true ./parking-app/build_web.sh` afin de bloquer si
   Supabase n'est pas conforme.
5. Committer la branche seulement lorsque ces validations sont vertes.
6. Fusionner dans `main` après validation fonctionnelle ; `main` est la branche
   publiée. Pousser ensuite `main`.

Ne pas créer de pull request sauf demande explicite et ne jamais pousser un
build cassé sur `main`.

## Mobile

Le projet contient les cibles iOS et Android. Les mêmes limites de vérité
produit, de réglementation et de confidentialité s'appliquent aux builds
mobiles. Une clé publishable Supabase peut être distribuée dans l'app ; une clé
`service_role` ou tout autre secret serveur ne le peut jamais.

Le build Android `release` n'utilise jamais la signature de debug : il est non
signé en CI et ne devient distribuable qu'avec un `android/key.properties` et
un keystore de production conservés hors dépôt. Le job iOS valide un build
`--no-codesign`; l'archive App Store exige les certificats et profils réels.

## Portes externes avant publication publique

- déployer le schéma Supabase v4, le cron, l'Edge Function et ses secrets, puis
  obtenir un `verify_backend.sh` vert avec le secret de monitoring ;
- choisir des fournisseurs cartographie/routage/Overpass contractuels ou
  autohébergés : les endpoints publics par défaut n'offrent pas le SLA requis ;
- publier une politique de confidentialité et des mentions légales avec le
  responsable, les finalités, destinataires, durées, droits et un contact réel,
  puis les rendre accessibles avant le partage et depuis l'application ;
- installer les identités de signature stores et l'attestation d'application ;
- collecter une vérité terrain représentative et franchir les métriques de
  calibration/temps de recherche de l'étude avant toute promesse de précision.
