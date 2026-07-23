# atxmapdata.github.io

Web maps and tools built on one Austin civic **parcel database** (Supabase / PostGIS):
375,210 parcels joined with zoning, FLUM, streets, census, flood zones and 2.19M rows of
appraisal history — plus a knowledge graph and vector embeddings.

**Live map → https://atxmapdata.github.io/**
An Austin ZIP-level parcel atlas that reads **live** from the database through a PostgREST
GeoJSON endpoint (`public.zip_value_geojson`), shaded by average appraised value or parcel count.

The database is the product; this page is one view onto it — the same data can drive many more.
See [`PLAN.md`](PLAN.md) for the architecture and [`db/`](db/) for the SQL that runs inside the
database (the pg_cron loader schedule, the map cache, and RLS).
