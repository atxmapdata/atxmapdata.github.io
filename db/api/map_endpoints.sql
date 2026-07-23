-- =============================================================================
-- Public web-map API  --  project "Parcels" (aqbyxpiwugcvoephsvpm)   applied 2026-07-23
-- =============================================================================
-- Backs the live map at https://atxmapdata.github.io/. The map fetches
-- public.zip_value_geojson() via PostgREST with the publishable (anon) key.
--
-- Aggregating 375k parcels per request blew the anon statement timeout, so the
-- heavy build is cached: refresh_zip_value_geojson() (definer role, scheduled)
-- writes the FeatureCollection into map_cache; the public RPC just reads that row.
-- =============================================================================

create table if not exists public.map_cache(
  key        text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.map_cache enable row level security;
drop policy if exists "public read" on public.map_cache;
create policy "public read" on public.map_cache for select using (true);

-- Heavy builder — runs as definer (no anon timeout). ZIP areas + live parcel
-- count and average appraised value, as one GeoJSON FeatureCollection.
create or replace function public.refresh_zip_value_geojson()
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.map_cache(key, data, updated_at)
  values ('zip_value', (
    select jsonb_build_object(
      'type','FeatureCollection',
      'features', coalesce(jsonb_agg(
        jsonb_build_object(
          'type','Feature',
          'geometry', st_asgeojson(st_simplify(z.geom, 0.0004), 6)::jsonb,
          'properties', jsonb_build_object(
            'zipcode', z.zipcode,
            'parcels', coalesce(a.parcels, 0),
            'avg_value', a.avg_value)
        )), '[]'::jsonb))
    from public.zip_codes z
    left join (
      select zip, count(*)::int as parcels, round(avg(appr_market_val))::bigint as avg_value
      from public.parcels
      where zip is not null and appr_market_val > 0
      group by zip
    ) a on a.zip = z.zipcode
    where z.geom is not null
  ), now())
  on conflict (key) do update set data = excluded.data, updated_at = now();
$$;

-- Fast public endpoint the browser calls (anon-executable). Reads the cache only.
create or replace function public.zip_value_geojson()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select data from public.map_cache where key = 'zip_value';
$$;

grant  execute on function public.zip_value_geojson()          to anon, authenticated;
revoke execute on function public.refresh_zip_value_geojson()  from anon, authenticated;

-- Populate now, and keep it fresh daily (pg_cron).
select public.refresh_zip_value_geojson();
select cron.schedule('refresh_map_cache', '17 9 * * *', 'select public.refresh_zip_value_geojson()');
