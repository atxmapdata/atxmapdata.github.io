# Plumbing blueprint: Claude ⇄ QGIS ⇄ Supabase PostGIS, cloud-first via GitHub Actions

## Context
The user has QGIS 3.44 connected to Claude (qgis-mcp) and a **paid Supabase account already
holding parcel data**. They want a system that pulls Austin civic open data + live/real-time
feeds into Supabase PostGIS and drives automated multi-layer webmaps. They develop **cloud-first
with GitHub + GitHub Actions**; local dev exists but the production pipeline must run from GitHub,
not depend on a local QGIS being open. This document is the **plumbing/architecture blueprint** —
the decided foundation before we build any one vertical. Focus domains: **Austin civic + live ops**.

## Decisions (locked, with the reasoning)
1. **One Supabase project, multi-schema** (not a separate project). Parcels are the join backbone
   for civic/live (permits↔parcel, 311↔parcel, incidents↔parcel). Within a project, cross-schema
   spatial joins are free; across projects they need `postgres_fdw`. Because ingestion runs in
   GitHub Actions/Edge Functions (not a heavy local process), there is no compute-competition
   reason to split. Parcels stay in their existing schema, **read-only** to the pipeline role.
2. **Cloud-first execution: a GitHub repo + scheduled GitHub Actions is the pipeline runner.**
   The ETL is standalone Python in the repo (requests + Fiona/GDAL + psycopg2), not QGIS
   `execute_code`. QGIS-MCP (local) is the **authoring/QA surface**: connect to the live PostGIS,
   style, validate, build print/atlas, and prototype a transform before lifting it into the repo.
3. **Connect through the Supabase pooler, never the direct host.** GitHub Actions runners are
   IPv4-only and Supabase's direct DB host is IPv6-only → Actions must use
   `aws-0-<region>.pooler.supabase.com` (session mode for migrations, transaction mode for
   short-lived jobs), user `postgres.<project-ref>`. Missing this = every workflow hangs on connect.
4. **Refresh cadence by data speed.** Civic "current" → Actions cron (~*/15). "Live" → an
   Edge Function on `pg_cron` (~1 min) or a tiny always-on worker (Fly.io) for sub-minute; GitHub
   Actions cron (5-min min, best-effort) is too coarse for second-level vehicle tracking. Civic
   slice is built first; the live-cadence choice is deferred to the live slice.
5. **Publish cloud-first.** Static/large layers → **PMTiles** built by a publish Action, served from
   **GitHub Pages** MapLibre site (or Supabase Storage). **Live** layers → **Supabase Realtime**
   from that same Pages site. **Claude Artifact** for quick throwaway shares.
6. **Protect the parcel data.** A dedicated DB role (`etl_writer`) can write only to
   `staging`/`gis`/`live` and has **read-only** access to the parcels schema. No pipeline DDL or
   upsert ever targets parcel tables. Anon key + **RLS** for the public read path; service key
   stays in GitHub Secrets / Edge Functions only.

## Schema design (one project)
- `parcels` — existing data, untouched, read-only to pipelines (the join backbone)
- `staging` — raw pulls (as-fetched)
- `gis` — published/cleaned civic layers (311, permits, incidents, inspections…)
- `live` — streaming current-state (e.g. `vehicle_positions`, one row/vehicle) + optional
  append-only history for playback; tables added to the `supabase_realtime` publication
- Every geometry table: `geom geometry(Geometry,4326)`, `GIST` index, natural unique key
  (`socrata_id`), `updated_at timestamptz`; refresh = `INSERT … ON CONFLICT (socrata_id) DO UPDATE`
- `meta.sync_state` — per-feed cursor (max `:updated_at`), last-run, row counts (freshness dashboard)
- DDL lives as **versioned SQL migrations** in the repo, applied via the **Supabase CLI**
  (`supabase db push`) from a workflow — schema is code.

## Repo layout (sketch)
```
atx-gis/
  supabase/migrations/*.sql        # schema as versioned SQL (parcels untouched)
  pipelines/
    common/{db.py, soda.py}        # pooler connection, SODA client (paged, app-token, :updated_at)
    civic/ingest_<dataset>.py      # fetch -> normalize geom -> upsert -> advance sync_state
    live/ingest_gtfs.py            # GTFS-rt protobuf -> upsert live.vehicle_positions
    publish/build_pmtiles.py       # PostGIS -> GeoJSON/FlatGeobuf -> PMTiles
  web/                             # MapLibre GL site (GitHub Pages): PMTiles + Realtime + PostgREST
  .github/workflows/
    migrate.yml                    # on push to main -> supabase db push
    civic-sync.yml                 # schedule */15 -> run civic ingest
    live-sync.yml                  # schedule */5 (or Edge Fn for sub-minute)
    publish.yml                    # rebuild PMTiles + deploy Pages
  tests/
```

## Secrets (GitHub Secrets)
`SUPABASE_DB_URL` (pooler, IPv4) · `SUPABASE_SERVICE_KEY` · `SUPABASE_ANON_KEY` ·
`SOCRATA_APP_TOKEN`. The Pages site ships only the anon key + project URL (safe with RLS).

## Ingest specifics
- **Civic (SODA):** `https://data.austintexas.gov/resource/<id>.geojson?$where=:updated_at>'<cursor>'
  &$order=:id&$limit=50000&$offset=…`, `X-App-Token` header, paginate, upsert, advance cursor.
  Candidate datasets (confirm IDs at kickoff): Austin 311 unified; ATD real-time traffic incidents
  (a good civic↔live bridge); issued construction permits; low-water crossings / flood.
- **Live (GTFS-rt):** CapMetro VehiclePositions protobuf, decode with `gtfs-realtime-bindings`,
  upsert `live.vehicle_positions` (ON CONFLICT vehicle_id) → Realtime pushes to the map.

## Publish / read path
- Static: `publish/build_pmtiles.py` (PostGIS → PMTiles) committed/pushed to Pages or Storage;
  MapLibre reads the single PMTiles file (CDN-cheap). Modest layers may use a PostgREST GeoJSON RPC.
- Live: MapLibre + `@supabase/supabase-js` Realtime channel updates a GeoJSON source in place.
- The QGIS house style (QML / `layer_styles` table) is hand-mapped to the MapLibre style so web
  and QGIS print/atlas share one look.

## QGIS-MCP role (local authoring/QA — not production)
Connect to the live PostGIS (via pooler), style categorized/graduated layers, label, QA row
counts/geometry validity, build print layouts + atlas (per-council-district PDF packets), and
prototype transforms that then get lifted into `pipelines/`.

## First slice (proof of the whole loop — safe, civic-only, no parcel writes)
1. Add migrations for `staging`/`gis`/`meta` + the restricted `etl_writer` role (parcels read-only).
2. Repo scaffold + `common/{db,soda}` + one `civic/ingest_<dataset>.py` for a single Austin dataset.
3. `civic-sync.yml` on `*/15`; run once → backfill → confirm rows + `sync_state` advance.
4. `publish/build_pmtiles.py` + `web/` MapLibre + `publish.yml` → GitHub Pages map (or a Claude
   Artifact for the first look).
5. QGIS: connect to the new `gis` layer, confirm it renders live, style it once.
This proves ingest → store → publish → automate on one dataset; civic breadth = repeat step 2,
live ops = add the `live/` slice with its cadence choice.

## To confirm at kickoff (not blocking the blueprint)
- Supabase **project ref + region** (drives the pooler host) and whether parcels sit in `public`
  or a named schema; provide `SUPABASE_DB_URL` via Secrets, not chat.
- GitHub repo name/visibility (private recommended).
- Live-cadence tolerance (accept ~5 min via Actions, or go Edge Function/worker for sub-minute).
- Exact Austin dataset IDs for the first civic slice.

## Verification
- Migrations: `supabase db push` succeeds; `select postgis_version();`; parcels schema unchanged;
  `etl_writer` cannot write to parcels (negative test).
- Ingest: workflow run green; `gis.<table>` row count > 0; `meta.sync_state` cursor advanced;
  re-run is idempotent (no dupes, ON CONFLICT works).
- QGIS: load `gis.<table>` via pooler, `get_layer_features` + `render_map`/`get_canvas_screenshot`.
- Web: Pages map (or Artifact) renders the layer; (live slice) markers move via Realtime.
```
```
