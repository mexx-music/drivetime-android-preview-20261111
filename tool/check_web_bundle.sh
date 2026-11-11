#!/bin/sh
# Prüft einen fertigen Web-Build (build/web) auf Dinge, die nie im Browser
# landen dürfen: Service-Role-/Secret-Schlüssel, Datenbankadressen,
# Proxy-Geheimnisse. Öffentliche Supabase-Werte (URL, Publishable Key) sind
# erlaubt und werden nicht beanstandet.
#
#   flutter build web --release … && tool/check_web_bundle.sh
set -eu
DIR="${1:-build/web}"
[ -d "$DIR" ] || { echo "Kein Build in $DIR"; exit 2; }

found=0
check() {
  if grep -rIl -E "$1" "$DIR" >/dev/null 2>&1; then
    echo "GEFUNDEN: $2"
    grep -rIl -E "$1" "$DIR" | sed 's/^/  in /'
    found=1
  else
    echo "OK   kein $2"
  fi
}

check 'sb_secret_[A-Za-z0-9_-]+'                    'Supabase-Secret-Key (sb_secret_…)'
check 'service_role'                                 'Service-Role-Hinweis'
check 'postgres(ql)?://'                             'Datenbankadresse'
check 'CONTROL_CENTER_DATABASE_URL|catlab-cc-db'     'Control-Center-Zugang'
check 'pooler\.supabase\.com'                        'Datenbank-Pooler-Adresse'
check 'SUPABASE_SERVICE_ROLE|SERVICE_ROLE_KEY'       'Service-Role-Variable'

# Ein alter JWT-Schlüssel mit role=service_role wäre base64-codiert:
# '"role":"service_role"' → eyJyb2xlIjoic2VydmljZV9yb2xlIi…
check 'InNlcnZpY2Vfcm9sZS|c2VydmljZV9yb2xl'          'base64-codierter service_role-JWT'

exit $found
