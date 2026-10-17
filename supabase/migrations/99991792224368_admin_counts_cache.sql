-- Take the admin badge counts off the request path.
--
-- MEASURED CAUSE. `pg_stat_statements` ranks `get_admin_counts()` at **4.9% of
-- all database execution time** -- 3,232 calls in ~8h at a 1,117ms mean. It is
-- the third-largest consumer on the instance, behind only
-- `search_reindex_drain` (8.9%) and one PostgREST RPC.
--
-- WHY IT COSTS THAT. The function recomputes everything from scratch on every
-- call: a `pg_class` estimate sweep, then a LOOP over all 17 active
-- `triage_sources` running `count(*)` plus a filtered `count(*)` over each
-- triage VIEW by dynamic SQL, then ~10 further full-corpus counts
-- (`community_submissions`, `group_join_requests`, `entity_existence_audit`,
-- `tag_editorial_queue`, `triage_src_quality_personality`,
-- `event_quality_issues`). That is ~44 aggregates per call.
--
-- WHY IT IS CALLED SO OFTEN. `useAdminCounts` (src/hooks/useAdminCounts.ts) is
-- the single shared wrapper -- sidebar badges, command palette and cockpit
-- widgets all read it -- and it carries `refetchInterval: 60_000`. So every
-- open admin tab costs one full sweep per minute; 3,232 calls / 8h is ~6.7 per
-- minute, i.e. roughly six or seven admin tabs open. Nobody is misusing it;
-- the per-call cost is simply far too high for a badge.
--
-- CALM-STATE COST IS 260ms, NOT 1,117ms, and the difference matters for how
-- this is justified. Measured on a quiet instance: min 174ms / avg 260ms / max
-- 597ms over 5 runs. The 1,117ms mean in `pg_stat_statements` is inflated by
-- the saturation storms this database suffers (see below). So the honest
-- saving is ~9,700 calls/day x 260ms = **~42 min/day of database time at rest**,
-- rising to ~3h/day when measured at the storm mean -- against 288 refreshes/day
-- x 260ms = **75 seconds/day** after this change.
--
-- THE SECOND-ORDER REASON IS THE BIGGER ONE. This instance periodically
-- saturates: 47 active backends, zero lock contention, no worker-pool errors
-- and no self-overlapping cron runs -- pure CPU/IO exhaustion. During a storm
-- every admin tab still fires this sweep once a minute at >1s each, so the
-- badge probe is one of the loads feeding the condition that makes it slow.
-- Taking it off the request path removes a contributor, not just a cost.
--
-- WHAT THIS IS NOT. It is NOT a cron fix. The crons on this instance were
-- investigated first and are not misconfigured: they are already staggered
-- (`2-59/5`, `3-59/5`, `4-59/5`, `8-59/10`, `4-59/10`, `11-59/15`), no job
-- overlaps itself (every heavy one is advisory-locked, and 24h of
-- `cron.job_run_details` contains zero self-overlaps), and the 24-jobs-at-794s
-- signature that looks like a convoy is jobs being STARVED, not jobs being
-- expensive -- `avg_dur_s` equals `max_dur_s` across 20+ unrelated jobs, which
-- only happens when they share one queue and are released together. Ranking
-- jobs by total duration ranks victims. Do not re-derive that.
--
-- THE CACHE HOLDS THE WHOLE PAYLOAD, NOT PER-KEY COLUMNS, and that is the
-- load-bearing design choice. The payload is 60 keys today: ~18 `pg_class`
-- estimates keyed by table name, 2 keys per active triage source
-- (`<prefix><key>` and `<prefix><key>_overdue`, so the set MOVES when a source
-- is registered), 8 static gates, and a nested `sla_hours` object. Decomposing
-- that into columns would be a reimplementation that silently drifts the first
-- time someone adds a `triage_sources` row. Storing the function's own output
-- verbatim means the cached numbers are not a reimplementation of the counts,
-- they ARE the counts -- the same argument `99991792000410` makes for the
-- review-queue cache, and the reason every key survives by construction.
--
-- A SHAPE TEST WOULD NOT HAVE CAUGHT A DROPPED KEY. `adminQueues.test.ts`
-- asserts `ADMIN_QUEUES` matches a hardcoded `EXPECTED_COUNT_KEYS` list -- TS
-- config against TS constant. It never calls the RPC, so a cache that lost
-- keys would pass it. The postcondition at the foot of this file compares the
-- cached key set against a LIVE compute instead.
--
-- STALENESS IS VISIBLE, NOT HIDDEN. The reader adds `counts_as_of`, the same
-- field the review-queue cache exposes. `*/5` is chosen over the review
-- queue's `*/10` because these are glanceable badges and the compute is only
-- 260ms, so a tighter cadence costs 75s/day instead of 37s/day -- and over
-- `*/2` because this scheduler is already busy and a 5-minute-old badge count
-- is not meaningfully worse than a 2-minute-old one.
--
-- EMPTY CACHE FALLS BACK TO A LIVE COMPUTE, so the first call after deploy is
-- correct rather than blank, and the migration SEEDS the row at the end so
-- that path is not taken in practice (an empty cache plus six polling tabs
-- would otherwise be a thundering herd on deploy). A cache that merely goes
-- STALE is served as-is with its age in `counts_as_of`: freezing numbers is
-- better than six tabs each recomputing when the refresher is down, which is
-- the exact failure this file exists to prevent.

-- ------------------------------------------------------------------- cache
create table if not exists public.admin_counts_cache (
  id          boolean     primary key default true,
  payload     jsonb       not null,
  computed_at timestamptz not null default now(),
  constraint admin_counts_cache_singleton check (id)
);

comment on table public.admin_counts_cache is
  'Single-row cache of the get_admin_counts() payload. Refreshed by '
  'refresh_admin_counts() on the admin_counts_refresh cron. Holds the whole '
  'jsonb verbatim so the key set cannot drift from the computation.';

alter table public.admin_counts_cache enable row level security;
revoke all on table public.admin_counts_cache from anon, authenticated;

-- --------------------------------------------------------------- computation
-- The previous get_admin_counts() body, verbatim, minus the role check: the
-- caller is now either the cron (service_role) or the reader below, which
-- performs its own check. Keeping the expressions byte-identical is what makes
-- the correctness argument short.
create or replace function public.admin_counts_compute()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  result jsonb; estimates jsonb; v_sla jsonb := '{}'::jsonb;
  v_cnt bigint; v_overdue bigint; r record;
  sla_feedback_h constant int := 48;
  sla_event_quality_h constant int := 336;
begin
  select jsonb_object_agg(relname,reltuples::bigint) into estimates
  from pg_class where relnamespace='public'::regnamespace and relname=any(array[
    'venues','events','news_articles','personalities','cities','countries','hotels',
    'queer_villages','marketplace_listings','community_groups','unified_tags',
    'cms_pages','email_ingestions','workflow_runs','scrape_sources','content_links',
    'community_submissions','redirects']);
  result := coalesce(estimates,'{}'::jsonb);
  for r in select queue_key,view_name,count_key,count_prefix,sla_hours
           from triage_sources where active order by queue_key loop
    execute format(
      'select count(*),count(*) filter(where created_at < now() - %L::interval) from public.%I',
      r.sla_hours || ' hours',r.view_name) into v_cnt,v_overdue;
    result := result || jsonb_build_object(r.count_prefix||r.count_key,v_cnt)
      || jsonb_build_object(r.count_prefix||r.count_key||'_overdue',v_overdue);
    v_sla := v_sla || jsonb_build_object(r.count_key,r.sla_hours);
  end loop;
  result := result || jsonb_build_object(
    'review_feedback',(select count(*) from community_submissions
      where content_type='feedback' and feedback_status in ('new','under_review')),
    'review_feedback_overdue',(select count(*) from community_submissions
      where content_type='feedback' and feedback_status in ('new','under_review')
        and submitted_at < now()-(sla_feedback_h||' hours')::interval),
    'review_group_requests',(select count(*) from group_join_requests where status='pending'),
    'quality_existence',(select count(*) from entity_existence_audit
      where action='flag' and reverted_at is null),
    'quality_glossary',coalesce((select total_count from public.tag_editorial_queue(1,0,null) limit 1),0),
    'quality_personality',(select count(*) from public.triage_src_quality_personality),
    'quality_event',(select count(*) from public.event_quality_issues where status='open'),
    'quality_event_overdue',(select count(*) from public.event_quality_issues
      where status='open' and severity in ('critical','high')
        and detected_at<now()-(sla_event_quality_h||' hours')::interval),
    'sla_hours',v_sla||jsonb_build_object('feedback',sla_feedback_h,
      'quality_event',sla_event_quality_h)
  );
  return result;
end
$fn$;

revoke all on function public.admin_counts_compute() from public, anon, authenticated;
grant execute on function public.admin_counts_compute() to service_role;

-- ---------------------------------------------------------------- refresher
create or replace function public.refresh_admin_counts()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_payload jsonb;
  v_t0 timestamptz := clock_timestamp();
begin
  -- TRY, not blocking. pg_cron does not serialise across jobs, and a queued
  -- worker turns a stall into a pile-up; a skipped tick is free because the
  -- next one recomputes from scratch anyway (the admin_automation_tracking
  -- precedent).
  if not pg_try_advisory_xact_lock(hashtext('admin_counts_refresh')) then
    return jsonb_build_object('ok', true, 'skipped', 'another refresh holds the lock');
  end if;

  v_payload := public.admin_counts_compute();

  insert into public.admin_counts_cache (id, payload, computed_at)
  values (true, v_payload, now())
  on conflict (id) do update
    set payload = excluded.payload, computed_at = excluded.computed_at;

  return jsonb_build_object(
    'ok', true,
    'keys', (select count(*) from jsonb_object_keys(v_payload)),
    'elapsed_ms', round(extract(epoch from (clock_timestamp()-v_t0))*1000));
end
$fn$;

revoke all on function public.refresh_admin_counts() from public, anon, authenticated;
grant execute on function public.refresh_admin_counts() to service_role;

-- ------------------------------------------------------------------- reader
create or replace function public.get_admin_counts()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_payload jsonb;
  v_as_of   timestamptz;
begin
  if not has_any_role_jwt(array['admin'::app_role,'moderator'::app_role]) then
    raise exception 'unauthorized' using errcode='42501';
  end if;

  select c.payload, c.computed_at into v_payload, v_as_of
  from public.admin_counts_cache c where c.id;

  -- Empty cache only: compute live so the first call after a deploy is correct
  -- rather than blank. A merely STALE cache is served as-is -- see the header.
  if v_payload is null then
    v_payload := public.admin_counts_compute();
    v_as_of   := now();
  end if;

  return v_payload || jsonb_build_object('counts_as_of', v_as_of);
end
$fn$;

-- ------------------------------------------------------------ registry + cron
insert into public.admin_automations (name, slug, description, action, trigger, schedule, enabled, managed_by, can_run_now, can_dry_run)
values (
  'Admin counts refresh',
  'admin_counts_refresh',
  'Recomputes the cached admin badge counts so get_admin_counts does not run ~44 full-corpus aggregates on every poll from every open admin tab.',
  jsonb_build_object('type','rpc','fn','refresh_admin_counts',
                     'command','SELECT public.refresh_admin_counts();',
                     'jobname','admin_counts_refresh'),
  jsonb_build_object('type','schedule'),
  '*/5 * * * *', true, 'system', false, false)
on conflict (slug) do update
  set action = excluded.action, schedule = excluded.schedule,
      description = excluded.description, enabled = true;

-- An action->>'type'='rpc' row cannot be rescheduled by sync_automations_to_cron
-- branch (d), so rpc automations are scheduled by their own migration. Unschedule
-- first so a re-run repoints rather than duplicating.
do $cron$
begin
  perform cron.unschedule('admin_counts_refresh')
  where exists (select 1 from cron.job where jobname='admin_counts_refresh');
  perform cron.schedule('admin_counts_refresh', '*/5 * * * *',
                        'SELECT public.refresh_admin_counts();');
end
$cron$;

-- Seed immediately: an empty cache plus six polling tabs is a thundering herd.
select public.refresh_admin_counts();

-- ------------------------------------------------------------- postconditions
do $verify$
declare
  v_cached  text[];
  v_live    text[];
  v_read    text[];
  v_as_of   timestamptz;
begin
  select array(select jsonb_object_keys(payload) order by 1), computed_at
    into v_cached, v_as_of
  from public.admin_counts_cache where id;

  if v_cached is null then
    raise exception 'admin_counts_cache was not seeded';
  end if;

  v_live := array(select jsonb_object_keys(public.admin_counts_compute()) order by 1);

  -- The whole point: the cached key set IS the computed key set. A shape test
  -- over TS constants cannot assert this.
  if v_cached is distinct from v_live then
    raise exception 'cached key set differs from a live compute: cached=% live=%',
      v_cached, v_live;
  end if;

  -- Exercise the READER, not just the table. A migration carries no JWT, so the
  -- role check would raise 42501 first and the assertion would be vacuous;
  -- claim admin for this transaction only (the 61000301100200 precedent).
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","user_role":"admin"}', true);

  v_read := array(select jsonb_object_keys(public.get_admin_counts()) order by 1);

  if not (v_cached <@ v_read) then
    raise exception 'reader dropped keys the cache holds: cache=% reader=%',
      v_cached, v_read;
  end if;

  if not ('counts_as_of' = any(v_read)) then
    raise exception 'reader does not expose counts_as_of, so staleness would be invisible';
  end if;

  if array_length(v_read,1) <> array_length(v_cached,1) + 1 then
    raise exception 'reader returned % keys, expected cache(%) + counts_as_of',
      array_length(v_read,1), array_length(v_cached,1);
  end if;
end
$verify$;
