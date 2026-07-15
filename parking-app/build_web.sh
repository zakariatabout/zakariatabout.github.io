#!/usr/bin/env bash
# Valide et compile ParkRadar pour GitHub Pages, puis remplace le dossier
# /parking à la racine du dépôt. Ce script ne commit, ne fusionne et ne pousse
# aucun changement.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
app_dir="$script_dir/app"
publish_dir="$repo_dir/parking"
staging_dir="$repo_dir/parking.tmp"

# Chaque valeur peut être remplacée par une variable d'environnement. La clé
# Supabase ci-dessous est publishable ; une clé service_role ne doit jamais
# être transmise à Flutter.
SUPABASE_URL="${SUPABASE_URL:-https://xkhsvwqzuzmrvdrghshv.supabase.co}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-sb_publishable_KmxkQQjvFmvblhBX3WBwHw__of4oMsF}"
PARIS_DATA_BASE_URL="${PARIS_DATA_BASE_URL:-https://opendata.paris.fr/api/explore/v2.1/catalog/datasets}"
GEOCODING_SEARCH_URL="${GEOCODING_SEARCH_URL:-https://data.geopf.fr/geocodage/search}"
OVERPASS_URL="${OVERPASS_URL:-https://overpass-api.de/api/interpreter}"
# Aucun transfert automatique vers un second opérateur. Une instance de
# secours contractuelle peut être injectée explicitement en production.
OVERPASS_FALLBACK_URL="${OVERPASS_FALLBACK_URL:-}"
OSRM_DRIVING_BASE_URL="${OSRM_DRIVING_BASE_URL:-https://router.project-osrm.org/route/v1/driving}"
MAP_TILE_URL_TEMPLATE="${MAP_TILE_URL_TEMPLATE:-}"
if [[ -z "$MAP_TILE_URL_TEMPLATE" ]]; then
  MAP_TILE_URL_TEMPLATE='https://tile.openstreetmap.org/{z}/{x}/{y}.png'
fi
MAP_TILE_ATTRIBUTION="${MAP_TILE_ATTRIBUTION:-© contributeurs OpenStreetMap}"
NETWORK_TIMEOUT_SECONDS="${NETWORK_TIMEOUT_SECONDS:-30}"
OVERPASS_TIMEOUT_SECONDS="${OVERPASS_TIMEOUT_SECONDS:-18}"
COMMUNITY_TIMEOUT_SECONDS="${COMMUNITY_TIMEOUT_SECONDS:-12}"
COMMUNITY_EVENT_TTL_MINUTES="${COMMUNITY_EVENT_TTL_MINUTES:-15}"
COMMUNITY_RETENTION_HOURS="${COMMUNITY_RETENTION_HOURS:-24}"
COMMUNITY_POLL_INTERVAL_SECONDS="${COMMUNITY_POLL_INTERVAL_SECONDS:-20}"
COMMUNITY_LEGACY_FALLBACK="${COMMUNITY_LEGACY_FALLBACK:-false}"
COMMUNITY_REPORT_URL="${COMMUNITY_REPORT_URL:-}"
PARIS_DATA_MAX_PAGES="${PARIS_DATA_MAX_PAGES:-100}"
VERIFY_REMOTE_BACKEND="${VERIFY_REMOTE_BACKEND:-false}"

if ! command -v deno >/dev/null 2>&1; then
  echo "Deno est requis pour valider l'Edge Function et le schéma Supabase." >&2
  exit 2
fi

case "$COMMUNITY_LEGACY_FALLBACK" in
  true | false) ;;
  *)
    echo "COMMUNITY_LEGACY_FALLBACK doit valoir true ou false." >&2
    exit 2
    ;;
esac

case "$VERIFY_REMOTE_BACKEND" in
  true | false) ;;
  *)
    echo "VERIFY_REMOTE_BACKEND doit valoir true ou false." >&2
    exit 2
    ;;
esac

if [[ "$COMMUNITY_LEGACY_FALLBACK" == "true" ]]; then
  echo "Attention : repli Supabase legacy activé pour une migration contrôlée." >&2
fi

dart_defines=(
  "--dart-define=SUPABASE_URL=$SUPABASE_URL"
  "--dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"
  "--dart-define=PARIS_DATA_BASE_URL=$PARIS_DATA_BASE_URL"
  "--dart-define=GEOCODING_SEARCH_URL=$GEOCODING_SEARCH_URL"
  "--dart-define=OVERPASS_URL=$OVERPASS_URL"
  "--dart-define=OVERPASS_FALLBACK_URL=$OVERPASS_FALLBACK_URL"
  "--dart-define=OSRM_DRIVING_BASE_URL=$OSRM_DRIVING_BASE_URL"
  "--dart-define=MAP_TILE_URL_TEMPLATE=$MAP_TILE_URL_TEMPLATE"
  "--dart-define=MAP_TILE_ATTRIBUTION=$MAP_TILE_ATTRIBUTION"
  "--dart-define=NETWORK_TIMEOUT_SECONDS=$NETWORK_TIMEOUT_SECONDS"
  "--dart-define=OVERPASS_TIMEOUT_SECONDS=$OVERPASS_TIMEOUT_SECONDS"
  "--dart-define=COMMUNITY_TIMEOUT_SECONDS=$COMMUNITY_TIMEOUT_SECONDS"
  "--dart-define=COMMUNITY_EVENT_TTL_MINUTES=$COMMUNITY_EVENT_TTL_MINUTES"
  "--dart-define=COMMUNITY_RETENTION_HOURS=$COMMUNITY_RETENTION_HOURS"
  "--dart-define=COMMUNITY_POLL_INTERVAL_SECONDS=$COMMUNITY_POLL_INTERVAL_SECONDS"
  "--dart-define=COMMUNITY_LEGACY_FALLBACK=$COMMUNITY_LEGACY_FALLBACK"
  "--dart-define=COMMUNITY_REPORT_URL=$COMMUNITY_REPORT_URL"
  "--dart-define=PARIS_DATA_MAX_PAGES=$PARIS_DATA_MAX_PAGES"
)

# Compatibilité uniquement : ne rien transmettre par défaut afin que le build
# normal utilise l'autocomplétion IGN autorisée.
if [[ -n "${NOMINATIM_SEARCH_URL:-}" ]]; then
  dart_defines+=("--dart-define=NOMINATIM_SEARCH_URL=$NOMINATIM_SEARCH_URL")
fi

echo "Validation Edge/Supabase…"
cd "$repo_dir"
bash -n parking-app/build_web.sh parking-app/verify_backend.sh parking-app/run_ios.sh
deno fmt --check \
  parking-app/supabase/functions/report-parking-event/ \
  parking-app/supabase/schema_parse_test.ts
deno check \
  parking-app/supabase/functions/report-parking-event/index.ts \
  parking-app/supabase/schema_parse_test.ts
deno test parking-app/supabase/functions/report-parking-event/index_test.ts
deno test --allow-read parking-app/supabase/schema_parse_test.ts

echo "Validation Flutter…"
cd "$app_dir"
flutter pub get
flutter analyze --fatal-infos
flutter test --coverage
awk -F: '
  /^LF:/ { lines += $2 }
  /^LH:/ { hits += $2 }
  END {
    if (lines == 0) exit 2
    coverage = 100 * hits / lines
    printf "Couverture lignes : %.2f%%\n", coverage
    if (coverage < 75) exit 1
  }
' coverage/lcov.info

if [[ "$VERIFY_REMOTE_BACKEND" == "true" ]]; then
  echo "Vérification Edge/RPC/cron et des droits Supabase…"
  SUPABASE_URL="$SUPABASE_URL" SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
    PARKRADAR_HEALTHCHECK_TOKEN="${PARKRADAR_HEALTHCHECK_TOKEN:-}" \
    "$script_dir/verify_backend.sh"
fi

echo "Compilation web…"
flutter build web --release --base-href /parking/ "${dart_defines[@]}"

# Copie via un dossier temporaire : /parking n'est remplacé qu'après un build
# complet et une copie réussie.
rm -rf -- "$staging_dir"
cp -R build/web "$staging_dir"
rm -rf -- "$publish_dir"
mv "$staging_dir" "$publish_dir"

echo "Build validé et copié dans $publish_dir."
echo "Vérifier le site et Edge/RPC/cron/RLS Supabase avant de fusionner dans main."
