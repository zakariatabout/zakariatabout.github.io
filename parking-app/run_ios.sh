#!/usr/bin/env bash
# Lance ParkRadar sur l'iPhone branché en USB, avec la couche communautaire
# Supabase activée (mêmes clés que le web). À exécuter sur votre Mac, iPhone
# connecté et déverrouillé.
#
# Prérequis : Flutter + Xcode + CocoaPods installés (voir README).
set -euo pipefail

SUPABASE_URL="https://xkhsvwqzuzmrvdrghshv.supabase.co"
SUPABASE_ANON_KEY="sb_publishable_KmxkQQjvFmvblhBX3WBwHw__of4oMsF"

cd "$(dirname "$0")/app"

flutter run --release \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
