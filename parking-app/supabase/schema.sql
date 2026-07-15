-- ParkRadar — socle P0 de la couche communautaire Supabase.
--
-- Ce script est idempotent et migre aussi le premier schéma public. L'app lit
-- la RPC agrégée et écrit via l'Edge Function. Un repli historique ne peut être
-- réactivé que pendant une migration contrôlée (COMMUNITY_LEGACY_FALLBACK).

begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.parking_events (
  id          bigint generated always as identity primary key,
  event_type  text not null check (event_type in ('parked', 'freed')),
  lat         double precision not null check (lat between -90 and 90),
  lon         double precision not null check (lon between -180 and 180),
  created_at  timestamptz not null default now()
);

-- Le jeton aléatoire de l'installation n'est jamais conservé en clair. Les
-- anciennes lignes restent nulles et sont purgées après environ 24 h.
alter table public.parking_events
  add column if not exists reporter_hash text;
alter table public.parking_events
  add column if not exists reporter_ip_hash text;

create index if not exists parking_events_recent_idx
  on public.parking_events (created_at desc);
create index if not exists parking_events_bbox_recent_idx
  on public.parking_events (lat, lon, created_at desc);
create index if not exists parking_events_reporter_recent_idx
  on public.parking_events (reporter_hash, created_at desc)
  where reporter_hash is not null;
create index if not exists parking_events_reporter_ip_recent_idx
  on public.parking_events (reporter_ip_hash, created_at desc)
  where reporter_ip_hash is not null;

alter table public.parking_events enable row level security;

-- Migration de l'ancien modèle « lecture/écriture anonyme de la table brute ».
drop policy if exists "lecture publique des événements"
  on public.parking_events;
drop policy if exists "signalement public"
  on public.parking_events;
revoke all on table public.parking_events from public, anon, authenticated;
do $$
declare
  v_sequence text;
begin
  v_sequence := pg_get_serial_sequence('public.parking_events', 'id');
  if v_sequence is not null then
    execute format(
      'revoke usage, select on sequence %s from public, anon, authenticated',
      v_sequence
    );
  end if;
end;
$$;

-- Supprime l'ancienne surcharge éventuellement déployée avant le passage par
-- Edge Function. Elle ne doit surtout pas conserver un grant anonyme.
drop function if exists public.report_parking_event(
  text, double precision, double precision, text
);
drop function if exists public.report_parking_event(
  text, double precision, double precision, text, text
);

-- Insertion contrôlée, appelable uniquement par la clé service_role détenue
-- dans l'Edge Function :
--   * coordonnées quantifiées à 3 décimales (~70–110 m à Paris),
--   * 1 événement / 20 s et 30 / h par installation,
--   * 1 événement / 2 s et 120 / h par IP hachée,
--   * 12 événements / minute et cellule pour limiter les rafales.
create or replace function public.report_parking_event(
  p_event_type text,
  p_lat double precision,
  p_lon double precision,
  p_client_token text,
  p_ip_hash text,
  p_dry_run boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_reporter_hash text;
  v_ip_hash text;
  v_lat double precision;
  v_lon double precision;
  v_inserted_id bigint;
begin
  if p_event_type is null or p_event_type not in ('parked', 'freed') then
    raise exception using
      errcode = '22023', message = 'invalid_event_type';
  end if;
  if p_lat is null or p_lon is null
      or p_lat::text in ('NaN', 'Infinity', '-Infinity')
      or p_lon::text in ('NaN', 'Infinity', '-Infinity')
      or p_lat < 48.80 or p_lat > 48.91
      or p_lon < 2.22 or p_lon > 2.47 then
    raise exception using
      errcode = '22023', message = 'invalid_coordinates';
  end if;
  if p_client_token is null
      or length(p_client_token) < 32
      or length(p_client_token) > 128 then
    raise exception using
      errcode = '22023', message = 'invalid_client_token';
  end if;
  if p_ip_hash is null or p_ip_hash !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode = '22023', message = 'invalid_ip_hash';
  end if;

  v_reporter_hash := encode(
    extensions.digest(convert_to(p_client_token, 'UTF8'), 'sha256'),
    'hex'
  );
  v_ip_hash := p_ip_hash;
  v_lat := round(p_lat::numeric, 3)::double precision;
  v_lon := round(p_lon::numeric, 3)::double precision;

  -- Les verrous non bloquants sérialisent les rafales sans laisser un abuseur
  -- remplir la file de connexions PostgREST.
  if not pg_try_advisory_xact_lock(hashtext(v_reporter_hash)::bigint) then
    raise exception using errcode = 'P0001', message = 'rate_limit_busy';
  end if;
  if not pg_try_advisory_xact_lock(hashtext('ip:' || v_ip_hash)::bigint) then
    raise exception using errcode = 'P0001', message = 'rate_limit_busy';
  end if;

  -- Sérialise aussi les auteurs différents qui ciblent la même cellule afin
  -- que la limite spatiale reste atomique sous concurrence.
  if not pg_try_advisory_xact_lock(
    hashtext('cell:' || v_lat::text || ':' || v_lon::text)::bigint
  ) then
    raise exception using errcode = 'P0001', message = 'rate_limit_busy';
  end if;

  -- La sonde de santé utilise une identité synthétique dédiée et ne doit pas
  -- dépendre du trafic réel d'une cellule. Elle traverse néanmoins les
  -- verrous, contraintes et éventuels triggers de la vraie table.
  if not coalesce(p_dry_run, false) then
    if exists (
      select 1
      from public.parking_events pe
      where pe.reporter_hash = v_reporter_hash
        and pe.created_at > now() - interval '20 seconds'
    ) then
      raise exception using errcode = 'P0001', message = 'rate_limit_short';
    end if;

    if (
      select count(*)
      from public.parking_events pe
      where pe.reporter_hash = v_reporter_hash
        and pe.created_at > now() - interval '1 hour'
    ) >= 30 then
      raise exception using errcode = 'P0001', message = 'rate_limit_hour';
    end if;

    if exists (
      select 1
      from public.parking_events pe
      where pe.reporter_ip_hash = v_ip_hash
        and pe.created_at > now() - interval '2 seconds'
    ) then
      raise exception using errcode = 'P0001', message = 'rate_limit_ip_short';
    end if;

    if (
      select count(*)
      from public.parking_events pe
      where pe.reporter_ip_hash = v_ip_hash
        and pe.created_at > now() - interval '1 hour'
    ) >= 120 then
      raise exception using errcode = 'P0001', message = 'rate_limit_ip_hour';
    end if;

    if (
      select count(*)
      from public.parking_events pe
      where pe.lat = v_lat and pe.lon = v_lon
        and pe.created_at > now() - interval '1 minute'
    ) >= 12 then
      raise exception using errcode = 'P0001', message = 'rate_limit_cell';
    end if;
  end if;

  insert into public.parking_events (
    event_type,
    lat,
    lon,
    reporter_hash,
    reporter_ip_hash
  ) values (
    p_event_type,
    v_lat,
    v_lon,
    v_reporter_hash,
    v_ip_hash
  ) returning id into v_inserted_id;

  -- Dans la transaction de la RPC, la ligne de sonde n'est jamais visible à
  -- un autre lecteur et n'est pas conservée. Une erreur d'INSERT ou de DELETE
  -- fait échouer et annule toute la transaction.
  if coalesce(p_dry_run, false) then
    delete from public.parking_events where id = v_inserted_id;
  end if;

  return true;
end;
$$;

-- Lecture publique uniquement sous forme de cellules agrégées, limitée à un
-- petit rectangle, 15 minutes et 200 groupes. La position exacte n'est jamais
-- exposée, y compris si un ancien client a envoyé davantage de précision.
create or replace function public.recent_parking_events(
  p_min_lat double precision,
  p_max_lat double precision,
  p_min_lon double precision,
  p_max_lon double precision,
  p_max_age_seconds integer default 900,
  p_limit integer default 200
)
returns table (
  event_type text,
  lat double precision,
  lon double precision,
  created_at timestamptz,
  report_count integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_max_age_seconds integer;
  v_limit integer;
begin
  if p_min_lat is null or p_max_lat is null
      or p_min_lon is null or p_max_lon is null
      or p_min_lat < -90 or p_max_lat > 90
      or p_min_lon < -180 or p_max_lon > 180
      or p_min_lat >= p_max_lat or p_min_lon >= p_max_lon
      or p_max_lat - p_min_lat > 0.1
      or p_max_lon - p_min_lon > 0.1 then
    raise exception using errcode = '22023', message = 'invalid_bounds';
  end if;

  v_max_age_seconds := least(greatest(coalesce(p_max_age_seconds, 900), 1), 900);
  v_limit := least(greatest(coalesce(p_limit, 200), 1), 200);

  return query
  with latest_per_reporter as (
    select
      pe.event_type,
      round(pe.lat::numeric, 3)::double precision as cell_lat,
      round(pe.lon::numeric, 3)::double precision as cell_lon,
      pe.created_at,
      pe.reporter_hash,
      pe.reporter_ip_hash,
      row_number() over (
        partition by
          round(pe.lat::numeric, 3),
          round(pe.lon::numeric, 3),
          coalesce(pe.reporter_hash, 'legacy:' || pe.id::text)
        order by pe.created_at desc, pe.id desc
      ) as reporter_rank
    from public.parking_events pe
    where pe.created_at >= now() - make_interval(secs => v_max_age_seconds)
      and pe.lat between p_min_lat and p_max_lat
      and pe.lon between p_min_lon and p_max_lon
  ), grouped as (
    select
      latest.event_type,
      latest.cell_lat,
      latest.cell_lon,
      date_trunc('minute', latest.created_at) as public_minute,
      max(latest.created_at) as latest_at_exact,
      greatest(
        1,
        least(
          count(distinct latest.reporter_hash),
          count(distinct latest.reporter_ip_hash) * 2,
          100
        )
      )::integer as corroboration_count
    from latest_per_reporter latest
    where latest.reporter_rank = 1
    group by
      latest.event_type,
      latest.cell_lat,
      latest.cell_lon,
      date_trunc('minute', latest.created_at)
  )
  select
    grouped.event_type,
    grouped.cell_lat,
    grouped.cell_lon,
    grouped.public_minute,
    grouped.corroboration_count
  from grouped
  -- Les flux « garé » et « libéré » ainsi que les minutes restent des groupes
  -- distincts. Un événement récent ne donne donc pas artificiellement son âge
  -- à des corroborations presque expirées et ne masque pas le type opposé.
  order by grouped.latest_at_exact desc, grouped.event_type
  limit v_limit;
end;
$$;

create or replace function public.purge_expired_parking_events()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_deleted bigint;
begin
  delete from public.parking_events
  where created_at < now() - interval '24 hours';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.report_parking_event(
  text, double precision, double precision, text, text, boolean
) from public, anon, authenticated, service_role;
revoke all on function public.recent_parking_events(
  double precision, double precision, double precision, double precision,
  integer, integer
) from public, anon, authenticated, service_role;
revoke all on function public.purge_expired_parking_events()
  from public, anon, authenticated, service_role;

grant execute on function public.report_parking_event(
  text, double precision, double precision, text, text, boolean
) to service_role;
grant execute on function public.recent_parking_events(
  double precision, double precision, double precision, double precision,
  integer, integer
) to anon, authenticated;
grant execute on function public.purge_expired_parking_events()
  to service_role;

-- La rétention est un invariant de confidentialité, pas une opération
-- manuelle. Le module Supabase Cron doit être activé avant cette migration ;
-- cron.schedule remplace le job existant lorsqu'il porte le même nom. Une
-- exécution par minute borne le dépassement théorique du TTL à moins de 60 s.
select cron.schedule(
  'parkradar-purge-expired-events',
  '* * * * *',
  $$select public.purge_expired_parking_events()$$
);
update cron.job
set active = true
where jobname = 'parkradar-purge-expired-events'
  and username = current_user;

create or replace function public.community_backend_health()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with purge_status as (
    select details.status, details.end_time
    from cron.job job
    left join lateral (
      select run.status, run.end_time
      from cron.job_run_details run
      where run.jobid = job.jobid
        and run.end_time is not null
      order by run.runid desc
      limit 1
    ) details on true
    where job.jobname = 'parkradar-purge-expired-events'
      and job.username = current_user
      and job.active
      and job.schedule = '* * * * *'
      and job.command = 'select public.purge_expired_parking_events()'
    limit 1
  )
  select jsonb_build_object(
    'schema_version', '2026-07-p0-v4',
    'purge_job_active', exists (
      select 1
      from cron.job
      where jobname = 'parkradar-purge-expired-events'
        and username = current_user
        and active
        and schedule = '* * * * *'
        and command = 'select public.purge_expired_parking_events()'
    ),
    'purge_last_run_at', (select end_time from purge_status),
    'purge_last_run_succeeded', coalesce((
      select status = 'succeeded'
        and end_time >= now() - interval '3 minutes'
      from purge_status
    ), false),
    'anon_table_access',
      has_table_privilege('anon', 'public.parking_events', 'select')
      or has_table_privilege('anon', 'public.parking_events', 'insert')
      or has_table_privilege('anon', 'public.parking_events', 'update')
      or has_table_privilege('anon', 'public.parking_events', 'delete'),
    'authenticated_table_access',
      has_table_privilege('authenticated', 'public.parking_events', 'select')
      or has_table_privilege('authenticated', 'public.parking_events', 'insert')
      or has_table_privilege('authenticated', 'public.parking_events', 'update')
      or has_table_privilege('authenticated', 'public.parking_events', 'delete'),
    'anon_report_execute', has_function_privilege(
      'anon',
      'public.report_parking_event(text,double precision,double precision,text,text,boolean)',
      'execute'
    ),
    'authenticated_report_execute', has_function_privilege(
      'authenticated',
      'public.report_parking_event(text,double precision,double precision,text,text,boolean)',
      'execute'
    ),
    'service_report_execute', has_function_privilege(
      'service_role',
      'public.report_parking_event(text,double precision,double precision,text,text,boolean)',
      'execute'
    )
  );
$$;

-- Sonde privée appelée par l'Edge Function. Le contrôle de current_user évite
-- qu'une clé publishable placée par erreur dans SUPABASE_SERVICE_ROLE_KEY ne
-- produise un faux diagnostic vert.
create or replace function public.community_edge_health()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
begin
  if current_user <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  return public.community_backend_health();
end;
$$;

revoke all on function public.community_backend_health()
  from public, anon, authenticated, service_role;
revoke all on function public.community_edge_health()
  from public, anon, authenticated, service_role;
grant execute on function public.community_backend_health()
  to anon, authenticated, service_role;
grant execute on function public.community_edge_health()
  to service_role;

comment on function public.report_parking_event(
  text, double precision, double precision, text, text, boolean
) is 'Insertion ParkRadar via Edge, limitée par installation, IP et cellule.';
comment on function public.recent_parking_events(
  double precision, double precision, double precision, double precision,
  integer, integer
) is 'Événements ParkRadar récents agrégés, sans accès à la table brute.';
comment on function public.community_backend_health()
is 'Version, purge et privilèges clients du backend communautaire ParkRadar.';
comment on function public.community_edge_health()
is 'Sonde privée attestant que l Edge Function utilise réellement service_role.';

commit;

-- Défense complémentaire avant une forte montée en charge : attestation
-- Apple/Google et détection d'anomalies distribuées. IP, installation et
-- cellule limitent déjà les abus courants, mais pas un réseau Sybil complet.
