# Déploiement sécurisé de la couche communautaire

La migration de `schema.sql` révoque l'accès anonyme historique à la table
`parking_events`. Elle doit donc être coordonnée avec un build ParkRadar qui
écrit via l'Edge Function et lit via la RPC agrégée. L'application actuelle
échoue volontairement sans revenir à la table brute si ces composants sont
absents.

## Ordre de publication

1. Sauvegarder la table `public.parking_events` et relever les métriques du
   projet Supabase.
2. Préparer et valider le nouveau build Web/iOS/Android avec
   `COMMUNITY_LEGACY_FALLBACK=false`.
3. Activer le module Supabase Cron (`pg_cron`) dans **Integrations → Cron**.
   La migration échoue volontairement si la purge ne peut pas être planifiée.
4. Exécuter intégralement `schema.sql` dans le SQL Editor Supabase.
   Attendre au moins une exécution minute du cron et vérifier son succès.
5. Configurer `REPORTER_HASH_SALT`, `PARKRADAR_PUBLISHABLE_KEY`,
   `HEALTHCHECK_TOKEN` et `ALLOWED_ORIGINS`, puis déployer
   `functions/report-parking-event` selon son README. Enregistrer le même secret
   de santé côté CI sous `PARKRADAR_HEALTHCHECK_TOKEN`, jamais dans Flutter.
6. Depuis la racine du dépôt, lancer :

   ```bash
   PARKRADAR_HEALTHCHECK_TOKEN='<secret-monitoring>' \
     ./parking-app/verify_backend.sh
   ```

7. Publier immédiatement le nouveau client. Les anciens clients continueront
   à afficher la carte, mais leur ancienne fonction communautaire pourra être
   indisponible après la révocation.
8. Surveiller pendant au moins une heure les erreurs PostgREST, les appels à
   `recent_parking_events`, `report_parking_event`,
   `community_backend_health`, `community_edge_health` et à l'Edge Function,
   les exécutions cron, les refus de limitation et le volume de lignes.
9. Vérifier la rétention et les droits d'accès aux logs Supabase/relais, puis
   les refléter dans l'information de confidentialité du produit.
10. Ajouter limitation au gateway, détection d'anomalies et attestation
    d'application avant une montée en charge publique.

Protégé par le secret de monitoring distinct, le contrôle ne conserve aucun
signalement : la santé Edge traverse la
validation, le HMAC, les verrous et un véritable `INSERT` dans la RPC avec
`p_dry_run=true`, puis supprime la ligne dans la même transaction. Elle confirme
ensuite le rôle serveur, les privilèges et un succès du cron datant de moins de
trois minutes. Le script vérifie aussi le CORS GitHub Pages et utilise, pour les
accès directs, une donnée invalide ou un filtre qui ne peut cibler aucune ligne.
