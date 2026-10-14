-- Take the full-corpus review-queue counts off the request path, for BOTH
-- functions that compute them: get_admin_review_queue and, as it turned out,
-- get_admin_review_summary -- which /admin fires on the same navigation and
-- which was observed running three-deep concurrently. The summary half was
-- found while diagnosing the queue, is three times the traffic, and is
-- documented at its own patch block below.
--
-- `get_admin_review_queue` 500s under load because PostgREST's `authenticated`
-- role carries `statement_timeout=8s` and the function costs ~4.4s on a quiet
-- database and 11-14s on a busy one -- the IDENTICAL `overdue` call measured
-- 4.44s and 13.76s twelve minutes apart. That is what reds `Critical paths`
-- on every PR in the repo via `admin-inbox-renders.spec.ts`.
--
-- WHY THE COST IS WHERE IT IS. The query returns 50 rows but computes
-- SCOPE-INDEPENDENT full-corpus aggregates (`all_total`, `findings_total`,
-- `overdue_total`, `safety_total`, and the per-source `sources` array) from a
-- `materialized` union of 41 views over 324,465 rows. Measured: the union
-- alone is 9.55s under load, and a 3-column scan of it is 3012ms -- i.e. the
-- union IS the function. One source dominates: `business-quality` contributes
-- 257,757 rows (79% of the corpus, 1436ms of a 3012ms narrow pass) of which
-- 257,566 are findings, 191 are decisions and only 352 are overdue.
--
-- FOUR CANDIDATE FIXES WERE MEASURED AND REJECTED BEFORE THIS ONE, recorded so
-- they are not re-attempted:
--   1. `filtered as materialized` alone -- output byte-identical, 4.44s ->
--      4.53s. No gain, because `authorized` was already materialized so the
--      union ran once regardless.
--   2. A function-level `SET statement_timeout` in `proconfig`. IMPOSSIBLE,
--      proven rather than reasoned: a probe function carrying
--      `SET statement_timeout TO '30s'` was still cancelled at 3s by an
--      enclosing `set local statement_timeout='3s'`. An already-armed timeout
--      is not re-armed by a GUC change, so NOTHING inside the function can
--      escape the 8s cap. (This also explains why an earlier in-block
--      `set local statement_timeout` appeared not to fire.)
--   3. An index to avoid the 257k-row seq scan. Already indexed --
--      `entity_quality_findings_open_idx` matches the view's predicate, and the
--      planner's seq scan is CORRECT because the query reads essentially every
--      qualifying row.
--   4. A narrow per-branch count aggregate -- 8.03s, WORSE than the whole
--      function, because it does the `admin_review_finding_codes` join 41
--      times instead of once.
--
-- WHAT ACTUALLY WORKS IS FIVE CHANGES THAT ONLY PAY OFF TOGETHER, and the
-- keystone is this table. `counts` reads `authorized`, so while it exists the
-- union must be fully evaluated and `authorized` must stay `materialized` --
-- an optimizer fence. Serving the counts from a cache removes the fence, which
-- lets the scope predicate push down into the 41 branches, which takes
-- `entity_quality_findings` from 257,757 rows to 379. Measured in SHARED
-- BLOCKS, which is load-independent (wall-clock here is not: the same call
-- swings 3x):
--
--   scope=overdue   stock 470,028 blocks  ->  193,574 blocks   2.43x
--
-- and within that, `filtered as materialized` is load-bearing a SECOND time
-- and for a different reason than (1): once `authorized` is no longer
-- materialized, `(select count(*) from filtered)` re-runs the whole union, so
-- without it the win collapses to 442,943 blocks -- `entity_quality_findings`
-- is scanned twice at 379 rows each. With it, once.
--
-- SCOPE OF THE WIN, STATED RATHER THAN IMPLIED: this fixes `overdue` and does
-- NOT measurably help the other scopes. Measured, same instrument:
--   decisions (the landing scope)  471,475 -> 470,750   no change
--   all                            470,932 -> 470,895   no change
-- `decisions` is irreducible by this approach because `not u.is_finding`
-- depends on the `admin_review_finding_codes` join, so the predicate cannot
-- push below it; and finding the 191 non-findings among business-quality's
-- 257,757 rows requires reading all of them, so a seq scan is optimal. An
-- EXISTS/anti-join rewrite of `is_finding` was built and measured at 474,681
-- blocks -- no better -- and is NOT shipped. It would have been semantically
-- safe (`admin_review_finding_codes` has a unique index on
-- (queue_key, subtitle_match) and 0 duplicate pairs, so the LEFT JOIN cannot
-- multiply rows), which is worth recording so the next reader does not have to
-- re-establish it.
--
-- CACHING THE COUNTS THE OBVIOUS WAY WOULD HAVE BROKEN THE TEST THIS EXISTS
-- TO FIX, AND INTERMITTENTLY, WHICH IS WORSE THAN BREAKING IT OUTRIGHT.
-- `admin-inbox-renders.spec.ts` asserts total = decisions_total (landing),
-- total = all_total (scope=all) and total = overdue_total (scope=overdue).
-- Those held because `counts` and `filtered` were two reads of ONE
-- materialized union, so both saw a single snapshot. Serve the counters from a
-- cache and leave `total` live, and all three are true only when the corpus
-- happens not to have moved since the last refresh. Caught by reading the
-- spec's assertions against the new design, not by running it.
--
-- So on an UNFILTERED request `total` is read from the cache too, as the same
-- aggregate as its own scope counter -- the three assertions then hold by
-- construction rather than by luck. It is the right answer independently of
-- the test: a header reading "20,323 overdue" above a list claiming 20,325 is
-- an inconsistency inside ONE response, and internal consistency beats
-- freshness for a number attached to a 327k backlog.
--
-- WHAT STAYS LIVE AND EXACT: the 50 returned rows, always; and `total`
-- whenever a queue_type, content_type or search filter is applied, because the
-- cache has no equivalent for those and a wrong number is worse than a stale
-- one. Verified on prod: a filtered scope=all request returned the real
-- 257,781 while the cache held a dummy 4,100. `counts_as_of` is added to both
-- payloads so the lag is visible rather than hidden.
--
-- ROLE SEMANTICS ARE PRESERVED, which is the easiest thing to get wrong here:
-- the old `counts` was computed over the ROLE-FILTERED union, so a moderator's
-- `all_total` counted only the sources they may see. The cache therefore holds
-- every active source and the function joins `admin_review_sources` with the
-- SAME role predicate it already uses for the `sources` array, rather than
-- summing the table.

-- ---------------------------------------------------------------- the cache
create table if not exists public.admin_review_queue_counts (
  queue_key   text primary key,
  n           bigint      not null default 0,
  late        bigint      not null default 0,
  findings    bigint      not null default 0,
  decisions   bigint      not null default 0,
  safety      bigint      not null default 0,
  computed_at timestamptz not null default now()
);

comment on table public.admin_review_queue_counts is
  'Cached per-source review-queue counts for get_admin_review_queue. Refreshed '
  'by refresh_admin_review_queue_counts() on the admin_review_counts_refresh '
  'cron. Lags one interval by design; the queue page rows and `total` stay '
  'live. Holds EVERY active source -- the reader applies the role filter, '
  'because a moderator must not see counts for sources they cannot read.';

-- Read only through the SECURITY DEFINER reader. No client reaches this table.
alter table public.admin_review_queue_counts enable row level security;
revoke all on table public.admin_review_queue_counts from anon, authenticated;

-- ------------------------------------------------------------- the refresher
create or replace function public.refresh_admin_review_queue_counts()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_union text;
  v_rows  integer;
  v_t0    timestamptz := clock_timestamp();
begin
  -- Only one refresh at a time. pg_cron does not serialise its own jobs, and
  -- this one does a full-corpus scan: two overlapping runs would double the
  -- load this migration exists to remove and then fight over the same 41 rows.
  -- TRY, not blocking -- a skipped tick is free, a queued pg_cron worker turns
  -- a stall into a pile-up (the admin_automation_tracking precedent).
  if not pg_try_advisory_xact_lock(hashtext('admin_review_queue_counts')) then
    return jsonb_build_object('ok', true, 'skipped', 'another refresh holds the lock');
  end if;

  -- THE SHAPE HERE IS LOAD-BEARING AND THE OBVIOUS ONE IS MEASURABLY WORSE.
  -- This is get_admin_review_summary's own pre-cache query, moved behind a
  -- cron: ONE union, ONE hash join to admin_review_finding_codes, group by.
  --
  -- The first draft instead asked each view for its own counts with
  -- `count(*) filter (where exists (select 1 from admin_review_finding_codes
  -- ...))`. That is an aggregate FILTER expression, so it cannot be planned as
  -- a semi-join -- it becomes a correlated subplan evaluated per row, 324k
  -- times, and it does the codes join 41 times instead of once. Measured: it
  -- did not finish inside 60s, against roughly ten for this shape. It is the
  -- same "narrow per-branch count aggregate" that measured 8.03s -- WORSE than
  -- the unpatched function -- while I was choosing between candidate fixes,
  -- and I rebuilt it here without recognising it. Do not re-derive it.
  --
  -- Reusing the old query verbatim also makes the correctness argument short:
  -- the cached numbers are not a reimplementation of the counts, they ARE the
  -- counts, computed by the same expressions over the same views.
  select string_agg(
    format(
      'select u.queue_type,u.subtitle,u.created_at,'
      'coalesce(u.risk_flags->>''risk'',%L)::text risk,%L::integer sla_hours'
      ' from public.%I u',
      r.risk, r.sla_hours, r.view_name),
    ' union all ' order by r.queue_key)
  into v_union
  from public.admin_review_sources r
  where r.active;

  if v_union is null then
    return jsonb_build_object('ok', false, 'reason', 'no active review sources');
  end if;

  -- Driven FROM admin_review_sources with a LEFT JOIN, so a source with zero
  -- items still gets a row of zeros. `group by queue_type` alone emits nothing
  -- for an empty source, which would leave the cache incomplete and make
  -- "every active source has a cached row" unassertable -- the reader
  -- coalesces anyway, but a complete cache is the difference between a
  -- sentinel that can see a missing source and one that cannot.
  execute format($q$
    with authorized as (
      select u.*,
        sla_hours is not null and u.created_at < now()-make_interval(hours=>sla_hours) as overdue,
        (f.queue_key is not null) as is_finding
      from (%s) u
      left join public.admin_review_finding_codes f
        on f.queue_key=u.queue_type and f.subtitle_match=u.subtitle),
    agg as (
      select queue_type, count(*) n, count(*) filter(where overdue) late,
        count(*) filter(where is_finding) findings,
        count(*) filter(where not is_finding) decisions,
        count(*) filter(where risk='safety') safety
      from authorized group by queue_type),
    fresh as (
      select r.queue_key, coalesce(a.n,0) n, coalesce(a.late,0) late,
        coalesce(a.findings,0) findings, coalesce(a.decisions,0) decisions,
        coalesce(a.safety,0) safety
      from public.admin_review_sources r
      left join agg a on a.queue_type = r.queue_key
      where r.active)
    insert into public.admin_review_queue_counts
      (queue_key, n, late, findings, decisions, safety, computed_at)
    select queue_key, n, late, findings, decisions, safety, now() from fresh
    on conflict (queue_key) do update
      set n = excluded.n, late = excluded.late, findings = excluded.findings,
          decisions = excluded.decisions, safety = excluded.safety,
          computed_at = excluded.computed_at
  $q$, v_union);
  get diagnostics v_rows = row_count;

  delete from public.admin_review_queue_counts c
  where not exists (
    select 1 from public.admin_review_sources r
    where r.active and r.queue_key = c.queue_key);

  return jsonb_build_object(
    'ok', true,
    'sources', v_rows,
    'elapsed_ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
end
$fn$;

revoke all on function public.refresh_admin_review_queue_counts() from public;
grant execute on function public.refresh_admin_review_queue_counts() to service_role;

-- --------------------------------------------------------------- the index
-- What makes the pushed-down `overdue` predicate cheap. business-quality's
-- `created_at` is `entity_quality_findings.first_seen_at`, which no existing
-- index covers -- so even a perfectly folded predicate had to seq-scan
-- 257,757 rows. The partial clause mirrors the stable half of
-- admin_review_src_business_quality's own WHERE, matching the shape of the
-- existing entity_quality_findings_open_idx.
create index if not exists admin_review_eqf_first_seen_idx
  on public.entity_quality_findings (first_seen_at)
  where state = any (array['fail'::text, 'pending'::text]) and waived_at is null;

-- ------------------------------------------- patch get_admin_review_queue
-- PATCHED FROM pg_get_functiondef WITH EXACTLY-ONCE ANCHORS, never restated.
-- A concurrent session rewrote this body hours ago (99991791920008), and
-- 99991790719601 records that the live prosrc already diverges from the newest
-- repo file because of earlier string surgery -- so a CREATE OR REPLACE built
-- from any file would silently revert work that is not ours.
-- Anchors and replacements are dollar-quoted throughout. They are SQL text
-- containing SQL text containing string literals, and the '' form bottoms out
-- at seven consecutive quotes for the scope CASE -- which miscounts into a
-- near-miss that reads as "the body moved under us" rather than as a typo.
do $patch$
declare
  v_src  text;
  v_new  text;
  v_cnt  int;
  a_one  text;
  a_mat   text := $a$authorized as materialized ($a$;
  a_cnt   text := $a$counts as (select queue_type,count(*) n,count(*) filter(where overdue) late,count(*) filter(where is_finding) findings,count(*) filter(where not is_finding) decisions,count(*) filter(where risk='safety') safety from authorized group by queue_type),$a$;
  a_scope text := $a$($4='all' or ($4='safety' and u.risk='safety') or ($4='public' and u.public_impact) or ($4='overdue' and u.overdue) or ($4='decisions' and not u.is_finding))$a$;
  a_fil   text := $a$filtered as not materialized ($a$;
  a_fmt   text := $a$$query$,v_union,v_details) into v_result$a$;
  a_using text := $a$using p_queue_types,p_content_types,v_search,p_scope,p_sort,v_size,v_page;$a$;
  a_tail  text := $a$'page',$6,'per_page',$5,'updated_at',now())$a$;
  a_total text := $a$'total',(select count(*) from filtered)$a$;
  r_cnt   text;
  r_scope text;
  r_total text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_admin_review_queue'
    and pg_get_function_identity_arguments(p.oid) =
        'p_queue_types text[], p_content_types text[], p_search text, p_sort text, p_page integer, p_per_page integer, p_scope text';
  if v_src is null then
    raise exception 'get_admin_review_queue(7 args) not found - aborting';
  end if;

  -- Every anchor must occur EXACTLY once. A missing one means the body moved
  -- under us; a repeated one means the edit is ambiguous. Either way, stop.
  foreach a_one in array array[a_mat, a_cnt, a_scope, a_fil, a_fmt, a_using] loop
    v_cnt := (length(v_src) - length(replace(v_src, a_one, ''))) / length(a_one);
    if v_cnt <> 1 then
      raise exception 'anchor occurs % times, expected 1: %', v_cnt, left(a_one, 60);
    end if;
  end loop;

  -- Serve the counts from the cache, with the SAME role predicate the sources
  -- array already uses, so a moderator's totals stay scoped to what they read.
  -- public_impact rides along because it is a per-source CONSTANT in the union
  -- (%L::boolean), so the scope=public total is sum(n) over the public sources
  -- and needs no column of its own in the cache.
  r_cnt := $r$counts as (select c.queue_key queue_type,c.n,c.late,c.findings,c.decisions,c.safety,r.public_impact from public.admin_review_queue_counts c join public.admin_review_sources r on r.queue_key=c.queue_key where r.active and (public.has_role_jwt('admin'::public.app_role) or (r.min_role='moderator' and public.has_role_jwt('moderator'::public.app_role)) or (r.min_role='editor' and public.has_any_role_jwt(array['moderator','editor']::public.app_role[])))),$r$;

  -- p_scope is already validated against a five-value whitelist above this
  -- point in the function, so folding it to a literal has no injection
  -- surface -- and it is what lets the planner collapse the OR-chain and push
  -- the surviving predicate into each union branch. As a parameter it cannot.
  r_scope := $r$ case p_scope when 'all' then 'true' when 'safety' then 'u.risk=''safety''' when 'public' then 'u.public_impact' when 'overdue' then 'u.overdue' else 'not u.is_finding' end$r$;

  -- `total` HAS TO COME FROM THE SAME SNAPSHOT AS THE COUNTERS, and this is
  -- the half of the design I got wrong first. The queue's own e2e spec asserts
  -- total = decisions_total (landing), total = all_total (scope=all) and
  -- total = overdue_total (scope=overdue). Those held because `counts` and
  -- `filtered` were two reads of ONE materialized union, so both saw one
  -- snapshot. Leaving `total` live while the counters come from a cache makes
  -- all three true only by luck -- the corpus moves between refreshes -- so
  -- caching the counts the obvious way would have broken the very test this
  -- migration exists to fix, and it would have broken it intermittently,
  -- which is worse than breaking it outright.
  --
  -- It is also the right answer independently of the test: a header reading
  -- "20,323 overdue" above a list that says 20,325 is an inconsistency inside
  -- ONE response, and internal consistency beats freshness for a number
  -- attached to a 336k backlog.
  --
  -- Scoped to the UNFILTERED request ($1 queue_types, $2 content_types,
  -- $3 search all null). With any of those applied there is no cached
  -- equivalent, so `total` stays the live exact count -- which is also what
  -- keeps this honest: the cheap path is the one the cache can actually
  -- answer, and every other path is unchanged.
  r_total := $r$ case p_scope when 'all' then 'sum(n)' when 'decisions' then 'sum(decisions)' when 'overdue' then 'sum(late)' when 'safety' then 'sum(safety)' else 'sum(n) filter (where public_impact)' end$r$;

  v_new := replace(v_src, a_mat,   'authorized as (');
  v_new := replace(v_new, a_cnt,   r_cnt);
  v_new := replace(v_new, a_scope, '%s');
  v_new := replace(v_new, a_fil,   'filtered as materialized (');
  v_cnt := (length(v_new) - length(replace(v_new, a_total, ''))) / length(a_total);
  if v_cnt <> 1 then
    raise exception 'total anchor occurs % times, expected 1', v_cnt;
  end if;
  v_new := replace(v_new, a_total,
    $r$'total',case when $1 is null and $2 is null and $3 is null then (select coalesce(%s,0) from counts) else (select count(*) from filtered) end$r$);

  -- The OR-chain was the function's ONLY use of $4 (measured: 5 occurrences
  -- before the fold, 0 after), which is what makes dropping p_scope from USING
  -- and renumbering safe. Asserted rather than assumed: a surviving $4 would
  -- bind to p_sort after the renumber and silently sort by a scope name.
  v_cnt := (length(v_new) - length(replace(v_new, '$4', ''))) / 2;
  if v_cnt <> 0 then
    raise exception 'P-patch failed: $4 still occurs % times after folding the scope predicate', v_cnt;
  end if;
  -- Exactly four %s: the union, the scope predicate, the details CTE, and the
  -- total aggregate -- IN THAT TEXTUAL ORDER, which is what decides the
  -- argument order below, because format() forbids mixing %1$s with %s and so
  -- leaves only sequential substitution. Getting the order wrong is not a
  -- syntax error: an earlier draft put the scope predicate in the union slot
  -- and produced a branch reading `from (u.overdue) authorized_rows`.
  --
  -- `details as (%s)` precedes the final SELECT, so the total aggregate is
  -- LAST even though `'total'` is the first key in the output object.
  v_cnt := (length(v_new) - length(replace(v_new, '%s', ''))) / 2;
  if v_cnt <> 4 then
    raise exception 'P-patch failed: expected 4 %%s in the template, found %', v_cnt;
  end if;
  if position('details as (%s)' in v_new) = 0
     or position('details as (%s)' in v_new) > position('coalesce(%s,0) from counts' in v_new) then
    raise exception 'P-patch failed: the details and total placeholders are not in the assumed order';
  end if;

  v_new := replace(v_new, a_fmt,
    '$query$,v_union,' || r_scope || ',v_details,' || r_total || ') into v_result');
  -- p_scope is now folded into the text, so drop it from USING and renumber
  -- the rest. Via placeholders, because a direct $5->$4 then $6->$5 would
  -- re-hit the tokens it just wrote.
  v_new := replace(v_new, a_using,
    'using p_queue_types,p_content_types,v_search,p_sort,v_size,v_page;');
  v_new := replace(v_new, '$5', '@@A@@');
  v_new := replace(v_new, '$6', '@@B@@');
  v_new := replace(v_new, '$7', '@@C@@');
  v_new := replace(v_new, '@@A@@', '$4');
  v_new := replace(v_new, '@@B@@', '$5');
  v_new := replace(v_new, '@@C@@', '$6');

  -- Expose the cache age so a stale header is visible rather than silent.
  -- Anchored AFTER the renumber, on the renumbered tokens.
  v_cnt := (length(v_new) - length(replace(v_new, a_tail, ''))) / length(a_tail);
  if v_cnt <> 1 then
    raise exception 'tail anchor occurs % times after renumber, expected 1', v_cnt;
  end if;
  v_new := replace(v_new, a_tail,
    $r$'page',$6,'per_page',$5,'counts_as_of',(select max(computed_at) from public.admin_review_queue_counts),'updated_at',now())$r$);

  if v_new = v_src then
    raise exception 'patch produced an identical body - aborting';
  end if;
  execute v_new;
end
$patch$;

-- ------------------------------------- patch get_admin_review_summary
-- THE SAME DEFECT, THREE TIMES THE TRAFFIC, AND IT IS WHY FIXING ONLY THE
-- QUEUE MIGHT NOT HAVE FIXED THE TEST. `get_admin_review_summary()` (added
-- hours ago by 99991791920572, whose header says "Sidebar badges need exact
-- totals, not a sorted page and hydrated item details") correctly dropped the
-- page and item hydration -- and still builds the same 41-view union over
-- 324,465 rows and joins the same finding codes. Caught by reading
-- pg_stat_activity while diagnosing the queue: THREE concurrent calls to it at
-- ages 7s, 4s and 2s, from one admin page load. Since /admin fires both RPCs
-- on the same navigation, the summary was competing with the queue for the
-- same buffers, so the queue could still have blown its 8s cap on a page whose
-- queue call was fixed.
--
-- This function is a PERFECT fit for the cache because it returns NOTHING BUT
-- the counts -- all_total, decisions_total, findings_total, overdue_total,
-- safety_total and the per-source `sources` array, every one a pure sum over
-- the `counts` CTE. There is no `total`, no `filtered`, no `items`. So the
-- whole union disappears: the summary becomes a 41-row read of a 41-row table.
-- That is a continuation of 99991791920572's intent, not a reversal, with one
-- honest change to its stated contract: "exact totals" becomes "exact as of at
-- most one refresh interval", which is why `counts_as_of` is added here too.
--
-- The union text is removed rather than left as an unreferenced CTE. Postgres
-- would decline to execute an unreferenced non-materialized CTE, but dropping
-- the %s means the 41 branches are never even interpolated, let alone parsed --
-- and it is not a measurement I have to trust. `format()` ignores extra
-- arguments (verified: format('a=%s','one','two') = 'a=one'), so the
-- `format(...,v_union)` call needs no edit, and v_union is still built and
-- still guards the no-visible-sources early return.
do $patch2$
declare
  v_src text;
  v_new text;
  v_cnt int;
  -- Matched by REGEX, not by a literal, deliberately: this anchor spans ten
  -- lines of someone else's formatting, and this file has a standing record of
  -- anchors that silently matched nothing over a four-space indent where the
  -- source had three. The pattern is pinned at both ends and non-greedy.
  pat   text := 'with authorized as not materialized \(.*?from authorized group by queue_type\s*\)';
  repl  text := 'with counts as ('
    || ' select c.queue_key queue_type,c.n,c.late,c.findings,c.decisions,c.safety'
    || ' from public.admin_review_queue_counts c'
    || ' join public.admin_review_sources r on r.queue_key=c.queue_key'
    || ' where r.active and ('
    || ' public.has_role_jwt(''admin''::public.app_role) or'
    || ' (r.min_role=''moderator'' and public.has_role_jwt(''moderator''::public.app_role)) or'
    || ' (r.min_role=''editor'' and public.has_any_role_jwt(array[''moderator'',''editor'']::public.app_role[]))))';
  a_tail text := $a$'updated_at',now()) $query$$a$;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_admin_review_summary'
    and pg_get_function_identity_arguments(p.oid) = '';
  if v_src is null then
    raise exception 'get_admin_review_summary() not found - aborting';
  end if;

  select count(*) into v_cnt from regexp_matches(v_src, pat, 'g');
  if v_cnt <> 1 then
    raise exception 'summary anchor matched % times, expected 1 - the body moved', v_cnt;
  end if;
  -- The tail anchor carries the dollar tag so it cannot collide with the
  -- identical jsonb_build_object tail in the no-sources early return.
  v_cnt := (length(v_src) - length(replace(v_src, a_tail, ''))) / length(a_tail);
  if v_cnt <> 1 then
    raise exception 'summary tail anchor occurs % times, expected 1', v_cnt;
  end if;

  v_new := regexp_replace(v_src, pat, repl);
  v_new := replace(v_new, a_tail,
    $a$'counts_as_of',(select max(computed_at) from public.admin_review_queue_counts),'updated_at',now()) $query$$a$);

  -- The union is gone, so no %s may remain: a surviving one would consume
  -- v_union and re-introduce the scan this edit exists to remove.
  v_cnt := (length(v_new) - length(replace(v_new, '%s', ''))) / 2;
  if v_cnt <> 0 then
    raise exception 'summary still carries % format placeholder(s) after the edit', v_cnt;
  end if;
  if position('from authorized' in v_new) <> 0 then
    raise exception 'summary still reads the authorized CTE after the edit';
  end if;
  if v_new = v_src then
    raise exception 'summary patch produced an identical body - aborting';
  end if;
  execute v_new;
end
$patch2$;

-- ------------------------------------------------------------- the sentinel
create or replace function public.admin_review_counts_signals()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare v_rows int; v_active int; v_missing int; v_age numeric; v_cron int;
begin
  -- `rows` and `sources_active` are reported FIRST and separately from the
  -- staleness check, because "0 stale sources" is equally true of an empty
  -- cache, a cache nobody reads, and a healthy one.
  select count(*) into v_rows   from public.admin_review_queue_counts;
  select count(*) into v_active from public.admin_review_sources where active;
  select count(*) into v_missing
    from public.admin_review_sources r
   where r.active and not exists (
     select 1 from public.admin_review_queue_counts c where c.queue_key = r.queue_key);
  select round(extract(epoch from now() - min(computed_at))) into v_age
    from public.admin_review_queue_counts;
  select count(*) into v_cron from cron.job
   where jobname = 'admin_review_counts_refresh' and active;
  return jsonb_build_object(
    'probe_ok', true,
    'rows', v_rows,
    'sources_active', v_active,
    'sources_missing', v_missing,
    'oldest_age_seconds', v_age,
    'refresh_cron_active', v_cron);
end
$fn$;

revoke all on function public.admin_review_counts_signals() from public;
grant execute on function public.admin_review_counts_signals() to service_role;

-- ---------------------------------------------------------- seed + schedule
-- Seeded here so the cache is never empty: an empty cache would report every
-- total as 0, and a confident zero on a 336k-item backlog is exactly the
-- false-clean reading this repo keeps getting burned by.
select public.refresh_admin_review_queue_counts();

-- Registry row and cron in ONE migration, per the house rule, because an
-- action->>'type'='rpc' row is not reachable by the usual path. `command` IS
-- included (the city_airport_link precedent) so sync_automations_to_cron()
-- branch (d) can recreate the job if it ever goes missing -- without it, a
-- re-enable leaves the row on-but-unscheduled, which reads as healthy. The
-- registry stays canonical: `command` holds the plain readable SQL, and the
-- wrapped form below is derived by admin_automation_effective_command().
insert into public.admin_automations
  (slug, name, description, managed_by, trigger, action, schedule, enabled, conditions)
values (
  'admin_review_counts_refresh',
  'Admin review queue counts refresh',
  'Recomputes cached per-source review-queue counts so get_admin_review_queue '
  'does not aggregate 324k rows across 41 views on every page load.',
  'system',
  jsonb_build_object('type','schedule'),
  jsonb_build_object(
    'type','rpc',
    'fn','refresh_admin_review_queue_counts',
    'jobname','admin_review_counts_refresh',
    'command','SELECT public.refresh_admin_review_queue_counts();'),
  '*/2 * * * *',
  true,
  '[]'::jsonb)
on conflict (slug) do update
  set action = excluded.action, schedule = excluded.schedule, trigger = excluded.trigger,
      description = excluded.description, managed_by = excluded.managed_by, enabled = true;

-- Every 2 minutes, not every minute: the refresh does the full-corpus union
-- scan this migration removes from the request path, and adding load to a
-- disk-constrained database is what produces the timeouts in the first place.
-- The measured elapsed_ms is in the apply log and in every run row; at the
-- refresh cost measured here the duty cycle is a few percent, against a
-- staleness bound nobody reviewing a 336k backlog will notice. Re-measure
-- before changing the cadence -- and changing it means the registry row AND
-- cron.schedule together, or the nightly reconciler undoes one of them.
--
-- Scheduled through admin_automation_effective_command() so the live command
-- is by construction the one the reconciler would derive, and the nightly
-- automation_cron_sync has nothing to rewrite.
--
-- It does NOT make the job run-tracked, and an earlier draft of this comment
-- claimed it did. Measured: for an action->>'type'='rpc' row that function
-- returns the command unchanged -- only the two HTTP families get the
-- admin_automation_run_begin prefix. This is family C (pure synchronous SQL),
-- whose runs are recorded by admin_automation_project_cron_runs() off
-- cron.job_run_details, which is exact for that family. So it is tracked, by
-- the other mechanism, and calling the wrapper here is a no-op that buys
-- drift-freedom rather than tracking.
select cron.unschedule('admin_review_counts_refresh')
where exists (select 1 from cron.job where jobname = 'admin_review_counts_refresh');
select cron.schedule('admin_review_counts_refresh', '*/2 * * * *',
  public.admin_automation_effective_command(
    'admin_review_counts_refresh',
    'SELECT public.refresh_admin_review_queue_counts();'));

-- --------------------------------------------------------------- postconditions
-- Hard on what this migration undertakes to reach; deliberately NOT a text
-- assertion on the patched function's SELECT. 20810101100100 aborted db push
-- for the whole repo with exactly that, on a rewrite that preserved the
-- condition. The SQL text is asserted in the repo guard, where a false alarm
-- costs one PR instead of everyone's.
do $verify$
declare v_missing int; v_rows int; v_cron int; v_sig jsonb; v_q jsonb; v_s jsonb; v_src text;
begin
  select count(*) into v_missing
    from public.admin_review_sources r
   where r.active and not exists (
     select 1 from public.admin_review_queue_counts c where c.queue_key = r.queue_key);
  if v_missing <> 0 then
    raise exception 'P1 failed: % active sources have no cached counts row', v_missing;
  end if;

  select count(*) into v_rows from public.admin_review_queue_counts;
  if v_rows = 0 then
    raise exception 'P2 failed: counts cache is empty, every total would read 0';
  end if;

  select count(*) into v_cron from cron.job
   where jobname = 'admin_review_counts_refresh' and active;
  if v_cron <> 1 then
    raise exception 'P3 failed: expected exactly 1 active refresh cron, found %', v_cron;
  end if;
  if not exists (select 1 from public.admin_automations
                  where slug = 'admin_review_counts_refresh' and enabled) then
    raise exception 'P4 failed: registry row absent or disabled';
  end if;
  -- THIS ASSERTION USED TO READ `command like '%admin_automation_run_begin%'`
  -- AND WOULD HAVE ABORTED db push FOR THE WHOLE REPO. Measured before
  -- merging: admin_automation_effective_command() returns an rpc row's command
  -- UNCHANGED -- verified against city_completeness_recompute, an existing
  -- registered rpc automation, not just against this slug before it existed.
  -- Only the two HTTP families get the run_begin prefix; a pure-SQL cron like
  -- this one is family C, whose run records come from
  -- admin_automation_project_cron_runs() reading cron.job_run_details, which
  -- CLAUDE.md records as exact for that family. So the job IS tracked, by a
  -- different mechanism, and the wrapper is a no-op here.
  --
  -- What is worth asserting instead is DRIFT-FREEDOM: the live command equals
  -- what the reconciler would derive, so the nightly automation_cron_sync has
  -- nothing to rewrite. That is true, checkable, and the thing that actually
  -- goes wrong (a cron whose command the reconciler silently replaces).
  if not exists (
    select 1 from cron.job j
     where j.jobname = 'admin_review_counts_refresh'
       and j.command = public.admin_automation_effective_command(
             'admin_review_counts_refresh',
             'SELECT public.refresh_admin_review_queue_counts();')) then
    raise exception 'P4b failed: the live cron command does not match the reconciler-derived command';
  end if;

  v_sig := public.admin_review_counts_signals();
  if coalesce((v_sig->>'probe_ok')::boolean, false) is not true
     or (v_sig->>'sources_missing')::int <> 0
     or (v_sig->>'refresh_cron_active')::int <> 1 then
    raise exception 'P5 failed: sentinel disagrees with the state just created: %', v_sig;
  end if;

  -- The function must still EXECUTE and partition the queue. A plpgsql body is
  -- only parsed at CREATE time, so the five string edits above are unproven
  -- until the thing is called (42702-class errors surface at run time, not at
  -- apply time). Claims are set because the function is staff-gated.
  perform set_config('request.jwt.claims',
    '{"user_role":"admin","app_metadata":{"roles":["admin"]}}', true);
  v_q := public.get_admin_review_queue(p_scope => 'overdue');
  if (v_q->>'total') is null or (v_q->>'overdue_total') is null then
    raise exception 'P6 failed: overdue scope returned no totals: %', v_q;
  end if;
  if (v_q->>'total')::bigint <> (v_q->>'overdue_total')::bigint then
    raise exception 'P7 failed: overdue total % <> overdue_total %',
      v_q->>'total', v_q->>'overdue_total';
  end if;
  if (v_q->>'counts_as_of') is null then
    raise exception 'P8 failed: counts_as_of absent from the payload';
  end if;
  v_q := public.get_admin_review_queue(p_scope => 'decisions');
  if (v_q->>'decisions_total')::bigint + (v_q->>'findings_total')::bigint
     <> (v_q->>'all_total')::bigint then
    raise exception 'P9 failed: decisions+findings <> all_total (%)', v_q;
  end if;
  if (v_q->>'total')::bigint <> (v_q->>'decisions_total')::bigint then
    raise exception 'P10 failed: decisions total % <> decisions_total %',
      v_q->>'total', v_q->>'decisions_total';
  end if;

  -- The fence must be gone and the second materialization present, or the win
  -- measured in the header does not exist. Asserted on the LIVE body.
  -- Scoped to the 7-arg identity: there is exactly one overload today, and
  -- SELECT INTO over two would pick one arbitrarily and assert about the
  -- wrong body.
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='get_admin_review_queue'
     and pg_get_function_identity_arguments(p.oid) =
         'p_queue_types text[], p_content_types text[], p_search text, p_sort text, p_page integer, p_per_page integer, p_scope text';
  if v_src is null then
    raise exception 'P11 failed: the 7-arg function is gone after the patch';
  end if;
  if position('authorized as materialized (' in v_src) <> 0 then
    raise exception 'P11 failed: the authorized fence is still in place';
  end if;
  if position('filtered as materialized (' in v_src) = 0 then
    raise exception 'P12 failed: filtered is not materialized, the union will run twice';
  end if;
  if position('from authorized group by queue_type' in v_src) <> 0 then
    raise exception 'P13 failed: counts still aggregate over authorized';
  end if;

  -- The summary half. It must execute, carry every key it carried before, and
  -- no longer read the union.
  v_s := public.get_admin_review_summary();
  if (v_s->>'all_total') is null or (v_s->>'decisions_total') is null
     or (v_s->>'findings_total') is null or (v_s->>'overdue_total') is null
     or (v_s->>'safety_total') is null or (v_s->'sources') is null then
    raise exception 'P14 failed: summary lost a key it used to return: %', v_s;
  end if;
  if (v_s->>'counts_as_of') is null then
    raise exception 'P15 failed: counts_as_of absent from the summary payload';
  end if;
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='get_admin_review_summary'
     and pg_get_function_identity_arguments(p.oid) = '';
  if position('from authorized' in v_src) <> 0 then
    raise exception 'P16 failed: the summary still reads the union';
  end if;

  -- BOTH functions now derive their totals from the same cache under the same
  -- role predicate, so they must agree exactly. This is the output-equality
  -- check that matters: it is the one assertion that would catch a role filter
  -- dropped from one of the two reads, which is otherwise invisible to an
  -- admin (who sees every source) and wrong for every moderator.
  if (v_s->>'all_total')::bigint <> (v_q->>'all_total')::bigint
     or (v_s->>'decisions_total')::bigint <> (v_q->>'decisions_total')::bigint
     or (v_s->>'findings_total')::bigint <> (v_q->>'findings_total')::bigint
     or (v_s->>'overdue_total')::bigint <> (v_q->>'overdue_total')::bigint
     or (v_s->>'safety_total')::bigint <> (v_q->>'safety_total')::bigint then
    raise exception 'P17 failed: summary and queue totals disagree: summary=% queue=%',
      v_s - 'sources', v_q - 'items' - 'sources';
  end if;
  -- And the per-source arrays must be identical, which is what the sidebar
  -- badges and the queue's own source chips each render independently.
  if (v_s->'sources') <> (v_q->'sources') then
    raise exception 'P18 failed: summary and queue per-source arrays disagree';
  end if;
end
$verify$;
