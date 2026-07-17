# ParkRadar — Étude design : devenir aussi beau et désirable que Waze (2026)

> Étude produite par une orchestration de 6 agents (≈305 000 tokens de
> recherche, 81 recherches web et lectures de code) : carte vectorielle,
> langage de design Waze, polish Flutter, crédibilité des estimations, audit
> design du code existant, puis critique de complétude par un « directeur
> artistique » exigeant. **Contrairement aux études précédentes, celle-ci
> TRANCHE : chaque sujet se termine par une décision unique.**

Date : juillet 2026 — Version 1.0

---

## 0. Synthèse : pourquoi l'app paraît « pas très poussée »

Le diagnostic tient en quatre faits, tous vérifiés dans le code ou sourcés :

1. **80 % du « c'est laid » vient du fond de carte.** ParkRadar affiche les
   tuiles raster brutes d'openstreetmap.org — le rendu le plus daté qui
   existe, et dont la [politique d'usage OSM](https://operations.osmfoundation.org/policies/tiles/)
   décourage l'utilisation en production. Waze, lui, travaille sa carte comme
   un produit : fond désaturé, routes hiérarchisées, POI supprimés, un seul
   accent de couleur.
2. **Zéro animation d'interface.** L'audit du code le confirme : aucun
   `Animated*`, aucun `AnimationController` dans `lib/`. Les panneaux
   apparaissent d'un coup, la caméra saute au lieu de glisser, le marqueur
   véhicule est un disque inerte. Le « feel » Waze, c'est d'abord du mouvement.
3. **Aucune personnalité.** Icônes Material génériques partout, pas une
   illustration, pas de mascotte, pas de ton. Waze a fait de sa personnalité
   (mascotte, humour, célébrations) son arme de rétention.
4. **Les estimations écrasées détruisent la confiance.** À 19h, une rue
   résidentielle parisienne est réellement à ~93 % d'occupation et un secteur
   de bureaux à ~62 % — si l'app affiche des valeurs proches partout,
   n'importe quel Parisien détecte le faux en dix secondes. Le moteur actuel
   écrase le contraste (capacité effective trop grande) ET l'affiche mal
   (pourcentages au lieu de libellés).

Le reste de l'étude détaille chaque chantier ; la §7 donne la feuille de
route consolidée en 3 phases.

---

## 1. La carte — décisions

### Constats clés
- **[OpenFreeMap](https://openfreemap.org/)** : vectoriel, gratuit, **sans
  limite, sans clé, usage commercial autorisé** (MIT, en prod chez MapHub).
  Styles prêts : `liberty` (le plus abouti), `positron`, `dark`.
- **[Stadia Maps](https://docs.stadiamaps.com/map-styles/alidade-smooth/)** :
  la meilleure paire raster clair/sombre (« Alidade Smooth » / « Dark »),
  compatible **immédiatement** avec le `MAP_TILE_URL_TEMPLATE` existant,
  gratuit en non-commercial, ~20 $/mois en commercial. Variante `@2x`
  (retina) = netteté transformée sur iPhone.
- **⚠️ PIÈGE ÉVITÉ — CARTO** : les rasters Voyager/Positron/Dark Matter que
  tous les tutoriels recommandent sont **contractuellement réservés aux
  clients Enterprise** ([FAQ CARTO](https://docs.carto.com/faqs/carto-basemaps)).
  Ne pas les utiliser.
- **MapTiler** : très beau mais free tier non-commercial uniquement.
- Packages Flutter : **maplibre_gl v0.26** est redevenu sain (web WASM réglé,
  renderer Metal iOS) ; le nouveau **maplibre** (bindings FFI, tilt/3D) est
  prometteur mais pré-1.0.
- Le look Waze est un travail de **style**, pas de moteur : refonte 2024 =
  bruit visuel supprimé, routes principales élargies, couleurs assourdies,
  UN accent de marque, ~30 % de lecture plus rapide sur carte simplifiée.

### ✅ DÉCISIONS
| Horizon | Décision |
|---|---|
| **Aujourd'hui** (0 code) | Basculer sur **Stadia Alidade Smooth `@2x`** (clair) + **Alidade Smooth Dark** (sombre), via le template existant. Ajouter un 2ᵉ template sombre commuté par le ThemeMode. Attribution « © Stadia Maps © OpenMapTiles © OpenStreetMap ». |
| **Phase 2** (2-4 sem.) | Migration **maplibre_gl v0.26+** avec **OpenFreeMap** (gratuit illimité commercial) comme source. Style **forké dans Maputnik** : fond gris doux désaturé, accent ParkRadar réservé à l'itinéraire et aux places, routes élargies avec casing, 80 % des POI supprimés aux zooms de conduite, déclinaison sombre systématique. |
| **Plus tard** | Option coût-zéro souveraine : extrait PMTiles Île-de-France auto-hébergé sur Cloudflare R2 (~0-2 $/mois). |

---

## 2. Le langage de design — mini-brand ParkRadar

### Ce que Waze nous apprend ([Pentagram](https://www.pentagram.com/work/waze), teardowns)
- Identité « Block by Block » : blocs colorés, typo arrondie (Boing), mascotte
  en forme de bulle de dialogue ; ton « bold, witty, welcoming ».
- **30 Moods** débloquables → appartenance et rétention.
- Google Maps en contre-exemple : sa désaturation 2023 a été rejetée
  (« colder, less human » — Elizabeth Laraki, ex-designer Google Maps).
  **Leçon : ne jamais désaturer l'interface, seulement le fond de carte.**
- Onboarding : pas de mur d'inscription, 5 **bénéfices** illustrés (pas des
  fonctionnalités).

### ✅ DÉCISION — le mini-brand ParkRadar
| Élément | Choix |
|---|---|
| Primaire | **Bleu Radar** `#2563EB` (confiance + énergie) |
| Succès | **Vert Place Libre** `#22C55E` (place trouvée) |
| Alerte | **Corail** `#F97066` (payant/interdit) |
| Fonds | sombre **Asphalte** `#0F172A` · clair **crème** `#FAF7F2` (jamais de blanc pur — leçon Merino) |
| Typo | **Nunito/Baloo 2** (titres, esprit Boing arrondi) + **Inter/Manrope** (UI) ; chiffres tabulaires géants pour ETA et temps de recherche |
| Ton | complice, léger, clins d'œil parisiens (« Place trouvée, champion du créneau ! ») — jamais corporate |
| Mascotte | un **petit plot/radar arrondi** façon bulle (états vides + célébrations) — optionnelle en phase 1, Rive en phase 3 |

### Les 5 patterns UI à adopter
1. **Bottom sheet persistante à 3 crans** (peek 96 px / mi-hauteur / plein
   écran) qui ne se ferme jamais — le pattern Google Maps.
2. **Pilules flottantes** au-dessus de la carte (recherche, filtres
   gratuit/payant, recentrer) — ombre douce, fond translucide.
3. **Mode conduite** : CTA « Y aller » ≥ 56 dp, bandeau d'instruction en haut
   (là où va l'œil), le reste réduit au minimum.
4. **Carte d'info hiérarchisée** : UN gros chiffre (temps de recherche) +
   label discret + badge de disponibilité coloré.
5. **États vides illustrés** avec la mascotte (« Aucune place ici… on élargit
   le radar ? ») ; onboarding en 3-4 bénéfices illustrés, sans inscription.

---

## 3. Le polish Flutter — techniques et arbitrages

### Constats
- Le codebase n'a **aucun package d'animation** — terrain vierge.
- Material 3 Expressive (I/O 2025) fait des **ressorts physiques** la norme.
- **Découverte critique** : le template iOS Flutter **omet la clé
  `CADisableMinimumFrameDurationOnPhone`** — sans elle, l'app est plafonnée à
  **60 Hz sur les iPhone ProMotion**. 30 minutes pour débloquer 120 Hz.
- `flutter_map_animations` (AnimatedMapController) anime les mouvements de
  caméra sur le moteur ACTUEL — le meilleur ratio effort/impact.

### ✅ DÉCISIONS (arbitrages demandés par la critique)
| Sujet | Décision | Alternative écartée |
|---|---|---|
| Bottom sheet | **DraggableScrollableSheet natif** (snap 0.12/0.45/0.92) d'abord | `smooth_sheets` seulement si conflits de gestes avérés |
| Animations | **flutter_animate** (entrées, shimmer) + **AnimatedMapController** + springs via `motor` en phase 2 | — |
| Mascotte | **Lottie d'abord** (assets tout faits pour états vides/onboarding, quelques heures) ; **Rive en phase 3** si la mascotte devient interactive | faire les deux d'emblée |
| Haptique | wrapper maison sur `HapticFeedback` (snaps sheet = selectionClick, sélection = lightImpact, arrivée = mediumImpact) | — |
| Accessibilité | gate systématique `MediaQuery.disableAnimationsOf` sur toute animation continue | — |

---

## 4. Les estimations — le problème du test à 19h, résolu

### Le diagnostic (sourcé)
- Réalité mesurée ([Bâle/ETRR 2024](https://link.springer.com/article/10.1186/s12544-024-00682-w),
  [SFpark](https://millardball.its.ucla.edu/wp-content/uploads/sites/22/2022/06/Millard-Ball_Weinberger_Hampshire_2014_Assessing_the_impacts_SFPark.pdf),
  capteurs Melbourne) : à 19h, **résidentiel ≈ 90-93 %** d'occupation
  (les résidents rentrent avant la gratuité de 20h), **commerçant ≈ 95 %**
  (pic dîner), **bureaux ≈ 62 %** (vidé après 18h). C'est **l'inversion
  résidentiel/bureaux** qui rend un moteur crédible.
- Spécificité Paris ignorée par le moteur actuel : **payant 9h-20h** → ruée
  résidente 18h-20h, dimanche = profil nuit. Un moteur qui ignore la règle
  des 20h ne peut pas être crédible à Paris.
- Défaut structurel : avec une capacité effective de 20-30 places, la formule
  donne P > 0,75 pour toute occupation < 0,95 → tout se ressemble.
- Le design de la crédibilité ([Google Popular Times](https://blog.google/products-and-platforms/products/maps/maps101-popular-times-and-live-busyness-information/),
  [recherche 2020-2026](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2020.579267/full)) :
  **jamais de pourcentage**, des libellés qualitatifs + barres relatives,
  « données insuffisantes » plutôt qu'un chiffre inventé — montrer
  l'incertitude AUGMENTE la confiance.

### ✅ DÉCISIONS
1. **Trois archétypes de rue** (résidentiel dense / mixte commerçant /
   bureaux), classés par POI + tags OSM, avec **profils horaires 24 valeurs
   révisés** (fournis en annexe de la recherche — à 19h : 0,93 / 0,95 / 0,62).
2. **Modulateurs Paris** : effet fin-de-payant 18h-20h, dimanche = gratuit,
   densité restaurants/bars (rayon 150 m, données Overpass déjà chargées),
   samedi, événements (opendata « Que faire à Paris »).
3. **Capacité effective réduite à 5-10 places** (le tronçon qu'un conducteur
   accepte vraiment) → le contraste revient mécaniquement.
4. **Sortie en TEMPS DE RECHERCHE, jamais en %** : « Facile · <3 min »,
   « Moyen · 3-8 min », « Difficile · 8-15 min », « Très difficile · >15 min,
   envisagez un parking ». Un temps est vérifiable ; un pourcentage non.
5. **Mini-histogramme 24h** « Habituellement à cette heure » (barres
   relatives, curseur sur l'heure choisie) + **une ligne de POURQUOI**
   (« Rue résidentielle : les résidents rentrent avant 20h — gratuit
   ensuite ») + conseil actionnable (« visez les rues côté bureaux à 300 m »).
6. **Refuser de deviner** : rue jamais observée → « Données insuffisantes »
   (le signal de crédibilité le plus fort — c'est ce que fait Google).
7. Vérité terrain minimale : 3 soirées × 10-15 tronçons (~150 points) pour
   recaler les courbes du soir + LA question objective à un tap après
   stationnement (« Trouvé en : <2 min / 2-5 / 5-15 / abandonné ») — la
   méthode exacte de Google (régression logistique sur réponses objectives).

---

## 5. L'audit du code — les 10 liftings classés impact/effort

L'agent d'audit a identifié les points précis (fichier:méthode) :

| # | Lifting | Où | Effort |
|---|---|---|---|
| 1 | **Animer l'apparition des panneaux/bannières** (AnimatedSwitcher + slide/fade, enfin consommer `ParkRadarMotion`) | `park_responsive_map_panel.dart:26` + `map_screen.dart:1372` | XS |
| 2 | **Marqueur véhicule vivant** : halo de précision GPS, pulsation, cône de cap | `_userMarker` (`map_screen.dart:879`) | S |
| 3 | **Caméra animée** (AnimatedMapController partout où `.move()` saute) | 6 sites listés | S |
| 4 | **Hiérarchiser le panneau boucle** : grande jauge/anneau de temps de recherche, lignes d'audit reléguées dans « Détails », CTA pleine largeur | `_buildLoopPanel:1882` | M |
| 5 | **HUD animé** : AnimatedSwitcher sur l'instruction (clé = étape), décompte fluide de la distance | `_buildNavigationHud:1496` | S |
| 6 | **Famille de marqueurs unifiée** `ParkMapMarker` (même goutte, 3 tailles, ancrage bottom-center) — aujourd'hui 5 familles incohérentes | `_markers:1060` | M |
| 7 | **Verre dépoli** (BackdropFilter) sur recherche, contrôles, légende + token `ParkRadarBlur` | 3 widgets | S |
| 8 | **États vides illustrés** + animation radar de chargement | 4 panneaux | M |
| 9 | **Célébration « Place trouvée »** (check animé, confetti léger, haptique) | `_reportParked:449` | XS |
| 10 | **Scrim dégradé** en haut de carte (lisibilité) | `park_responsive_map_panel.dart:118` | XS |

Contraintes à respecter (héritées du code récent) : préserver la mémoïsation
des couches (widgets const, pas de closures par frame), tous les `Semantics`
existants, le thème conduite à fort contraste (pas de flou au volant), et
`MediaQuery.disableAnimations`.

---

## 6. Ce que la critique a exigé d'ajouter

Le 6ᵉ agent (directeur artistique) a pointé 6 manques — intégrés ici :

1. **Cible visuelle concrète** → prochaine action : produire une **maquette
   HTML/Figma du « north star »** (écran carte + sheet + mode conduite) AVANT
   de coder la phase 2, pour valider le look une bonne fois.
2. **Arbitrages** → faits dans cette étude (tableaux ✅ DÉCISIONS).
3. **User flow de bout en bout** → à spécifier sur la maquette : ouverture →
   recherche (sans inscription) → choix de rue → guidage → « garé »
   (célébration) → retrouver sa voiture. Un scénario directeur, pas des
   micro-interactions empilées.
4. **Première impression hors-app** → icône (revoir le pin actuel avec la
   nouvelle palette), splash, screenshots App Store scénarisés — à traiter en
   phase 3 avec TestFlight.
5. **Protocole de validation** → 5 conducteurs parisiens, test A/B des
   tuiles (Stadia vs style forké), test de « glanceabilité » au volant
   (info captée en <1 s ?), métriques : temps jusqu'à première place,
   rétention J7.
6. **Contexte réel de conduite** → lisibilité plein soleil (contraste jour à
   tester dehors), manipulation à une main sur support, guidage utilisable en
   vocal seul — et la stratégie CarPlay (déjà identifiée comme brèche dans
   l'étude produit : la fonction parking de Waze n'existe pas sur CarPlay).

---

## 7. Feuille de route consolidée

### Phase 0 — « Le choc visuel » (~1 semaine, aucun changement de moteur)
| Action | Effort |
|---|---|
| Tuiles **Stadia Alidade Smooth @2x** clair/sombre commutées par thème | XS |
| Clé **120 Hz ProMotion** dans Info.plist | XS |
| **AnimatedMapController** (caméra qui glisse) | S |
| **Haptique** (service maison) | XS |
| Panneaux/bannières **animés** (#1) + scrim (#10) + célébration (#9) | S |
| **Profils horaires révisés + capacité 5-10 + libellés temps de recherche** | S |

→ À la fin de cette semaine, l'app *paraît* déjà une autre app, et le test à
19h devient crédible.

### Phase 1 — « L'app premium » (~2 semaines)
Sheet 3 crans + marqueurs unifiés + véhicule vivant + panneau hiérarchisé +
HUD animé + états vides Lottie + flutter_animate + histogramme 24h +
ligne « pourquoi » + typo Nunito/Inter.

### Phase 2 — « La carte à nous » (~2-4 semaines)
Maquette north-star validée → migration **maplibre_gl + OpenFreeMap** +
**style ParkRadar forké dans Maputnik** (clair/sombre) → tilt/rotation natifs.

### Phase 3 — « La marque qui vit »
Mascotte Rive interactive, moods saisonniers, gamification légère (2-3
mécaniques max), assets App Store, protocole de validation utilisateur,
CarPlay.

---

## 8. Sources principales
Carte : [OpenFreeMap](https://openfreemap.org/) · [Stadia styles](https://docs.stadiamaps.com/map-styles/alidade-smooth/) · [FAQ CARTO (restriction)](https://docs.carto.com/faqs/carto-basemaps) · [maplibre_gl](https://pub.dev/packages/maplibre_gl) · [maplibre](https://pub.dev/packages/maplibre) · [politique tuiles OSM](https://operations.osmfoundation.org/policies/tiles/)
Design : [Pentagram × Waze](https://www.pentagram.com/work/waze) · [Waze Moods & engagement](https://strivecloud.io/blog/app-engagement-waze/) · [onboarding Waze](https://goodux.appcues.com/blog/wazes-upfront-benefits) · [leçon Google Maps 2023](https://www.cnbc.com/2023/11/29/google-maps-new-colors-upset-some-including-former-designer.html)
Flutter : [flutter_animate](https://pub.dev/packages/flutter_animate) · [flutter_map_animations](https://pub.dev/packages/flutter_map_animations) · [smooth_sheets](https://pub.dev/packages/smooth_sheets) · [M3 Expressive](https://m3.material.io/blog/building-with-m3-expressive) · [Rive vs Lottie](https://rive.app/blog/rive-as-a-lottie-alternative) · [bug 120 Hz](https://github.com/flutter/flutter/issues/90675)
Estimations : [SFpark (Millard-Ball et al.)](https://millardball.its.ucla.edu/wp-content/uploads/sites/22/2022/06/Millard-Ball_Weinberger_Hampshire_2014_Assessing_the_impacts_SFPark.pdf) · [occupation résidentielle (ETRR 2024)](https://link.springer.com/article/10.1186/s12544-024-00682-w) · [capteurs Melbourne](https://discover.data.vic.gov.au/dataset/on-street-car-parking-sensor-data-2019) · [Google — prédire la difficulté de parking](https://research.google/blog/using-machine-learning-to-predict-parking-difficulty/) · [Popular Times](https://blog.google/products-and-platforms/products/maps/maps101-popular-times-and-live-busyness-information/) · [confiance & incertitude](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2020.579267/full) · [stationnement payant Paris](https://www.paris.fr/pages/payer-son-stationnement-2129)
