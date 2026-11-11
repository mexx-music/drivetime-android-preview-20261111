# CatLab API Control Center – Datenbankschema

Reines Schema. Es ist an keine laufende Anwendung angeschlossen; der
DriveTime-Proxy schreibt noch nichts hierher.

## Aufbau

| Datei | Inhalt |
|---|---|
| `migrations/…0001_cc_foundation.sql` | Einheiten, Pläne, Nutzer, Projekte, Anbieter, Leistungen, Preisliste, Freikontingente |
| `migrations/…0002_cc_usage.sql` | Sitzungen, Arbeitseinheiten, Verbrauchsereignisse (partitioniert), Zähler |
| `migrations/…0003_cc_billing.sql` | Rechnungsimporte, Rechnungsfakten, Abgleichssicht |
| `migrations/…0004_cc_settings.sql` | Projekt- und Leistungseinstellungen |
| `migrations/…0005_cc_seed_drivetime.sql` | Stammdaten DriveTime / Google Maps, bewusst ohne Preise |
| `migrations/…0006_cc_identity.sql` | `cc.users` an `auth.users`, Konten und Mitgliedschaften; entfernt `cc.users.plan` |
| `migrations/…0007_cc_quota.sql` | Plan-Kontingente, Entitlements, Tour-Ledger, Funktionen, Rechte |
| `tests/auth_stub.sql` | Nur lokal: Ersatz für `auth.users`. Bricht in Supabase ab |
| `tests/schema_test.sql` | Grundschema, läuft in einer Transaktion und macht sie am Ende rückgängig |
| `tests/quota_test.sql` | Kontingent-Schicht, ebenfalls in einer zurückgenommenen Transaktion |
| `tests/run_local.sh` | Stub, Migrationen, beide SQL-Tests und Prüfung auf zurückgebliebene Daten |

Parallelität (echte getrennte Verbindungen) und der Migrationslauf selbst
werden in `proxy/test/quota_db.test.js` geprüft.

## Lokal ausführen

Wegwerfcontainer nur für den eigenen Rechner. Das Passwort unten ist kein
Zugangsdatum, sondern eine Vorgabe ohne Bedeutung; der Container wird danach
wieder entfernt.

```bash
docker run -d --rm --name cc-pg -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=controlcenter -p 55432:5432 postgres:17-alpine
PSQL="docker exec -i cc-pg psql -U postgres -d controlcenter" supabase/tests/run_local.sh
```

In Supabase existiert `auth.users` bereits; dort läuft `auth_stub.sql` nie.

## Kontingente: Rechte für den Proxy (noch nicht angelegt)

Die Funktionen sind `SECURITY DEFINER` mit leerem `search_path`; niemand hat
Rechte an den Tabellen. Eine spätere Proxy-Rolle bekommt nur:

```sql
grant usage on schema cc to <proxy_rolle>;
grant execute on function cc.ensure_personal_account(uuid),
                          cc.ensure_default_entitlement(uuid, text),
                          cc.reserve_tour(uuid, text, uuid, uuid),
                          cc.use_tour_call(uuid, uuid),
                          cc.finish_tour_call(uuid, uuid, boolean),
                          cc.release_tour(uuid, uuid),
                          cc.complete_tour(uuid, uuid),
                          cc.counter_try_increment(smallint, integer, text, text, text, numeric, numeric, numeric)
  to <proxy_rolle>;
```

Plan-Kontingente (`cc.plan_quotas`) und Entitlements außerhalb des
Standard-Free-Plans setzt nur ein Administrator. Ohne aktive, vollständige
Kontingentzeile reserviert `cc.reserve_tour` keine Tour.

## Zwei Kostenzahlen, die nie addiert werden

* `cc.usage_events.cost_estimate` – eigene Schätzung, beim Buchen festgeschrieben.
* `cc.billing_facts.cost_actual` – was der Anbieter später tatsächlich berechnet hat.

`cc.v_reconciliation` stellt beide nebeneinander und bildet bewusst keine
gemeinsame Summe.

## Offene Entscheidungen

* Aufbewahrungsdauer der Verbrauchsereignisse. `cc.drop_usage_partition(date)`
  steht bereit, wird aber von nichts aufgerufen.
* Preise sind noch nicht eingetragen. Ohne Preis bleibt `cost_estimate` leer;
  Mengen werden trotzdem gezählt.
* Monatspartitionen reichen bis August 2027. `cc.ensure_usage_partition(date)`
  legt weitere an.

## Offene technische Aufgabe vor Produktionsbetrieb

Die Monatspartitionen von `cc.usage_events` sind bis **August 2027** vorbereitet.
Danach landet jede Buchung in der Auffangpartition `usage_events_default`.
Daten gehen dabei nicht verloren, aber die Auffangpartition wüchse unbegrenzt
und der Vorteil der Partitionierung – Abfragen auf einen Monat zu begrenzen und
alte Monate in einem Schritt zu löschen – ginge verloren.

Vor dem Produktionsbetrieb ist deshalb ein automatischer Mechanismus vorzusehen,
der rechtzeitig weitere Monate anlegt, etwa ein monatlicher Lauf von
`cc.ensure_usage_partition(current_date + interval '3 months')`. Ob das ein
Cron-Job, ein Supabase-Zeitplan oder ein Schritt beim Deployment wird, hängt
davon ab, wo die Datenbank am Ende läuft, und ist noch nicht entschieden.

Zur Kontrolle, wie weit die Partitionen reichen:

```sql
select max(c.relname) from pg_class c
  join pg_inherits i on i.inhrelid = c.oid
 where c.relkind = 'r' and i.inhparent = 'cc.usage_events'::regclass
   and c.relname ~ '^usage_events_[0-9]{6}$';
```
