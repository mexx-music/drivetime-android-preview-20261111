-- CatLab API Control Center — Abrechnungsdaten des Anbieters
--
-- Strikt getrennt von der eigenen Schätzung. In diese Tabellen schreibt
-- ausschließlich ein Import, niemals die Live-Messung. Deshalb gibt es auch
-- keine gemeinsame Summe über beide Quellen – nur einen Abgleich.

create table cc.billing_imports (
  id             bigserial primary key,
  provider_id    smallint not null references cc.providers(id),
  ran_at         timestamptz not null default now(),
  period_start   date not null,
  period_end     date not null,
  rows_imported  integer not null default 0,
  ok             boolean not null default true,
  message        text,
  source         text not null check (source in ('manual','api','bigquery')),
  check (period_end >= period_start)
);

create index billing_imports_provider_idx on cc.billing_imports (provider_id, ran_at desc);

create table cc.billing_facts (
  id           bigserial primary key,
  import_id    bigint not null references cc.billing_imports(id) on delete cascade,
  provider_id  smallint not null references cc.providers(id),
  service_id   integer references cc.services(id),   -- null = nicht zuordenbar
  project_id   smallint references cc.projects(id),  -- null = nicht zuordenbar
  period_start date not null,
  period_end   date not null,
  quantity     numeric(20,4),
  cost_actual  numeric(18,9) not null,
  currency     char(3) not null,             -- Originalwährung des Anbieters
  raw_ref      text,                         -- Rechnungs-/Zeilenbezug
  imported_at  timestamptz not null default now(),
  check (period_end >= period_start)
);

create index billing_facts_period_idx  on cc.billing_facts (provider_id, period_start, period_end);
create index billing_facts_service_idx on cc.billing_facts (service_id, period_start) where service_id is not null;

comment on table cc.billing_facts is
  'NUR importierte Anbieterdaten. Wird nie aus eigenen Messungen befüllt.';
comment on column cc.billing_facts.cost_actual is
  'Tatsächlich abgerechnet, verzögert. Nie mit cc.usage_events.cost_estimate addieren.';

-- Abgleich: Schätzung gegen Rechnung, je Monat und Leistung. Bewusst eine
-- Sicht und keine Tabelle, damit sie nie veraltet.
create or replace view cc.v_reconciliation as
with est as (
  select to_char(ts, 'YYYY-MM') as period,
         service_id,
         sum(cost_estimate) filter (where cost_estimate is not null) as estimate_sum,
         min(currency) as currency
    from cc.usage_events
   group by 1, 2
), act as (
  select to_char(period_start, 'YYYY-MM') as period,
         service_id,
         sum(cost_actual) as actual_sum,
         min(currency) as currency
    from cc.billing_facts
   group by 1, 2
)
select coalesce(est.period, act.period)         as period,
       coalesce(est.service_id, act.service_id) as service_id,
       est.estimate_sum,
       act.actual_sum,
       coalesce(est.currency, act.currency)     as currency,
       case when act.actual_sum is null then null
            else round(est.estimate_sum - act.actual_sum, 4) end as delta_abs,
       case when act.actual_sum is null or act.actual_sum = 0 then null
            else round((est.estimate_sum - act.actual_sum) / act.actual_sum * 100, 2)
       end as delta_pct,
       case when act.actual_sum is null then 'missing-actuals'
            when est.estimate_sum is null then 'missing-estimate'
            when act.actual_sum = 0 then 'ok'
            when abs((est.estimate_sum - act.actual_sum) / act.actual_sum) > 0.10 then 'drift'
            else 'ok'
       end as status
  from est full outer join act
    on est.period = act.period
   and coalesce(est.service_id, -1) = coalesce(act.service_id, -1);

comment on view cc.v_reconciliation is
  'Stellt Schätzung und Rechnung nebeneinander. Bildet bewusst KEINE Gesamtsumme aus beidem.';
