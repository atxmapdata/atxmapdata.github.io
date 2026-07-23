-- =============================================================================
-- Civic loader scheduling (pg_cron)  --  project "Parcels" (aqbyxpiwugcvoephsvpm)
-- =============================================================================
-- Source of truth for the in-database civic ETL schedule. Applied live 2026-07-23.
--
-- The existing loaders (parcels/zoning/flum/streets_load_step, zoning/flum_join_step)
-- are one-shot, self-idling backfill steppers: each call advances ONE page, guarded
-- by a per-loader advisory lock, and returns 'already complete' (a no-op) once its
-- *_load_state.completed flag is set. Nothing resets the cursor, so once a dataset
-- finishes it never re-fetches -- i.e. this schedule performs BACKFILL COMPLETION,
-- not recurring refresh. (For refresh, add a periodic cursor-reset job; see bottom.)
--
-- Idempotent: safe to re-run. `create or replace` + cron.schedule upsert-by-name.
-- =============================================================================

-- 1) Orchestrator: one cron entry point that advances every incomplete loader/joiner
--    by a page, in dependency order (joiners self-wait on their load completing).
--    PARCELS IS INTENTIONALLY EXCLUDED: its load cursor is vestigial (parcels were
--    bulk-loaded via another path) and resuming parcels_load_step would needlessly
--    re-page the Travis County TCAD server. Add it back only if you truly want a full
--    TCAD re-walk. Each step is isolated so one transient HTTP error can't mask others.
--    search_path is pinned (public visible so the called steps resolve http_*/st_*;
--    pg_temp for the joiners' temp tables) -- also clears the mutable-search-path lint.
create or replace function public.pipeline_tick()
returns text
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_out text := '';
begin
  begin v_out := v_out || 'zoning_load='  || public.zoning_load_step(1000)  || '; ';
  exception when others then v_out := v_out || 'zoning_load=ERR:'  || left(sqlerrm,100) || '; '; end;

  begin v_out := v_out || 'flum_load='    || public.flum_load_step(1000)    || '; ';
  exception when others then v_out := v_out || 'flum_load=ERR:'    || left(sqlerrm,100) || '; '; end;

  begin v_out := v_out || 'streets_load=' || public.streets_load_step(2000) || '; ';
  exception when others then v_out := v_out || 'streets_load=ERR:' || left(sqlerrm,100) || '; '; end;

  begin v_out := v_out || 'zoning_join='  || public.zoning_join_step(5000)  || '; ';
  exception when others then v_out := v_out || 'zoning_join=ERR:'  || left(sqlerrm,100) || '; '; end;

  begin v_out := v_out || 'flum_join='    || public.flum_join_step(5000)    || '; ';
  exception when others then v_out := v_out || 'flum_join=ERR:'    || left(sqlerrm,100) || '; '; end;

  return v_out;
end $$;

-- 2) Schedule: every 2 minutes. Cheap no-op (~0.0s) once all backfills are complete;
--    only does external fetches while a loader is mid-backfill (advisory lock prevents
--    overlap with a manual run). cron.schedule upserts by job name.
select cron.schedule('civic_pipeline_tick', '*/2 * * * *', 'select public.pipeline_tick()');

-- -----------------------------------------------------------------------------
-- Operations
-- -----------------------------------------------------------------------------
-- Inspect the job:
--   select jobid, jobname, schedule, active, command from cron.job
--   where jobname = 'civic_pipeline_tick';
--
-- Recent runs (health):
--   select runid, status, return_message, start_time,
--          round(extract(epoch from (end_time - start_time))::numeric,1) as secs
--   from cron.job_run_details
--   where jobid = (select jobid from cron.job where jobname='civic_pipeline_tick')
--   order by start_time desc limit 12;
--
-- Loader progress:
--   select 'streets' src, completed, next_offset::text cur, last_result, updated_at
--     from public.streets_load_state where id=1
--   union all select 'zoning', completed, next_offset::text, last_result, updated_at
--     from public.zoning_load_state where id=1
--   union all select 'flum',   completed, next_offset::text, last_result, updated_at
--     from public.flum_load_state where id=1;
--
-- Pause / remove:
--   update cron.job set active = false where jobname = 'civic_pipeline_tick';  -- pause
--   select cron.unschedule('civic_pipeline_tick');                            -- remove
--
-- -----------------------------------------------------------------------------
-- Adding recurring refresh (NOT enabled -- opt-in later)
-- -----------------------------------------------------------------------------
-- The steppers only backfill once. To make a dataset re-pull for freshness, reset
-- its cursor on a cadence; the every-2-min tick above then re-pages it, and the
-- joiners must be reset too so parcels re-derive their zoning_base/flum_code:
--
--   -- weekly, Sundays 08:00 UTC: re-pull zoning + flum + streets, then rejoin
--   select cron.schedule('civic_refresh_reset', '0 8 * * 0', $$
--     update public.zoning_load_state  set completed=false, next_offset=0    where id=1;
--     update public.flum_load_state    set completed=false, next_offset=0    where id=1;
--     update public.streets_load_state set completed=false, next_offset=0    where id=1;
--     update public.zoning_join_state  set completed=false, last_parcel_id='' where id=1;
--     update public.flum_join_state    set completed=false, last_parcel_id='' where id=1;
--   $$);
--
-- Note: these loaders send NO Socrata app token, so a full re-page is unauthenticated
-- and subject to throttling. Consider adding X-App-Token before scheduling refresh.
