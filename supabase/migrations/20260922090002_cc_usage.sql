-- CatLab API Control Center — Verbrauch
--
-- Kette:  PROJECT → SESSION/USER → WORK_UNIT → USAGE_EVENTS → KOSTEN
--
-- Datensparsamkeit: hier stehen keine Nutzinhalte. Keine Adressen, keine
-- Prompts, keine Roh-IP. Was gespeichert wird, dient der Abrechnung und der
-- Missbrauchserkennung, sonst nichts.

-- ------------------------------------------------------------- Sitzungen
create table cc.sessions (
  id           uuid primary key default gen_random_uuid(),
  project_id   smallint not null references cc.projects(id),
  user_id      uuid references cc.users(id),   -- null = anonym (Phase 1)
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  ip_hash      text,        -- sha256(IP + Tagessalz), NIE die Roh-IP
  ua_hash      text,
  trust        smallint not null default 0
               check (trust between -1 and 1)  -- -1 gesperrt, 0 neu, 1 bestätigt
);

create index sessions_project_seen_idx on cc.sessions (project_id, last_seen_at desc);
create index sessions_user_idx        on cc.sessions (user_id) where user_id is not null;
create index sessions_iphash_idx      on cc.sessions (ip_hash, created_at desc) where ip_hash is not null;

comment on column cc.sessions.ip_hash is
  'sha256(IP + täglich wechselndem Salz). Erlaubt Missbrauchserkennung innerhalb eines Tages, keine Verkettung darüber hinaus.';

-- ---------------------------------------------------------- Arbeitseinheit
-- Die fachliche Einheit des jeweiligen Projekts: bei DriveTime eine
-- Routenberechnung, bei einem LLM-Projekt eine Anfrage. Genau hierüber wird
-- "Requests pro Berechnung" auswertbar.
create table cc.work_units (
  id          uuid primary key,              -- vom Client erzeugt
  project_id  smallint not null references cc.projects(id),
  session_id  uuid references cc.sessions(id) on delete set null,
  kind        text not null,                 -- 'route' | 'ferry-route' | 'completion'
  status      text not null default 'ok'
              check (status in ('ok','error','limited')),
  created_at  timestamptz not null default now(),
  finished_at timestamptz
);

create index work_units_project_created_idx on cc.work_units (project_id, created_at desc);
create index work_units_session_idx         on cc.work_units (session_id, created_at desc)
  where session_id is not null;

-- ------------------------------------------------------------- Verbrauch
-- Die größte Tabelle. Nach Monat partitioniert: hält die Indizes klein und
-- macht das Aufräumen alter Daten zu einem DROP statt zu Millionen DELETEs.
create table cc.usage_events (
  id                bigserial,
  ts                timestamptz not null default now(),
  project_id        smallint not null references cc.projects(id),
  service_id        integer  not null references cc.services(id),
  work_unit_id      uuid,      -- bewusst ohne FK, siehe Hinweis unten
  session_id        uuid,      -- dito
  quantity          numeric(20,4) not null check (quantity >= 0),
  unit              text not null references cc.units(key),
  cache_hit         boolean not null default false,
  ok                boolean not null default true,
  -- Kostenschätzung: zum Zeitpunkt der Buchung berechnet und festgeschrieben.
  cost_estimate     numeric(18,9),
  unit_price_applied numeric(18,9),
  currency          char(3),
  price_valid_from  date,
  primary key (id, ts)
) partition by range (ts);

comment on table cc.usage_events is
  'Append-only. Enthält KEINE Nutzinhalte (keine Adressen, keine Prompts).';
comment on column cc.usage_events.cost_estimate is
  'Eigene Schätzung, zum Buchungszeitpunkt festgeschrieben. Niemals mit cc.billing_facts.cost_actual vermischen.';
comment on column cc.usage_events.work_unit_id is
  'Ohne Fremdschlüssel: Arbeitseinheiten werden früher bereinigt als die Verbrauchsdaten.';

-- Partitionen. Eine Auffangpartition verhindert, dass ein vergessener
-- Monatslauf zu abgewiesenen Buchungen führt.
create table cc.usage_events_default partition of cc.usage_events default;

-- Indexe an der Elterntabelle. Jede Partition – auch jede künftige – erbt sie,
-- ohne dass die Anlegefunktion daran erinnert werden muss.
-- Ein Teilindex (where ...) ist an partitionierten Tabellen nicht erlaubt,
-- deshalb hier die vollen Spaltenindexe.
create index usage_events_project_ts_idx  on cc.usage_events (project_id, ts desc);
create index usage_events_service_ts_idx  on cc.usage_events (service_id, ts desc);
create index usage_events_work_unit_idx   on cc.usage_events (work_unit_id, ts desc);
create index usage_events_session_ts_idx  on cc.usage_events (session_id, ts desc);

create or replace function cc.ensure_usage_partition(p_month date)
returns text language plpgsql as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_name  text := format('usage_events_%s', to_char(v_start, 'YYYYMM'));
begin
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'cc' and c.relname = v_name) then
    return v_name || ' (vorhanden)';
  end if;
  execute format(
    'create table cc.%I partition of cc.usage_events for values from (%L) to (%L)',
    v_name, v_start, v_end);
  -- Indexe nicht hier anlegen: sie hängen an der partitionierten Tabelle
  -- und werden von Postgres an jede neue Partition vererbt.
  return v_name || ' (angelegt)';
end $$;

-- Die nächsten zwölf Monate vorbereiten.
do $$
declare i int;
begin
  for i in 0..11 loop
    perform cc.ensure_usage_partition((date_trunc('month', now()) + (i || ' month')::interval)::date);
  end loop;
end $$;

-- Append-only erzwingen: eine gebuchte Schätzung darf sich nicht nachträglich
-- ändern, auch nicht durch einen Fehler in einem späteren Importlauf.
create or replace function cc.deny_change() returns trigger language plpgsql as $$
begin
  raise exception 'cc.usage_events ist append-only (% nicht erlaubt)', tg_op;
end $$;

create trigger usage_events_append_only
  before update or delete on cc.usage_events
  for each row execute function cc.deny_change();

-- ---------------------------------------------------------------- Zähler
-- Schneller Pfad für Limitprüfungen. Wird per Upsert hochgezählt, übersteht
-- Neustarts und bleibt bei gleichzeitigen Requests korrekt.
create table cc.counters (
  project_id    smallint not null references cc.projects(id),
  service_id    integer  not null references cc.services(id),
  scope         text not null check (scope in ('global','session','user')),
  scope_key     text not null default '',    -- '' für global
  period        text not null,               -- '2026-09-22' oder '2026-09'
  quantity      numeric(20,4) not null default 0,
  cost_estimate numeric(18,9) not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (project_id, service_id, scope, scope_key, period)
);

create index counters_lookup_idx on cc.counters (project_id, scope, period);

-- ---------------------------------------------------------------------------
-- Aufbewahrung. Die Funktion löscht eine ganze Monatspartition in einem Schritt
-- statt zeilenweise; das ist der Grund für die Partitionierung überhaupt.
--
-- Sie läuft NICHT von selbst. Es gibt bewusst noch keinen Zeitplan, weil die
-- Aufbewahrungsdauer noch nicht entschieden ist. Der Aufruf bleibt eine
-- bewusste Handlung, solange das so ist.
create or replace function cc.drop_usage_partition(p_month date)
returns text language plpgsql as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_name  text := format('usage_events_%s', to_char(v_start, 'YYYYMM'));
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'cc' and c.relname = v_name) then
    return v_name || ' (nicht vorhanden)';
  end if;
  -- Erst abhängen, dann löschen: zwischen beiden Schritten kann man die
  -- Tabelle noch sichern, falls sich jemand vertan hat.
  execute format('alter table cc.usage_events detach partition cc.%I', v_name);
  execute format('drop table cc.%I', v_name);
  return v_name || ' (gelöscht)';
end $$;

comment on function cc.drop_usage_partition(date) is
  'Entfernt einen kompletten Verbrauchsmonat. Wird von nichts automatisch aufgerufen.';
