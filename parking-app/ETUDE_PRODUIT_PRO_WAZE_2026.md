# ParkRadar → produit professionnel « niveau Waze » — Étude d'amélioration (2026)

> Étude complémentaire à [`ETUDE.md`](ETUDE.md) (faisabilité) et
> [`ETUDE_FIABILITE_PRODUIT_2026.md`](ETUDE_FIABILITE_PRODUIT_2026.md) (fiabilité
> prédictive et backend). Ce document répond à une question précise : **que
> manque-t-il, concrètement, pour que ParkRadar cesse d'être un prototype
> heuristique et devienne un produit grand public professionnel comparable à
> Waze / Google Maps / INRIX ?** Chaque axe suit le format : *ce que font les
> leaders → écart de ParkRadar → recommandations priorisées*.

Date : juillet 2026 — Version 1.0

---

## 0. Synthèse exécutive — la vérité sans détour

ParkRadar est aujourd'hui un **prototype techniquement propre** : app iOS native + PWA,
~176 tests, modèle d'incertitude auditable, données réelles de Paris, garde-fou
légal « fail-closed », couche communautaire. C'est déjà mieux que 90 % des
side-projects. **Mais entre ce prototype et un produit pro, il y a trois murs**,
et aucun ne se franchit avec du code seul :

1. **Le mur de la vérité terrain.** Les probabilités affichées sont des
   *estimations non calibrées*. Un acteur pro comme INRIX valide sa précision par
   des campagnes de **ground-truth trimestrielles** et atteint « ~99 % de
   couverture et de précision » sur 46 instances de villes dans 12 pays, avec
   ≥90 % d'exactitude sur les règles/tarifs
   ([INRIX, juin 2026](https://www.businesswire.com/news/home/20260604808273/en/INRIX-Sets-the-Standard-for-Predictive-and-Accurate-Parking-Intelligence)).
   ParkRadar n'a **aucune mesure de sa propre précision** aujourd'hui. Sans ça,
   « probabilité 80 % » est un chiffre décoratif.

2. **Le mur des données.** Waze/Google/INRIX reposent sur des **flottes de
   dizaines de millions de véhicules connectés** et des partenariats villes.
   ParkRadar repose sur de l'open data statique + une communauté encore
   inexistante (problème de l'œuf et de la poule).

3. **Le mur de l'expérience de conduite.** Waze, c'est du **guidage vocal
   turn-by-turn, CarPlay/Android Auto, mains-libres, alertes temps réel,
   gamification**. ParkRadar affiche une carte + une boucle : c'est un *outil de
   consultation*, pas encore un *copilote de conduite*.

**Verdict honnête** : ParkRadar ne « battra pas Waze » et ne doit pas le prétendre.
Sa **stratégie gagnante n'est pas de refaire Waze**, mais de devenir **le meilleur
sur le dernier kilomètre — la place en voirie** — là où Waze/Google s'arrêtent
(ils guident vers l'adresse, pas vers une place). La feuille de route ci-dessous
vise ce positionnement, en franchissant d'abord le **mur n°1 (vérité terrain)**,
car sans lui tout le reste est bâti sur du sable.

**Ordre de priorité recommandé :** Vérité terrain & calibration (P0) → Sécuriser
le backend prod (P0) → Copilote de conduite CarPlay (P1) → Amorçage communautaire
(P1) → Monétisation (P2).

---

## 1. Fiabilité prédictive & vérité terrain — LE mur n°1

### Ce que font les leaders
- **INRIX** : modèles statistiques *sans capteurs*, mais adossés à une
  **infrastructure de validation** — bench testing mensuel (imagerie satellite,
  données municipales, API) + **ground-truth trimestriel en conditions réelles**,
  affichant ~99 % de couverture/précision et ≥90 % sur règles/prix/restrictions
  ([INRIX Curb Analytics](https://inrix.com/blog/introducing-new-on-street-occupancy-predictions-for-curb-analytics/),
  [INRIX 2026](https://www.businesswire.com/news/home/20260604808273/en/INRIX-Sets-the-Standard-for-Predictive-and-Accurate-Parking-Intelligence)).
- **Parknav** (partenaire INRIX) : ML + big data pour prédire quelles rues auront
  des places libres en temps réel, déployé sur les 30 plus grandes villes
  allemandes, **sans capteurs**
  ([INRIX × Parknav](https://inrix.com/press-releases/on-street-germany/)).
- **SpotAngels** : *predicted availability* par **vision par ordinateur sur
  dashcams** de la communauté (comptage de voitures garées) + crowdsourcing.
- **SFpark (San Francisco)** : capteurs au sol sur des milliers de places
  (2011-2013) → **jeu de données de vérité terrain** encore utilisé aujourd'hui
  pour entraîner et *valider* les modèles académiques.
- **Recherche académique** : la prédiction d'occupation fusionne multi-sources
  (transactions, trafic, météo, événements) avec des modèles spatio-temporels
  récents (transformers auto-supervisés)
  ([arXiv 2509.04362](https://arxiv.org/pdf/2509.04362)).

### Écart de ParkRadar
- Modèle **heuristique** `P = 1 - occupation^(capacité/facteur)` : un *prior*
  raisonnable, mais **jamais confronté à la réalité**.
- **Zéro métrique de calibration** : on ne sait pas si « 70 % » correspond
  vraiment à 70 % de succès observés.
- Le refactor Codex a déjà fait le bon travail d'**honnêteté** (afficher
  incertitude/confiance/fraîcheur, plafonner la confiance « non calibrée ») —
  c'est la bonne fondation, mais la calibration elle-même reste à faire.

### Recommandations (priorisées)
1. **[P0] Campagne de vérité terrain, même minuscule.** Choisir 20-40 tronçons à
   Paris, relever manuellement l'occupation réelle à plusieurs créneaux
   (matin/midi/soir/nuit, semaine/week-end) pendant 2-3 semaines. Une appli de
   saisie (ou un simple formulaire) suffit. **C'est le geste qui débloque tout le
   reste.**
2. **[P0] Mesurer la calibration** avec des métriques standard : **Brier score**,
   **reliability diagram** (les « 70 % annoncés » tombent-ils bien à ~70 %
   observés ?), **ECE** (Expected Calibration Error). Le refactor a déjà l'archi
   `probability_calibrator.dart` prête à recevoir ça.
3. **[P1] Calibration supervisée** (isotonic regression / Platt scaling) une fois
   les premières observations réunies : transforme le prior heuristique en
   probabilités *honnêtes*.
4. **[P1] Enrichir le prior** avec des signaux vérifiables sans capteurs :
   transactions horodateurs Paris (proxy d'occupation des zones payantes), trafic
   temps réel, POI/densité, météo, événements (matchs, marchés). C'est l'approche
   « sensorless » d'INRIX/Parknav.
5. **[P2] Vision par ordinateur** (façon SpotAngels) : dashcams/photos
   communautaires → comptage de voitures. Puissant mais coûteux ; à réserver à
   l'échelle.

**Indicateur cible P0 :** publier un premier *reliability diagram* — le jour où
vous pouvez dire « nos 70 % valent vraiment 65-75 % sur le terrain », ParkRadar
change de catégorie.

---

## 2. Stratégie de données à l'échelle — sortir du cold-start

### Ce que font les leaders
- **Waze/Google** : données de **véhicules connectés à grande échelle** (FCD) +
  contributions communautaires massives.
- **INRIX** : agrège données de flottes, applis partenaires, capteurs de villes,
  transactions de paiement.
- **EasyPark/PayByPhone/Flowbird** : **transactions de paiement** = signal
  d'occupation des zones payantes (qui paie, où, quand).

### Écart de ParkRadar
- Données **statiques** (open data Paris : géométrie + régimes) + communauté
  **vide**. Le signal temps réel n'existe pas encore faute d'utilisateurs.

### Recommandations
1. **[P0] Valeur dès 0 utilisateur** (règle d'or anti œuf-et-poule, déjà bien
   engagée) : la vraie valeur immédiate de ParkRadar à Paris n'est PAS la
   disponibilité live — c'est **« où ai-je le droit de me garer, à quel prix,
   combien de temps »** (payant/gratuit/résident/livraison). C'est le modèle
   SpotAngels (« rules first ») : utile sans un seul autre utilisateur.
2. **[P1] Partenariats data** : demander l'accès aux **transactions horodateurs**
   à la Ville de Paris / à l'opérateur (proxy d'occupation puissant et légal).
3. **[P1] Boucle de contribution passive** : détecter automatiquement
   arrivée/départ (voiture→piéton) pour générer des événements *sans effort
   utilisateur* — c'est ce qui a fait décoller SpotAngels.
4. **[P2] Ville par ville** : ne pas s'éparpiller ; densifier Paris avant
   d'étendre (Lyon, Marseille selon leur open data).

---

## 3. Navigation & UX « niveau Waze » — le copilote de conduite

### Ce que font les leaders
- **Waze** : au moment de choisir la destination, propose le stationnement à
  proximité (horaires, tarifs) ; à la fermeture, **pose automatiquement un pin de
  voiture** et affiche un **ETA piéton** à la réouverture
  ([Waze Help](https://support.google.com/waze/answer/7052890)). Guidage vocal
  turn-by-turn, alertes communautaires, gamification.
- **Google Maps** : *destination guidance* qui **éclaire le bâtiment et son
  entrée** à l'approche + parkings à proximité
  ([MacRumors](https://www.macrumors.com/2024/08/01/google-maps-waze-new-carplay-features/)).
- **Limite exploitable** : la fonction parking de Waze **n'est PAS disponible sur
  CarPlay / Android Auto / AAOS**
  ([pocket-lint](https://www.pocket-lint.com/waze-update-carplay-android-auto/)).
  → **C'est une brèche stratégique** : un copilote de *recherche de place* natif
  CarPlay n'existe pas encore chez les géants.

### Écart de ParkRadar
- ParkRadar est un **outil de consultation carto**, pas un copilote : pas de
  guidage vocal turn-by-turn, pas de mode conduite mains-libres, pas de
  CarPlay/Android Auto, pas de pin de voiture auto + ETA retour.
- Le refactor a déjà les briques utiles : contrôleur de carte anti-réponses
  obsolètes, suivi de progression, manœuvres OSRM structurées, session « garée ».

### Recommandations
1. **[P1] Guidage vocal turn-by-turn** pendant la boucle de recherche (les
   manœuvres OSRM existent déjà ; il « suffit » de la synthèse vocale + du suivi
   de progression déjà codé).
2. **[P1] Pin de voiture automatique + ETA piéton retour** (copie de la meilleure
   idée de Waze ; la « session garée » locale existe déjà).
3. **[P1→P2] CarPlay / Android Auto** : le créneau différenciant. Viser un mode
   « recherche de place » mains-libres que Waze n'offre pas en voiture.
4. **[P2] Détection automatique gare/départ** (confort + données, cf. axe 2).
5. **[P2] Aimants d'engagement** : signalements communautaires rapides,
   micro-gamification (façon Waze), historique de ses places.

---

## 4. Temps réel & croissance communautaire

### Ce que font les leaders
- **Waze** : communauté massive auto-entretenue (signalements, corrections).
- **SpotAngels** : contributions **passives** (dashcams/arrière-plan) + subscription
  reversant ~50 % à un *pool communautaire* récompensant les contributeurs.

### Écart de ParkRadar
- Mécanique de signalement **présente et propre** (agrégation par cellule, TTL,
  Edge Function), mais **densité nulle** sans base d'utilisateurs.

### Recommandations
1. **[P1] Zéro friction** : privilégier la contribution passive (détection auto)
   à la contribution manuelle.
2. **[P1] Densité locale d'abord** : concentrer l'acquisition sur 1-2
   arrondissements de Paris pour atteindre une masse critique là, plutôt que
   diluer partout.
3. **[P2] Incitations** : reconnaissance/gamification, éventuellement modèle de
   récompense à la SpotAngels.

---

## 5. Architecture & scalabilité backend

### Ce que font les leaders
- Infra **temps réel géo-distribuée**, streaming, anti-abus, observabilité fine.

### Écart de ParkRadar
- **Supabase mono-région** (eu-west-1), lecture par **polling** (pas de
  WebSocket), pas encore d'observabilité de production. Le refactor a **bien
  durci** la sécurité (RPC privée, Edge Function d'écriture, quotas, hachage IP,
  RLS v4) — c'est la bonne direction.
- **⚠️ Bloqueur actuel connu et documenté** : le backend prod expose encore
  l'**ancien contrat** ; la table autorise des `UPDATE`/`DELETE` anonymes (retours
  204 au lieu de 401/403). **À corriger avant toute mise en avant du mode
  communautaire** (procédure dans `supabase/ROLLOUT.md` + `verify_backend.sh`).

### Recommandations
1. **[P0] Déployer le schéma v4 sécurisé** et rendre `verify_backend.sh` vert
   (secrets, RLS, RPC, cron, Edge Function). *Sécurité avant croissance.*
2. **[P2] Passer du polling au push** (Supabase Realtime / WebSocket) quand la
   densité le justifie.
3. **[P2] Observabilité** (logs, métriques, alertes) et anti-abus renforcé.

---

## 6. Monétisation & marché

### Le marché (chiffres)
- Applis de recherche de parking : **~523,5 M$ en 2025**
  ([Future Market Insights](https://www.futuremarketinsights.com/reports/parking-finder-apps-market)).
- Marché plus large des applis de stationnement mobile : **~7,2 Md$ en 2025**,
  CAGR **11,8 %** → ~19,6 Md$ en 2034
  ([Dataintelo](https://dataintelo.com/report/mobile-parking-app-market)).
- Smart parking (tout inclus) : **~11 Md$ en 2025** → **~82 Md$ en 2035** (CAGR
  22,2 %) ([SNS Insider](https://www.snsinsider.com/reports/smart-parking-market-3356)).
- **Le gratuit domine** : la version gratuite ≈ **65 % du revenu** en 2025 (large
  base d'utilisateurs), la monétisation se faisant sur le **premium/réservation/
  paiement/pub**
  ([Future Market Insights](https://www.futuremarketinsights.com/reports/parking-finder-apps-market)).

### Recommandations (pistes, non exclusives)
1. **[P2] Freemium** : gratuit (carte + règles + boucle), premium (~2-4 €/mois :
   prédiction à l'heure d'arrivée, alertes nettoyage/amendes, multi-véhicules).
2. **[P2] Commission paiement** stationnement (intégration PayByPhone/Flowbird/
   EasyPark).
3. **[P2] Affiliation parkings** (Zenpark/Onepark/Saemes) quand la voirie est
   saturée — le « plan B » rémunéré.
4. **[P3] B2B data** : vendre les cartes d'occupation aux villes/constructeurs
   (le modèle Parknav→INRIX) — seulement une fois la vérité terrain acquise.

---

## 7. Conformité RGPD/CNIL & confiance

### Enjeux
- Les traces de déplacement sont des **données personnelles sensibles**. Waze et
  consorts sont scrutés sur ce point.

### Recommandations
1. **[P0] Minimisation & anonymisation** (déjà bien engagé : quantification des
   coordonnées en cellules ~70-110 m, hachage IP côté Edge, TTL/purge). Continuer
   dans cette voie.
2. **[P0] Consentement explicite** avant tout partage communautaire (déjà prévu).
3. **[P1] Registre CNIL / privacy by design** documenté ; politique de
   confidentialité claire.
4. **[Transverse] Responsabilité produit** : **ne jamais promettre une place**,
   toujours parler en probabilité/incertitude, rappeler que **la signalisation sur
   place prévaut**, et **ne pas inciter au stationnement illégal** (le garde-fou
   fail-closed va exactement dans ce sens).

---

## 8. Feuille de route priorisée (effort indicatif)

L'effort est en « points » relatifs (S ≈ jours, M ≈ semaines, L ≈ 1-2 mois, XL ≈
trimestre), pour un petit noyau de développement.

| Priorité | Chantier | Effort | Pourquoi c'est là |
|---|---|---|---|
| **P0** | Campagne de vérité terrain (20-40 rues) + métriques de calibration (Brier, reliability diagram) | M | **Débloque toute la crédibilité prédictive.** Sans ça, tout le reste est décoratif. |
| **P0** | Sécuriser le backend prod (schéma v4, RLS, `verify_backend.sh` vert) | S-M | Faille anonyme UPDATE/DELETE ouverte aujourd'hui. Sécurité avant croissance. |
| **P0** | Conformité RGPD de base (consentement, minimisation, politique) | S | Prérequis légal avant toute diffusion large. |
| **P1** | Copilote de conduite : guidage vocal turn-by-turn + pin voiture auto + ETA retour | M | Transforme l'outil en produit ; réutilise le code de progression existant. |
| **P1** | Calibration supervisée (isotonic/Platt) sur les premières observations | M | Rend les % honnêtes ; branche sur l'archi calibrator déjà prête. |
| **P1** | Amorçage communautaire local (détection passive gare/départ, densité 1-2 arrondissements) | M-L | Attaque l'œuf-et-poule là où c'est gagnable. |
| **P1-P2** | CarPlay / Android Auto (mode recherche de place mains-libres) | L | **Brèche stratégique** : Waze ne l'offre pas en voiture. |
| **P2** | Partenariat données (transactions horodateurs Ville de Paris) | L | Signal d'occupation réel, légal, à l'échelle. |
| **P2** | Monétisation freemium + commission paiement | M | Une fois la valeur et la rétention prouvées. |
| **P2** | Backend push (Realtime/WebSocket) + observabilité | M-L | Quand la densité le justifie. |
| **P3** | Extension multi-villes ; B2B data | XL | Après avoir gagné Paris et la vérité terrain. |

### Métriques de succès à instrumenter (aujourd'hui : aucune)
- **Précision prédictive** : Brier score, ECE, reliability diagram (cible :
  calibration < 10 % d'écart).
- **Valeur réelle** : **temps de recherche économisé mesuré** vs recherche naïve
  (le seul KPI qui prouve l'utilité).
- **Engagement** : rétention J1/J7/J30, DAU/MAU, taux de contribution.
- **Coûts** : coût d'infra par utilisateur actif, coût des données.

---

## 9. Conclusion honnête

ParkRadar a une **base technique de qualité professionnelle** et un **positionnement
juste** : le dernier kilomètre en voirie, là où Waze et Google s'arrêtent. Ce
n'est pas rien — c'est même exactement le bon angle.

Mais « niveau Waze » ne se décrète pas : il se **mesure**. Le jour où ParkRadar
pourra afficher un *reliability diagram* prouvant que ses probabilités sont
calibrées sur de la vérité terrain, et un chiffre de *temps de recherche
économisé* mesuré, il aura franchi le seul mur qui compte vraiment. Le reste —
copilote de conduite, CarPlay, communauté, monétisation — est du travail
d'ingénierie et de croissance connu et faisable.

**La prochaine action à plus forte valeur n'est pas d'ajouter une fonction : c'est
de lancer la première petite campagne de vérité terrain (P0).** C'est peu
spectaculaire, mais c'est ce qui sépare un joli prototype d'un produit dont on
peut, un jour, dire qu'il rivalise avec les meilleurs.

---

## Sources principales
- INRIX — précision & validation ground-truth : [BusinessWire 2026](https://www.businesswire.com/news/home/20260604808273/en/INRIX-Sets-the-Standard-for-Predictive-and-Accurate-Parking-Intelligence), [INRIX Curb Analytics (sans capteurs)](https://inrix.com/blog/introducing-new-on-street-occupancy-predictions-for-curb-analytics/), [INRIX × Parknav](https://inrix.com/press-releases/on-street-germany/)
- Waze / Google Maps — parking & navigation : [Waze Help — Find parking](https://support.google.com/waze/answer/7052890), [MacRumors — CarPlay features](https://www.macrumors.com/2024/08/01/google-maps-waze-new-carplay-features/), [pocket-lint — parking pas sur CarPlay/Android Auto](https://www.pocket-lint.com/waze-update-carplay-android-auto/)
- Marché & monétisation : [Future Market Insights — Parking Finder Apps](https://www.futuremarketinsights.com/reports/parking-finder-apps-market), [Dataintelo — Mobile Parking App](https://dataintelo.com/report/mobile-parking-app-market), [SNS Insider — Smart Parking](https://www.snsinsider.com/reports/smart-parking-market-3356)
- Recherche : [Prédiction d'occupation multi-sources (arXiv 2509.04362)](https://arxiv.org/pdf/2509.04362), [Smart On-Street Parking — survey (arXiv 2602.06517)](https://arxiv.org/pdf/2602.06517)
