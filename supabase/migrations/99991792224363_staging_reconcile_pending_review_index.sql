-- run_staging_reconcile_committed read 2.1 GB of buffers every 5 minutes to do nothing, against
-- a 2 GB shared_buffers. One run could evict the entire cache. That is how a single cron job
-- took the whole database down three times on 2026-10-16.
--
-- THE PILE-UP THEORY IS FALSE, AND THE ADVISORY LOCK WAS NEVER MISSING. The obvious reading of
-- a */5 job running 15 minutes is that three more fire on top of it, and that reading was the
-- starting hypothesis here. It cannot happen: the function has opened with
-- pg_try_advisory_xact_lock(hashtext('staging_reconcile_committed')) since the migration that
-- created it (50600101100000, line 60), so an overlapping firing returns
-- {"skipped": ...} in milliseconds. The run_details agree -- in the 22:00 hour the MINIMUM
-- duration was 11.3s, not sub-second, so nothing was skipping on the lock. Adding a lock would
-- have been a no-op shipped as a fix.
--
-- TWO OF THE THREE HEADLINE DURATIONS ARE NOT QUERY TIMES AT ALL. From cron.job_run_details:
--
--   21:07:05  527.9s  job_pid NULL   'job startup timeout'
--   21:34:00  675.6s  job_pid NULL   'job startup timeout'
--   22:29:00  896.4s  job_pid 50079  'canceling statement due to statement timeout'
--   19:29:00  120.0s  job_pid 187833 'canceling ...' CONTEXT: SQL statement "WITH cand AS"
--
-- A NULL job_pid means pg_cron never forked a backend, so the first two measure the instance
-- being saturated and not this function executing. The apparent 527 -> 675 -> 896 growth trend
-- is therefore an artifact of mixing the two. The honest execution ceiling is the 19:29 run:
-- exactly 120.0s, the instance-wide statement_timeout from
-- /etc/postgresql-custom/platform-defaults.conf, hit inside Class A. The 896s run died in
-- `jsonb_build...`, i.e. the closing still_pending count. Saturation that hour was instance-wide
-- and not this job alone: 122 startup timeouts across 60 DISTINCT jobs in the 22:00 hour.
--
-- WHAT IT ACTUALLY COSTS. Three predicates on ingestion_staging (1,573 MB, ~299k rows), none of
-- them indexed, EXPLAIN (ANALYZE, BUFFERS) on prod:
--
--   Class A  15,457 ms  165,852 buffers  -> 0 rows   Index Scan ingestion_staging_target_record_idx
--                                                    Rows Removed by Filter: 164,467
--   Class B   3,170 ms   32,465 buffers  -> 0 rows   Bitmap Heap Scan idx_ingestion_staging_disposition
--                                                    Rows Removed by Filter: 64,173
--   count     1,545 ms   69,425 buffers  -> 16 rows  Seq Scan
--                                                    Rows Removed by Filter: 235,203
--   total    ~20,170 ms  267,742 buffers (~2.1 GB)
--
-- Class A is the instructive one. Its index is (target_record_id, target_table, created_at)
-- WHERE target_record_id IS NOT NULL, so the planner uses it to answer `target_record_id IS NOT
-- NULL` -- 164,467 rows -- and then heap-fetches every one of them to test `review_status`,
-- which is not in that index, and discards all of them. EVERY ONE of the seven EXISTS subplans
-- reports "never executed": the target-table re-resolution that looks like the expense costs
-- nothing. The expense is reading 164k heap tuples to evaluate one unindexed column.
--
-- THE JOB IS SLOWEST EXACTLY WHEN IT IS CAUGHT UP -- the same inversion recorded in
-- 99991789897895 for search_embeddings_reconcile, which is why that file is worth reading next
-- to this one. LIMIT p_batch short-circuits only when rows flow. Measured distribution:
--
--   review_status='pending_review' -> 16 rows, ALL disposition='pending', ALL target_record_id NULL
--
-- so Class A (needs target_record_id NOT NULL) and Class B (needs disposition='rejected') match
-- ZERO rows by construction, the LIMIT never trips, and both scans always run to completion. A
-- real backlog would make this job look fast. p_batch=2000 was never the lever.
--
-- THE FIX IS ONE 16 kB PARTIAL INDEX on the predicate all three queries share. Measured on prod
-- by creating it, re-running all three, and forcing a ROLLBACK so nothing committed:
--
--   Class A  15,457 ms -> 0.175 ms   165,852 -> 17 buffers   (Index Only Scan)
--   Class B   3,170 ms -> 0.081 ms    32,465 -> 17 buffers
--   count     1,545 ms -> 0.062 ms    69,425 ->  7 buffers   (Index Only Scan)
--   total    ~20,170 ms -> 0.32 ms   267,742 -> 41 buffers   (2.1 GB -> 328 kB, ~6,500x)
--
-- It is PARTIAL, not a plain (review_status, created_at), so its size stays proportional to the
-- pending backlog rather than to the corpus: 16 kB today against ~5 MB for the full-table form.
-- When the queue does back up the scan cost grows with the queue, which is the correct shape and
-- the point of 99991789897895.
--
-- WHY NO EXISTING INDEX SERVES IT, checked rather than assumed. Of the 17 indexes on this table
-- the two that name review_status -- idx_ingestion_staging_review_pending_pending
-- (review_status, disposition) and idx_ingestion_staging_triage (created_at DESC) -- are both
-- partial on `review_status='pending_review' AND disposition='pending'`. Class A has no
-- disposition predicate, Class B asks for disposition='rejected', and the count has neither, so
-- all three are excluded from those indexes by construction. Nothing is dropped here: those two
-- have other readers, and removing an index is not this file's change to make.
--
-- MEASURED AND REJECTED: `SET enable_indexonlyscan TO 'off'` on the function. This instance has
-- a recorded history of the stale-visibility-map / index-only-scan pathology, and that was the
-- first thing checked. It is not this. ingestion_staging is relallvisible 68,291 of 69,425 pages
-- (98%), its plans are a plain Index Scan and a Bitmap Heap Scan, and the defect is a missing
-- index rather than a mis-costed one. Disabling index-only scans would make this STRICTLY worse:
-- the fix above lands as an Index Only Scan.
--
-- MEASURED AND REJECTED: lowering p_batch or relaxing the */5 cadence. Both treat the symptom.
-- The work is 0 rows and the scans ignore the LIMIT, so a smaller batch changes nothing, and a
-- longer interval only reduces how often 2.1 GB is thrown away. At 0.32 ms per run neither
-- number needs to move, and the schedule and p_batch=2000 are deliberately left untouched so
-- this file's effect is attributable to the index alone.
--
-- NOT DONE, on instruction and on merit: widening statement_timeout, or teaching the health
-- checks to tolerate the slow run. The 120s cancel was the only thing bounding the damage.
--
-- BUILD COST: 2,054 ms measured on prod (again in a rolled-back transaction). CREATE INDEX takes
-- SHARE on ingestion_staging and blocks writes for that long; the ingest pipeline writes here
-- continuously. CONCURRENTLY is unavailable because migrations run inside a transaction. Two
-- seconds of blocked writes is cheaper than the 15s this job already spends every 5 minutes.
--
-- NOT FIXED HERE, named rather than left implied:
--   * The instance-wide contention itself. 60 distinct jobs hit startup timeouts in one hour;
--     autovacuum on the 902 MB search_embeddings and search_reindex_drain were both in
--     pg_stat_activity during a slow window per 99991792179076. This change removes one large
--     contributor -- it does not claim to fix the convoy, and a before/after on wall clock would
--     be dishonest on an instance whose load varies by an order of magnitude within the hour,
--     for exactly the reasons that migration records.
--   * public.cities is relallvisible 1,521 of 3,870 pages (39%) with 872 dead tuples and no
--     recorded vacuum. That IS the stale-VM shape, it is unrelated to this job's plans, and
--     VACUUM cannot run inside a migration.
--
-- ROLLBACK: drop index public.idx_ingestion_staging_pending_review;

create index if not exists idx_ingestion_staging_pending_review
  on public.ingestion_staging (created_at)
  where review_status = 'pending_review';

comment on index public.idx_ingestion_staging_pending_review is
  'Serves all three scans in run_staging_reconcile_committed (both cand CTEs and the closing '
  'still_pending count). Partial so its size tracks the pending backlog, not the corpus. '
  'Before: 267,742 buffers / ~20s per run. After: 41 buffers / 0.32 ms. See 99991792224363.';

do $verify$
declare
  v_plan text;
begin
  -- Hard postcondition 1: the index exists.
  if not exists (
    select 1 from pg_indexes
     where schemaname = 'public'
       and tablename  = 'ingestion_staging'
       and indexname  = 'idx_ingestion_staging_pending_review'
  ) then
    raise exception 'idx_ingestion_staging_pending_review is missing after this migration';
  end if;

  -- Hard postcondition 2: the planner actually USES it. A present-but-unused index is the
  -- failure this file exists to remove, and it reads identically to a fixed job from the
  -- index list alone. The closing count is probed because it was the CHEAPEST of the three
  -- scans and still read 541 MB; if this one is served from the index, the two heavier
  -- predicates -- which share the same leading predicate -- are reachable too.
  execute $q$explain (format json)
            select count(*) from public.ingestion_staging
             where review_status = 'pending_review'$q$
     into v_plan;

  if v_plan like '%Seq Scan%' then
    raise exception 'still_pending count still seq-scans ingestion_staging: %', v_plan;
  end if;

  if v_plan not like '%idx_ingestion_staging_pending_review%' then
    raise exception 'still_pending count does not use the new index: %', v_plan;
  end if;
end $verify$;
