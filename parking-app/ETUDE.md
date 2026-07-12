# Étude de faisabilité — Application de stationnement « Waze du parking »

> **Concept** : une application de navigation où l'utilisateur saisit son adresse de destination, et
> l'application le guide non pas vers l'adresse exacte, mais le long d'un **itinéraire de recherche
> optimisé** qui maximise sa probabilité de trouver une place de stationnement libre dans la rue,
> en tenant compte du trafic et de l'heure — comme Waze le fait pour les itinéraires.

Date : juillet 2026 — Version 1.0

---

## 1. Résumé exécutif

L'idée est solide et le problème est réel : selon les études urbaines classiques (Donald Shoup),
**jusqu'à 30 % du trafic en centre-ville est constitué de conducteurs qui cherchent une place**
(« cruising »). Le besoin est massif, quotidien et douloureux.

**Verdict de l'étude :**

- ✅ **Techniquement faisable** : des acteurs comme Parknav/INRIX prouvent qu'on peut prédire la
  disponibilité rue par rue **sans capteurs**, avec plus de 80 % de précision, uniquement à partir
  de données historiques et de machine learning.
- ⚠️ **Le vrai défi n'est pas l'algorithme, c'est la donnée** : il faut résoudre le problème de
  l'œuf et de la poule (il faut des utilisateurs pour avoir des données, et des données pour attirer
  des utilisateurs). SpotAngels l'a résolu par le crowdsourcing passif + la vision par ordinateur.
- 🎯 **Recommandation** : démarrer par un MVP centré sur **une seule ville** (par ex. une ville
  française avec de l'open data stationnement, comme Paris), avec un modèle de probabilité
  « statique » (historique + règles) avant d'ajouter le temps réel crowdsourcé.

---

## 2. Le problème

- Chercher une place en ville prend en moyenne **8 à 15 minutes** dans les grandes agglomérations.
- Ce « cruising » génère du trafic parasite, de la pollution, du stress et des retards.
- Les GPS actuels (Waze, Google Maps) guident vers **l'adresse**, pas vers **une place** : le
  guidage s'arrête précisément au moment où le problème du conducteur commence.
- Les solutions existantes couvrent surtout les **parkings en ouvrage** (payants, réservables),
  mais la majorité des conducteurs veulent une place **dans la rue** (moins chère ou gratuite).

**L'opportunité** : personne ne possède le « dernier kilomètre » du trajet en voiture.

---

## 3. Parcours utilisateur cible

1. L'utilisateur saisit son **adresse de destination** (ou la reçoit depuis son agenda/Waze).
2. L'app calcule l'itinéraire en tenant compte du **trafic**, comme un GPS classique.
3. À l'approche de la destination (~500 m), l'app bascule en **mode recherche de place** :
   - elle affiche une carte de chaleur des rues avec la **probabilité de place libre** (vert/orange/rouge) ;
   - elle guide le conducteur sur une **boucle de recherche optimale** (les rues les plus prometteuses d'abord) ;
   - elle intègre les places libérées **en temps réel** par les autres utilisateurs (comme les alertes Waze).
4. Une fois garé, l'app :
   - détecte le stationnement (arrêt du GPS + passage en marche à pied) et **marque la place comme prise** ;
   - mémorise l'emplacement du véhicule et guide à pied vers la destination ;
   - rappelle les règles (zone payante, durée max, jour de nettoyage) pour éviter les amendes ;
   - propose le **paiement du stationnement** (intégration PayByPhone/Flowbird = source de revenus).
5. Quand l'utilisateur repart, l'app détecte le départ et **signale une place libérée** aux autres.

Chaque utilisateur est à la fois consommateur et **capteur** de données : c'est exactement le
modèle Waze appliqué au stationnement.

---

## 4. État de l'art et concurrents

| Acteur | Approche | Enseignement |
|---|---|---|
| **Parknav** (+ partenariat INRIX) | Prédiction ML rue par rue, sans capteurs, >80 % de précision, toutes rues d'une ville, 24/7 | La prédiction pure (sans temps réel) suffit déjà à créer de la valeur |
| **INRIX Parking** | Données de 300M+ de véhicules connectés, prédictions d'occupation « sans capteurs », 1 200+ villes | Les données de véhicules connectés (FCD) sont l'or de ce marché |
| **SpotAngels** (« Waze du parking ») | Crowdsourcing passif (détection arrivée/départ en arrière-plan), vision par ordinateur sur les panneaux et dashcams, carte des règles de stationnement | Le modèle communautaire fonctionne ; les **règles** (amendes évitées) sont un excellent produit d'appel avant même la disponibilité |
| **Google Maps** | Indicateur de « difficulté de stationnement » à destination | Fonctionnalité superficielle : pas de guidage vers une place — c'est la brèche à exploiter |
| **SFpark (San Francisco)** | Capteurs dans la chaussée sur des milliers de places (2011-2013) | Les capteurs physiques sont trop chers à grande échelle ; mais leurs données publiques servent à entraîner les modèles de recherche |
| **EasyPark, PayByPhone, Flowbird** | Paiement du stationnement | Partenaires naturels (pas concurrents) : leurs **données de transactions** = signal d'occupation |
| **Zenpark, Onepark, ParkSpot** | Réservation de parkings privés/ouvrages | Complément « plan B » quand la probabilité en voirie est trop faible |

**Positionnement différenciant** : aucun acteur grand public ne fait le **guidage actif** vers une
place en voirie avec probabilité + temps réel communautaire. Parknav vend en B2B (constructeurs
auto), SpotAngels est surtout fort aux USA sur les règles. Le créneau « Waze du parking en
français, guidage actif » est ouvert.

---

## 5. Le cœur du système : la probabilité de place libre

### 5.1 Le modèle de données

L'unité de base n'est pas la place individuelle mais le **segment de rue** (un tronçon entre deux
intersections, ou un côté de rue). Pour chaque segment on stocke :

- **Statique** : nombre de places, type (gratuit / payant / zone bleue / livraison / résident),
  tarif, règles horaires, jours de nettoyage. → Sources : open data (voir 5.3) + OpenStreetMap.
- **Historique** : profil d'occupation par heure × jour de semaine (courbes apprises).
- **Temps réel** : événements « place prise » / « place libérée » signalés par les utilisateurs,
  avec décroissance temporelle (une place libérée il y a 30 s est fiable ; il y a 10 min, presque plus).

### 5.2 La formule de probabilité

Pour un segment avec `c` places et un taux d'occupation estimé `ρ(t)` :

```
P(au moins une place libre) = 1 − ρ(t)^c
```

C'est le modèle de base (places indépendantes). Exemple concret : une rue de 20 places occupée à
95 % offre quand même `1 − 0,95²⁰ ≈ 64 %` de chances d'avoir une place — c'est pour cela que la
prédiction par segment fonctionne bien même en zone tendue, et c'est ce qui rend le produit crédible.

Le taux `ρ(t)` est prédit par un modèle ML. La littérature (données SFpark, Melbourne) montre que
fonctionnent bien : **gradient boosting / forêts aléatoires** (simple, robuste, idéal MVP), puis
**LSTM / réseaux récurrents** pour les dépendances temporelles fines. Variables d'entrée :

- heure, jour de semaine, jours fériés / vacances scolaires ;
- météo (pluie → plus de voitures) ;
- trafic ambiant (proxy de la demande) ;
- événements locaux (matchs, concerts, marchés) ;
- caractéristiques du quartier (commerces, bureaux, résidentiel — via OSM) ;
- signaux temps réel récents sur le segment et les segments voisins.

**Correction bayésienne temps réel** : la prédiction historique sert de *prior*, et chaque
événement crowdsourcé (départ signalé, échec de recherche) met à jour la probabilité *a posteriori*
du segment pendant quelques minutes.

### 5.3 Sources de données (par ordre de disponibilité)

1. **Open data** (dès le jour 1, gratuit) :
   - [Paris Data — emplacements de stationnement en voirie](https://opendata.paris.fr/explore/dataset/stationnement-voie-publique-emplacements/) : géométrie et type de chaque zone de stationnement ;
   - [transport.data.gouv.fr](https://transport.data.gouv.fr) : point d'accès national français aux données de mobilité ;
   - **données de transactions horodateurs / PayByPhone** quand disponibles : excellent proxy d'occupation des zones payantes ;
   - **OpenStreetMap** : réseau routier + tags `parking:lane` de plus en plus renseignés.
2. **Crowdsourcing passif** (dès les premiers utilisateurs) : détection automatique
   arrivée/départ via les API d'activité du téléphone (passage voiture→piéton), sans action manuelle.
   C'est la méthode SpotAngels — clé : **zéro friction**.
3. **Crowdsourcing actif** : bouton « je viens de partir », signalement de rue pleine (comme les
   signalements Waze).
4. **Plus tard, à l'échelle** : données de véhicules connectés (FCD), caméras/dashcams + vision
   par ordinateur, partenariats villes (capteurs, horodateurs).

### 5.4 Le démarrage à froid (« cold start »)

Sans historique, on peut déjà produire une probabilité utile :

- capacité et type de chaque segment (open data) ;
- densité de POI autour (OSM) → proxy de demande par heure ;
- trafic temps réel comme proxy d'affluence ;
- transfert des courbes apprises sur les datasets publics (SFpark, Melbourne) vers des quartiers
  similaires.

C'est exactement l'approche « sans capteurs » validée par Parknav/INRIX à >80 % de précision.

---

## 6. Le guidage : routage qui maximise la probabilité

C'est la deuxième brique différenciante. La recherche académique (routage dynamique avec
probabilité de stationnement) montre des gains de **jusqu'à 24 % sur le temps total de trajet**.

### 6.1 Principe

Le problème n'est pas « aller à l'adresse » mais « **minimiser l'espérance du temps total** » :

```
Temps total espéré = temps de conduite + temps de recherche espéré + temps de marche jusqu'à destination
```

Algorithme (variante d'A* adaptée, conforme à l'état de l'art) :

1. **Phase approche** : routage classique avec trafic jusqu'à un point d'entrée de la « zone de
   recherche » (rayon ~300-500 m autour de la destination, ajustable selon la volonté de marcher).
2. **Phase recherche** : construction d'une **boucle de recherche** sur le graphe des segments,
   où le coût de chaque segment combine :
   - temps de parcours (avec trafic) ;
   - probabilité de trouver une place `p_i` sur ce segment ;
   - distance de marche du segment à la destination.
   On enchaîne les segments jusqu'à ce que la probabilité cumulée
   `1 − ∏(1 − p_i)` dépasse un seuil (ex. 90 %) — approche « threshold-based » brevetée/publiée
   dans la littérature.
3. **Re-routage dynamique** : si une place se libère en temps réel sur le chemin, ou si le
   conducteur dépasse un segment sans se garer, la boucle est recalculée (le fait d'avoir parcouru
   une rue sans trouver est lui-même une **observation** qui met à jour le modèle).
4. **Plan B automatique** : si la probabilité cumulée en voirie est trop basse (< 50 % en 10 min),
   proposer le parking en ouvrage le plus proche (avec tarif) — c'est là que Zenpark/Onepark
   deviennent des partenaires d'affiliation.

### 6.2 Le piège du « troupeau » (self-defeating prediction)

Si tous les utilisateurs sont envoyés vers la même « meilleure rue », la place disparaît avant leur
arrivée et la prédiction s'auto-détruit. Solutions connues :

- **diversification** : répartir les utilisateurs simultanés sur des boucles différentes ;
- décompter les utilisateurs déjà en route vers un segment dans le calcul de `p_i` ;
- à terme, allocation type « réservation souple » de segments.

À faible échelle (MVP), ce problème est négligeable ; il faut juste l'avoir dans l'architecture.

---

## 7. Architecture technique proposée (MVP)

```
┌─────────────────────────────┐
│  App mobile (Flutter ou     │  carte, guidage, détection parked/unparked,
│  React Native)              │  signalements, paiement (plus tard)
└──────────────┬──────────────┘
               │ HTTPS / WebSocket (événements temps réel)
┌──────────────┴──────────────┐
│  Backend API (ex. FastAPI/  │  comptes, sessions de recherche,
│  Node)                      │  agrégation des événements
├─────────────────────────────┤
│  Moteur de routage          │  OSRM / Valhalla / GraphHopper (open source)
│  + module boucle de         │  avec coûts personnalisés par segment
│  recherche                  │
├─────────────────────────────┤
│  Service de prédiction      │  modèle gradient boosting par segment,
│  (Python, scikit-learn /    │  recalcul périodique + correction bayésienne
│  XGBoost, puis LSTM)        │  temps réel
├─────────────────────────────┤
│  Base de données            │  PostgreSQL + PostGIS (segments, événements,
│  géospatiale                │  historiques) ; Redis pour le temps réel
├─────────────────────────────┤
│  Pipelines d'ingestion      │  open data Paris / transport.data.gouv.fr,
│                             │  OSM, météo, trafic
└─────────────────────────────┘
```

**Briques open source clés** : OpenStreetMap (carte), OSRM/Valhalla (routage modifiable),
MapLibre/Mapbox (affichage), PostGIS (géospatial). Rien à réinventer côté carto : toute la valeur
ajoutée est dans **la couche probabilité + la boucle de recherche**.

---

## 8. Feuille de route

| Phase | Durée indicative | Contenu | Critère de succès |
|---|---|---|---|
| **0. Prototype** | 4-6 semaines | Carte web d'**une ville** avec segments + probabilité statique (open data + heuristiques horaires). Pas de compte, pas de temps réel. | La carte de chaleur « semble juste » aux habitants ; validation terrain sur 20 rues |
| **1. MVP mobile** | 2-3 mois | App mobile : destination → boucle de recherche guidée + carte de chaleur. Détection parked/unparked passive. Règles de stationnement (anti-amendes) comme produit d'appel. | Temps de recherche mesuré < recherche « naïve » ; rétention hebdo |
| **2. Temps réel communautaire** | +2 mois | Places libérées en direct, signalements, correction bayésienne, re-routage dynamique. | Densité d'événements suffisante dans les quartiers cibles |
| **3. Monétisation & échelle** | ensuite | Paiement du stationnement intégré, affiliation parkings, premium (prédiction longue portée, multi-villes), B2B data (villes, constructeurs). | Revenu par utilisateur actif |

**Stratégie anti œuf-et-poule** (leçon SpotAngels) : la valeur du jour 1 ne doit **pas** dépendre
de la communauté. Les règles de stationnement + la probabilité historique fonctionnent avec zéro
utilisateur. Le temps réel communautaire est un **amplificateur**, pas un prérequis.

---

## 9. Modèle économique (pistes)

1. **Freemium** : gratuit avec guidage de base ; premium (~2-4 €/mois) pour prédiction à l'heure
   d'arrivée, alertes nettoyage/amendes, multi-véhicules. (Modèle SpotAngels, avec reversement
   possible aux contributeurs.)
2. **Commission sur paiement** du stationnement (intégration PayByPhone/Flowbird/EasyPark).
3. **Affiliation parkings privés** (Zenpark, Onepark, Saemes) quand la voirie est saturée.
4. **B2B data** : vendre les cartes d'occupation aux villes (politique tarifaire, à la SFpark),
   constructeurs automobiles et GPS (le modèle Parknav→INRIX).

---

## 10. Risques et défis

| Risque | Gravité | Mitigation |
|---|---|---|
| Précision perçue insuffisante (« l'app m'a promis une place, il n'y en avait pas ») | 🔴 Élevée | Toujours communiquer en **probabilité/couleur**, jamais en promesse ; seuil de boucle à 90 % ; mesurer et afficher le temps de recherche économisé |
| Google/Waze ajoute la fonctionnalité | 🔴 Élevée | Aller vite sur un marché local (France), profondeur de données locales (règles, zones résidents), communauté |
| Œuf et poule des données temps réel | 🟠 Moyenne | Valeur jour-1 sans communauté (cf. §8) ; lancement ville par ville, quartier par quartier |
| Consommation batterie (GPS en arrière-plan) | 🟠 Moyenne | API d'activité natives (geofencing, activity recognition) plutôt que GPS continu |
| RGPD / vie privée (traces de déplacement) | 🟠 Moyenne | Anonymisation des événements, agrégation par segment, minimisation des données, CNIL dès la conception |
| Prédiction auto-destructrice à grande échelle | 🟡 Faible (au début) | Diversification des boucles (cf. §6.2) |
| Distraction au volant | 🟡 Faible | Guidage vocal, UI minimale en conduite |

---

## 11. Recommandation et prochaines étapes concrètes

1. **Choisir la ville pilote** (Paris a le meilleur open data ; une ville moyenne tendue peut être
   moins concurrentielle et plus facile pour un partenariat mairie).
2. **Construire le prototype Phase 0** : ingestion de l'open data stationnement + OSM, découpage en
   segments, heuristique de probabilité horaire, carte de chaleur web interactive. C'est
   entièrement réalisable dans ce dépôt (GitHub Pages peut héberger la démo cartographique).
3. **Valider sur le terrain** : comparer la carte aux observations réelles sur 20-30 rues à
   différentes heures ; c'est le test qui décide de tout.
4. Si validation ok → MVP mobile (Phase 1).

---

## Sources principales

- [Parknav — Real Time On-Street Parking](https://parknav.com/) et [partenariat INRIX/Parknav](https://inrix.com/press-releases/on-street-germany/)
- [INRIX — On-Street Occupancy Predictions sans capteurs](https://inrix.com/blog/introducing-new-on-street-occupancy-predictions-for-curb-analytics/) et [INRIX Parking Data](https://inrix.com/products/parking-data-software/)
- [SpotAngels — How we are building Parking Maps](https://www.spotangels.com/blog/how-we-are-building-parking-maps-for-the-world-at-spotangels/) ; [étude de cas HBS](https://aiinstitute.hbs.edu/platform-digit/submission/spotangels-using-crowds-to-solve-the-car-parking-problem/) ; [TechCrunch — levée de fonds](https://techcrunch.com/2018/07/24/spotangels-parking-funding/) ; [Forbes](https://www.forbes.com/sites/juliewalmsley/2019/02/07/this-startup-wants-to-help-you-outsmart-your-citys-parking-rules/)
- [Prédiction d'occupation avec info géospatiale (SFpark)](https://www.tandfonline.com/doi/full/10.1080/10095020.2021.1937337) ; [prédiction court-terme par deep learning](https://www.sciencedirect.com/science/article/pii/S2095756424000011) ; [ML in the web of things](https://www.sciencedirect.com/science/article/pii/S2542660520301335)
- [Dynamic Vehicle Routing with Parking Probability (−24 % temps de trajet)](https://journals.sagepub.com/doi/abs/10.1177/03611981211031223) ; [Probability-Aware Parking Selection (arXiv)](https://arxiv.org/html/2601.00521v1) ; [algorithme de routage voirie + parkings](https://www.researchgate.net/publication/324407090_A_NEW_ALGORITHM_FOR_PARK_SPOT_ROUTING_INCLUDING_ON-STREET_PARKING_AND_PARKING_GARAGES) ; [temps de recherche en voirie (arXiv)](https://arxiv.org/pdf/1806.10874)
- [Paris Data — stationnement voie publique (emplacements)](https://opendata.paris.fr/explore/dataset/stationnement-voie-publique-emplacements/) ; [emprises](https://opendata.paris.fr/explore/dataset/stationnement-sur-voie-publique-emprises/) ; [Saemes OpenData](https://opendata.saemes.fr/explore/)
