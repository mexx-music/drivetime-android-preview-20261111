-- CatLab API Control Center — Kontingente, Entitlements, Tour-Ledger
--
-- Die verbindliche, synchrone Schicht. Sie entscheidet, OB ein
-- kostenpflichtiger Aufruf stattfinden darf. Getrennt von der Telemetrie
-- (cc.work_units, cc.usage_events), die nur festhält, was passiert ist:
--
--   * Kontingente werden NIE aus usage_events berechnet.
--   * Die einzige Verbindung ist später tours.id = work_units.id.
--
-- Fail closed: fehlt eine Einstellung oder ist sie NULL, gibt es keine Tour.
-- NULL heißt nie "unbegrenzt".
--
-- Konkrete Mengen (Touren je Monat, Aufrufe je Tour, Laufzeit) setzt diese
-- Migration bewusst NICHT. Ohne sie sind alle Pläne gesperrt.

-- ---------------------------------------------------------------- Hilfen
create or replace function cc.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ----------------------------------------------------------- Plan-Kontingente
-- Je Projekt und Plan. Eine Zeile ist erst wirksam, wenn sie aktiv ist - und
-- aktiv darf sie nur mit vollständigen Werten sein.
create table cc.plan_quotas (
  project_id          smallint not null references cc.projects(id),
  plan_key            text     not null references cc.plans(key),
  -- Tourenplanungen je Abrechnungszeitraum. 0 ist erlaubt und sperrt.
  tours_per_period    integer check (tours_per_period >= 0),
  -- Kostenpflichtige Provider-Aufrufe, die eine Tour höchstens auslösen darf
  -- (inklusive Wiederholungen).
  max_calls_per_tour  integer check (max_calls_per_tour > 0),
  -- Adresseingabe (Autocomplete/Geocoding) außerhalb von Touren, je Tag.
  -- Wird vom Proxy über cc.counter_try_increment durchgesetzt.
  input_calls_per_day integer check (input_calls_per_day >= 0),
  -- Wie lange eine Tour Aufrufe (auch Wiederholungen) ausführen darf.
  tour_ttl            interval check (tour_ttl > interval '0' and tour_ttl <= interval '1 day'),
  active              boolean not null default false,
  note                text,
  updated_at          timestamptz not null default now(),
  updated_by          text,
  primary key (project_id, plan_key),
  constraint plan_quotas_active_complete check (
    not active
    or (tours_per_period is not null
        and max_calls_per_tour is not null
        and tour_ttl is not null)
  )
);

create trigger plan_quotas_touch before update on cc.plan_quotas
  for each row execute function cc.touch_updated_at();

comment on table cc.plan_quotas is
  'Nutzerkontingente je Projekt und Plan. NICHT verwechseln mit cc.free_allowances (Freimengen des Anbieters).';
comment on column cc.plan_quotas.active is
  'Ohne active=true und vollständige Werte reserviert cc.reserve_tour keine Tour (fail closed).';

comment on table cc.free_allowances is
  'Freimengen des ANBIETERS (z. B. Google) je Leistung und Monat. Keine Nutzerkontingente - die stehen in cc.plan_quotas.';

-- ------------------------------------------------------------- Entitlements
-- Welchen Plan ein Konto in einem Projekt hat. Die einzige Wahrheit über den
-- Plan; schreibt nur der Server (später auch der Zahlungs-Webhook).
create table cc.entitlements (
  account_id   uuid     not null references cc.accounts(id) on delete cascade,
  project_id   smallint not null references cc.projects(id),
  plan_key     text     not null references cc.plans(key),
  status       text     not null check (status in ('active', 'past_due', 'canceled', 'suspended')),
  source       text     not null check (source in ('default_free', 'manual', 'stripe')),
  -- calendar_month: Zeitraum ist der laufende Kalendermonat (UTC), ohne
  --                 dass jemand ihn fortschreiben muss (Free).
  -- explicit:       period_start/period_end kommen von außen, z. B. aus dem
  --                 Abo beim Zahlungsanbieter. Ausserhalb davon: keine Tour.
  period_mode  text     not null check (period_mode in ('calendar_month', 'explicit')),
  period_start timestamptz,
  period_end   timestamptz,
  external_ref text check (external_ref is null or length(external_ref) between 1 and 200),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (account_id, project_id),
  constraint entitlements_period check (
    (period_mode = 'calendar_month' and period_start is null and period_end is null)
    or (period_mode = 'explicit' and period_start is not null and period_end is not null
        and period_end > period_start)
  )
);

create unique index entitlements_external_ref_uq on cc.entitlements (source, external_ref)
  where external_ref is not null;

create trigger entitlements_touch before update on cc.entitlements
  for each row execute function cc.touch_updated_at();

comment on table cc.entitlements is
  'Plan eines Kontos je Projekt. Nur serverseitig beschrieben; ein Client bestimmt nie seinen Plan.';

-- ---------------------------------------------------------------- Touren
-- Das verbindliche Ledger. Eine Tour = ein "Route berechnen".
--
--   reserved  zählt gegen das Kontingent bis expires_at + Nachlauf
--             (cc.tour_settle_grace), solange kein Aufruf gelungen ist.
--   consumed  mindestens ein kostenpflichtiger Aufruf war erfolgreich.
--             Endgültig verbraucht. Wiederholungen bis expires_at bleiben
--             in derselben Tour.
--   released  nie ein erfolgreicher Aufruf, freigegeben. Zählt nicht. Endgültig.
create table cc.tours (
  id               uuid primary key default gen_random_uuid(),
  account_id       uuid     not null references cc.accounts(id) on delete cascade,
  -- Nur nach dem Löschen des Nutzers null; das Konto behält sein Ledger.
  user_id          uuid     references cc.users(id) on delete set null,
  project_id       smallint not null references cc.projects(id),
  plan_key         text     not null references cc.plans(key),
  period_start     timestamptz not null,
  state            text     not null default 'reserved'
                   check (state in ('reserved', 'consumed', 'released')),
  idempotency_key  uuid     not null,
  calls_used       integer  not null default 0,
  calls_in_flight  integer  not null default 0,
  call_budget      integer  not null check (call_budget > 0),
  first_success_at timestamptz,
  last_call_at     timestamptz,
  expires_at       timestamptz not null,
  completed_at     timestamptz,
  released_at      timestamptz,
  created_at       timestamptz not null default now(),
  constraint tours_calls_range   check (calls_used between 0 and call_budget),
  constraint tours_inflight_range check (calls_in_flight between 0 and calls_used),
  constraint tours_consumed_success check ((state = 'consumed') = (first_success_at is not null)),
  constraint tours_released_at   check ((state = 'released') = (released_at is not null)),
  constraint tours_released_idle check (state <> 'released' or calls_in_flight = 0),
  constraint tours_completed     check (completed_at is null or state = 'consumed'),
  constraint tours_expiry        check (expires_at > created_at)
);

-- Ein Reservierungsversuch = ein Schlüssel je Nutzer. Doppelklick und
-- HTTP-Wiederholung treffen dieselbe Zeile.
create unique index tours_idempotency_uq on cc.tours (user_id, idempotency_key);
-- Zählen je Konto, Projekt und Zeitraum.
create index tours_account_period_idx on cc.tours (account_id, project_id, created_at);

comment on table cc.tours is
  'Verbindliches Tour-Ledger für Kontingente. Später gilt tours.id = work_units.id; sonst keine Verbindung zur Telemetrie.';

-- Zustandswechsel und unveränderliche Spalten schützen - auch gegen einen
-- Fehler in einer künftigen Funktion oder eine Handkorrektur.
create or replace function cc.tours_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id               is distinct from old.id
     or new.account_id    is distinct from old.account_id
     or new.project_id    is distinct from old.project_id
     or new.plan_key      is distinct from old.plan_key
     or new.period_start  is distinct from old.period_start
     or new.idempotency_key is distinct from old.idempotency_key
     or new.call_budget   is distinct from old.call_budget
     or new.expires_at    is distinct from old.expires_at
     or new.created_at    is distinct from old.created_at then
    raise exception 'cc.tours: unveränderliche Spalte geändert (Tour %)', old.id;
  end if;
  -- user_id darf nur durch das Löschen des Nutzers auf null gehen.
  if new.user_id is distinct from old.user_id and new.user_id is not null then
    raise exception 'cc.tours: user_id kann nicht umgehängt werden (Tour %)', old.id;
  end if;
  if old.state = 'released' and (new.state <> 'released' or new.calls_used <> old.calls_used) then
    raise exception 'cc.tours: freigegebene Tour ist endgültig (Tour %)', old.id;
  end if;
  if old.state = 'consumed' and new.state <> 'consumed' then
    raise exception 'cc.tours: verbrauchte Tour kann nicht zurückgesetzt werden (Tour %)', old.id;
  end if;
  if new.calls_used < old.calls_used then
    raise exception 'cc.tours: calls_used darf nicht sinken (Tour %)', old.id;
  end if;
  if old.first_success_at is not null and new.first_success_at is distinct from old.first_success_at
     or old.completed_at is not null and new.completed_at is distinct from old.completed_at
     or old.released_at is not null and new.released_at is distinct from old.released_at then
    raise exception 'cc.tours: gesetzter Zeitstempel ist endgültig (Tour %)', old.id;
  end if;
  return new;
end $$;

create trigger tours_guard before update on cc.tours
  for each row execute function cc.tours_guard();

-- Wie lange eine reservierte Tour nach expires_at noch zählt. Ein Aufruf darf
-- nur vor expires_at beginnen; der Nachlauf muss länger sein als jeder
-- Provider-Aufruf dauern kann, damit eine Antwort, die knapp nach expires_at
-- eintrifft, nie auf einer schon wieder frei gezählten Tour landet.
create or replace function cc.tour_settle_grace() returns interval
language sql immutable set search_path = '' as $$ select interval '5 minutes' $$;

-- Zählt diese Tour zum Zeitpunkt p_at gegen das Kontingent?
create or replace function cc.tour_counts(p_state text, p_expires_at timestamptz, p_at timestamptz)
returns boolean language sql immutable set search_path = '' as $$
  select p_state = 'consumed'
      or (p_state = 'reserved' and p_expires_at + cc.tour_settle_grace() > p_at)
$$;

-- -------------------------------------------------- Zähler: Konto-Ebene
-- Business/Fleet brauchen später Grenzen je Konto. Die Tabelle ist bisher
-- unbenutzt; die Erweiterung ist eine reine Obermenge.
alter table cc.counters drop constraint if exists counters_scope_check;
alter table cc.counters add constraint counters_scope_check
  check (scope in ('global', 'session', 'user', 'account'));

-- ============================================================ Funktionen
-- Alle SECURITY DEFINER mit leerem search_path: eine spätere Proxy-Rolle
-- bekommt ausschließlich EXECUTE auf diese Funktionen, keinerlei Rechte an
-- den Tabellen. Jeder Name ist voll qualifiziert.
--
-- Rückgabe jeweils jsonb mit "status". Fachliche Ablehnungen sind keine
-- Fehler, sondern Statuswerte; Exceptions bedeuten einen Programmierfehler.

create or replace function cc._tour_json(p_status text, t cc.tours)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'status',       p_status,
    'tour_id',      t.id,
    'account_id',   t.account_id,
    'state',        t.state,
    'calls_used',   t.calls_used,
    'call_budget',  t.call_budget,
    'expires_at',   t.expires_at,
    'completed',    t.completed_at is not null)
$$;

-- ------------------------------------------------ persönliches Konto anlegen
-- Idempotent und parallel sicher. Der Nutzer muss in auth.users existieren.
create or replace function cc.ensure_personal_account(p_user_id uuid)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_account uuid;
begin
  if p_user_id is null then
    raise exception 'ensure_personal_account: p_user_id fehlt';
  end if;
  insert into cc.users (id) values (p_user_id) on conflict (id) do nothing;

  select a.id into v_account from cc.accounts a where a.personal_owner = p_user_id;
  if v_account is null then
    insert into cc.accounts (kind, personal_owner) values ('personal', p_user_id)
      on conflict (personal_owner) where personal_owner is not null do nothing
      returning id into v_account;
    if v_account is null then
      select a.id into v_account from cc.accounts a where a.personal_owner = p_user_id;
    end if;
  end if;

  insert into cc.account_members (account_id, user_id, role)
    values (v_account, p_user_id, 'owner')
    on conflict (account_id, user_id) do nothing;
  return v_account;
end $$;

-- --------------------------------------- Standard-Entitlement (Free) anlegen
-- Legt nur an, wenn noch keins existiert. Überschreibt nie einen Pro-Plan.
create or replace function cc.ensure_default_entitlement(p_account_id uuid, p_project_key text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_project smallint;
  v_created boolean;
  e cc.entitlements;
begin
  select p.id into v_project from cc.projects p where p.key = p_project_key and p.active;
  if v_project is null then
    return jsonb_build_object('status', 'unknown_project');
  end if;
  insert into cc.entitlements (account_id, project_id, plan_key, status, source, period_mode)
    values (p_account_id, v_project, 'free', 'active', 'default_free', 'calendar_month')
    on conflict (account_id, project_id) do nothing;
  v_created := found;
  select * into e from cc.entitlements where account_id = p_account_id and project_id = v_project;
  return jsonb_build_object('status', case when v_created then 'created' else 'existing' end,
                            'plan_key', e.plan_key, 'entitlement_status', e.status,
                            'source', e.source);
end $$;

-- ------------------------------------------------------------ reserve_tour
-- Reserviert eine Tour, bevor irgendein kostenpflichtiger Aufruf stattfindet.
--
-- p_account_id null = persönliches Konto des Nutzers.
--
-- status: reserved | existing | quota_exhausted | quota_not_configured |
--         no_entitlement | entitlement_inactive | not_member | user_disabled |
--         account_disabled | project_paused | unknown_project |
--         idempotency_conflict | invalid_argument
create or replace function cc.reserve_tour(
  p_user_id         uuid,
  p_project_key     text,
  p_idempotency_key uuid,
  p_account_id      uuid default null
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_now      timestamptz := now();
  v_project  smallint;
  v_mode     text;
  v_account  uuid;
  v_ent      cc.entitlements;
  v_quota    cc.plan_quotas;
  v_start    timestamptz;
  v_end      timestamptz;
  v_used     integer;
  v_tour     cc.tours;
begin
  if p_user_id is null or p_project_key is null or p_idempotency_key is null then
    return jsonb_build_object('status', 'invalid_argument');
  end if;

  select p.id, s.mode into v_project, v_mode
    from cc.projects p left join cc.project_settings s on s.project_id = p.id
   where p.key = p_project_key and p.active;
  if v_project is null then
    return jsonb_build_object('status', 'unknown_project');
  end if;

  -- Wiederholung desselben Versuchs: dieselbe Tour zurück, auch wenn sich
  -- inzwischen Kontingent oder Plan geändert haben.
  select * into v_tour from cc.tours t
   where t.user_id = p_user_id and t.idempotency_key = p_idempotency_key;
  if found then
    if v_tour.project_id <> v_project
       or (p_account_id is not null and v_tour.account_id <> p_account_id) then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    return cc._tour_json('existing', v_tour);
  end if;

  if v_mode is null or v_mode in ('off', 'cache_only') then
    return jsonb_build_object('status', 'project_paused');
  end if;

  if not exists (select 1 from cc.users u where u.id = p_user_id) then
    return jsonb_build_object('status', 'not_member');
  end if;
  if exists (select 1 from cc.users u where u.id = p_user_id and u.disabled_at is not null) then
    return jsonb_build_object('status', 'user_disabled');
  end if;

  if p_account_id is null then
    select a.id into v_account from cc.accounts a where a.personal_owner = p_user_id;
  else
    v_account := p_account_id;
  end if;
  if v_account is null or not exists (
       select 1 from cc.account_members m
        where m.account_id = v_account and m.user_id = p_user_id) then
    return jsonb_build_object('status', 'not_member');
  end if;
  if exists (select 1 from cc.accounts a where a.id = v_account and a.disabled_at is not null) then
    return jsonb_build_object('status', 'account_disabled');
  end if;

  -- Die Sperre auf das Entitlement serialisiert alle Reservierungen dieses
  -- Kontos in diesem Projekt. Wer hier wartet, sieht danach die Tour des
  -- Vorgängers (READ COMMITTED: jede Anweisung mit frischem Snapshot).
  select * into v_ent from cc.entitlements e
   where e.account_id = v_account and e.project_id = v_project
   for update;
  if not found then
    return jsonb_build_object('status', 'no_entitlement');
  end if;

  -- Nach dem Warten erneut: ein paralleler Versuch mit demselben Schlüssel
  -- kann die Tour inzwischen angelegt haben.
  select * into v_tour from cc.tours t
   where t.user_id = p_user_id and t.idempotency_key = p_idempotency_key;
  if found then
    if v_tour.project_id <> v_project or v_tour.account_id <> v_account then
      return jsonb_build_object('status', 'idempotency_conflict');
    end if;
    return cc._tour_json('existing', v_tour);
  end if;

  if v_ent.status <> 'active' then
    return jsonb_build_object('status', 'entitlement_inactive', 'reason', v_ent.status);
  end if;
  if v_ent.period_mode = 'calendar_month' then
    v_start := date_trunc('month', v_now, 'UTC');
    v_end   := v_start + interval '1 month';
  else
    v_start := v_ent.period_start;
    v_end   := v_ent.period_end;
    if not (v_now >= v_start and v_now < v_end) then
      return jsonb_build_object('status', 'entitlement_inactive', 'reason', 'outside_period');
    end if;
  end if;

  select * into v_quota from cc.plan_quotas q
   where q.project_id = v_project and q.plan_key = v_ent.plan_key;
  if not found or not v_quota.active
     or v_quota.tours_per_period is null
     or v_quota.max_calls_per_tour is null
     or v_quota.tour_ttl is null then
    return jsonb_build_object('status', 'quota_not_configured', 'plan_key', v_ent.plan_key);
  end if;

  select count(*) into v_used from cc.tours t
   where t.account_id = v_account and t.project_id = v_project
     and t.created_at >= v_start and t.created_at < v_end
     and cc.tour_counts(t.state, t.expires_at, v_now);

  if v_used >= v_quota.tours_per_period then
    return jsonb_build_object(
      'status', 'quota_exhausted', 'plan_key', v_ent.plan_key,
      'tours_used', v_used, 'tours_limit', v_quota.tours_per_period,
      'period_start', v_start, 'period_end', v_end);
  end if;

  begin
    insert into cc.tours (account_id, user_id, project_id, plan_key, period_start,
                          idempotency_key, call_budget, expires_at, created_at)
    values (v_account, p_user_id, v_project, v_ent.plan_key, v_start,
            p_idempotency_key, v_quota.max_calls_per_tour, v_now + v_quota.tour_ttl, v_now)
    returning * into v_tour;
  exception when unique_violation then
    -- Derselbe Schlüssel über ein anderes Konto: dort hält die Sperre nicht.
    select * into v_tour from cc.tours t
     where t.user_id = p_user_id and t.idempotency_key = p_idempotency_key;
    if v_tour.project_id = v_project and v_tour.account_id = v_account then
      return cc._tour_json('existing', v_tour);
    end if;
    return jsonb_build_object('status', 'idempotency_conflict');
  end;

  return cc._tour_json('reserved', v_tour) || jsonb_build_object(
    'plan_key', v_ent.plan_key,
    'tours_used', v_used + 1, 'tours_limit', v_quota.tours_per_period,
    'period_start', v_start, 'period_end', v_end);
end $$;

-- ----------------------------------------------------------- use_tour_call
-- Vor JEDEM kostenpflichtigen Provider-Aufruf einer Tour. Ein einziges
-- UPDATE mit allen Bedingungen: parallel ausgeführt kann das Budget nie
-- überschritten werden (die zweite Anweisung prüft nach dem Warten die
-- Bedingungen auf der neuen Zeile erneut).
--
-- Danach MUSS cc.finish_tour_call folgen, auch bei einem Fehler.
--
-- status: ok | not_found | released | completed | expired | budget_exhausted |
--         not_member | invalid_argument
create or replace function cc.use_tour_call(p_tour_id uuid, p_user_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  t cc.tours;
begin
  if p_tour_id is null or p_user_id is null then
    return jsonb_build_object('status', 'invalid_argument');
  end if;

  update cc.tours x
     set calls_used = x.calls_used + 1,
         calls_in_flight = x.calls_in_flight + 1,
         last_call_at = now()
   where x.id = p_tour_id
     and x.user_id = p_user_id
     and x.state <> 'released'
     and x.completed_at is null
     and x.expires_at > now()
     and x.calls_used < x.call_budget
     and exists (select 1 from cc.account_members m
                  where m.account_id = x.account_id and m.user_id = x.user_id)
     and not exists (select 1 from cc.users u
                      where u.id = x.user_id and u.disabled_at is not null)
  returning * into t;
  if found then
    return cc._tour_json('ok', t);
  end if;

  -- Nur zur Begründung der Ablehnung; entscheidet nichts mehr.
  select * into t from cc.tours x where x.id = p_tour_id and x.user_id = p_user_id;
  if not found then
    -- Auch eine fremde Tour: ihre Existenz wird nicht verraten.
    return jsonb_build_object('status', 'not_found');
  end if;
  return cc._tour_json(
    case
      when t.state = 'released'          then 'released'
      when t.completed_at is not null    then 'completed'
      when t.expires_at <= now()         then 'expired'
      when t.calls_used >= t.call_budget then 'budget_exhausted'
      else 'not_member'
    end, t);
end $$;

-- -------------------------------------------------------- finish_tour_call
-- Ergebnis eines mit use_tour_call begonnenen Aufrufs. Der erste Erfolg macht
-- die Tour endgültig zu "consumed".
--
-- status: ok | no_call_in_flight | not_found | invalid_argument
create or replace function cc.finish_tour_call(p_tour_id uuid, p_user_id uuid, p_success boolean)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  t cc.tours;
begin
  if p_tour_id is null or p_user_id is null or p_success is null then
    return jsonb_build_object('status', 'invalid_argument');
  end if;

  update cc.tours x
     set calls_in_flight = x.calls_in_flight - 1,
         state = case when p_success then 'consumed' else x.state end,
         first_success_at = case when p_success then coalesce(x.first_success_at, now())
                                 else x.first_success_at end
   where x.id = p_tour_id and x.user_id = p_user_id and x.calls_in_flight > 0
  returning * into t;
  if found then
    return cc._tour_json('ok', t);
  end if;

  if exists (select 1 from cc.tours x where x.id = p_tour_id and x.user_id = p_user_id) then
    return jsonb_build_object('status', 'no_call_in_flight');
  end if;
  return jsonb_build_object('status', 'not_found');
end $$;

-- ------------------------------------------------------------- release_tour
-- Gibt eine Reservierung frei - nur ohne jeden Erfolg und ohne laufenden
-- Aufruf. Ein laufender Aufruf könnte noch gelingen; sonst ließe sich eine
-- Tour kostenlos nutzen, indem man sie während des Aufrufs freigibt.
--
-- status: released | already_released | consumed | call_in_flight | not_found |
--         invalid_argument
create or replace function cc.release_tour(p_tour_id uuid, p_user_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  t cc.tours;
begin
  if p_tour_id is null or p_user_id is null then
    return jsonb_build_object('status', 'invalid_argument');
  end if;

  update cc.tours x
     set state = 'released', released_at = now()
   where x.id = p_tour_id and x.user_id = p_user_id
     and x.state = 'reserved' and x.first_success_at is null and x.calls_in_flight = 0
  returning * into t;
  if found then
    return cc._tour_json('released', t);
  end if;

  select * into t from cc.tours x where x.id = p_tour_id and x.user_id = p_user_id;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  return cc._tour_json(
    case
      when t.state = 'released' then 'already_released'
      when t.state = 'consumed' then 'consumed'
      else 'call_in_flight'
    end, t);
end $$;

-- ------------------------------------------------------------ complete_tour
-- Schließt eine verbrauchte Tour vorzeitig: danach keine weiteren Aufrufe.
-- Ändert nichts am Kontingent.
--
-- status: completed | already_completed | not_consumed | not_found | invalid_argument
create or replace function cc.complete_tour(p_tour_id uuid, p_user_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  t cc.tours;
begin
  if p_tour_id is null or p_user_id is null then
    return jsonb_build_object('status', 'invalid_argument');
  end if;
  update cc.tours x set completed_at = now()
   where x.id = p_tour_id and x.user_id = p_user_id
     and x.state = 'consumed' and x.completed_at is null
  returning * into t;
  if found then
    return cc._tour_json('completed', t);
  end if;
  select * into t from cc.tours x where x.id = p_tour_id and x.user_id = p_user_id;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  return cc._tour_json(
    case when t.completed_at is not null then 'already_completed' else 'not_consumed' end, t);
end $$;

-- ---------------------------------------------------- counter_try_increment
-- Atomares Prüfen-und-Hochzählen für Grenzen je Tag/Monat (global, Konto,
-- Nutzer, Sitzung). Eine einzige Anweisung: der Konfliktfall sperrt die Zeile
-- und prüft die Grenze auf dem aktuellen Stand. Kein Lesen-dann-Schreiben.
--
-- p_limit null = nicht konfiguriert = abgelehnt (nie unbegrenzt).
--
-- Rückgabe: {allowed, quantity, limit, reason?}
--   reason: limit_reached | limit_not_configured | invalid_argument
create or replace function cc.counter_try_increment(
  p_project_id smallint,
  p_service_id integer,
  p_scope      text,
  p_scope_key  text,
  p_period     text,
  p_amount     numeric,
  p_limit      numeric,
  p_cost       numeric default 0
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_q numeric;
begin
  if p_limit is null then
    return jsonb_build_object('allowed', false, 'reason', 'limit_not_configured');
  end if;
  if p_project_id is null or p_service_id is null or p_scope is null or p_scope_key is null
     or p_period is null or p_amount is null or p_amount <= 0 or p_limit < 0
     or coalesce(p_cost, 0) < 0
     or p_scope not in ('global', 'session', 'user', 'account')
     or (p_scope = 'global') <> (p_scope_key = '')
     or p_period !~ '^[0-9]{4}-[0-9]{2}(-[0-9]{2})?$' then
    return jsonb_build_object('allowed', false, 'reason', 'invalid_argument');
  end if;

  insert into cc.counters as c
         (project_id, service_id, scope, scope_key, period, quantity, cost_estimate, updated_at)
  select p_project_id, p_service_id, p_scope, p_scope_key, p_period,
         p_amount, coalesce(p_cost, 0), now()
   where p_amount <= p_limit
  on conflict (project_id, service_id, scope, scope_key, period) do update
     set quantity      = c.quantity + excluded.quantity,
         cost_estimate = c.cost_estimate + excluded.cost_estimate,
         updated_at    = now()
   where c.quantity + excluded.quantity <= p_limit
  returning c.quantity into v_q;

  if found then
    return jsonb_build_object('allowed', true, 'quantity', v_q, 'limit', p_limit);
  end if;

  select c.quantity into v_q from cc.counters c
   where c.project_id = p_project_id and c.service_id = p_service_id
     and c.scope = p_scope and c.scope_key = p_scope_key and c.period = p_period;
  return jsonb_build_object('allowed', false, 'reason', 'limit_reached',
                            'quantity', coalesce(v_q, 0), 'limit', p_limit);
end $$;

-- ================================================================ Rechte
-- Niemand außer dem Eigentümer darf die Tabellen direkt anfassen oder die
-- Funktionen ausführen. Eine spätere Proxy-Rolle bekommt gezielt EXECUTE auf
-- die Funktionen (siehe supabase/README-controlcenter.md); diese Migration
-- legt bewusst keine Rolle an.
revoke all on cc.accounts, cc.account_members, cc.plan_quotas, cc.entitlements, cc.tours
  from public;

-- Zusätzliche Sicherung, falls die Tabellen je über die Data API erreichbar
-- würden: RLS an, keine Policies = kein Zugriff für API-Rollen. Der
-- Eigentümer (und damit SECURITY DEFINER) ist davon nicht betroffen.
alter table cc.accounts        enable row level security;
alter table cc.account_members enable row level security;
alter table cc.plan_quotas     enable row level security;
alter table cc.entitlements    enable row level security;
alter table cc.tours           enable row level security;

-- Funktionen sind in PostgreSQL standardmäßig für PUBLIC ausführbar.
revoke execute on function
  cc.touch_updated_at(),
  cc.tours_guard(),
  cc.tour_settle_grace(),
  cc.tour_counts(text, timestamptz, timestamptz),
  cc._tour_json(text, cc.tours),
  cc.ensure_personal_account(uuid),
  cc.ensure_default_entitlement(uuid, text),
  cc.reserve_tour(uuid, text, uuid, uuid),
  cc.use_tour_call(uuid, uuid),
  cc.finish_tour_call(uuid, uuid, boolean),
  cc.release_tour(uuid, uuid),
  cc.complete_tour(uuid, uuid),
  cc.counter_try_increment(smallint, integer, text, text, text, numeric, numeric, numeric)
  from public;

-- In Supabase existieren die API-Rollen anon und authenticated. Sie sollen
-- hier nichts dürfen - auch nicht über künftige Standardrechte.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on cc.accounts, cc.account_members, cc.plan_quotas, '
                     'cc.entitlements, cc.tours from %I', r);
      execute format('revoke all on all functions in schema cc from %I', r);
    end if;
  end loop;
end $$;
