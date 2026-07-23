# Plumbing blueprint: Claude ⇄ QGIS ⇄ Supabase PostGIS, cloud-first via GitHub Actions

> **Reanalyzed 2026-07-23 against the CORRECT database.** Prior versions of this plan were
> built against the wrong Supabase project (`pubchat` / `tqnklodtiithbsxxyycp`, FREE). This
> version reflects live discovery on the PAID target: org `cityanatomyservices`, project
> **`Parcels`**, ref **`aqbyxpiwugcvoephsvpm`**, URL `https://aqbyxpiwugcvoephsvpm.supabase.co`.
> **Key finding: this database already implements most of the civic pipeline this plan set out
> to build** — so the plan is now "extend what exists," not "build greenfield." This DB backs the
> live site **austingraph.github.io**; all changes are strictly additive (see Hard Constraints).

## Context
QGIS 3.44 connected to Claude (qgis-mcp) + a paid Supabase project already holding Austin parcel
data. Goal: pull Austin civic open data + live/real-time feeds into Supabase PostGIS and drive
automated multi-layer webmaps, developed **cloud-first with GitHub + GitHub Actions** (the
production pipeline must not depend on a local QGIS). Focus domains: **Austin civic + live ops**.

## Verified environment (discovery 2026-07-23, correct DB)
- **Postgres 17.6** (aarch64) · **PostGIS 3.3.7** (GEOS 3.14.1, PROJ 9.7.1).
- **pgvector `vector 0.8.0` installed** — `parcel_embeddings.embedding vector(1536)`, ivfflat
  cosine index (`lists=100`). 40k embeddings over 101k `parcel_documents` (backfill partial).
- **`pg_cron 1.6.4` installed**, but `cron.job` is **empty** — nothing is currently scheduled.
- **`http 1.6` installed** (public schema) and used by the existing in-DB loaders. **`pg_net`
  NOT installed** (loaders use synchronous `http`, not async `pg_net`).
- **No migration history** — `supabase_migrations` is empty; the schema was built ad-hoc, not via
  the Supabase CLI. "Schema as code" requires baselining the existing objects first.
- **Realtime**: `supabase_realtime` publication exists with **0 tables** (no live slice yet).
- **Region: AWS `us-west-2`** → pooler host `aws-0-us-west-2.pooler.supabase.com`, user
  `postgres.aqbyxpiwugcvoephsvpm` (session mode for migrations, transaction mode for short jobs).

## What already exists (the correction — inventory of `public`)
The join backbone and civic layers are **already built and already joined onto parcels**:
- **`parcels`** (375,210) — PK `parcel_id text`; **dual geometry** `geom MULTIPOLYGON,4326` +
  `centroid POINT,4326`, both GIST. Already denormalized with `zoning_base`, `zoning_ztype`,
  `multi_zoned`, `flum_code/flum_label`, `upzoning_flag/upzoning_gap`, a full `appr_*` appraisal
  block (market/land/impr/assessed/taxable vals, owner_name/state, yr_built, neighborhood,
  deed_date…), and `sitecheck_flood/watershed/jurisdiction`, `zip`. Extra btree indexes on
  `flum_code`, `zoning_base`, `upzoning_flag`, `appr_neighborhood`, `zip`.
- **Civic layers (all SRID 4326):** `zoning` (22,494) + `zoning_rules`/`zoning_intensity`,
  `flum` (79,835) + `flum_categories`, `streets` (68,511, MULTILINESTRING), `census_blocks`
  (16,906) / `census_block_groups` (766), `flood_zones` (9,315), `overlay_watershed`,
  `overlay_jurisdiction`, `zip_codes`, `market_context`.
- **`parcel_appraisal_history`** (2,188,389) — PK `(parcel_id, yr)`; long time series.
- **RAG layer:** `parcel_documents` (101,094) + `parcel_embeddings` (pgvector, above) +
  `match_parcel_documents()` RPC.
- **Knowledge graph:** `kg_nodes` (149,859: `node_type`/`external_id`/`parcel_id`/`label`/jsonb)
  + `kg_edges` (108,203: `from_node`/`to_node`/`edge_type`/`weight`/jsonb), uniquely indexed.
  `kg_ingest_state` shows active ingest of **permits, zoning_cases, votes** (last runs Jun–Jul 2026).
- **Public API already serving the site:** SECURITY DEFINER RPCs `parcel_demographics`,
  `parcel_market_context`, `parcel_value_context`, `parcel_value_history`, `redev_score`,
  `redev_candidate_count`, `redev_candidates_geojson`, `flum_select_geojson`,
  `absentee_select_geojson`, `zoning_district`, `link_point_to_parcel`; view `parcel_zoning_bases`.

## Decisions (locked, with reasoning — revised for the real DB)
1. **One Supabase project, multi-schema.** Unchanged and already true: parcels are the join
   backbone; cross-schema spatial joins stay in-project. Parcels remain read-only to any new
   pipeline role.
2. **Hybrid execution — match the runner to the data (revised).** The existing **in-database**
   civic loaders (`*_load_step`/`*_join_step` plpgsql using `http` + `*_load_state` cursors) are
   **kept and scheduled via `pg_cron`** (they currently run only on manual invocation — the
   scheduling is the gap to close). **New** work that benefits from real tooling — the live
   GTFS-rt slice and the PMTiles publish — runs as **standalone Python in GitHub Actions**.
   QGIS-MCP (local) stays the authoring/QA surface. *(Supersedes the original "all ETL is Python
   in Actions" decision, which conflicted with the working in-DB pipeline.)*
3. **Connect through the Supabase pooler, never the direct host.** GitHub Actions runners are
   IPv4-only; the direct DB host is IPv6-only → Actions use `aws-0-us-west-2.pooler.supabase.com`
   (session mode for migrations, transaction mode for short jobs), user
   `postgres.aqbyxpiwugcvoephsvpm`. Region confirmed **AWS us-west-2**.
4. **Refresh cadence by data speed.** Civic "current" → `pg_cron` on the in-DB loaders (or Actions
   cron ~*/15 for new Python jobs). "Live" → Edge Function on `pg_cron` (~1 min) or a small
   always-on worker for sub-minute; Actions cron (5-min floor) is too coarse for vehicle tracking.
5. **Publish cloud-first.** Static/large layers → **PMTiles** built by a publish Action, served
   from **GitHub Pages** MapLibre site. Some layers already have GeoJSON RPCs (reuse them). **Live**
   layers → **Supabase Realtime** (publication is currently empty — greenfield).
6. **Protect existing data.** A dedicated pipeline role writes only to **new** schemas/tables and
   is **read-only** on every existing object; no DDL/upsert targets parcels or the civic/KG tables.
   Service key stays in GitHub Secrets / Edge Functions; anon key + RLS for the public read path.

## Target schema — additive deltas only
Existing `public` objects are **untouched**. New work adds:
- **`live`** — streaming current-state (e.g. `vehicle_positions`, one row/vehicle) + optional
  append-only history for playback; tables added to the `supabase_realtime` publication. (PG17 +
  `pg_partman 5.3` available if history needs time-partitioning.)
- **`staging`/`meta`** — only if a *new* Python civic loader needs raw-pull landing + its own
  sync cursor. Existing civic loaders already have their `*_load_state` cursors in `public`; do
  not duplicate them.
- Every new geometry table: `geom geometry(Geometry,4326)`, GIST index, natural unique key,
  `updated_at timestamptz`; refresh = `INSERT … ON CONFLICT DO UPDATE` (mirror the existing pattern).
- **Baseline migration first:** snapshot the existing schema into `supabase/migrations/0000_baseline.sql`
  so future DDL is versioned without rewriting history. New objects go in numbered migrations after it.

## Existing in-DB pipeline (document + schedule; do not rebuild)
- Loaders `parcels_load_step`, `zoning_load_step`, `flum_load_step`, `streets_load_step` and
  joiners `zoning_join_step`, `flum_join_step`: `http`-fetch → paged offset → upsert → advance the
  matching `*_load_state`/`*_join_state` row, guarded by `pg_try_advisory_lock`. Exact source
  endpoints live in each function body (record them when scheduling).
- State snapshot (2026-07): `zoning`, `flum`, `flum_join`, `zoning_join` = **done**; `streets` and
  `parcels` cursors show **incomplete** (`streets` offset 26000/28000; `parcels` `completed:false`
  at `next_offset=4000` **despite 375k rows present** → parcels were bulk-loaded by a different
  path; the cursor is likely vestigial — **verify before relying on it**).
- **Action:** create `cron.job` entries for the loaders that should run on a cadence (they are
  currently unscheduled), and record the schedules here.

## New work (genuinely greenfield)
- **Live (GTFS-rt):** CapMetro VehiclePositions protobuf → decode (`gtfs-realtime-bindings`) →
  upsert `live.vehicle_positions` (ON CONFLICT vehicle_id) → Supabase Realtime pushes to the map.
- **Publish:** `publish/build_pmtiles.py` (PostGIS → GeoJSON/FlatGeobuf → **PMTiles** via
  tippecanoe) committed to Pages/Storage; MapLibre reads the single PMTiles file. Reuse existing
  GeoJSON RPCs (`flum_select_geojson`, `redev_candidates_geojson`, …) where they already fit.

## Security findings (report-only — Hard-Constraint #3; nothing auto-applied)
Fresh audit on the correct DB. **Decision 2026-07-23:** the project is open-source / non-commercial
and the site is public read-only, so **public READ of civic reference data is accepted and
intended** — RLS is not needed merely to hide it. The one worthwhile hardening is **blocking
anonymous WRITES**: the anon key ships in the public site JS, and on a table with RLS disabled the
`anon` role can also INSERT/UPDATE/DELETE. **Applied 2026-07-23** (migration
`enable_rls_read_only_public_reference_tables`): enabled RLS + a permissive `SELECT`-only policy
(`using (true)`) on the four exposed tables — reads unchanged, anonymous writes now blocked.
Everything below is informational.
- **RLS disabled on PostgREST-exposed tables (ERROR → ✅ RESOLVED 2026-07-23):** `flood_zones`,
  `overlay_watershed`, `overlay_jurisdiction`, `zip_codes` now have RLS + read-only policies
  (reads unchanged, writes blocked). `spatial_ref_sys` (PostGIS system table) intentionally left as-is.
- **SECURITY DEFINER view (ERROR):** `parcel_zoning_bases`.
- **Anon/authenticated-executable SECURITY DEFINER functions (WARN):** `parcel_demographics`,
  `parcel_market_context`, `parcel_value_context`, `parcel_value_history`, `st_estimatedextent*`
  — expose appraisal + owner data via `/rpc/*`. Likely intentional for the site; confirm.
- **Mutable `search_path` (WARN):** ~15 functions (`*_load_step`, `*_join_step`, geojson RPCs,
  `match_parcel_documents`, `redev_*`). Harden with `SET search_path = ''`.
- **Extensions in `public` (WARN):** `postgis`, `vector`, `http`. Note for hardening (moving
  PostGIS is high-risk; usually left as-is on Supabase).
- **RLS-enabled-no-policy (INFO):** `census_blocks`/`census_block_groups` (currently no API
  access — confirm intended) and the `*_load_state`/`*_join_state` cursor tables (fine).

## Hard constraints (this DB backs austingraph.github.io — carry forward)
1. **Strictly additive:** create ONLY new schemas/tables. No DDL on existing objects.
2. **Pipeline role READ-ONLY** on existing tables; writes confined to new schemas.
3. **No RLS/permission change as an auto-applied migration** — report findings + proposed SQL
   separately for review.
4. **No destructive operations** anywhere in the plan.
5. Mark anything unverifiable as **PENDING** rather than assuming.

## Repo layout (sketch)
```
atx-gis/  (repo: atxmapdata.github.io)
  supabase/migrations/
    0000_baseline.sql              # snapshot of existing public schema (versioning baseline)
    0001_live_schema.sql           # new: live.* + realtime publication membership
  pipelines/
    live/ingest_gtfs.py            # GTFS-rt protobuf -> upsert live.vehicle_positions
    publish/build_pmtiles.py       # PostGIS -> GeoJSON/FlatGeobuf -> PMTiles (tippecanoe)
  db/cron/                         # documented pg_cron schedules for existing *_load_step loaders
  web/                             # MapLibre GL site (Pages): PMTiles + Realtime + PostgREST RPCs
  .github/workflows/
    migrate.yml                    # on push to main -> supabase db push (after baseline)
    live-sync.yml                  # schedule (or Edge Fn for sub-minute)
    publish.yml                    # rebuild PMTiles + deploy Pages
  tests/
```

## Secrets (GitHub Secrets)
`SUPABASE_DB_URL` (pooler, IPv4) · `SUPABASE_SERVICE_KEY` · `SUPABASE_ANON_KEY` ·
`SOCRATA_APP_TOKEN`. The Pages site ships only the anon key + project URL (safe once RLS decisions
above are made).

## First slice (proof of the loop — additive, no writes to existing data)
1. Baseline migration `0000_baseline.sql` (snapshot existing schema) so DDL is versioned.
2. Schedule one existing in-DB loader via `pg_cron`; confirm a run advances its `*_load_state`.
3. `0001_live_schema.sql`: `live.vehicle_positions` + add to `supabase_realtime`; `ingest_gtfs.py`
   + `live-sync.yml`; confirm rows + Realtime push.
4. `build_pmtiles.py` + `web/` MapLibre + `publish.yml` → GitHub Pages map (or a Claude Artifact).
5. QGIS: connect to the live PostGIS via pooler, confirm layers render, style once.

## Verification
- Baseline: `supabase db push` succeeds; existing objects unchanged; PostGIS/pgvector intact.
- In-DB loaders: `pg_cron` run green; `*_load_state` cursor advances; re-run idempotent.
- Live: `live.vehicle_positions` row count > 0; markers move via Realtime.
- Publish: Pages map renders the layer; existing GeoJSON RPCs still resolve.
- Security: each report-only finding has a decision + reviewed SQL before any RLS change.

## To confirm at kickoff (not blocking)
- ~~Supabase region~~ **confirmed AWS us-west-2**; still provide `SUPABASE_DB_URL` (pooler) via Secrets, not chat.
- GitHub repo visibility (private recommended for pipeline code).
- Live-cadence tolerance (~5 min via Actions vs Edge Function/worker for sub-minute).
- Exact CapMetro GTFS-rt feed URL for the first live slice; source endpoints inside the existing
  `*_load_step` bodies (for documenting the civic loaders).
