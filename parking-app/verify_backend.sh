#!/usr/bin/env bash
# Vérifie sans écrire de signalement valide que le backend communautaire
# déployé expose lecture agrégée, Edge Function, purge et privilèges attendus.
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://xkhsvwqzuzmrvdrghshv.supabase.co}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-sb_publishable_KmxkQQjvFmvblhBX3WBwHw__of4oMsF}"
PARKRADAR_HEALTHCHECK_TOKEN="${PARKRADAR_HEALTHCHECK_TOKEN:-}"

if [[ ! "$SUPABASE_URL" =~ ^https://[^/]+$ ]]; then
  echo "SUPABASE_URL doit être une origine HTTPS sans chemin final." >&2
  exit 2
fi
if [[ ${#PARKRADAR_HEALTHCHECK_TOKEN} -lt 32 ]]; then
  echo "PARKRADAR_HEALTHCHECK_TOKEN (32 caractères minimum) est requis ; il ne doit jamais être embarqué dans l'app." >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

common_headers=(
  --connect-timeout 5
  --max-time 20
  --header "apikey: $SUPABASE_ANON_KEY"
  --header "Authorization: Bearer $SUPABASE_ANON_KEY"
  --header "Content-Type: application/json"
)

recent_status="$(curl --silent --show-error \
  --output "$tmp_dir/recent.json" --write-out '%{http_code}' \
  "${common_headers[@]}" \
  --request POST \
  --data '{"p_min_lat":48.84,"p_max_lat":48.88,"p_min_lon":2.32,"p_max_lon":2.38,"p_max_age_seconds":900,"p_limit":1}' \
  "$SUPABASE_URL/rest/v1/rpc/recent_parking_events")"

health_status="$(curl --silent --show-error \
  --output "$tmp_dir/health.json" --write-out '%{http_code}' \
  "${common_headers[@]}" \
  --request POST --data '{}' \
  "$SUPABASE_URL/rest/v1/rpc/community_backend_health")"

edge_health_status="$(curl --silent --show-error \
  --output "$tmp_dir/edge-health.json" --write-out '%{http_code}' \
  "${common_headers[@]}" \
  --header "Origin: https://zakariatabout.github.io" \
  --header "x-parkradar-health-token: $PARKRADAR_HEALTHCHECK_TOKEN" \
  "$SUPABASE_URL/functions/v1/report-parking-event")"

edge_preflight_status="$(curl --silent --show-error \
  --output /dev/null --dump-header "$tmp_dir/edge-preflight.headers" \
  --write-out '%{http_code}' \
  "${common_headers[@]}" \
  --request OPTIONS \
  --header "Origin: https://zakariatabout.github.io" \
  --header "Access-Control-Request-Method: POST" \
  --header "Access-Control-Request-Headers: apikey,authorization,content-type" \
  "$SUPABASE_URL/functions/v1/report-parking-event")"
tr '[:upper:]' '[:lower:]' < "$tmp_dir/edge-preflight.headers" \
  > "$tmp_dir/edge-preflight-lower.headers"

# Un type invalide est rejeté par l'Edge Function avant tout appel à la base.
edge_status="$(curl --silent --show-error \
  --output "$tmp_dir/edge.json" --write-out '%{http_code}' \
  "${common_headers[@]}" \
  --request POST \
  --header "Origin: https://zakariatabout.github.io" \
  --data '{"event_type":"healthcheck","lat":48.856,"lon":2.352,"client_token":"invalid"}' \
  "$SUPABASE_URL/functions/v1/report-parking-event")"

direct_select_status="$(curl --silent --show-error \
  --output "$tmp_dir/direct-select.json" --write-out '%{http_code}' \
  "${common_headers[@]}" \
  "$SUPABASE_URL/rest/v1/parking_events?select=id&limit=0")"

# L'insertion porte une latitude que la contrainte SQL refuserait même si les
# droits étaient ouverts. PATCH et DELETE ciblent une clé primaire impossible.
direct_insert_status="$(curl --silent --show-error \
  --output "$tmp_dir/direct-insert.json" --write-out '%{http_code}' \
  "${common_headers[@]}" \
  --request POST \
  --data '{"event_type":"parked","lat":999,"lon":0}' \
  "$SUPABASE_URL/rest/v1/parking_events")"
direct_update_status="$(curl --silent --show-error \
  --output "$tmp_dir/direct-update.json" --write-out '%{http_code}' \
  "${common_headers[@]}" \
  --request PATCH \
  --data '{"lat":0}' \
  "$SUPABASE_URL/rest/v1/parking_events?id=is.null")"
direct_delete_status="$(curl --silent --show-error \
  --output "$tmp_dir/direct-delete.json" --write-out '%{http_code}' \
  "${common_headers[@]}" \
  --request DELETE \
  "$SUPABASE_URL/rest/v1/parking_events?id=is.null")"

failed=false
if [[ "$recent_status" != "200" ]]; then
  echo "ÉCHEC : recent_parking_events répond HTTP $recent_status (attendu 200)." >&2
  failed=true
fi
if [[ "$edge_preflight_status" != "200" ]] || \
    ! grep -Fq 'access-control-allow-origin: https://zakariatabout.github.io' \
      "$tmp_dir/edge-preflight-lower.headers" || \
    ! grep -Eq 'access-control-allow-headers:.*apikey' \
      "$tmp_dir/edge-preflight-lower.headers" || \
    ! grep -Eq 'access-control-allow-headers:.*authorization' \
      "$tmp_dir/edge-preflight-lower.headers" || \
    ! grep -Eq 'access-control-allow-headers:.*content-type' \
      "$tmp_dir/edge-preflight-lower.headers"; then
  echo "ÉCHEC : CORS GitHub Pages incomplet sur l'Edge Function (HTTP $edge_preflight_status)." >&2
  failed=true
fi
edge_health_compact="$(tr -d '[:space:]' < "$tmp_dir/edge-health.json")"
if [[ "$edge_health_status" != "200" ]] || \
    [[ "$edge_health_compact" != *'"ok":true'* ]] || \
    [[ "$edge_health_compact" != *'"schema_version":"2026-07-p0-v4"'* ]]; then
  echo "ÉCHEC : l'Edge Function ne confirme pas ses secrets et le backend (HTTP $edge_health_status)." >&2
  failed=true
fi
health_compact="$(tr -d '[:space:]' < "$tmp_dir/health.json")"
if [[ "$health_status" != "200" ]] || \
    [[ "$health_compact" != *'"schema_version":"2026-07-p0-v4"'* ]] || \
    [[ "$health_compact" != *'"purge_job_active":true'* ]] || \
    [[ "$health_compact" != *'"purge_last_run_at":'* ]] || \
    [[ "$health_compact" != *'"purge_last_run_succeeded":true'* ]] || \
    [[ "$health_compact" != *'"anon_table_access":false'* ]] || \
    [[ "$health_compact" != *'"authenticated_table_access":false'* ]] || \
    [[ "$health_compact" != *'"anon_report_execute":false'* ]] || \
    [[ "$health_compact" != *'"authenticated_report_execute":false'* ]] || \
    [[ "$health_compact" != *'"service_report_execute":true'* ]]; then
  echo "ÉCHEC : community_backend_health ne confirme pas version, purge et révocations (HTTP $health_status)." >&2
  failed=true
fi
if [[ "$edge_status" != "400" ]] || \
    ! grep -Fq 'invalid_event_type' "$tmp_dir/edge.json"; then
  echo "ÉCHEC : l'Edge Function ne rejette pas invalid_event_type (HTTP $edge_status)." >&2
  failed=true
fi
for access in \
  "SELECT:$direct_select_status" \
  "INSERT:$direct_insert_status" \
  "UPDATE:$direct_update_status" \
  "DELETE:$direct_delete_status"; do
  operation="${access%%:*}"
  status="${access##*:}"
  if [[ "$status" != "401" && "$status" != "403" ]]; then
    echo "ÉCHEC : accès direct $operation à parking_events répond HTTP $status (attendu 401/403)." >&2
    failed=true
  fi
done

if [[ "$failed" == "true" ]]; then
  echo "Déployer schéma + cron + secrets + Edge Function selon parking-app/supabase/ROLLOUT.md, puis relancer." >&2
  exit 1
fi

echo "Backend communautaire conforme : Edge/RPC/cron actifs, table brute protégée."
