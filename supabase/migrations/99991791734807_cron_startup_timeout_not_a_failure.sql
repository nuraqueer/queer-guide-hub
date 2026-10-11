-- A pg_cron "job startup timeout" is NOT a failure of the job, and counting it
-- as one auto-paused search_reindex_drain and stopped all of site search.
--
-- WHAT HAPPENED (measured on prod, 2026-10-11)
--   2026-10-10 07:00:27, 07:00:37, 07:01:00 -- three consecutive runs of
--   search_reindex_drain ended in cron.job_run_details as
--   status='failed', return_message='job startup timeout'. That message means
--   pg_cron could not obtain a background worker in time: the command NEVER
--   STARTED. admin_automation_project_cron_runs() projected every 'failed' row
--   as an 'error' run, admin_automation_runs_after_finish() counted them toward
--   auto_pause_threshold=3, set enabled=false and unscheduled the job.
--   The queue then grew for 28 hours: 269,477 rows (~46k distinct entities),
--   so every write since 07:02 -- venues, events, news, marketplace, and the 17
--   cities an admin merged that day -- stayed stale in search_documents. The
--   merged cities kept appearing in /admin/governance?mode=merge because the
--   cluster finder groups search_documents, not cities.
--   In the trailing 7 days 'job startup timeout' hit 14 distinct jobs (18 runs),
--   so the drain was the first victim, not the only candidate.
--
-- THE RULE
--   Same class as a pg_net `timed_out` response, which this repo already
--   records as 'partial' and never counts: absence of evidence, not evidence of
--   failure. A startup timeout says something about the worker pool at that
--   instant and nothing about the job. It is now projected as status='partial'
--   with summary.reason='cron_startup_timeout', which bumps
--   consecutive_partials (nothing pauses on that -- verified: the only reader is
--   admin_automation_runs_after_finish) and leaves consecutive_failures alone.
--
-- COST, stated rather than hidden
--   A job that can PERMANENTLY not start never auto-pauses. That is the right
--   error: pausing does not give it a worker either, it only also stops it from
--   running once the pool frees up. It stays visible as a run of 'partial' rows.
--
-- HOW
--   Patched from pg_get_functiondef() with exactly-once anchors, never restated:
--   the live body is the source of truth and a restatement from a repo file is
--   how later string-surgery patches get silently reverted.

do $patch$
declare
  v_src  text;
  v_code text;
  v_new  text;
  -- anchor 1: the status literal in the failed-branch INSERT
  a1_old constant text := E'a.id, a.slug, ''error'', coalesce(d.start_time, now()),';
  a1_new constant text := E'a.id, a.slug,\n          case when d.return_message = ''job startup timeout'' then ''partial'' else ''error'' end,\n          coalesce(d.start_time, now()),';
  -- anchor 2: the failed-branch summary (the linking branch uses 'cron_source',
  -- the sampled-success branch adds 'sampled', so this literal is unique)
  a2_old constant text := E'jsonb_build_object(''source'', ''cron.job_run_details'')';
  a2_new constant text := E'jsonb_build_object(''source'', ''cron.job_run_details'')\n            || case when d.return_message = ''job startup timeout''\n                    then jsonb_build_object(''reason'', ''cron_startup_timeout'')\n                    else ''{}''::jsonb end';
  -- anchor 3: the error tally
  a3_old constant text := E'v_errors := v_errors + 1;';
  a3_new constant text := E'if d.return_message is distinct from ''job startup timeout'' then\n          v_errors := v_errors + 1;\n        end if;';

begin
  -- Every check reads a comment-stripped copy: a comment quoting an anchor
  -- must neither satisfy the idempotency test nor inflate an anchor count.
  v_code := regexp_replace(
    pg_get_functiondef('public.admin_automation_project_cron_runs(integer)'::regprocedure),
    '--[^' || chr(10) || ']*', '', 'g');

  if position('cron_startup_timeout' in v_code) > 0 then
    raise notice 'admin_automation_project_cron_runs already patched; skipping';
    return;
  end if;

  if (length(v_code) - length(replace(v_code, a1_old, ''))) / length(a1_old) <> 1 then
    raise exception 'anchor 1 (failed-branch status literal) not found exactly once';
  end if;
  if (length(v_code) - length(replace(v_code, a2_old, ''))) / length(a2_old) <> 1 then
    raise exception 'anchor 2 (failed-branch summary) not found exactly once';
  end if;
  if (length(v_code) - length(replace(v_code, a3_old, ''))) / length(a3_old) <> 1 then
    raise exception 'anchor 3 (v_errors tally) not found exactly once';
  end if;

  -- the patch itself is applied to the live body verbatim
  v_src := pg_get_functiondef('public.admin_automation_project_cron_runs(integer)'::regprocedure);
  v_new := replace(replace(replace(v_src, a1_old, a1_new), a2_old, a2_new), a3_old, a3_new);
  execute v_new;
end
$patch$;

do $verify$
declare
  v_src text;
begin
  -- comments stripped so a header quoting the rule cannot satisfy the check
  v_src := regexp_replace(
    pg_get_functiondef('public.admin_automation_project_cron_runs(integer)'::regprocedure),
    '--[^\n]*', '', 'g');

  if position(E'when d.return_message = ''job startup timeout'' then ''partial'' else ''error'' end' in v_src) = 0 then
    raise exception 'postcondition: startup timeout is not projected as partial';
  end if;
  if position(E'if d.return_message is distinct from ''job startup timeout'' then' in v_src) = 0 then
    raise exception 'postcondition: startup timeout still counted in v_errors';
  end if;
  if position(E'''reason'', ''cron_startup_timeout''' in v_src) = 0 then
    raise exception 'postcondition: startup timeout runs are not labelled';
  end if;
  -- a real failure must still be an error
  if position(E'else ''error'' end' in v_src) = 0 then
    raise exception 'postcondition: genuine failures no longer projected as error';
  end if;
end
$verify$;
