-- content_revisions grew to 6.25M machine rows / 3.6 GB in 4 weeks. The 90-day
-- horizon in 50010101100100 was sized from "~5k revisions/day"; measured
-- 2026-10-12 it is ~255k/day (a one-off 2026-10-11 org-spine backfill spiked it
-- to 452k). At 578 B/row all-in (heap + 3 indexes) that is ~13 GB at 90 days on
-- a 21 GB database, not the 290 MB CLAUDE.md claimed.
--
-- ── WHERE THE VOLUME IS (system rows, last 24h, measured) ────────────────────
--   marketplace_listings  143.5k  96% change ONLY quality_dimensions_at
--   events                 37.8k  96% change ONLY last_verified_at
--   organizations         ~13k/d  recurring completeness_score churn (left alone)
-- Both big sources are heartbeat timestamps: the row did not change, a checker
-- looked at it. The evidence of the check lives in the *_quality_signals
-- ledgers; a revision that says "timestamp moved" is not a revert target.
--
-- ── WHAT THIS DOES ──────────────────────────────────────────────────────────
-- 1. Adds those two columns to ignore_columns. The trigger already drops an
--    UPDATE whose ONLY changes are ignored columns, so these writes record
--    nothing, while a real change to the same row (price, title, status) is
--    still recorded. That is strictly better than excluding the table, which
--    would lose marketplace edits entirely.
-- 2. Retention 90d -> 21d for actor_kind='system'. human/declared untouched.
-- 3. The prune could never keep up: 20000/night against 255k/day. It now runs
--    hourly at 50000 (1.2M/day capacity) and drains the existing backlog.
--    Hourly rather than a bigger nightly batch keeps each delete short.
--
-- DELETE does not shrink the file: freed space is recycled by new inserts, so
-- the 3.6 GB stays allocated until a VACUUM FULL / pg_repack (not run here,
-- both lock the table).

BEGIN;

UPDATE public.content_versioned_tables t
   SET ignore_columns = (
     SELECT array_agg(DISTINCT c ORDER BY c)
       FROM unnest(t.ignore_columns || ARRAY[v.col]) AS c
   )
  FROM (VALUES
    ('marketplace_listings', 'quality_dimensions_at'),
    ('events',               'last_verified_at')
  ) AS v(tbl, col)
 WHERE t.table_name = v.tbl;

CREATE OR REPLACE FUNCTION public.run_content_revision_prune(
  p_batch      integer DEFAULT 50000,
  p_keep_days  integer DEFAULT 21
) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_deleted   bigint;
  v_remaining bigint;
BEGIN
  WITH doomed AS (
    SELECT id FROM public.content_revisions
     WHERE actor_kind = 'system'
       AND created_at < now() - make_interval(days => greatest(p_keep_days, 1))
     ORDER BY created_at
     LIMIT greatest(p_batch, 1)
  )
  DELETE FROM public.content_revisions r USING doomed d WHERE r.id = d.id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  SELECT count(*) INTO v_remaining
    FROM public.content_revisions
   WHERE actor_kind = 'system'
     AND created_at < now() - make_interval(days => greatest(p_keep_days, 1));

  RETURN jsonb_build_object('deleted', v_deleted, 'remaining', v_remaining, 'keep_days', p_keep_days);
END $$;

REVOKE ALL ON FUNCTION public.run_content_revision_prune(integer, integer) FROM PUBLIC, anon, authenticated;

-- Registry is canonical; the live job is moved to match in the same statement
-- group so the nightly reconciler finds no drift.
UPDATE public.admin_automations
   SET schedule    = '20 * * * *',
       description = 'Deletes system-actor content revisions older than 21 days, 50k per hour. Human and declared revisions are never pruned — they are the record a revert reads.',
       action      = jsonb_set(action, '{command}', to_jsonb('SELECT public.run_content_revision_prune(50000, 21);'::text))
 WHERE slug = 'content_revision_prune';

SELECT cron.alter_job(
  job_id   := (SELECT jobid FROM cron.job WHERE jobname = 'content_revision_prune'),
  schedule := '20 * * * *',
  command  := 'SELECT public.run_content_revision_prune(50000, 21);'
);

DO $verify$
DECLARE
  v_args  text;
  v_cron  text;
  v_reg   text;
  v_ml    text[];
  v_ev    text[];
BEGIN
  SELECT pg_get_function_arguments('public.run_content_revision_prune(integer,integer)'::regprocedure) INTO v_args;
  IF v_args NOT LIKE '%p_keep_days integer DEFAULT 21%' OR v_args NOT LIKE '%p_batch integer DEFAULT 50000%' THEN
    RAISE EXCEPTION 'prune defaults not applied: %', v_args;
  END IF;

  SELECT command INTO v_cron FROM cron.job WHERE jobname = 'content_revision_prune';
  SELECT action->>'command' INTO v_reg FROM public.admin_automations WHERE slug = 'content_revision_prune';
  IF v_cron IS NULL OR v_cron IS DISTINCT FROM v_reg OR v_cron NOT LIKE '%(50000, 21)%' THEN
    RAISE EXCEPTION 'live cron and registry disagree or not updated: cron=% registry=%', v_cron, v_reg;
  END IF;
  IF (SELECT schedule FROM cron.job WHERE jobname = 'content_revision_prune') IS DISTINCT FROM '20 * * * *' THEN
    RAISE EXCEPTION 'live cron schedule not hourly';
  END IF;

  SELECT ignore_columns INTO v_ml FROM public.content_versioned_tables WHERE table_name = 'marketplace_listings';
  SELECT ignore_columns INTO v_ev FROM public.content_versioned_tables WHERE table_name = 'events';
  IF ('quality_dimensions_at' = ANY (v_ml)) IS NOT TRUE OR ('last_verified_at' = ANY (v_ev)) IS NOT TRUE THEN
    RAISE EXCEPTION 'heartbeat columns not in ignore_columns: ml=% ev=%', v_ml, v_ev;
  END IF;
  -- The rest of the derived-column list must survive the array rewrite.
  IF ('updated_at' = ANY (v_ml) AND 'title_normalized' = ANY (v_ml) AND 'updated_at' = ANY (v_ev)) IS NOT TRUE THEN
    RAISE EXCEPTION 'existing ignore_columns lost: ml=% ev=%', v_ml, v_ev;
  END IF;
END $verify$;

COMMIT;
