-- CatLab API Control Center — Steuerung
--
-- In Schritt 3a werden diese Werte nur angelegt, nicht ausgewertet. Limits,
-- Kill Switch und Cache-only-Modus werden erst in einem späteren Schritt
-- scharf geschaltet.

create table cc.project_settings (
  project_id        smallint primary key references cc.projects(id),
  mode              text not null default 'normal'
                    check (mode in ('normal','warning','cache_only','off')),
  daily_cap_qty     numeric(20,4),
  monthly_cap_qty   numeric(20,4),
  daily_cap_cost    numeric(18,9),
  monthly_cap_cost  numeric(18,9),
  currency          char(3),
  thresholds        jsonb not null default '{"info":50,"warn":75,"critical":90,"stop":100}'::jsonb,
  updated_at        timestamptz not null default now(),
  updated_by        text
);

comment on column cc.project_settings.mode is
  'normal | warning | cache_only | off. "off" ist der Kill Switch: keine kostenpflichtigen Aufrufe mehr, Seite bleibt erreichbar.';

create table cc.service_settings (
  project_id     smallint not null references cc.projects(id),
  service_id     integer  not null references cc.services(id),
  enabled        boolean not null default true,
  daily_cap_qty  numeric(20,4),
  updated_at     timestamptz not null default now(),
  primary key (project_id, service_id)
);
