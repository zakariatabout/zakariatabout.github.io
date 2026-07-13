#!/usr/bin/env bash
# Compile ParkRadar (web) avec la couche communautaire Supabase activée,
# puis déploie le résultat dans /parking à la racine du site.
#
# La clé "publishable" (ex-"anon public") est publique par conception :
# elle est protégée côté serveur par les règles RLS de la table
# parking_events. Aucun secret ici.
set -euo pipefail

SUPABASE_URL="https://xkhsvwqzuzmrvdrghshv.supabase.co"
SUPABASE_ANON_KEY="sb_publishable_KmxkQQjvFmvblhBX3WBwHw__of4oMsF"

cd "$(dirname "$0")/app"

flutter build web --release --base-href /parking/ \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"

rm -rf ../../parking
cp -r build/web ../../parking
echo "Déployé dans /parking (mode communautaire partagé activé)."
