-- CatLab API Control Center — Identität und Konten
--
-- Kette:  auth.users (Supabase Auth)  →  cc.users  →  cc.account_members  →  cc.accounts
--
-- Das Konto (account) besitzt das Kontingent, nicht der einzelne Nutzer.
-- Heute hat jeder Nutzer genau ein persönliches Konto. Business/Fleet hängen
-- später mehrere Nutzer an dasselbe Konto, ohne dass sich an Kontingent oder
-- Tour-Ledger etwas ändert.
--
-- Voraussetzung: auth.users existiert. In Supabase ist das immer der Fall;
-- für lokale Tests legt supabase/tests/auth_stub.sql einen Ersatz an.

do $$
begin
  if to_regclass('auth.users') is null then
    raise exception 'auth.users fehlt. Lokal zuerst supabase/tests/auth_stub.sql ausführen.';
  end if;
end $$;

-- ------------------------------------------------------ cc.users bereinigen
-- Die globale Spalte "plan" war ein Platzhalter aus Phase 1. Ein Plan gilt
-- aber je Projekt und gehört dem Konto, nicht dem Nutzer: das steht künftig
-- in cc.entitlements. Zwei Quellen für den Plan wären ein Fehler, der nur
-- darauf wartet, zu passieren.
--
-- Nicht still Daten verwerfen: wer einen anderen Plan als 'free' trägt, wäre
-- eine echte Information, die hier verloren ginge.
do $$
declare n bigint;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'cc' and table_name = 'users' and column_name = 'plan') then
    execute 'select count(*) from cc.users where plan <> ''free''' into n;
    if n > 0 then
      raise exception 'cc.users: % Nutzer mit einem anderen Plan als free. Erst nach cc.entitlements übertragen.', n;
    end if;
  end if;

  select count(*) into n
    from cc.users u
   where not exists (select 1 from auth.users a where a.id = u.id);
  if n > 0 then
    raise exception 'cc.users: % Nutzer ohne passenden auth.users-Eintrag. Erst bereinigen.', n;
  end if;
end $$;

alter table cc.users drop column if exists plan;

-- cc.users.id ist die Nutzer-ID aus Supabase Auth. Wird der Auth-Nutzer
-- gelöscht, verschwindet auch sein Eintrag hier.
alter table cc.users
  add constraint users_auth_fk foreign key (id) references auth.users(id) on delete cascade;

comment on table cc.users is
  'Ein Nutzer aus Supabase Auth (id = auth.users.id). Trägt keinen Plan: der steht in cc.entitlements am Konto.';

-- Sitzungen dürfen das Löschen eines Nutzers nicht blockieren. Die Sitzung
-- bleibt als anonyme Sitzung für die Auswertung erhalten.
alter table cc.sessions drop constraint if exists sessions_user_id_fkey;
alter table cc.sessions
  add constraint sessions_user_id_fkey foreign key (user_id)
  references cc.users(id) on delete set null;

-- ------------------------------------------------------------------ Konten
create table cc.accounts (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('personal', 'organization')),
  -- Nur bei persönlichen Konten: der eine Besitzer. Wird er gelöscht, geht
  -- sein persönliches Konto mit.
  personal_owner uuid references cc.users(id) on delete cascade,
  name           text check (name is null or length(name) between 1 and 200),
  created_at     timestamptz not null default now(),
  disabled_at    timestamptz,
  check ((kind = 'personal') = (personal_owner is not null))
);

-- Höchstens ein persönliches Konto je Nutzer.
create unique index accounts_personal_owner_uq on cc.accounts (personal_owner)
  where personal_owner is not null;

comment on table cc.accounts is
  'Besitzt Kontingent und Tour-Ledger. personal = genau ein Nutzer; organization = Business/Fleet (später).';

create table cc.account_members (
  account_id uuid not null references cc.accounts(id) on delete cascade,
  user_id    uuid not null references cc.users(id)    on delete cascade,
  role       text not null check (role in ('owner', 'admin', 'member')),
  created_at timestamptz not null default now(),
  primary key (account_id, user_id)
);

create index account_members_user_idx on cc.account_members (user_id);

comment on table cc.account_members is
  'Wer ein Konto und damit dessen Kontingent nutzen darf.';
