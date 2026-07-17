# ParkRadar — Plan d'excellence technique (2026)

> Troisième volet du corpus d'études : [`ETUDE.md`](ETUDE.md) (faisabilité),
> [`ETUDE_FIABILITE_PRODUIT_2026.md`](ETUDE_FIABILITE_PRODUIT_2026.md) (fiabilité
> & backend), [`ETUDE_PRODUIT_PRO_WAZE_2026.md`](ETUDE_PRODUIT_PRO_WAZE_2026.md)
> (marché & positionnement). **Celui-ci est différent : il est ancré dans le code
> réel.** Il résulte de deux audits exhaustifs du codebase (écran/contrôleur d'une
> part, couche services d'autre part — fichiers, méthodes et lignes cités) croisés
> avec une recherche des meilleures briques techniques disponibles. Chaque
> chantier dit : *quoi coder, dans quels fichiers, avec quoi, dans quel ordre, et
> comment vérifier que c'est réussi.*

Date : juillet 2026 — Version 1.0 — Base de code auditée : branche
`codex/etude-fiabilite-parkradar-2026` (commit `c305067`, 176 tests verts).

---

## 0. Synthèse exécutive

L'audit confirme une **fondation d'ingénierie sérieuse** : machine à phases
(`ParkingMapPhase`) comme source de vérité unique, protections systématiques
contre les réponses réseau obsolètes (compteurs de génération), garde-fou légal
« fail-closed », design system complet, accessibilité soignée, erreurs réseau
typées. **À préserver absolument.**

Mais l'audit révèle aussi **trois découvertes structurantes** :

1. **Le mode conduite n'existe pas encore.** Le « guidage » actuel est un bandeau
   d'instruction posé sur une carte statique orientée nord : pas de voix, pas de
   rotation selon le cap, pas d'ETA, pas de plein écran — et **l'écran peut
   s'éteindre en pleine navigation** (aucun wakelock). Or les données pour tout
   cela (`headingDegrees`, `speedMetersPerSecond`, `alongRouteMeters`,
   `durationSeconds`, instructions OSRM en français prêtes à vocaliser) sont
   **déjà calculées par le code… puis jetées**.

2. **La boucle d'apprentissage est débranchée.** Le calibrateur supervisé
   (`LogisticProbabilityCalibrator`, Platt scaling) est **écrit, testé… et jamais
   instancié**. Surtout, il n'existe **aucun mécanisme d'enregistrement des
   observations terrain** (« j'ai trouvé une place / je n'ai pas trouvé ») ni
   **aucune télémétrie**. Sans collecte, la confiance restera plafonnée à vie et
   les études précédentes (calibration = mur n°1) resteront lettre morte.

3. **Le rendu se reconstruit intégralement à chaque échantillon GPS.** Un
   `setState` global rebâtit l'écran entier (2 166 lignes de widgets, polylines
   et marqueurs recalculés) plusieurs fois par seconde en guidage. Ajouter voix
   et rotation sans corriger cela aggraverait la charge et la batterie : **la
   performance est le prérequis des chantiers conduite.**

L'ordre d'exécution recommandé découle mécaniquement de ces trois faits :
**A. Performance → B. Mode Conduite Pro → C. Boucle d'apprentissage →
D. Cache & résilience → E. Temps réel → F. Détection auto → G. Fondations.**

---

## 1. État des lieux — forces et manques (issus de l'audit)

### Forces à préserver (ne pas casser en refactorant)
| Force | Où |
|---|---|
| Machine à phases + état immuable `copyWith` avec sentinelle `_unset` | `parking_map_controller.dart:21,147-225` |
| Compteurs de génération anti-réponses obsolètes (recherche, destination, route, plan, tracking, session) | contrôleur, partout |
| Écritures de session sérialisées + compensation si libération pendant un POST | `map_screen.dart:319-440` |
| Garde-fou légal : aucun guidage sans couverture réglementaire vérifiée | `hasVerifiedLegalCoverage`, `canStartGuidance` (contrôleur:97,144) |
| Chargement par couches non bloquant (Paris Data ≠ Overpass ≠ communauté) | `selectDestination` (contrôleur:386-445) |
| Erreurs réseau typées (`sealed NetworkException`), double timeout, abort propre | `network_client.dart:100-216` |
| Accessibilité : `Semantics` systématiques, `liveRegion` sur HUD, cibles 48 dp, info jamais portée par la couleur seule | `map_screen.dart` + design system |
| Reroutage automatique déjà présent (base saine) | `_maybeReroute` (contrôleur:797-821) |

### Manques bloquants pour un « niveau Waze »
| # | Manque | Preuve dans le code |
|---|---|---|
| M1 | Rebuild global à chaque échantillon GPS ; polylines/markers recalculés à chaque frame | `_handleControllerChanged` → `setState(() {})` (`map_screen.dart:168`) ; `_availabilityPolylines:647`, `_markers:807-963` |
| M2 | Aucun TTS (guidage 100 % visuel) | grep `tts/speak` = 0 ; `pubspec.yaml` sans paquet audio |
| M3 | Écran peut s'éteindre en navigation | aucun wakelock dans le projet |
| M4 | Carte nord-en-haut : `headingDegrees` capturé puis ignoré | `location_service.dart:52` vs `map_screen.dart:283` (`move` sans rotation) |
| M5 | Pas d'ETA ni de restant : `durationSeconds` et `alongRouteMeters` jetés | `_syncGuidanceStep:189-197` ne garde que `stepIndex` |
| M6 | Tracker n'expose pas la distance à la prochaine manœuvre (offsets privés) | `route_progress_tracker.dart` (`_stepOffsets` privé) |
| M7 | Perte GPS = arrêt sec du guidage (pas de reprise/backoff — tunnels) | `onError` (`map_screen.dart:287-304`) |
| M8 | Reroute grossier : seuil fixe 60 m/30 s, 1 sample aberrant suffit, double calcul de distance | `_maybeReroute` (contrôleur:797-821) |
| M9 | Calibrateur supervisé jamais branché ; **aucun store d'observations, aucune télémétrie** | `LogisticProbabilityCalibrator` non instancié ; `engine = const ProbabilityEngine()` (contrôleur:238) |
| M10 | **Aucun cache** : Paris Data + Overpass + routes re-téléchargés à chaque recherche | grep `cache` = 0 ; `selectDestination:412` |
| M11 | Aucun retry/backoff réseau ; fallback Overpass vide par défaut | `network_client.dart` ; `config.dart:43-48` |
| M12 | Communauté : polling 20 s (pas de Supabase Realtime) ; `watchRecentEventsNear` = code mort | `config.dart:82-85` ; contrôleur `_startCommunityPolling:914` |
| M13 | i18n inexistante : dizaines de chaînes FR en dur, y compris dans le contrôleur (couche métier) | contrôleur:228,439,691 ; formats de date faits main |
| M14 | `map_screen.dart` = god-file de 2 166 lignes (rendu + GPS + session + partage + formatage) | structure du fichier |
| M15 | Pas de thème nuit/plein écran/paysage adaptés à la conduite | `main.dart:20` (`ThemeMode.system` figé) |

---

## 2. Chantier A — Performance de rendu *(prérequis, effort : S-M)*

**Objectif :** que le mode guidage coûte quasi zéro rebuild par échantillon GPS.

1. **Découper l'écoute du contrôleur.** Remplacer le `setState` global
   (`map_screen.dart:168`) par des sous-arbres sélectifs :
   `ListenableBuilder`/`ValueListenableBuilder` par zone (HUD, panneau, couches
   carte), ou exposer des `ValueNotifier` ciblés depuis le contrôleur
   (position, phase, route). La position GPS ne doit redessiner **que** le
   marqueur véhicule et le HUD, jamais les polylines.
2. **Mémoïser les couches.** Cacher `_availabilityPolylines`, `_legalPolylines`
   et `_markers` : ne les recalculer que quand `scored`/`parisSpots`/`loop`/
   `communityEvents` changent (comparaison d'identité suffit, l'état est
   immuable). La `Polyline` d'itinéraire ne doit être reconstruite qu'au
   reroutage.
3. **Mesurer avant/après** avec DevTools (rebuild counts) et inscrire le
   résultat dans le commit.

**Critère de réussite :** en guidage, un échantillon GPS ne déclenche plus le
rebuild des `PolylineLayer`/`MarkerLayer` (vérifiable au compteur de rebuilds) ;
aucune régression des 176 tests.

---

## 3. Chantier B — Mode Conduite Pro *(le cœur « Waze », effort : M-L)*

Transformer la phase `guiding` en véritable copilote. Tout s'appuie sur des
données **déjà présentes**.

### B1. Immédiat (quick wins, quelques heures chacun)
- **Wakelock** : paquet `wakelock_plus`, activé à l'entrée en `guiding`,
  désactivé à la sortie (`_startGuidance`/`_stopGuidance`,
  `map_screen.dart:252-317`). → règle M3.
- **Thème conduite** : forcer un mode sombre à fort contraste pendant
  `guiding` (rendre `themeMode` réactif à la phase — `main.dart:20`). → M15.
- **Layout conduite** : quand `phase == guiding`, basculer sur un layout dédié
  dans `build` (`map_screen.dart:557-581`) : HUD manœuvre en très gros
  (`displaySmall` plutôt que `titleMedium`), bandeau bas ETA/restant, overlays
  non essentiels masqués, `SystemChrome` immersif. En paysage : carte plein
  écran, HUD en colonne latérale fine (ne pas réutiliser le panneau 420 px).

### B2. ETA & progression (déblocage de données jetées)
- **Exposer `distanceToNextManeuverMeters` et `remainingMeters` /
  `remainingSeconds`** dans `RouteProgressSnapshot`
  (`route_progress_tracker.dart` — les `_stepOffsets` privés contiennent déjà
  tout ; il manque 3 champs publics). → M5, M6.
- **HUD** : afficher « Dans 200 m → Tournez à droite sur X », ETA (heure
  locale), distance restante. `_syncGuidanceStep` (`map_screen.dart:189-197`)
  doit conserver le snapshot complet, pas seulement `stepIndex`.

### B3. Caméra de conduite
- **Propager `headingDegrees` et `speedMetersPerSecond`** du
  `LocationSample` jusqu'au contrôleur (`updateUserPosition` ne transmet que la
  position — contrôleur:578). → M4.
- **`moveAndRotate`** pendant le guidage : carte orientée cap, véhicule au
  tiers inférieur (offset), zoom adaptatif à la vitesse. Bouton « recentrer »
  qui réapparaît après un pan manuel (état `cameraFollowing`).
- flutter_map supporte la rotation ; pour un rendu vraiment fluide à terme,
  voir Chantier G (MapLibre vectoriel).

### B4. Guidage vocal (TTS)
- Paquet **[flutter_tts](https://fluttergems.dev/ai-voice-assistant/)** (ou
  l'abstraction [voice_guidance](https://pub.dev/packages/voice_guidance) pour
  garder le domaine indépendant de la plateforme). L'approche standard :
  [les instructions de manœuvre sont des chaînes envoyées au TTS de la
  plateforme](https://developer.here.com/documentation/flutter-sdk-navigate/4.7.3.0/dev_guide/topics/navigation.html).
- **Le contenu existe déjà** : `RouteStep.instruction` est généré en français
  (« Tournez à droite sur X » — `routing_service.dart:169-189`). Créer un
  `VoiceGuidanceService` : annonce à la transition d'étape **et** à des seuils
  de distance (400 m / 100 m / « maintenant »), anti-répétition, mute
  utilisateur, respect du mode silencieux. Point d'insertion :
  `_syncGuidanceStep` + les seuils issus de B2. → M2.
- ⚠️ Tester sur appareil réel (les moteurs TTS varient fortement iOS/Android —
  les émulateurs ne reproduisent pas l'audio natif).

### B5. Résilience GPS & reroute intelligent
- **Perte GPS ≠ arrêt** : remplacer l'arrêt sec (`onError`,
  `map_screen.dart:287-304`) par un état HUD « signal GPS perdu » + reprise
  automatique avec backoff (tunnels, parkings couverts). → M7.
- **Reroute robuste** : exiger N échantillons off-route consécutifs, seuil
  fonction de `accuracyMeters` et de la vitesse, et réutiliser
  `distanceToRouteMeters` du tracker au lieu du second calcul dans
  `_maybeReroute`. → M8.

**Critères de réussite B :** guidage testable en voiture avec téléphone posé :
écran toujours allumé, carte orientée cap, annonces vocales aux bons moments,
ETA visible, traversée d'un tunnel sans perdre la session.

---

## 4. Chantier C — Boucle d'apprentissage *(le fossé concurrentiel, effort : M)*

C'est la traduction en code du « mur n°1 » des études précédentes. La
consommation est prête (`LogisticProbabilityCalibrator` codé, versions
propagées) ; **il manque toute la collecte**.

1. **Store d'observations d'issue de recherche** (nouveau
   `SearchOutcomeStore`) : à la fin d'un guidage, enregistrer
   `(segmentId, PredictionVersions, predictedProbability, plannedHour,
   outcome ∈ {trouvé, non-trouvé, abandonné}, searchMinutes réels, timestamp)`.
   Déclencheurs déjà en place : « Place trouvée » (`_reportParked`) et
   « Arrêter » (`_stopGuidance`) — il suffit d'y brancher l'écriture. Les
   `parked/freed` communautaires actuels ne sont **pas** des labels (quantifiés
   ~100 m, sans probabilité associée) : ne pas les confondre.
2. **Mini-télémétrie qualité** (respectueuse : agrégats anonymes, opt-in) :
   export périodique des observations vers une table Supabase dédiée →
   permet de calculer hors-ligne **Brier score, reliability diagram, ECE** et
   les paramètres du calibrateur.
3. **Brancher le calibrateur** : instancier
   `LogisticProbabilityCalibrator(slope, intercept, version, nObs)` calculé
   hors-ligne et l'injecter dans `ProbabilityEngine` (contrôleur:238) via une
   config versionnée. Dès `nObs > 0`, la confiance et le plafond 0,95 se
   débloquent automatiquement (mécanique déjà codée dans
   `availability_estimate.dart:190`).
4. **Mode « campagne terrain »** (optionnel mais puissant) : un écran caché
   de saisie rapide (segment → occupé/libre) pour réaliser soi-même la
   campagne de vérité terrain de 20-40 rues décrite dans l'étude marché.

**Critère de réussite :** premier reliability diagram tracé sur données réelles ;
`isCalibrated = true` sur au moins un périmètre (même petit).

---

## 5. Chantier D — Cache & résilience réseau *(effort : S-M)*

1. **Cache mémoire + disque avec TTL** pour Paris Data, Overpass et routes :
   aujourd'hui, re-taper la même destination re-télécharge tout
   (`selectDestination` → `_fetchSpots`, contrôleur:412). Clé =
   destination quantifiée + rayon ; TTL différencié (Paris Data : heures ;
   Overpass : jours ; routes : minutes). → M10.
2. **Retry/backoff** (2 tentatives, jitter) sur timeout et 5xx dans
   `NetworkClient` — les exceptions typées rendent ça trivial à cibler. → M11.
3. **Fallback Overpass réel** (le secondaire est vide par défaut) et cache de
   tuiles léger pour l'itinérance. → M11.

**Critère :** recherche répétée = 0 requête réseau (hit cache) ; une panne
transitoire d'un endpoint ne fait plus échouer la couche du premier coup.

---

## 6. Chantier E — Temps réel communautaire *(effort : S-M)*

1. **Supabase Realtime** (CDC/broadcast par cellule) à la place du polling
   20 s — latence de ~10 s moyenne aujourd'hui, incompatible avec « une place
   vient de se libérer ». → M12.
2. **Consolider le code mort** : le `watchRecentEventsNear` du service n'est
   pas utilisé par le contrôleur (qui a son propre `Timer.periodic`) — une
   seule mécanique doit survivre.
3. Conserver quantification (~70-110 m), TTL et bornes d'influence (±0,12)
   déjà bien conçus.

*(Pré-requis inchangé : le déploiement du schéma v4 sécurisé côté prod,
documenté dans `supabase/ROLLOUT.md` — hors de portée du code client.)*

---

## 7. Chantier F — Détection automatique « je me gare / je repars » *(effort : M)*

Le levier n°1 d'alimentation des données communautaires **sans friction**
(modèle SpotAngels) :

- L'[Activity Recognition Transition API d'Android](https://developer.android.com/codelabs/activity-recognition-transition)
  est explicitement conçue pour « détecter que l'utilisateur sort de son
  véhicule et commence à marcher ». Côté Flutter :
  [flutter_activity_recognition](https://pub.dev/packages/flutter_activity_recognition)
  (stream d'activité, iOS + Android) ou
  [tracelet](https://pub.dev/packages/tracelet) (géolocalisation d'arrière-plan
  économe avec reconnaissance d'activité intégrée, geofencing, persistance).
- Détection **voiture → marche** = proposer « Vous venez de vous garer ici ? »
  (notification/écran) qui pré-remplit `_reportParked` ; **marche → voiture**
  près de la position mémorisée = proposer « Vous libérez la place ? ».
- Toujours **opt-in explicite** (consentement dédié), traitement local,
  publication de la seule cellule quantifiée — cohérent avec la posture RGPD
  du produit. iOS : `NSMotionUsageDescription` requis.

**Critère :** sur un trajet réel, la proposition « garé ici ? » apparaît dans
la minute suivant la coupure moteur, sans avoir ouvert l'app.

---

## 8. Chantier G — Fondations long terme *(effort : L, à lisser)*

1. **i18n** : introduire `flutter_localizations` + ARB, **sortir d'abord les
   chaînes du contrôleur** (couche métier ne doit produire que des codes
   d'erreur, l'UI les traduit) ; remplacer les formats de date artisanaux par
   `intl`. → M13.
2. **Dé-god-fileiser `map_screen.dart`** : extraire la logique
   session/partage (`_reportParked`/`_shareParkedAndConfirm`) vers un
   contrôleur/service testable, découper le rendu en widgets par phase. → M14.
3. **Migration MapLibre** (étude puis bascule) :
   [maplibre_gl](https://github.com/maplibre/flutter-maplibre-gl) ou le
   récent [maplibre](https://pub.dev/packages/maplibre) (bindings natifs
   FFI/JNI) apportent tuiles **vectorielles**, rendu natif, rotation/tilt
   fluides — le standard visuel d'une app de conduite moderne, et l'un des
   [SDK cartographiques les plus rapides](https://fluttergems.dev/packages/maplibre/).
   À faire **après** le chantier A (la mémoïsation reste utile) et une fois le
   mode conduite stabilisé, car c'est un changement de moteur de rendu.
4. **CarPlay / Android Auto** (différenciateur stratégique identifié dans
   l'étude marché) : nécessite du code natif (templates CarPlay) au-delà de
   Flutter pur — à instruire comme projet dédié une fois B livré, en
   capitalisant sur le `VoiceGuidanceService` et le tracker enrichi.

---

## 9. Feuille de route séquencée

| Sprint | Contenu | Dépend de | Livrable vérifiable |
|---|---|---|---|
| 1 | **A** Performance rendu + **B1** wakelock/thème/layout conduite | — | Compteur de rebuilds ; écran allumé en guidage |
| 2 | **B2** ETA/restant + **B3** caméra orientée cap | A | HUD complet, carte qui tourne |
| 3 | **B4** guidage vocal + **B5** résilience GPS/reroute | B2 | Test voiture réel : voix + tunnel OK |
| 4 | **C** store d'observations + télémétrie + branchement calibrateur | — (parallélisable) | Premier reliability diagram |
| 5 | **D** cache/retry + **E** Realtime | — | 0 requête sur recherche répétée ; latence < 2 s sur événement |
| 6 | **F** détection auto | B (session stable) | Proposition « garé ici ? » automatique |
| continu | **G** i18n, découpage, puis étude MapLibre / CarPlay | — | — |

Règles de conduite du chantier (héritées de la discipline actuelle du repo) :
chaque sprint garde `flutter analyze` propre et la suite de tests verte (176+),
ajoute des tests pour chaque nouveau service, et n'introduit **aucune** promesse
produit non mesurée (pas de « temps réel » affiché tant que Realtime n'est pas
déployé, pas de « % fiable » tant que le calibrateur n'est pas alimenté).

---

## 10. Sources techniques

- TTS / guidage vocal : [approche standard manœuvres → TTS plateforme (HERE)](https://developer.here.com/documentation/flutter-sdk-navigate/4.7.3.0/dev_guide/topics/navigation.html) · [packages TTS Flutter](https://fluttergems.dev/ai-voice-assistant/) · [voice_guidance](https://pub.dev/packages/voice_guidance) · [principe turn-by-turn OSRM en Flutter](https://github.com/liodali/osm_flutter/discussions/136)
- Détection d'activité : [Android Activity Recognition Transition API](https://developer.android.com/codelabs/activity-recognition-transition) · [flutter_activity_recognition](https://pub.dev/packages/flutter_activity_recognition) · [tracelet](https://pub.dev/packages/tracelet) · [activity_recognition_flutter](https://pub.dev/packages/activity_recognition_flutter)
- Cartographie vectorielle : [maplibre_gl](https://github.com/maplibre/flutter-maplibre-gl) · [maplibre (bindings natifs)](https://pub.dev/packages/maplibre) · [panorama des SDK cartographiques Flutter](https://fluttergems.dev/geolocation-maps/)
- Audits internes : deux analyses exhaustives du codebase (écran/contrôleur ; services) réalisées sur le commit `c305067` — références de lignes citées dans le corps du document.
