-- CatLab API Control Center — Grundlagen
--
-- Alles liegt im Schema "cc", damit es neben den Tabellen einzelner Projekte
-- klar abgegrenzt bleibt. Das Modell ist bewusst provider- und
-- projektunabhängig: DriveTime ist das erste Projekt, nicht das einzige.

create extension if not exists btree_gist;   -- für die Preis-Überlappungsprüfung

create schema if not exists cc;

-- ---------------------------------------------------------------- Einheiten
-- Als Tabelle statt ENUM: neue Abrechnungseinheiten sollen ohne Typänderung
-- dazukommen können.
create table cc.units (
  key         text primary key,
  description text not null
);

insert into cc.units (key, description) values
  ('request',   'ein API-Aufruf (z. B. Google Directions)'),
  ('token',     'ein Token (z. B. LLM-Ein- oder -Ausgabe)'),
  ('character', 'ein Zeichen (z. B. Text-to-Speech)'),
  ('element',   'ein abgerechnetes Element (z. B. Kartenkachel, Bild)')
on conflict (key) do nothing;

-- ------------------------------------------------------------------- Pläne
-- Vorbereitet für Free/Pro/Business. In Phase 1 wird damit nichts erzwungen.
create table cc.plans (
  key         text primary key,
  name        text not null,
  sort_order  smallint not null default 0
);

insert into cc.plans (key, name, sort_order) values
  ('free',     'Free',     10),
  ('pro',      'Pro',      20),
  ('business', 'Business', 30),
  ('fleet',    'Fleet',    40)
on conflict (key) do nothing;

-- ----------------------------------------------------------------- Nutzer
-- Nur angelegt, damit sessions.user_id später ein Ziel hat. Noch kein Login.
create table cc.users (
  id          uuid primary key default gen_random_uuid(),
  plan        text not null default 'free' references cc.plans(key),
  created_at  timestamptz not null default now(),
  disabled_at timestamptz
);

-- --------------------------------------------------------------- Projekte
create table cc.projects (
  id          smallserial primary key,
  key         text not null unique,          -- 'drivetime'
  name        text not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- -------------------------------------------------------------- Anbieter
create table cc.providers (
  id             smallserial primary key,
  key            text not null unique,       -- 'google-maps', 'anthropic'
  name           text not null,
  billing_source text not null default 'none'
                 check (billing_source in ('none','manual','api','bigquery')),
  created_at     timestamptz not null default now()
);

-- -------------------------------------------------------------- Leistungen
-- Eine Zeile je abrechenbarer Leistung. Ein Chatmodell wird zu zwei Zeilen,
-- Ein- und Ausgabe, weil beide getrennt bepreist werden.
create table cc.services (
  id          serial primary key,
  provider_id smallint not null references cc.providers(id),
  key         text not null,                 -- 'directions', 'claude-sonnet-in'
  name        text not null,
  unit        text not null references cc.units(key),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (provider_id, key)
);

-- ------------------------------------------------------------ Preisliste
-- Zeitlich versioniert. Die Ausschlussbedingung verhindert überlappende
-- Zeiträume je Leistung – sonst wäre der Preis zu einem Zeitpunkt mehrdeutig.
create table cc.price_list (
  id          bigserial primary key,
  service_id  integer not null references cc.services(id),
  unit_price  numeric(18,9) not null check (unit_price >= 0),
  currency    char(3) not null,              -- Originalwährung, keine Umrechnung
  valid_from  date not null,
  valid_to    date,                          -- null = offenes Ende
  source      text not null default 'manuell',
  created_at  timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  constraint price_no_overlap exclude using gist (
    service_id with =,
    daterange(valid_from, valid_to, '[)') with &&
  )
);

create index price_list_service_from_idx
  on cc.price_list (service_id, valid_from desc);

-- Gültiger Preis zu einem Zeitpunkt. Wegen der Ausschlussbedingung höchstens
-- eine Zeile.
create or replace function cc.price_at(p_service integer, p_at timestamptz)
returns table (unit_price numeric, currency char(3), valid_from date)
language sql stable as $$
  select pl.unit_price, pl.currency, pl.valid_from
    from cc.price_list pl
   where pl.service_id = p_service
     and pl.valid_from <= (p_at at time zone 'UTC')::date
     and (pl.valid_to is null or pl.valid_to > (p_at at time zone 'UTC')::date)
   limit 1
$$;

-- --------------------------------------------------- Freikontingent/Monat
create table cc.free_allowances (
  service_id    integer not null references cc.services(id),
  period        char(7) not null,            -- '2026-09'
  allowance_qty numeric(20,4) not null check (allowance_qty >= 0),
  source        text not null default 'manuell',
  updated_at    timestamptz not null default now(),
  primary key (service_id, period)
);

comment on schema cc is
  'CatLab API Control Center: Verbrauch und Kosten über Projekte und Anbieter hinweg.';
comment on table cc.price_list is
  'Preise nach Datum versioniert. Änderungen wirken NIE rückwirkend auf bereits gebuchte usage_events.';
