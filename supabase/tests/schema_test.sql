-- Schema-Prüfungen für das Control Center.
-- Ausführen:  psql -v ON_ERROR_STOP=1 -f supabase/tests/schema_test.sql
\set ON_ERROR_STOP on
\timing off
set client_min_messages = notice;

begin;

-- Innerhalb der Transaktion, damit der Testlauf auch diese
-- Hilfsfunktion restlos zurücknimmt und in der Zieldatenbank nichts bleibt.
create or replace function cc_assert(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok then raise notice 'OK   %', label;
  else raise exception 'FEHLGESCHLAGEN: %', label;
  end if;
end $$;

-- ===================================================== 1) Beide Einheiten
-- Google Directions (request) und ein Token-Anbieter im selben Modell.
insert into cc.providers (key, name, billing_source)
  values ('anthropic', 'Anthropic', 'manual') on conflict (key) do nothing;

insert into cc.services (provider_id, key, name, unit)
select p.id, v.key, v.name, v.unit from cc.providers p,
  (values ('claude-sonnet-in',  'Claude Sonnet Eingabe', 'token'),
          ('claude-sonnet-out', 'Claude Sonnet Ausgabe', 'token')) as v(key,name,unit)
 where p.key='anthropic' on conflict do nothing;

insert into cc.projects (key, name) values ('catlab-demo','Demo') on conflict (key) do nothing;

-- ================================================ 2) Preisversionierung
-- Zwei aufeinanderfolgende Perioden für dieselbe Leistung.
insert into cc.price_list (service_id, unit_price, currency, valid_from, valid_to, source)
select id, 0.005000000, 'USD', date '2026-01-01', date '2026-07-01', 'test-p1'
  from cc.services where key='directions';
insert into cc.price_list (service_id, unit_price, currency, valid_from, valid_to, source)
select id, 0.008000000, 'USD', date '2026-07-01', null, 'test-p2'
  from cc.services where key='directions';

select cc_assert(
  (select unit_price from cc.price_at((select id from cc.services where key='directions'),
                                       '2026-03-15T00:00:00Z')) = 0.005,
  'Preis vor der Umstellung wird gefunden');
select cc_assert(
  (select unit_price from cc.price_at((select id from cc.services where key='directions'),
                                       '2026-09-15T00:00:00Z')) = 0.008,
  'Preis nach der Umstellung wird gefunden');
select cc_assert(
  (select valid_from from cc.price_at((select id from cc.services where key='directions'),
                                       '2026-07-01T00:00:00Z')) = date '2026-07-01',
  'Grenztag gehört zur neuen Periode');

-- Überlappung muss abgewiesen werden
do $$
declare blocked boolean := false;
begin
  begin
    insert into cc.price_list (service_id, unit_price, currency, valid_from, valid_to)
    select id, 0.009, 'USD', date '2026-05-01', date '2026-08-01'
      from cc.services where key='directions';
  exception when exclusion_violation then blocked := true;
  end;
  perform cc_assert(blocked, 'überlappende Preisperiode wird abgewiesen');
end $$;

-- ====================================== 3) Kette Session → Work → Events
insert into cc.sessions (id, project_id, ip_hash)
select '11111111-1111-1111-1111-111111111111', id, 'sha256-beispiel'
  from cc.projects where key='drivetime';

insert into cc.work_units (id, project_id, session_id, kind)
select '22222222-2222-2222-2222-222222222222', p.id,
       '11111111-1111-1111-1111-111111111111', 'route'
  from cc.projects p where p.key='drivetime';

-- Zwei Directions-Requests für EINE Routenberechnung, Preis zum Zeitpunkt.
insert into cc.usage_events
  (ts, project_id, service_id, work_unit_id, session_id, quantity, unit,
   cache_hit, ok, cost_estimate, unit_price_applied, currency, price_valid_from)
select '2026-09-15T10:00:00Z'::timestamptz, p.id, s.id,
       '22222222-2222-2222-2222-222222222222',
       '11111111-1111-1111-1111-111111111111',
       1, 'request', false, true,
       1 * pr.unit_price, pr.unit_price, pr.currency, pr.valid_from
  from cc.projects p, cc.services s,
       lateral cc.price_at(s.id, '2026-09-15T10:00:00Z'::timestamptz) pr
 where p.key='drivetime' and s.key='directions';

insert into cc.usage_events
  (ts, project_id, service_id, work_unit_id, session_id, quantity, unit,
   cache_hit, ok, cost_estimate, unit_price_applied, currency, price_valid_from)
select '2026-09-15T10:00:01Z'::timestamptz, p.id, s.id,
       '22222222-2222-2222-2222-222222222222',
       '11111111-1111-1111-1111-111111111111',
       1, 'request', true, true,
       0, pr.unit_price, pr.currency, pr.valid_from
  from cc.projects p, cc.services s,
       lateral cc.price_at(s.id, '2026-09-15T10:00:01Z'::timestamptz) pr
 where p.key='drivetime' and s.key='directions';

select cc_assert(
  (select count(*) from cc.usage_events
    where work_unit_id='22222222-2222-2222-2222-222222222222') = 2,
  'Requests pro Berechnung auswertbar (2 Requests, 1 Berechnung)');

-- Token-Anbieter, gleiche Tabelle, andere Einheit
insert into cc.price_list (service_id, unit_price, currency, valid_from, source)
select id, 0.000003000, 'USD', date '2026-01-01', 'test' from cc.services where key='claude-sonnet-in';

insert into cc.usage_events
  (ts, project_id, service_id, quantity, unit, cost_estimate,
   unit_price_applied, currency, price_valid_from)
select '2026-09-15T11:00:00Z'::timestamptz, p.id, s.id, 18500, 'token',
       18500 * pr.unit_price, pr.unit_price, pr.currency, pr.valid_from
  from cc.projects p, cc.services s,
       lateral cc.price_at(s.id, '2026-09-15T11:00:00Z'::timestamptz) pr
 where p.key='catlab-demo' and s.key='claude-sonnet-in';

select cc_assert(
  (select round(cost_estimate,6) from cc.usage_events where unit='token') = 0.055500,
  'Token-Verbrauch wird im selben Modell korrekt bewertet');
select cc_assert(
  (select count(distinct unit) from cc.usage_events) = 2,
  'request und token stehen nebeneinander in derselben Tabelle');

-- ============================== 4) Preisänderung wirkt NICHT rückwirkend
do $$
declare before_val numeric; after_val numeric;
begin
  select cost_estimate into before_val from cc.usage_events
   where unit='request' and cache_hit=false;
  -- Preis nachträglich ändern
  update cc.price_list set unit_price = 0.050
   where service_id=(select id from cc.services where key='directions')
     and valid_from = date '2026-07-01';
  select cost_estimate into after_val from cc.usage_events
   where unit='request' and cache_hit=false;
  perform cc_assert(before_val = after_val,
    'gebuchte Schätzung bleibt nach Preisänderung unverändert');
  perform cc_assert(before_val = 0.008,
    'gebuchter Wert entspricht dem damals gültigen Preis');
end $$;

-- ================================================ 5) Append-only greift
do $$
declare blocked boolean := false;
begin
  begin update cc.usage_events set cost_estimate = 99 where unit='token';
  exception when others then blocked := true; end;
  perform cc_assert(blocked, 'UPDATE auf usage_events wird abgewiesen');
end $$;
do $$
declare blocked boolean := false;
begin
  begin delete from cc.usage_events where unit='token';
  exception when others then blocked := true; end;
  perform cc_assert(blocked, 'DELETE auf usage_events wird abgewiesen');
end $$;

-- ======================================= 6) Optionale Verknüpfungen
insert into cc.usage_events (ts, project_id, service_id, quantity, unit)
select '2026-09-15T12:00:00Z'::timestamptz, p.id, s.id, 1, 'request'
  from cc.projects p, cc.services s
 where p.key='drivetime' and s.key='geocode';
select cc_assert(
  (select count(*) from cc.usage_events u join cc.services s on s.id=u.service_id
    where s.key='geocode' and u.work_unit_id is null and u.session_id is null) = 1,
  'Ereignis ohne Berechnung und ohne Sitzung ist erlaubt');

-- Sitzung löschen: Arbeitseinheit bleibt, Verknüpfung wird null
delete from cc.sessions where id='11111111-1111-1111-1111-111111111111';
select cc_assert(
  (select session_id is null from cc.work_units
    where id='22222222-2222-2222-2222-222222222222'),
  'Arbeitseinheit überlebt das Löschen der Sitzung');
select cc_assert(
  (select count(*) from cc.usage_events
    where session_id='11111111-1111-1111-1111-111111111111') = 2,
  'Verbrauchsdaten überleben das Löschen der Sitzung');

-- =========================================== 7) Nutzer später anhängbar
-- cc.users.id ist die ID aus Supabase Auth; ein Plan steht nicht mehr am
-- Nutzer, sondern in cc.entitlements am Konto (Migration 0006/0007).
insert into auth.users (id) values ('33333333-3333-3333-3333-333333333333');
insert into cc.users (id) values ('33333333-3333-3333-3333-333333333333');
insert into cc.sessions (id, project_id, user_id)
select '44444444-4444-4444-4444-444444444444', id,
       '33333333-3333-3333-3333-333333333333'
  from cc.projects where key='drivetime';
select cc_assert(
  (select count(*) from information_schema.columns
    where table_schema='cc' and table_name='users' and column_name='plan') = 0,
  'Nutzer trägt keinen eigenen Plan mehr');

do $$
declare blocked boolean := false;
begin
  begin
    insert into cc.users (id) values ('55555555-5555-5555-5555-555555555555');
  exception when foreign_key_violation then blocked := true;
  end;
  perform cc_assert(blocked, 'cc.users nur für existierende Auth-Nutzer');
end $$;

-- Auth-Nutzer löschen: cc.users geht mit, die Sitzung bleibt anonym bestehen.
delete from auth.users where id='33333333-3333-3333-3333-333333333333';
select cc_assert(
  not exists (select 1 from cc.users where id='33333333-3333-3333-3333-333333333333'),
  'Löschen in auth.users entfernt den cc-Nutzer');
select cc_assert(
  (select user_id is null from cc.sessions where id='44444444-4444-4444-4444-444444444444'),
  'Sitzung überlebt das Löschen des Nutzers anonym');

-- ================================================= 8) Zähler-Hochzählen
insert into cc.counters (project_id, service_id, scope, scope_key, period, quantity, cost_estimate)
select p.id, s.id, 'global', '', '2026-09-15', 1, 0.008
  from cc.projects p, cc.services s where p.key='drivetime' and s.key='directions'
on conflict (project_id, service_id, scope, scope_key, period) do update
  set quantity = cc.counters.quantity + excluded.quantity,
      cost_estimate = cc.counters.cost_estimate + excluded.cost_estimate;
insert into cc.counters (project_id, service_id, scope, scope_key, period, quantity, cost_estimate)
select p.id, s.id, 'global', '', '2026-09-15', 1, 0.008
  from cc.projects p, cc.services s where p.key='drivetime' and s.key='directions'
on conflict (project_id, service_id, scope, scope_key, period) do update
  set quantity = cc.counters.quantity + excluded.quantity,
      cost_estimate = cc.counters.cost_estimate + excluded.cost_estimate;
select cc_assert((select quantity from cc.counters where period='2026-09-15') = 2,
  'Zähler summiert per Upsert korrekt');

-- ========================================= 9) Trennung Schätzung/Rechnung
insert into cc.billing_imports (provider_id, period_start, period_end, source, rows_imported)
select id, date '2026-09-01', date '2026-09-30', 'manual', 1
  from cc.providers where key='google-maps';
insert into cc.billing_facts
  (import_id, provider_id, service_id, project_id, period_start, period_end,
   quantity, cost_actual, currency)
select bi.id, pv.id, s.id, p.id, date '2026-09-01', date '2026-09-30',
       2, 0.010, 'USD'
  from cc.billing_imports bi, cc.providers pv, cc.services s, cc.projects p
 where pv.key='google-maps' and s.key='directions' and p.key='drivetime'
   and bi.provider_id = pv.id;

select cc_assert(
  (select status from cc.v_reconciliation
    where period='2026-09' and service_id=(select id from cc.services where key='directions'))
   = 'drift',
  'Abgleich erkennt Abweichung zwischen Schätzung und Rechnung');
select cc_assert(
  (select actual_sum from cc.v_reconciliation
    where period='2026-09' and service_id=(select id from cc.services where key='claude-sonnet-in'))
   is null,
  'ohne Rechnungsdaten bleibt actual_sum null statt 0');

-- ========================================== 10) Datensparsamkeit im Schema
select cc_assert(
  (select count(*) from information_schema.columns
    where table_schema='cc' and table_name='usage_events'
      and column_name in ('origin','destination','address','prompt','payload','ip')) = 0,
  'usage_events enthält keine Felder für Nutzinhalte oder IP');
select cc_assert(
  (select count(*) from information_schema.columns
    where table_schema='cc' and table_name='sessions' and column_name='ip') = 0,
  'sessions speichert keine Roh-IP');

rollback;
