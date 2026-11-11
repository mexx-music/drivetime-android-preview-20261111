-- Stammdaten für das erste Projekt. Mehrfach ausführbar.
-- Preise bewusst NICHT gesetzt: sie werden erst eingetragen, wenn die
-- aktuelle Preisliste des Anbieters vorliegt. Ohne Preis bleibt
-- cost_estimate schlicht null – das ist ehrlicher als ein geratener Wert.

insert into cc.projects (key, name) values ('drivetime', 'DriveTime Arrival')
  on conflict (key) do nothing;

insert into cc.providers (key, name, billing_source) values
  ('google-maps', 'Google Maps Platform', 'manual')
  on conflict (key) do nothing;

insert into cc.services (provider_id, key, name, unit)
select p.id, v.key, v.name, v.unit
  from cc.providers p,
       (values
         ('directions',           'Directions API',        'request'),
         ('geocode',              'Geocoding API',         'request'),
         ('places-autocomplete',  'Places Autocomplete',   'request')
       ) as v(key, name, unit)
 where p.key = 'google-maps'
on conflict (provider_id, key) do nothing;

insert into cc.project_settings (project_id)
select id from cc.projects where key = 'drivetime'
on conflict (project_id) do nothing;
