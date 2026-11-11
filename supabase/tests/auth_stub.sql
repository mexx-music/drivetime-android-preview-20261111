-- NUR für lokale Testdatenbanken: ein minimaler Ersatz für Supabase Auth.
--
-- In Supabase existiert auth.users bereits und gehört Supabase. Diese Datei
-- bricht dort ab, statt irgendetwas anzulegen.
--
-- Reihenfolge lokal: auth_stub.sql → supabase/migrations/*.sql → Tests.
-- Enthält bewusst keine psql-Befehle, damit auch ein Treiber sie ausführen kann.

do $$
begin
  if exists (select 1 from pg_roles where rolname in ('supabase_auth_admin', 'supabase_admin')) then
    raise exception 'auth_stub.sql ist nur für lokale Tests und darf nicht in Supabase laufen';
  end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key,
  email text
);

comment on table auth.users is 'Lokaler Test-Ersatz für Supabase Auth (supabase/tests/auth_stub.sql).';
