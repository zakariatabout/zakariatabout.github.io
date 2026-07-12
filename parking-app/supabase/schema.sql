-- ParkRadar — schéma Supabase de la couche communautaire.
-- À exécuter dans le SQL Editor d'un projet Supabase (comme Tennis AI Coach).
-- Puis compiler l'app avec :
--   flutter build web --dart-define=SUPABASE_URL=https://<projet>.supabase.co \
--                     --dart-define=SUPABASE_ANON_KEY=<clé anon>

create table if not exists public.parking_events (
  id          bigint generated always as identity primary key,
  event_type  text        not null check (event_type in ('parked', 'freed')),
  lat         double precision not null check (lat between -90 and 90),
  lon         double precision not null check (lon between -180 and 180),
  created_at  timestamptz not null default now()
);

-- Requêtes de l'app : événements récents dans une boîte englobante.
create index if not exists parking_events_recent_idx
  on public.parking_events (created_at desc);
create index if not exists parking_events_lat_lon_idx
  on public.parking_events (lat, lon);

alter table public.parking_events enable row level security;

-- Signalements anonymes : tout le monde peut lire et écrire des événements,
-- mais uniquement insérer (jamais modifier ni supprimer).
create policy "lecture publique des événements"
  on public.parking_events for select
  to anon using (true);

create policy "signalement public"
  on public.parking_events for insert
  to anon with check (true);

-- Nettoyage : les événements de plus de 24 h n'ont plus de valeur temps réel.
-- (Activer pg_cron dans Database > Extensions, puis :)
-- select cron.schedule('purge-parking-events', '0 4 * * *',
--   $$delete from public.parking_events where created_at < now() - interval '24 hours'$$);
