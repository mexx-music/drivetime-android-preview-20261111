-- CatLab API Control Center — Tagesbudget für die Adresseingabe
--
-- Autocomplete und Geocoding vor "Route berechnen" gehören zu keiner Tour.
-- Angemeldet bekommen sie ein eigenes Tagesbudget je Konto:
-- cc.plan_quotas.input_calls_per_day (Migration 0007, bisher ungenutzt).
--
-- Keine neue Tabelle: gezählt wird in den vorhandenen cc.counters-Zeilen
-- (Ebene 'account', Periode = UTC-Tag, eine Zeile je Dienst). Das Budget gilt
-- für beide Dienste ZUSAMMEN; weil das zwei Zeilen sind, reicht
-- counter_try_increment allein nicht - diese Funktion prüft die Summe unter
-- derselben Sperre, die auch reserve_tour benutzt (Entitlement-Zeile).
--
-- Fail closed wie bei den Touren: fehlt eine Einstellung oder ist sie NULL,
-- gibt es keinen Aufruf. NULL heißt nie "unbegrenzt".

-- ------------------------------------------------------------ try_input_call
-- Unmittelbar VOR einem Autocomplete- oder Geocoding-Aufruf außerhalb einer
-- Tour. Zählt den Aufruf, wenn er erlaubt ist. Ein Aufruf zählt, sobald er
-- freigegeben ist - auch wenn Google danach scheitert (wie calls_used bei
-- Touren): sonst ließe sich das Budget mit fehlschlagenden Anfragen umgehen.
--
-- status: ok | input_quota_exhausted | input_quota_not_configured |
--         no_entitlement | entitlement_inactive | not_member | user_disabled |
--         account_disabled | project_paused | unknown_project | invalid_argument
create or replace function cc.try_input_call(
  p_user_id     uuid,
  p_project_key text,
  p_service_key text
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_project  smallint;
  v_mode     text;
  v_account  uuid;
  v_service  integer;
  v_ent      cc.entitlements;
  v_limit    integer;
  v_period   text := to_char(now() at time zone 'UTC', 'YYYY-MM-DD');
  v_used     numeric;
  v_own      numeric;
  r          jsonb;
begin
  if p_user_id is null or p_project_key is null
     or p_service_key is null or p_service_key not in ('geocode', 'places-autocomplete') then
    return jsonb_build_object('status', 'invalid_argument');
  end if;

  select p.id, s.mode into v_project, v_mode
    from cc.projects p left join cc.project_settings s on s.project_id = p.id
   where p.key = p_project_key and p.active;
  if v_project is null then
    return jsonb_build_object('status', 'unknown_project');
  end if;
  if v_mode is null or v_mode in ('off', 'cache_only') then
    return jsonb_build_object('status', 'project_paused');
  end if;

  select sv.id into v_service
    from cc.services sv join cc.providers pv on pv.id = sv.provider_id
   where pv.key = 'google-maps' and sv.key = p_service_key;
  if v_service is null then
    return jsonb_build_object('status', 'invalid_argument');
  end if;

  if not exists (select 1 from cc.users u where u.id = p_user_id) then
    return jsonb_build_object('status', 'not_member');
  end if;
  if exists (select 1 from cc.users u where u.id = p_user_id and u.disabled_at is not null) then
    return jsonb_build_object('status', 'user_disabled');
  end if;
  select a.id into v_account from cc.accounts a where a.personal_owner = p_user_id;
  if v_account is null or not exists (
       select 1 from cc.account_members m where m.account_id = v_account and m.user_id = p_user_id) then
    return jsonb_build_object('status', 'not_member');
  end if;
  if exists (select 1 from cc.accounts a where a.id = v_account and a.disabled_at is not null) then
    return jsonb_build_object('status', 'account_disabled');
  end if;

  -- Dieselbe Sperre wie reserve_tour: serialisiert alle Kontingent-
  -- Entscheidungen dieses Kontos im Projekt. Damit ist die Summe über beide
  -- Dienste unten exakt, auch bei gleichzeitigen Anfragen.
  select * into v_ent from cc.entitlements e
   where e.account_id = v_account and e.project_id = v_project
   for update;
  if not found then
    return jsonb_build_object('status', 'no_entitlement');
  end if;
  if v_ent.status <> 'active' then
    return jsonb_build_object('status', 'entitlement_inactive', 'reason', v_ent.status);
  end if;
  if v_ent.period_mode = 'explicit'
     and not (now() >= v_ent.period_start and now() < v_ent.period_end) then
    return jsonb_build_object('status', 'entitlement_inactive', 'reason', 'outside_period');
  end if;

  select q.input_calls_per_day into v_limit from cc.plan_quotas q
   where q.project_id = v_project and q.plan_key = v_ent.plan_key and q.active;
  if v_limit is null then
    return jsonb_build_object('status', 'input_quota_not_configured', 'plan_key', v_ent.plan_key);
  end if;

  select coalesce(sum(c.quantity), 0),
         coalesce(sum(c.quantity) filter (where c.service_id = v_service), 0)
    into v_used, v_own
    from cc.counters c join cc.services sv on sv.id = c.service_id
   where c.project_id = v_project and c.scope = 'account' and c.scope_key = v_account::text
     and c.period = v_period and sv.key in ('geocode', 'places-autocomplete');

  if v_used >= v_limit then
    return jsonb_build_object('status', 'input_quota_exhausted',
                              'used', v_used::bigint, 'limit', v_limit, 'period', v_period);
  end if;

  -- Grenze für DIESE Zeile = Tagesbudget minus das, was der andere Dienst
  -- schon verbraucht hat. Unter der Sperre oben exakt.
  r := cc.counter_try_increment(v_project, v_service, 'account', v_account::text, v_period,
                                1, v_limit - (v_used - v_own));
  if not (r->>'allowed')::boolean then
    return jsonb_build_object('status', 'input_quota_exhausted',
                              'used', v_used::bigint, 'limit', v_limit, 'period', v_period);
  end if;
  return jsonb_build_object('status', 'ok', 'used', (v_used + 1)::bigint, 'limit', v_limit, 'period', v_period);
end $$;

revoke execute on function cc.try_input_call(uuid, text, text) from public;

do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on function cc.try_input_call(uuid, text, text) from %I', r);
    end if;
  end loop;
end $$;

comment on function cc.try_input_call(uuid, text, text) is
  'Tagesbudget der Adresseingabe (Autocomplete + Geocoding zusammen) je Konto und UTC-Tag. Vor jedem Provider-Aufruf außerhalb einer Tour.';
