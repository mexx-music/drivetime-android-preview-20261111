-- Prüfungen für das Tagesbudget der Adresseingabe (Migration 0008).
-- Läuft in EINER Transaktion und nimmt am Ende alles zurück. Parallelität:
-- proxy/test/quota_db.test.js.
\set ON_ERROR_STOP on
\timing off
set client_min_messages = notice;

begin;

create function pg_temp.t(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok then raise notice 'OK   %', label;
  else raise exception 'FEHLGESCHLAGEN: %', label;
  end if;
end $$;

create function pg_temp.pid(k text) returns smallint language sql as
  $$ select id from cc.projects where key = k $$;

create function pg_temp.used(u uuid) returns numeric language sql as $$
  select coalesce(sum(c.quantity), 0) from cc.counters c
    join cc.accounts a on a.id::text = c.scope_key
   where a.personal_owner = u and c.scope = 'account'
     and c.period = to_char(now() at time zone 'UTC', 'YYYY-MM-DD')
$$;

insert into auth.users (id) values
  ('00000000-0000-4000-8000-0000000000a1'),
  ('00000000-0000-4000-8000-0000000000a2'),
  ('00000000-0000-4000-8000-0000000000a3');
insert into cc.projects (key, name) values ('itest', 'Input-Test'), ('itest-off', 'Input-Test aus');
insert into cc.project_settings (project_id) select id from cc.projects where key in ('itest', 'itest-off');
update cc.project_settings set mode = 'off' where project_id = pg_temp.pid('itest-off');

do $$
declare a uuid;
begin
  a := cc.ensure_personal_account('00000000-0000-4000-8000-0000000000a1');
  perform cc.ensure_default_entitlement(a, 'itest');
  perform cc.ensure_default_entitlement(a, 'itest-off');
  a := cc.ensure_personal_account('00000000-0000-4000-8000-0000000000a2');
  perform cc.ensure_default_entitlement(a, 'itest');
end $$;

-- ============================================================ fail closed
do $$
declare
  u uuid := '00000000-0000-4000-8000-0000000000a1';
  r jsonb;
begin
  r := cc.try_input_call(u, 'itest', 'places-autocomplete');
  perform pg_temp.t(r->>'status' = 'input_quota_not_configured', 'ohne Kontingentzeile: fail closed');

  insert into cc.plan_quotas (project_id, plan_key, tours_per_period, max_calls_per_tour, tour_ttl,
                              input_calls_per_day, active)
    values (pg_temp.pid('itest'), 'free', 5, 4, interval '10 minutes', null, true);
  r := cc.try_input_call(u, 'itest', 'geocode');
  perform pg_temp.t(r->>'status' = 'input_quota_not_configured',
                    'aktive Zeile, aber input_calls_per_day NULL: fail closed (nie unbegrenzt)');

  update cc.plan_quotas set input_calls_per_day = 3, active = false where project_id = pg_temp.pid('itest');
  r := cc.try_input_call(u, 'itest', 'geocode');
  perform pg_temp.t(r->>'status' = 'input_quota_not_configured', 'inaktive Zeile: fail closed');
  perform pg_temp.t(pg_temp.used(u) = 0, 'abgelehnte Aufrufe zählen nicht');

  update cc.plan_quotas set active = true where project_id = pg_temp.pid('itest');
end $$;

-- ================================================ Zählen, gemeinsames Budget
do $$
declare
  u uuid := '00000000-0000-4000-8000-0000000000a1';
  r jsonb;
  tours_before int := (select count(*) from cc.tours);
begin
  r := cc.try_input_call(u, 'itest', 'places-autocomplete');
  perform pg_temp.t(r->>'status' = 'ok' and (r->>'used')::int = 1 and (r->>'limit')::int = 3,
                    'Autocomplete zählt genau einen Input-Call');
  r := cc.try_input_call(u, 'itest', 'geocode');
  perform pg_temp.t(r->>'status' = 'ok' and (r->>'used')::int = 2,
                    'Geocoding zählt genau einen Input-Call, gemeinsames Budget');
  perform pg_temp.t(r->>'period' = to_char(now() at time zone 'UTC', 'YYYY-MM-DD'),
                    'Periode ist der UTC-Tag des Servers');
  r := cc.try_input_call(u, 'itest', 'geocode');
  perform pg_temp.t(r->>'status' = 'ok' and (r->>'used')::int = 3, 'dritter Aufruf am Limit erlaubt');

  r := cc.try_input_call(u, 'itest', 'places-autocomplete');
  perform pg_temp.t(r->>'status' = 'input_quota_exhausted' and (r->>'used')::int = 3,
                    'Budget erschöpft: Autocomplete abgelehnt');
  r := cc.try_input_call(u, 'itest', 'geocode');
  perform pg_temp.t(r->>'status' = 'input_quota_exhausted', 'Budget erschöpft: auch Geocoding abgelehnt');
  perform pg_temp.t(pg_temp.used(u) = 3, 'abgelehnte Aufrufe erhöhen den Zähler nicht');

  perform pg_temp.t((select count(*) from cc.counters c join cc.accounts a on a.id::text = c.scope_key
                      where a.personal_owner = u and c.scope = 'account') = 2,
                    'gezählt in den vorhandenen cc.counters, eine Zeile je Dienst');

  perform pg_temp.t((select count(*) from cc.tours) = tours_before,
                    'Eingabe-Aufrufe legen keine Tour an');
  r := cc.reserve_tour(u, 'itest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'reserved', 'Tour-Kontingent bleibt vom Eingabe-Budget unberührt');
end $$;

-- ======================================================= Tagesgrenze
do $$
declare
  u uuid := '00000000-0000-4000-8000-0000000000a2';
  a uuid := (select id from cc.accounts where personal_owner = '00000000-0000-4000-8000-0000000000a2');
  r jsonb;
begin
  -- Gestern voll ausgeschöpft: zählt heute nicht mit.
  insert into cc.counters (project_id, service_id, scope, scope_key, period, quantity)
  select pg_temp.pid('itest'), s.id, 'account', a::text,
         to_char((now() - interval '1 day') at time zone 'UTC', 'YYYY-MM-DD'), 99
    from cc.services s where s.key = 'geocode';
  r := cc.try_input_call(u, 'itest', 'geocode');
  perform pg_temp.t(r->>'status' = 'ok' and (r->>'used')::int = 1, 'Vortag zählt nicht mit');
  -- Konten sind getrennt: u1 ist erschöpft, u2 nicht.
  perform pg_temp.t(pg_temp.used(u) = 1, 'Budget gilt je Konto');
end $$;

-- ================================================ Konto, Plan, Projekt
do $$
declare
  u1 uuid := '00000000-0000-4000-8000-0000000000a1';
  u2 uuid := '00000000-0000-4000-8000-0000000000a2';
  a2 uuid := (select id from cc.accounts where personal_owner = '00000000-0000-4000-8000-0000000000a2');
begin
  perform pg_temp.t(cc.try_input_call(u1, 'itest-off', 'geocode')->>'status' = 'project_paused',
                    'Projekt im Modus off: keine Aufrufe');
  perform pg_temp.t(cc.try_input_call(u1, 'gibt-es-nicht', 'geocode')->>'status' = 'unknown_project',
                    'unbekanntes Projekt');
  perform pg_temp.t(cc.try_input_call(u1, 'itest', 'directions')->>'status' = 'invalid_argument',
                    'nur Autocomplete und Geocoding sind Eingabe-Aufrufe');
  perform pg_temp.t(cc.try_input_call(null, 'itest', 'geocode')->>'status' = 'invalid_argument',
                    'ohne Nutzer keine Freigabe');
  perform pg_temp.t(cc.try_input_call('00000000-0000-4000-8000-0000000000a3', 'itest', 'geocode')->>'status'
                    = 'not_member', 'Auth-Nutzer ohne Konto: keine Freigabe');
  perform pg_temp.t(cc.try_input_call(gen_random_uuid(), 'itest', 'geocode')->>'status' = 'not_member',
                    'unbekannter Nutzer: keine Freigabe');

  update cc.entitlements set status = 'canceled' where account_id = a2 and project_id = pg_temp.pid('itest');
  perform pg_temp.t(cc.try_input_call(u2, 'itest', 'geocode')->>'status' = 'entitlement_inactive',
                    'gekündigtes Entitlement: keine Freigabe');
  delete from cc.entitlements where account_id = a2 and project_id = pg_temp.pid('itest');
  perform pg_temp.t(cc.try_input_call(u2, 'itest', 'geocode')->>'status' = 'no_entitlement',
                    'ohne Entitlement: keine Freigabe');

  update cc.users set disabled_at = now() where id = u1;
  perform pg_temp.t(cc.try_input_call(u1, 'itest', 'geocode')->>'status' = 'user_disabled',
                    'gesperrter Nutzer: keine Freigabe');
  update cc.users set disabled_at = null where id = u1;
  update cc.accounts set disabled_at = now() where personal_owner = u1;
  perform pg_temp.t(cc.try_input_call(u1, 'itest', 'geocode')->>'status' = 'account_disabled',
                    'gesperrtes Konto: keine Freigabe');
end $$;

-- ================================================================ Rechte
do $$
begin
  perform pg_temp.t(
    (select prosecdef and proconfig @> array['search_path=""'] from pg_proc
      where oid = 'cc.try_input_call(uuid,text,text)'::regprocedure),
    'SECURITY DEFINER mit leerem search_path');
  perform pg_temp.t(not has_function_privilege('public', 'cc.try_input_call(uuid,text,text)', 'execute'),
                    'PUBLIC darf try_input_call nicht ausführen');
end $$;

rollback;
