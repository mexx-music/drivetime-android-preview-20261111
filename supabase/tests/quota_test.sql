-- Prüfungen für Konten, Entitlements, Kontingente und Tour-Ledger
-- (Migrationen 0006/0007).
--
-- Läuft in EINER Transaktion und nimmt am Ende alles zurück. Hilfsfunktionen
-- liegen in pg_temp, damit nichts außerhalb der Transaktion zurückbleibt.
-- Parallelität (zwei Verbindungen um den letzten Platz usw.) prüft
-- proxy/test/quota_db.test.js mit echten getrennten Verbindungen.
--
-- Ausführen:  psql -v ON_ERROR_STOP=1 -f supabase/tests/quota_test.sql
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

-- Erwartet, dass sql mit dem angegebenen SQLSTATE scheitert.
create function pg_temp.fails(sql text, expected_state text, label text) returns void
language plpgsql as $$
declare got text := null;
begin
  begin
    execute sql;
  exception when others then got := sqlstate;
  end;
  perform pg_temp.t(got = expected_state,
                    label || coalesce(' (SQLSTATE ' || got || ')', ' (kein Fehler)'));
end $$;

create function pg_temp.pid(k text) returns smallint language sql as
  $$ select id from cc.projects where key = k $$;

-- Feste Test-IDs
--  u1 Free-Nutzer        u2 zweiter Nutzer (auch Fleet-Mitglied)
--  u3 Fleet-Nutzer       u4 gesperrter Nutzer      u5 Zähl-Nutzer (fester Zeitraum)
--  u6 existiert nur in auth.users
insert into auth.users (id) values
  ('00000000-0000-4000-8000-000000000001'),
  ('00000000-0000-4000-8000-000000000002'),
  ('00000000-0000-4000-8000-000000000003'),
  ('00000000-0000-4000-8000-000000000004'),
  ('00000000-0000-4000-8000-000000000005'),
  ('00000000-0000-4000-8000-000000000006');

insert into cc.projects (key, name) values
  ('qtest', 'Quota-Test'), ('qtest2', 'Quota-Test 2'), ('qtest3', 'Ohne Einstellungen');
insert into cc.project_settings (project_id)
  select id from cc.projects where key in ('qtest', 'qtest2');

-- =================================================== Konten anlegen
do $$
declare a1 uuid; a1b uuid;
begin
  a1  := cc.ensure_personal_account('00000000-0000-4000-8000-000000000001');
  a1b := cc.ensure_personal_account('00000000-0000-4000-8000-000000000001');
  perform pg_temp.t(a1 = a1b, 'persönliches Konto: zweiter Aufruf liefert dasselbe Konto');
  perform pg_temp.t((select count(*) from cc.accounts
                      where personal_owner = '00000000-0000-4000-8000-000000000001') = 1,
                    'persönliches Konto: genau eins je Nutzer');
  perform pg_temp.t((select role from cc.account_members
                      where account_id = a1 and user_id = '00000000-0000-4000-8000-000000000001') = 'owner',
                    'persönliches Konto: Nutzer ist Besitzer');
  perform pg_temp.fails($q$ select cc.ensure_personal_account('00000000-0000-4000-8000-0000000000ff') $q$,
                        '23503', 'persönliches Konto nur für existierende Auth-Nutzer');

  perform cc.ensure_personal_account('00000000-0000-4000-8000-000000000002');
  perform cc.ensure_personal_account('00000000-0000-4000-8000-000000000003');
  perform cc.ensure_personal_account('00000000-0000-4000-8000-000000000004');
  perform cc.ensure_personal_account('00000000-0000-4000-8000-000000000005');
end $$;

-- ============================================ Entitlement und Fail-closed
do $$
declare
  a1 uuid := (select id from cc.accounts where personal_owner = '00000000-0000-4000-8000-000000000001');
  r jsonb;
begin
  r := cc.reserve_tour('00000000-0000-4000-8000-000000000001', 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'no_entitlement', '(4) ohne Entitlement keine Tour');

  r := cc.ensure_default_entitlement(a1, 'qtest');
  perform pg_temp.t(r->>'status' = 'created' and r->>'plan_key' = 'free',
                    'Standard-Entitlement Free wird angelegt');
  r := cc.ensure_default_entitlement(a1, 'qtest');
  perform pg_temp.t(r->>'status' = 'existing', 'Standard-Entitlement: zweiter Aufruf ändert nichts');

  -- (2) Keine Kontingentzeile
  r := cc.reserve_tour('00000000-0000-4000-8000-000000000001', 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'quota_not_configured', '(2) ohne Kontingent-Konfiguration: fail closed');

  -- (3)/(21) Zeile vorhanden, aber inaktiv und leer
  insert into cc.plan_quotas (project_id, plan_key) values (pg_temp.pid('qtest'), 'free');
  r := cc.reserve_tour('00000000-0000-4000-8000-000000000001', 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'quota_not_configured', '(3) inaktiver Plan ohne Werte: fail closed');

  perform pg_temp.fails($q$ update cc.plan_quotas set active = true
                             where plan_key = 'free' and project_id = pg_temp.pid('qtest') $q$,
                        '23514', '(21) aktiv ohne Werte ist nicht speicherbar (NULL heißt nie unbegrenzt)');
  perform pg_temp.fails($q$ update cc.plan_quotas
                               set active = true, tours_per_period = 5, tour_ttl = interval '10 minutes'
                             where plan_key = 'free' and project_id = pg_temp.pid('qtest') $q$,
                        '23514', '(21) aktiv ohne max_calls_per_tour ist nicht speicherbar');

  update cc.plan_quotas
     set tours_per_period = 2, max_calls_per_tour = 3, tour_ttl = interval '10 minutes'
   where plan_key = 'free' and project_id = pg_temp.pid('qtest');
  r := cc.reserve_tour('00000000-0000-4000-8000-000000000001', 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'quota_not_configured', '(3) vollständige Werte, aber inaktiv: fail closed');

  update cc.plan_quotas set active = true
   where plan_key = 'free' and project_id = pg_temp.pid('qtest');
end $$;

-- ======================================= Reservieren, Idempotenz, Zählen
do $$
declare
  u1 uuid := '00000000-0000-4000-8000-000000000001';
  k1 uuid := '10000000-0000-4000-8000-000000000001';
  k2 uuid := '10000000-0000-4000-8000-000000000002';
  r jsonb; r2 jsonb;
begin
  r := cc.reserve_tour(u1, 'qtest', k1);
  perform pg_temp.t(r->>'status' = 'reserved' and r->>'state' = 'reserved',
                    '(1) Free-Konto mit gültigem Entitlement: Tour reserviert');
  perform pg_temp.t((r->>'call_budget')::int = 3 and (r->>'calls_used')::int = 0,
                    '(1) Aufrufbudget kommt aus dem Plan');
  perform pg_temp.t((r->>'tours_used')::int = 1 and (r->>'tours_limit')::int = 2,
                    '(1) Rückgabe nennt Verbrauch und Grenze');
  perform pg_temp.t((r->>'expires_at')::timestamptz = now() + interval '10 minutes',
                    '(1) Laufzeit kommt aus dem Plan');
  perform pg_temp.t((select plan_key from cc.tours where id = (r->>'tour_id')::uuid) = 'free',
                    'Tour hält den Plan zum Zeitpunkt der Reservierung fest');

  r2 := cc.reserve_tour(u1, 'qtest', k1);
  perform pg_temp.t(r2->>'status' = 'existing' and r2->>'tour_id' = r->>'tour_id',
                    '(6) Doppelklick mit gleichem Schlüssel: dieselbe Tour');
  perform pg_temp.t((select count(*) from cc.tours where user_id = u1 and idempotency_key = k1) = 1,
                    '(7) gleicher Schlüssel erzeugt nie zwei Touren');
  r2 := cc.reserve_tour(u1, 'qtest2', k1);
  perform pg_temp.t(r2->>'status' = 'idempotency_conflict',
                    '(7) gleicher Schlüssel für ein anderes Projekt: Konflikt statt zweiter Tour');

  r := cc.reserve_tour(u1, 'qtest', k2);
  perform pg_temp.t(r->>'status' = 'reserved' and (r->>'tours_used')::int = 2,
                    '(9) reservierte Touren zählen gegen das Kontingent');
  r := cc.reserve_tour(u1, 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'quota_exhausted'
                    and (r->>'tours_used')::int = 2 and (r->>'tours_limit')::int = 2,
                    '(5) Kontingent ausgeschöpft: quota_exhausted');
  perform pg_temp.t((select count(*) from cc.tours where user_id = u1) = 2,
                    '(5) abgelehnter Versuch legt keine Tour an');

  -- Wiederholung eines alten Schlüssels bleibt auch bei vollem Kontingent möglich.
  r := cc.reserve_tour(u1, 'qtest', k1);
  perform pg_temp.t(r->>'status' = 'existing', '(6) Wiederholung trotz vollem Kontingent: dieselbe Tour');
end $$;

-- ========================================= Freigeben und Aufrufe einer Tour
do $$
declare
  u1 uuid := '00000000-0000-4000-8000-000000000001';
  u2 uuid := '00000000-0000-4000-8000-000000000002';
  t1 uuid := (select id from cc.tours where idempotency_key = '10000000-0000-4000-8000-000000000001');
  t2 uuid := (select id from cc.tours where idempotency_key = '10000000-0000-4000-8000-000000000002');
  t3 uuid;
  r jsonb;
begin
  r := cc.release_tour(t2, u1);
  perform pg_temp.t(r->>'status' = 'released' and r->>'state' = 'released',
                    '(13) reservierte Tour lässt sich freigeben');
  r := cc.release_tour(t2, u1);
  perform pg_temp.t(r->>'status' = 'already_released', 'zweites Freigeben ist harmlos');

  r := cc.reserve_tour(u1, 'qtest', '10000000-0000-4000-8000-000000000003');
  perform pg_temp.t(r->>'status' = 'reserved' and (r->>'tours_used')::int = 2,
                    '(11) freigegebene Tour zählt nicht mehr');
  t3 := (r->>'tour_id')::uuid;

  r := cc.use_tour_call(t2, u1);
  perform pg_temp.t(r->>'status' = 'released', '(18) freigegebene Tour kann nicht genutzt werden');

  -- Aufruf beginnt: Freigabe ist währenddessen gesperrt.
  r := cc.use_tour_call(t1, u1);
  perform pg_temp.t(r->>'status' = 'ok' and (r->>'calls_used')::int = 1,
                    '(15) use_tour_call zählt den Aufruf');
  perform pg_temp.t((select calls_in_flight from cc.tours where id = t1) = 1,
                    '(15) Aufruf ist als laufend vermerkt');
  r := cc.release_tour(t1, u1);
  perform pg_temp.t(r->>'status' = 'call_in_flight',
                    'Freigabe während eines laufenden Aufrufs wird verweigert');

  r := cc.finish_tour_call(t1, u1, true);
  perform pg_temp.t(r->>'status' = 'ok' and r->>'state' = 'consumed',
                    'erster erfolgreicher Aufruf macht die Tour zu consumed');
  perform pg_temp.t((select first_success_at from cc.tours where id = t1) = now(),
                    'Zeitpunkt des ersten Erfolgs ist festgehalten');
  r := cc.release_tour(t1, u1);
  perform pg_temp.t(r->>'status' = 'consumed' and
                    (select state from cc.tours where id = t1) = 'consumed',
                    '(14) verbrauchte Tour kann nicht freigegeben werden');

  -- Wiederholung in derselben Tour (z. B. nach Timeout des zweiten Aufrufs).
  r := cc.use_tour_call(t1, u1);
  perform pg_temp.t(r->>'status' = 'ok' and r->>'state' = 'consumed',
                    '(19) Retry einer verbrauchten Tour innerhalb der Laufzeit funktioniert');
  r := cc.finish_tour_call(t1, u1, false);
  perform pg_temp.t(r->>'state' = 'consumed', 'fehlgeschlagener Retry lässt die Tour verbraucht');
  r := cc.reserve_tour(u1, 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'quota_exhausted',
                    '(12) verbrauchte Tour zählt; ein Retry verbraucht keine zweite');

  r := cc.use_tour_call(t1, u1);
  perform pg_temp.t(r->>'status' = 'ok' and (r->>'calls_used')::int = 3, '(15) dritter Aufruf');
  perform cc.finish_tour_call(t1, u1, true);
  r := cc.use_tour_call(t1, u1);
  perform pg_temp.t(r->>'status' = 'budget_exhausted', '(16) Aufrufbudget kann nicht überschritten werden');
  perform pg_temp.t((select calls_used from cc.tours where id = t1) = 3,
                    '(16) abgelehnter Aufruf wird nicht gezählt');

  r := cc.finish_tour_call(t1, u1, true);
  perform pg_temp.t(r->>'status' = 'no_call_in_flight', 'Ergebnis ohne begonnenen Aufruf wird abgewiesen');

  -- (17) fremder Nutzer
  perform pg_temp.t(cc.use_tour_call(t3, u2)->>'status' = 'not_found', '(17) fremder Nutzer kann Tour nicht nutzen');
  perform pg_temp.t(cc.release_tour(t3, u2)->>'status' = 'not_found', '(17) fremder Nutzer kann Tour nicht freigeben');
  perform pg_temp.t(cc.finish_tour_call(t3, u2, true)->>'status' = 'not_found',
                    '(17) fremder Nutzer kann keinen Erfolg melden');
  perform pg_temp.t(cc.complete_tour(t3, u2)->>'status' = 'not_found', '(17) fremder Nutzer kann Tour nicht abschließen');
  perform pg_temp.t(cc.use_tour_call(gen_random_uuid(), u1)->>'status' = 'not_found', 'unbekannte Tour: not_found');

  -- Abschließen
  perform pg_temp.t(cc.complete_tour(t3, u1)->>'status' = 'not_consumed',
                    'reservierte Tour kann nicht abgeschlossen werden');
  perform pg_temp.t(cc.complete_tour(t1, u1)->>'status' = 'completed', 'verbrauchte Tour wird abgeschlossen');
  perform pg_temp.t(cc.complete_tour(t1, u1)->>'status' = 'already_completed', 'zweites Abschließen ist harmlos');
  perform pg_temp.t(cc.use_tour_call(t1, u1)->>'status' = 'completed', 'abgeschlossene Tour nimmt keine Aufrufe mehr');

  -- Fehlschlag allein verbraucht nichts.
  perform cc.use_tour_call(t3, u1);
  r := cc.finish_tour_call(t3, u1, false);
  perform pg_temp.t(r->>'state' = 'reserved', 'fehlgeschlagener Aufruf lässt die Tour reserviert');
  perform pg_temp.t(cc.release_tour(t3, u1)->>'status' = 'released',
                    'nach fehlgeschlagenem Aufruf ist Freigabe möglich');
end $$;

-- ==================================== Zählregeln über Zeit (fester Zeitraum)
-- u5 bekommt einen expliziten Zeitraum um "jetzt", damit Monatsgrenzen den
-- Test nicht beeinflussen. Touren werden direkt mit vergangenen Zeiten
-- angelegt - das ist die einzige Art, in einer Transaktion Zeit vergehen zu
-- lassen.
insert into cc.plans (key, name, sort_order) values ('qtest-plan', 'Testplan', 99);
insert into cc.plan_quotas (project_id, plan_key, tours_per_period, max_calls_per_tour, tour_ttl, active)
  values (pg_temp.pid('qtest'), 'qtest-plan', 2, 2, interval '10 minutes', true);
insert into cc.entitlements (account_id, project_id, plan_key, status, source,
                             period_mode, period_start, period_end)
select a.id, pg_temp.pid('qtest'), 'qtest-plan', 'active', 'manual', 'explicit',
       now() - interval '1 day', now() + interval '1 day'
  from cc.accounts a where a.personal_owner = '00000000-0000-4000-8000-000000000005';

do $$
declare
  u5 uuid := '00000000-0000-4000-8000-000000000005';
  a5 uuid := (select id from cc.accounts where personal_owner = '00000000-0000-4000-8000-000000000005');
  p  smallint := pg_temp.pid('qtest');
  r jsonb;
  t_old uuid;
begin
  -- Vor dem Zeitraum: zählt nicht.
  insert into cc.tours (account_id, user_id, project_id, plan_key, period_start, state,
                        idempotency_key, calls_used, call_budget, first_success_at,
                        expires_at, created_at)
  values (a5, u5, p, 'qtest-plan', now() - interval '40 days', 'consumed', gen_random_uuid(),
          1, 2, now() - interval '3 days', now() - interval '3 days' + interval '10 minutes',
          now() - interval '3 days');
  -- Reserviert, abgelaufen und über den Nachlauf hinaus: zählt nicht.
  insert into cc.tours (account_id, user_id, project_id, plan_key, period_start, state,
                        idempotency_key, call_budget, expires_at, created_at)
  values (a5, u5, p, 'qtest-plan', now() - interval '1 day', 'reserved', gen_random_uuid(),
          2, now() - cc.tour_settle_grace() - interval '1 second', now() - interval '30 minutes')
  returning id into t_old;

  r := cc.reserve_tour(u5, 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'reserved' and (r->>'tours_used')::int = 1,
                    '(10) abgelaufene Reservierung ohne Erfolg zählt nicht; Vorperiode zählt nicht');

  perform pg_temp.t(cc.use_tour_call(t_old, u5)->>'status' = 'expired',
                    'abgelaufene Tour nimmt keine Aufrufe mehr');

  -- Reserviert, abgelaufen, aber noch im Nachlauf: zählt weiter.
  insert into cc.tours (account_id, user_id, project_id, plan_key, period_start, state,
                        idempotency_key, call_budget, expires_at, created_at)
  values (a5, u5, p, 'qtest-plan', now() - interval '1 day', 'reserved', gen_random_uuid(),
          2, now() - interval '1 minute', now() - interval '11 minutes');
  r := cc.reserve_tour(u5, 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'quota_exhausted' and (r->>'tours_used')::int = 2,
                    'abgelaufene Reservierung zählt während des Nachlaufs weiter');
  perform pg_temp.t(cc.tour_counts('reserved', now() - interval '1 minute', now())
                    and not cc.tour_counts('reserved', now() - interval '6 minutes', now())
                    and cc.tour_counts('consumed', now() - interval '1 year', now())
                    and not cc.tour_counts('released', now() + interval '1 hour', now()),
                    'Zählregel: reserved bis Ablauf + Nachlauf, consumed immer, released nie');
end $$;

do $$
declare
  u5 uuid := '00000000-0000-4000-8000-000000000005';
  a5 uuid := (select id from cc.accounts where personal_owner = '00000000-0000-4000-8000-000000000005');
  p  smallint := pg_temp.pid('qtest');
  t uuid;
  r jsonb;
begin
  -- Ein Aufruf begann vor dem Ablauf und meldet seinen Erfolg danach: die
  -- Kosten sind entstanden, die Tour wird verbraucht.
  insert into cc.tours (account_id, user_id, project_id, plan_key, period_start, state,
                        idempotency_key, calls_used, calls_in_flight, call_budget,
                        expires_at, created_at)
  values (a5, u5, p, 'qtest-plan', now() - interval '1 day', 'reserved', gen_random_uuid(),
          1, 1, 2, now() - interval '10 seconds', now() - interval '10 minutes')
  returning id into t;
  r := cc.finish_tour_call(t, u5, true);
  perform pg_temp.t(r->>'state' = 'consumed', 'später Erfolg eines rechtzeitig begonnenen Aufrufs zählt');

  -- (4) Zeitraum vorbei bzw. noch nicht begonnen
  update cc.entitlements set period_start = now() - interval '2 days', period_end = now() - interval '1 day'
   where account_id = a5 and project_id = p;
  r := cc.reserve_tour(u5, 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'entitlement_inactive' and r->>'reason' = 'outside_period',
                    '(4) abgelaufener Abo-Zeitraum: fail closed');
  update cc.entitlements set period_start = now() + interval '1 day', period_end = now() + interval '2 days'
   where account_id = a5 and project_id = p;
  r := cc.reserve_tour(u5, 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'entitlement_inactive', '(4) Zeitraum noch nicht begonnen: fail closed');
  -- Das Zeitraumende gehört nicht mehr dazu.
  update cc.entitlements set period_start = now() - interval '1 day', period_end = now()
   where account_id = a5 and project_id = p;
  r := cc.reserve_tour(u5, 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'entitlement_inactive', '(4) Zeitraumende ist exklusiv');

  update cc.entitlements
     set status = 'canceled', period_start = now() - interval '1 day', period_end = now() + interval '1 day'
   where account_id = a5 and project_id = p;
  r := cc.reserve_tour(u5, 'qtest', gen_random_uuid());
  perform pg_temp.t(r->>'status' = 'entitlement_inactive' and r->>'reason' = 'canceled',
                    '(4) gekündigtes Entitlement: fail closed');
  update cc.entitlements set status = 'past_due' where account_id = a5 and project_id = p;
  perform pg_temp.t(cc.reserve_tour(u5, 'qtest', gen_random_uuid())->>'status' = 'entitlement_inactive',
                    '(4) past_due: fail closed');
  update cc.entitlements set status = 'active' where account_id = a5 and project_id = p;

  -- (3) Plan deaktiviert
  update cc.plan_quotas set active = false where project_id = p and plan_key = 'qtest-plan';
  perform pg_temp.t(cc.reserve_tour(u5, 'qtest', gen_random_uuid())->>'status' = 'quota_not_configured',
                    '(3) deaktivierter Plan: fail closed');
  -- (21) 0 Touren sperrt vollständig
  update cc.plan_quotas set active = true, tours_per_period = 0 where project_id = p and plan_key = 'qtest-plan';
  perform pg_temp.t(cc.reserve_tour(u5, 'qtest', gen_random_uuid())->>'status' = 'quota_exhausted',
                    '(21) Kontingent 0 sperrt vollständig');
end $$;

-- ============================================ Projekt, Nutzer, Konto gesperrt
do $$
declare
  u1 uuid := '00000000-0000-4000-8000-000000000001';
  u4 uuid := '00000000-0000-4000-8000-000000000004';
  a4 uuid := (select id from cc.accounts where personal_owner = '00000000-0000-4000-8000-000000000004');
  r jsonb;
begin
  perform pg_temp.t(cc.reserve_tour(u1, 'gibt-es-nicht', gen_random_uuid())->>'status' = 'unknown_project',
                    'unbekanntes Projekt');
  perform pg_temp.t(cc.reserve_tour(u1, 'qtest', null)->>'status' = 'invalid_argument',
                    'fehlender Idempotenzschlüssel');
  perform pg_temp.t(cc.reserve_tour(null, 'qtest', gen_random_uuid())->>'status' = 'invalid_argument',
                    'fehlender Nutzer');
  perform pg_temp.t(cc.reserve_tour(u1, 'qtest3', gen_random_uuid())->>'status' = 'project_paused',
                    'Projekt ohne Einstellungen: fail closed');

  update cc.project_settings set mode = 'off' where project_id = pg_temp.pid('qtest');
  perform pg_temp.t(cc.reserve_tour(u1, 'qtest', gen_random_uuid())->>'status' = 'project_paused',
                    'Projekt im Modus off: keine Tour');
  update cc.project_settings set mode = 'cache_only' where project_id = pg_temp.pid('qtest');
  perform pg_temp.t(cc.reserve_tour(u1, 'qtest', gen_random_uuid())->>'status' = 'project_paused',
                    'Projekt im Modus cache_only: keine Tour');
  update cc.project_settings set mode = 'warning' where project_id = pg_temp.pid('qtest');
  -- u1 hat hier genau eine zählende Tour (t1 verbraucht, t2/t3 freigegeben).
  perform pg_temp.t(cc.reserve_tour(u1, 'qtest', gen_random_uuid())->>'status' = 'reserved',
                    'Modus warning sperrt nicht');
  update cc.project_settings set mode = 'normal' where project_id = pg_temp.pid('qtest');

  perform cc.ensure_default_entitlement(a4, 'qtest');
  update cc.users set disabled_at = now() where id = u4;
  perform pg_temp.t(cc.reserve_tour(u4, 'qtest', gen_random_uuid())->>'status' = 'user_disabled',
                    'gesperrter Nutzer bekommt keine Tour');
  update cc.users set disabled_at = null where id = u4;
  update cc.accounts set disabled_at = now() where id = a4;
  perform pg_temp.t(cc.reserve_tour(u4, 'qtest', gen_random_uuid())->>'status' = 'account_disabled',
                    'gesperrtes Konto bekommt keine Tour');

  perform pg_temp.t(cc.reserve_tour('00000000-0000-4000-8000-000000000006', 'qtest', gen_random_uuid())->>'status'
                    = 'not_member', 'Auth-Nutzer ohne Konto bekommt keine Tour');
end $$;

-- ================================================ Fleet: gemeinsames Kontingent
insert into cc.plan_quotas (project_id, plan_key, tours_per_period, max_calls_per_tour, tour_ttl, active)
  values (pg_temp.pid('qtest'), 'fleet', 2, 5, interval '10 minutes', true);

do $$
declare
  u2 uuid := '00000000-0000-4000-8000-000000000002';
  u3 uuid := '00000000-0000-4000-8000-000000000003';
  u1 uuid := '00000000-0000-4000-8000-000000000001';
  org uuid;
  r jsonb; r3 jsonb;
begin
  insert into cc.accounts (kind, name) values ('organization', 'Spedition Test') returning id into org;
  insert into cc.account_members (account_id, user_id, role) values (org, u3, 'owner'), (org, u2, 'member');
  insert into cc.entitlements (account_id, project_id, plan_key, status, source, period_mode)
    values (org, pg_temp.pid('qtest'), 'fleet', 'active', 'manual', 'calendar_month');

  r3 := cc.reserve_tour(u3, 'qtest', gen_random_uuid(), org);
  perform pg_temp.t(r3->>'status' = 'reserved' and r3->>'account_id' = org::text,
                    'Fleet: Mitglied reserviert auf dem Firmenkonto');
  r := cc.reserve_tour(u2, 'qtest', gen_random_uuid(), org);
  perform pg_temp.t(r->>'status' = 'reserved' and (r->>'tours_used')::int = 2,
                    'Fleet: zweites Mitglied teilt dasselbe Kontingent');
  r := cc.reserve_tour(u3, 'qtest', gen_random_uuid(), org);
  perform pg_temp.t(r->>'status' = 'quota_exhausted', 'Fleet: gemeinsames Kontingent ist erschöpft');
  perform pg_temp.t(cc.reserve_tour(u1, 'qtest', gen_random_uuid(), org)->>'status' = 'not_member',
                    'Nicht-Mitglied kann nicht auf fremdes Konto reservieren');
  perform pg_temp.t(cc.use_tour_call((r3->>'tour_id')::uuid, u2)->>'status' = 'not_found',
                    'Tour gehört dem Mitglied, das sie gestartet hat');

  -- Mitgliedschaft endet mitten in der Tour.
  delete from cc.account_members where account_id = org and user_id = u2;
  r := cc.use_tour_call((select id from cc.tours where account_id = org and user_id = u2), u2);
  perform pg_temp.t(r->>'status' = 'not_member', 'nach Ende der Mitgliedschaft keine Aufrufe mehr');

  -- Auth-Nutzer wird gelöscht: persönliches Konto samt Ledger geht, auf dem
  -- Firmenkonto bleibt seine Tour ohne Nutzerbezug erhalten.
  delete from auth.users where id = u2;
  perform pg_temp.t(not exists (select 1 from cc.accounts where personal_owner = u2),
                    'Löschen des Nutzers entfernt sein persönliches Konto');
  perform pg_temp.t((select count(*) from cc.tours where account_id = org and user_id is null) = 1,
                    'Firmenkonto behält die Tour des gelöschten Nutzers');
  r := cc.reserve_tour(u3, 'qtest', gen_random_uuid(), org);
  perform pg_temp.t(r->>'status' = 'quota_exhausted',
                    'Tour eines gelöschten Nutzers zählt weiter fürs Firmenkonto');
end $$;

-- ================================================= (22) ungültige Zustandswechsel
do $$
declare
  t_consumed uuid := (select id from cc.tours where idempotency_key = '10000000-0000-4000-8000-000000000001');
  t_released uuid := (select id from cc.tours where idempotency_key = '10000000-0000-4000-8000-000000000002');
begin
  perform pg_temp.fails(format($q$ update cc.tours set state = 'reserved', first_success_at = null where id = %L $q$, t_consumed),
                        'P0001', '(22) consumed → reserved wird verhindert');
  perform pg_temp.fails(format($q$ update cc.tours set state = 'reserved', released_at = null where id = %L $q$, t_released),
                        'P0001', '(22) released → reserved wird verhindert');
  perform pg_temp.fails(format($q$ update cc.tours set state = 'consumed', first_success_at = now(), released_at = null where id = %L $q$, t_released),
                        'P0001', '(22) released → consumed wird verhindert');
  perform pg_temp.fails(format($q$ update cc.tours set calls_used = 1 where id = %L $q$, t_consumed),
                        'P0001', '(22) calls_used kann nicht sinken');
  perform pg_temp.fails(format($q$ update cc.tours set account_id = gen_random_uuid() where id = %L $q$, t_consumed),
                        'P0001', '(22) Konto einer Tour ist unveränderlich');
  perform pg_temp.fails(format($q$ update cc.tours set idempotency_key = gen_random_uuid() where id = %L $q$, t_consumed),
                        'P0001', '(22) Idempotenzschlüssel ist unveränderlich');
  perform pg_temp.fails(format($q$ update cc.tours set expires_at = expires_at + interval '1 day' where id = %L $q$, t_consumed),
                        'P0001', '(22) Laufzeit kann nicht verlängert werden');
  perform pg_temp.fails(format($q$ update cc.tours set call_budget = 100 where id = %L $q$, t_consumed),
                        'P0001', '(22) Aufrufbudget kann nicht erhöht werden');
  perform pg_temp.fails(format($q$ update cc.tours set first_success_at = now() - interval '1 hour' where id = %L $q$, t_consumed),
                        'P0001', '(22) Erfolgszeitpunkt ist endgültig');
  perform pg_temp.fails(format($q$ update cc.tours set user_id = '00000000-0000-4000-8000-000000000003' where id = %L $q$, t_consumed),
                        'P0001', '(22) Tour kann keinem anderen Nutzer übertragen werden');
  perform pg_temp.fails(format($q$ update cc.tours set state = 'consumed' where id = %L $q$,
                               (select id from cc.tours where state = 'reserved' limit 1)),
                        '23514', '(22) consumed ohne Erfolgszeitpunkt ist nicht speicherbar');
end $$;

-- ================================================= (23) Schlüssel und Verweise
do $$
declare
  u1 uuid := '00000000-0000-4000-8000-000000000001';
  a1 uuid := (select id from cc.accounts where personal_owner = '00000000-0000-4000-8000-000000000001');
begin
  perform pg_temp.fails(format($q$ insert into cc.tours (account_id, user_id, project_id, plan_key, period_start,
                                     idempotency_key, call_budget, expires_at)
                                   values (gen_random_uuid(), %L, pg_temp.pid('qtest'), 'free', now(),
                                     gen_random_uuid(), 1, now() + interval '1 minute') $q$, u1),
                        '23503', '(23) Tour braucht ein existierendes Konto');
  perform pg_temp.fails(format($q$ insert into cc.tours (account_id, user_id, project_id, plan_key, period_start,
                                     idempotency_key, call_budget, expires_at)
                                   values (%L, %L, pg_temp.pid('qtest'), 'free', now(),
                                     '10000000-0000-4000-8000-000000000001', 1, now() + interval '1 minute') $q$, a1, u1),
                        '23505', '(23) (Nutzer, Idempotenzschlüssel) ist eindeutig');
  perform pg_temp.fails(format($q$ insert into cc.tours (account_id, user_id, project_id, plan_key, period_start,
                                     idempotency_key, call_budget, expires_at, calls_used)
                                   values (%L, %L, pg_temp.pid('qtest'), 'free', now(),
                                     gen_random_uuid(), 1, now() + interval '1 minute', 2) $q$, a1, u1),
                        '23514', '(23) calls_used über dem Budget ist nicht speicherbar');
  perform pg_temp.fails(format($q$ insert into cc.accounts (kind, personal_owner) values ('personal', %L) $q$, u1),
                        '23505', '(23) höchstens ein persönliches Konto je Nutzer');
  perform pg_temp.fails($q$ insert into cc.accounts (kind) values ('personal') $q$,
                        '23514', '(23) persönliches Konto braucht einen Besitzer');
  perform pg_temp.fails(format($q$ insert into cc.accounts (kind, personal_owner) values ('organization', %L) $q$, u1),
                        '23514', '(23) Firmenkonto hat keinen persönlichen Besitzer');
  perform pg_temp.fails(format($q$ insert into cc.account_members (account_id, user_id, role) values (%L, %L, 'member') $q$, a1, u1),
                        '23505', '(23) Mitgliedschaft ist eindeutig');
  perform pg_temp.fails(format($q$ insert into cc.account_members (account_id, user_id, role) values (%L, %L, 'chef') $q$,
                               (select id from cc.accounts where kind = 'organization' limit 1), u1),
                        '23514', '(23) unbekannte Rolle wird abgewiesen');
  perform pg_temp.fails(format($q$ insert into cc.entitlements (account_id, project_id, plan_key, status, source, period_mode)
                                   values (%L, pg_temp.pid('qtest2'), 'free', 'active', 'manual', 'explicit') $q$, a1),
                        '23514', '(23) expliziter Zeitraum braucht Start und Ende');
  perform pg_temp.fails(format($q$ insert into cc.entitlements (account_id, project_id, plan_key, status, source, period_mode, period_start)
                                   values (%L, pg_temp.pid('qtest2'), 'free', 'active', 'default_free', 'calendar_month', now()) $q$, a1),
                        '23514', '(23) Kalendermonat hat keinen eigenen Zeitraum');
  perform pg_temp.fails(format($q$ insert into cc.entitlements (account_id, project_id, plan_key, status, source, period_mode)
                                   values (%L, pg_temp.pid('qtest2'), 'gold', 'active', 'manual', 'calendar_month') $q$, a1),
                        '23503', '(23) Entitlement nur mit bekanntem Plan');
  perform pg_temp.fails(format($q$ insert into cc.entitlements (account_id, project_id, plan_key, status, source, period_mode)
                                   values (%L, pg_temp.pid('qtest2'), 'free', 'active', 'appstore', 'calendar_month') $q$, a1),
                        '23514', '(23) unbekannte Quelle wird abgewiesen');
  perform pg_temp.fails($q$ insert into cc.plan_quotas (project_id, plan_key) values (pg_temp.pid('qtest'), 'gold') $q$,
                        '23503', '(23) Kontingent nur für bekannten Plan');
  perform pg_temp.fails($q$ insert into cc.plan_quotas (project_id, plan_key, tour_ttl) values (pg_temp.pid('qtest2'), 'free', interval '2 days') $q$,
                        '23514', '(23) Tour-Laufzeit ist nach oben begrenzt');

  insert into cc.entitlements (account_id, project_id, plan_key, status, source, period_mode,
                               period_start, period_end, external_ref)
    values (a1, pg_temp.pid('qtest2'), 'pro', 'active', 'stripe', 'explicit', now(), now() + interval '30 days', 'sub_test_1');
  perform pg_temp.fails(format($q$ insert into cc.entitlements (account_id, project_id, plan_key, status, source, period_mode,
                                     period_start, period_end, external_ref)
                                   values (%L, pg_temp.pid('qtest2'), 'pro', 'active', 'stripe', 'explicit', now(), now() + interval '1 day', 'sub_test_1') $q$,
                               (select id from cc.accounts where personal_owner = '00000000-0000-4000-8000-000000000003')),
                        '23505', '(23) externe Abo-Referenz ist eindeutig');

  perform pg_temp.t(
    (cc.ensure_default_entitlement(a1, 'qtest2'))->>'plan_key' = 'pro'
    and (select plan_key from cc.entitlements where account_id = a1 and project_id = pg_temp.pid('qtest2')) = 'pro',
    'Standard-Entitlement überschreibt nie einen bestehenden Pro-Plan');
end $$;

-- ================================================== Zähler: Prüfen und Zählen
do $$
declare
  p smallint := pg_temp.pid('qtest');
  s integer := (select id from cc.services where key = 'directions');
  r jsonb;
begin
  r := cc.counter_try_increment(p, s, 'global', '', '2026-09-26', 1, 2);
  perform pg_temp.t((r->>'allowed')::boolean and (r->>'quantity')::numeric = 1, 'Zähler: erster Aufruf erlaubt');
  r := cc.counter_try_increment(p, s, 'global', '', '2026-09-26', 1, 2, 0.005);
  perform pg_temp.t((r->>'allowed')::boolean and (r->>'quantity')::numeric = 2, 'Zähler: zweiter Aufruf erlaubt');
  r := cc.counter_try_increment(p, s, 'global', '', '2026-09-26', 1, 2);
  perform pg_temp.t(not (r->>'allowed')::boolean and r->>'reason' = 'limit_reached'
                    and (r->>'quantity')::numeric = 2, 'Zähler: Grenze erreicht, nicht weiter gezählt');
  perform pg_temp.t((select cost_estimate from cc.counters where project_id = p and service_id = s
                       and scope = 'global' and period = '2026-09-26') = 0.005,
                    'Zähler: Kostenschätzung summiert sich mit');

  r := cc.counter_try_increment(p, s, 'user', 'u-x', '2026-09', 1, null);
  perform pg_temp.t(not (r->>'allowed')::boolean and r->>'reason' = 'limit_not_configured',
                    '(21) Zähler ohne Grenze: abgelehnt, nie unbegrenzt');
  perform pg_temp.t(not exists (select 1 from cc.counters where scope_key = 'u-x'),
                    '(21) abgelehnter Zähler legt keine Zeile an');
  r := cc.counter_try_increment(p, s, 'user', 'u-y', '2026-09', 5, 3);
  perform pg_temp.t(not (r->>'allowed')::boolean and (r->>'quantity')::numeric = 0
                    and not exists (select 1 from cc.counters where scope_key = 'u-y'),
                    'Zähler: Menge über der Grenze wird schon beim ersten Mal abgelehnt');
  r := cc.counter_try_increment(p, s, 'user', 'u-z', '2026-09', 1, 0);
  perform pg_temp.t(not (r->>'allowed')::boolean, 'Zähler: Grenze 0 sperrt');
  r := cc.counter_try_increment(p, s, 'account', 'acc-1', '2026-09', 1, 10);
  perform pg_temp.t((r->>'allowed')::boolean, 'Zähler: Konto-Ebene wird unterstützt');

  perform pg_temp.t(cc.counter_try_increment(p, s, 'global', 'x', '2026-09', 1, 5)->>'reason' = 'invalid_argument',
                    'Zähler: global ohne Schlüssel');
  perform pg_temp.t(cc.counter_try_increment(p, s, 'user', '', '2026-09', 1, 5)->>'reason' = 'invalid_argument',
                    'Zähler: Nutzer-Ebene braucht einen Schlüssel');
  perform pg_temp.t(cc.counter_try_increment(p, s, 'planet', 'x', '2026-09', 1, 5)->>'reason' = 'invalid_argument',
                    'Zähler: unbekannte Ebene');
  perform pg_temp.t(cc.counter_try_increment(p, s, 'user', 'x', 'September', 1, 5)->>'reason' = 'invalid_argument',
                    'Zähler: Zeitraum im falschen Format');
  perform pg_temp.t(cc.counter_try_increment(p, s, 'user', 'x', '2026-09', 0, 5)->>'reason' = 'invalid_argument',
                    'Zähler: Menge 0 ist ungültig');
  perform pg_temp.t(cc.counter_try_increment(p, s, 'user', 'x', '2026-09', 1, 5, -1)->>'reason' = 'invalid_argument',
                    'Zähler: negative Kosten sind ungültig');
end $$;

-- ================================================================ Rechte
do $$
declare
  f text;
begin
  foreach f in array array[
    'cc.ensure_personal_account(uuid)', 'cc.ensure_default_entitlement(uuid,text)',
    'cc.reserve_tour(uuid,text,uuid,uuid)', 'cc.use_tour_call(uuid,uuid)',
    'cc.finish_tour_call(uuid,uuid,boolean)', 'cc.release_tour(uuid,uuid)',
    'cc.complete_tour(uuid,uuid)',
    'cc.counter_try_increment(smallint,integer,text,text,text,numeric,numeric,numeric)']
  loop
    perform pg_temp.t(
      (select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = f::regprocedure),
      'SECURITY DEFINER mit leerem search_path: ' || f);
    perform pg_temp.t(not has_function_privilege('public', f, 'execute'),
                      'PUBLIC darf nicht ausführen: ' || f);
  end loop;

  perform pg_temp.t((select bool_and(relrowsecurity) from pg_class
                      where oid in ('cc.accounts'::regclass, 'cc.account_members'::regclass,
                                    'cc.plan_quotas'::regclass, 'cc.entitlements'::regclass,
                                    'cc.tours'::regclass)),
                    'RLS ist auf allen neuen Tabellen an');
  perform pg_temp.t(not has_table_privilege('public', 'cc.tours', 'select')
                    and not has_table_privilege('public', 'cc.entitlements', 'update'),
                    'PUBLIC hat keine Tabellenrechte');
end $$;

-- Künftige Proxy-Rolle: nur EXECUTE. Rolle entsteht nur in dieser
-- Transaktion und wird mit ihr zurückgenommen.
create role cc_quota_test_proxy nologin;
grant usage on schema cc to cc_quota_test_proxy;
grant execute on function cc.reserve_tour(uuid, text, uuid, uuid),
                          cc.use_tour_call(uuid, uuid),
                          cc.finish_tour_call(uuid, uuid, boolean),
                          cc.release_tour(uuid, uuid)
  to cc_quota_test_proxy;
create role cc_quota_test_nobody nologin;
grant usage on schema cc to cc_quota_test_nobody;

set local role cc_quota_test_proxy;
do $$
declare r jsonb;
begin
  r := cc.reserve_tour('00000000-0000-4000-8000-000000000003', 'qtest', gen_random_uuid());
  perform pg_temp.t(r ? 'status', 'Proxy-Rolle kann reserve_tour ausführen');
end $$;
select pg_temp.fails($q$ select count(*) from cc.tours $q$, '42501', 'Proxy-Rolle kann Touren nicht direkt lesen');
select pg_temp.fails($q$ update cc.tours set calls_used = 0 $q$, '42501', 'Proxy-Rolle kann Touren nicht direkt ändern');
select pg_temp.fails($q$ update cc.entitlements set plan_key = 'fleet' $q$, '42501', 'Proxy-Rolle kann keinen Plan setzen');
select pg_temp.fails($q$ insert into cc.plan_quotas (project_id, plan_key) values (1, 'free') $q$, '42501',
                     'Proxy-Rolle kann keine Kontingente anlegen');
select pg_temp.fails($q$ select cc.ensure_default_entitlement(gen_random_uuid(), 'qtest') $q$, '42501',
                     'Proxy-Rolle hat nur die ausdrücklich erteilten Funktionen');
reset role;

set local role cc_quota_test_nobody;
select pg_temp.fails($q$ select cc.reserve_tour(gen_random_uuid(), 'qtest', gen_random_uuid()) $q$, '42501',
                     'Rolle ohne Freigabe kann reserve_tour nicht ausführen');
select pg_temp.fails($q$ select cc.counter_try_increment(1::smallint, 1, 'global', '', '2026-09', 1, 1) $q$, '42501',
                     'Rolle ohne Freigabe kann Zähler nicht erhöhen');
reset role;

rollback;
