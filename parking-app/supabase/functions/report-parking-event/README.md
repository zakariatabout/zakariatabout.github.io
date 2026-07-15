# Edge Function `report-parking-event`

Cette fonction est l'unique porte d'écriture publique de la communauté. Elle
valide la requête, hache l'adresse IP avec un secret serveur, puis appelle la
RPC privée avec la clé `service_role`. Le code applicatif ne les écrit pas en
clair dans la base ni dans ses propres logs : seuls le HMAC de l'IP et le
SHA-256 du jeton sont stockés pendant environ 24 heures (purge planifiée chaque
minute). L'infrastructure Supabase et son relais peuvent néanmoins traiter des
métadonnées réseau selon leur politique de logs ; leur accès et leur rétention
doivent être configurés et documentés séparément.

Avant le déploiement :

```bash
supabase secrets set REPORTER_HASH_SALT='<secret-aléatoire-de-32-octets-minimum>'
supabase secrets set PARKRADAR_PUBLISHABLE_KEY='<clé-publishable-du-client>'
supabase secrets set HEALTHCHECK_TOKEN='<secret-monitoring-distinct-de-32-octets-minimum>'
supabase secrets set ALLOWED_ORIGINS='https://zakariatabout.github.io'
supabase functions deploy report-parking-event --no-verify-jwt
```

`SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY` sont injectées par l'environnement
Supabase. La désactivation de la vérification JWT est intentionnelle car
ParkRadar n'impose pas de compte. Le handler exige tout de même la clé
publishable configurée ; elle identifie l'application mais, étant publique, ne
constitue pas une authentification forte. La limitation par
IP/installation/cellule reste appliquée en base. Une attestation Apple/Google et
une limitation au gateway doivent compléter ce socle avant une montée en charge
sensible.

Le `GET` de santé qui traverse une transaction réelle exige en plus
`x-parkradar-health-token`. Ce secret est réservé au monitoring, au script de
vérification et au secret GitHub Actions `PARKRADAR_HEALTHCHECK_TOKEN` ; il ne
doit apparaître dans aucun `--dart-define`, bundle Web ou binaire mobile.
