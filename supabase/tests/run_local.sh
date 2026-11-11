#!/bin/sh
# Kompletter lokaler Lauf gegen eine LEERE Wegwerf-Datenbank:
#   auth_stub.sql → alle Migrationen → schema_test.sql → quota_test.sql → input_test.sql
# und danach die Prüfung, dass die SQL-Tests keine Daten zurücklassen.
#
# Nie gegen Supabase ausführen (auth_stub.sql bricht dort ohnehin ab).
#
#   PSQL="psql postgresql://postgres:test@127.0.0.1:55433/cc" supabase/tests/run_local.sh
#   PSQL="docker exec -i cc-test psql -U postgres -d cc" supabase/tests/run_local.sh
set -eu

: "${PSQL:?PSQL setzen, z. B. PSQL=\"psql postgresql://…/cc\"}"
DIR=$(cd "$(dirname "$0")/.." && pwd)

run() { $PSQL -v ON_ERROR_STOP=1 -q "$@"; }

run < "$DIR/tests/auth_stub.sql"
for f in "$DIR"/migrations/*.sql; do
  echo "== $(basename "$f")"
  run < "$f"
done

# Zeilenzahl aller Tabellen in cc und auth - vor und nach den Tests gleich.
snapshot() {
  run -At <<'SQL'
select string_agg(format('%s=%s', t, n), ' ' order by t) from (
  select c.oid::regclass::text as t,
         (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from %s', c.oid::regclass), false, true, '')))[1]::text as n
    from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname in ('cc', 'auth') and c.relkind in ('r', 'p')
) x;
SQL
}

# Exit-Code von psql festhalten: in einer Pipe zählte sonst nur der von grep.
test_file() {
  status=0
  out=$(run < "$1" 2>&1) || status=$?
  printf '%s\n' "$out" | grep -E 'OK |FEHL|ERROR' | sed 's/.*NOTICE: *//' || true
  if [ "$status" -ne 0 ]; then
    echo "FEHLGESCHLAGEN: $(basename "$1")"
    exit 1
  fi
}

before=$(snapshot)
test_file "$DIR/tests/schema_test.sql"
test_file "$DIR/tests/quota_test.sql"
test_file "$DIR/tests/input_test.sql"
after=$(snapshot)

if [ "$before" != "$after" ]; then
  echo "FEHLGESCHLAGEN: Tests haben Daten zurückgelassen"
  echo "vorher:  $before"
  echo "nachher: $after"
  exit 1
fi
echo "OK   keine Testdaten zurückgeblieben"
