-- pg_net request ids are NOT unique over time, and the filing table's primary
-- key assumed they were.
--
-- Measured 2026-10-14. `net.http_request_queue`'s id sequence RESET between
-- 2026-10-12 16:56 and 17:00 UTC (the same window as the workflow-dispatcher
-- HTTP 500 burst that wrongly auto-paused it) and is now at ~6,673, replaying a
-- range in which public.admin_automation_run_requests already holds 175,802
-- historical ids (181,645 rows, ids 1-443,751).
--
-- request_id was that table's PRIMARY KEY and automation_http_post files with
-- `on conflict (request_id) do nothing`, so every fire whose fresh pg_net id
-- collided with an already-filed id was SILENTLY DROPPED. The run then had zero
-- requests, which admin_automation_reap_runs correctly reads as a legitimate
-- conditional no-op and books as
--   {"no_request": true, "note": "command committed without issuing an HTTP request"}
-- -- a permanent green. consecutive_failures can never increment for such a
-- run, so a tracked job can neither auto-pause nor record a real failure.
--
-- Scope when measured: 963 of 2,542 runs in 6h (38%) across 60 slugs; 4,475
-- falsely-green no_request runs in 48h. NOT specific to workflow_dispatcher.
--
-- The filing path itself was never broken and the three obvious suspects are
-- all innocent: admin_automation_run_begin does insert the context (it has no
-- short-circuit for an already-open run), pg_cron runs both statements in one
-- transaction on one backend (pg_backend_pid() matches, verified), and no
-- other caller consumes the context. Reproduced in a rolled-back transaction:
-- run_begin then automation_http_post returned request_id 6656 and filed
-- nothing, because 6656 was already filed against run 492234 (push_realtime,
-- 2026-10-13 05:51).
--
-- Three changes, and the first two MUST ship together: with the key swapped,
-- `on conflict (request_id)` no longer matches a unique index and would raise
-- 42P10, which inside the cron command rolls back the whole dispatch.
--
-- 1. PRIMARY KEY (request_id) -> (run_id, request_id). This is the fix rather
--    than pruning the 175,802 colliding rows, because the sequence will crawl
--    through that id space for weeks and a prune only moves the collision.
--    Verified 0 duplicate (run_id, request_id) pairs before the swap.
--
-- 2. automation_http_post files `on conflict (run_id, request_id) do nothing`,
--    which still absorbs a genuine double-file inside one run.
--
-- 3. admin_automation_reap_runs bounds its response join on time. The join is
--    `resp.id = req.request_id` and the whole point of the link table is that
--    the request id is exact -- but a recycled id is no longer exact, so a run
--    still 'running' from before the reset could be resolved against a fresh,
--    unrelated response, which is the mistake that join was written to make
--    unspellable. A response cannot predate its own request. The bound FAILS
--    OPEN on a NULL req.created_at (rows filed before that column existed), so
--    legacy rows keep today's behaviour instead of silently flipping to
--    'abandoned'.
--
-- 4. admin_automation_tracking_gaps gains no_request_24h. Nothing anywhere
--    counted this: unverifiable_automations filters summary->>'unverifiable',
--    which a no_request run never sets, and additionally requires EVERY recent
--    run of a slug to be unverifiable -- here roughly half of each job's runs
--    looked perfectly verified. It reports `finished` BESIDE the count, because
--    zero no_request out of zero finished runs must not read as a clean bill.
--    It stays a RATE and not a zero-invariant: several registered commands post
--    conditionally (hotel_reenrich_stale has a WHERE EXISTS,
--    news_verdict_geo_backfill an IF) and legitimately issue no request.

set lock_timeout = '5s';

alter table public.admin_automation_run_requests
  drop constraint admin_automation_run_requests_pkey,
  add constraint admin_automation_run_requests_pkey primary key (run_id, request_id);

create or replace function public.automation_http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb,
  timeout_milliseconds integer default 5000
)
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_request_id bigint;
  v_context private.admin_automation_run_contexts%rowtype;
  v_headers jsonb;
begin
  select * into v_context
  from private.admin_automation_run_contexts c
  where c.backend_pid = pg_backend_pid()
    and c.created_at >= now() - interval '15 minutes'
    and exists (
      select 1 from public.admin_automation_runs r
      where r.id = c.run_id and r.status = 'running' and r.finished_at is null
    )
  for update;

  v_headers := coalesce(headers, '{}'::jsonb)
    || case when v_context.run_id is null then '{}'::jsonb
            else jsonb_build_object('X-Automation-Run-Id', v_context.run_id::text) end;

  v_request_id := net.http_post(
    url := url,
    body := body,
    params := params,
    headers := v_headers,
    timeout_milliseconds := timeout_milliseconds
  );

  if v_context.run_id is not null then
    -- Keyed on (run_id, request_id), NOT request_id alone: pg_net's id
    -- sequence has reset at least once and replays ids this table already
    -- holds from earlier runs. Under the old key the collision silently
    -- dropped the filing and the run booked itself as a no-op success.
    insert into public.admin_automation_run_requests (request_id, run_id, url, timeout_ms)
    values (
      v_request_id, v_context.run_id, url, coalesce(timeout_milliseconds, 5000)
    )
    on conflict (run_id, request_id) do nothing;

    if v_context.remaining_requests <= 1 then
      delete from private.admin_automation_run_contexts
      where backend_pid = v_context.backend_pid and run_id = v_context.run_id;
    else
      update private.admin_automation_run_contexts
      set remaining_requests = remaining_requests - 1
      where backend_pid = v_context.backend_pid and run_id = v_context.run_id;
    end if;
  end if;

  return v_request_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_automation_reap_runs(p_grace_seconds integer DEFAULT 120)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r             record;
  v_finalized   int := 0;
  v_failed      int := 0;
  v_noop        int := 0;
  v_abandoned   int := 0;
  v_still_open  int := 0;
BEGIN
  FOR r IN
    SELECT
      run.id,
      run.started_at,
      COUNT(req.request_id)                                        AS n_req,
      COUNT(resp.id)                                               AS n_resp,
      COALESCE(MAX(req.timeout_ms), 5000)                          AS max_timeout_ms,
      -- A real failure: the target answered and said no, or the transport
      -- broke in a way that is not a client-side give-up.
      --
      -- The gateway idle-timeout envelope is excluded here and counted as a
      -- timeout below. See this migration's header for the measurement.
      COUNT(*) FILTER (
        WHERE resp.id IS NOT NULL
          AND NOT COALESCE(resp.timed_out, false)
          AND (resp.status_code >= 400 OR resp.error_msg IS NOT NULL OR private.automation_response_failed(resp.content))
          AND NOT (resp.status_code = 504 AND COALESCE(resp.content, '') ILIKE '%IDLE_TIMEOUT%')
      )                                                            AS n_bad,
      -- NOT a failure: somebody gave up waiting while the work kept running.
      -- Two shapes, one meaning.
      --
      -- (a) pg_net gave up client-side (`timed_out`). Measured on the first
      --     live pass -- 2 of 41 requests, both jobs whose registered command
      --     omits timeout_milliseconds and so inherits pg_net's 5s default
      --     while the edge function keeps running server-side.
      -- (b) The Supabase edge GATEWAY gave up at 150s and returned a 504
      --     IDLE_TIMEOUT envelope. `timed_out` is false because pg_net did
      --     receive a response -- but the response says "nobody was listening
      --     any more", not "the work failed". Measured 2026-09-04 on
      --     venue_accessibility_osm, which auto-paused itself over it while
      --     writing its own success rows.
      --
      -- Both are the absence of evidence. Recording either as evidence of
      -- absence auto-pauses a healthy job.
      COUNT(*) FILTER (
        WHERE COALESCE(resp.timed_out, false)
           OR (resp.id IS NOT NULL
               AND resp.status_code = 504
               AND COALESCE(resp.content, '') ILIKE '%IDLE_TIMEOUT%')
      )                                                            AS n_timeout,
      jsonb_agg(
        jsonb_build_object(
          'request_id',  req.request_id,
          'url',         req.url,
          'status_code', resp.status_code,
          'timed_out',   resp.timed_out,
          'error',       resp.error_msg,
          'body',        left(resp.content, 500)
        ) ORDER BY req.request_id
      ) FILTER (WHERE req.request_id IS NOT NULL)                  AS detail
    FROM public.admin_automation_runs run
    LEFT JOIN public.admin_automation_run_requests req ON req.run_id = run.id
    -- Joined ON THE REQUEST ID. This is the whole point of the link table --
    -- but pg_net's id sequence has reset at least once (2026-10-12), so the id
    -- is only exact WITHIN a time window: a response cannot predate its own
    -- request. Without this bound a run still 'running' from before a reset
    -- resolves against a fresh, unrelated response. Fails open on a NULL
    -- req.created_at so rows filed before that column existed keep their
    -- previous behaviour rather than flipping to 'abandoned'.
    LEFT JOIN net._http_response resp
           ON resp.id = req.request_id
          AND (req.created_at IS NULL OR resp.created >= req.created_at)
    WHERE run.status = 'running'
    GROUP BY run.id, run.started_at
  LOOP
    -- No request issued, and the transaction that would have issued one has
    -- already committed (the run row's own survival proves that). Several
    -- commands post conditionally -- hotel_reenrich_stale has a WHERE EXISTS,
    -- news_verdict_geo_backfill an IF -- so this is a legitimate no-op, NOT a
    -- failure. Recording it as an error would auto-pause healthy jobs.
    IF r.n_req = 0 THEN
      IF r.started_at < now() - make_interval(secs => p_grace_seconds) THEN
        UPDATE public.admin_automation_runs
        SET status = 'success', finished_at = now(),
            summary = jsonb_build_object('no_request', true,
                                         'note', 'command committed without issuing an HTTP request')
        WHERE id = r.id;
        v_noop := v_noop + 1;
        v_finalized := v_finalized + 1;
      ELSE
        v_still_open := v_still_open + 1;
      END IF;

    ELSIF r.n_resp = r.n_req THEN
      -- Three-way, and the middle one is the whole point: 'partial' records
      -- the run and stamps last_run_at but does NOT touch
      -- consecutive_failures, so an unverifiable job stays visible without
      -- being auto-paused on absence of evidence. Fix the cause by making the
      -- work fit inside the gateway's 150s idle timeout (and raising the
      -- registered timeout_milliseconds above it, so the gateway's answer is
      -- actually received rather than pre-empted); then a genuine hang becomes
      -- a countable failure instead of an unknown.
      UPDATE public.admin_automation_runs
      SET status = CASE WHEN r.n_bad > 0 THEN 'error'
                        WHEN r.n_timeout > 0 THEN 'partial'
                        ELSE 'success' END,
          finished_at = now(),
          error = CASE WHEN r.n_bad > 0
                       THEN r.n_bad || ' of ' || r.n_req || ' request(s) failed'
                       WHEN r.n_timeout > 0
                       THEN r.n_timeout || ' of ' || r.n_req
                            || ' request(s) gave up waiting (pg_net client-side, or gateway 504 IDLE_TIMEOUT)'
                            || ' — outcome unknown, shorten the work or raise timeout_milliseconds'
                       ELSE NULL END,
          summary = jsonb_build_object('requests', r.detail)
                    || CASE WHEN r.n_bad = 0 AND r.n_timeout > 0
                            THEN jsonb_build_object('unverifiable', true) ELSE '{}'::jsonb END
      WHERE id = r.id;
      v_finalized := v_finalized + 1;
      IF r.n_bad > 0 THEN v_failed := v_failed + 1; END IF;

    -- Responses missing past the request's OWN timeout plus grace. pg_net
    -- normally writes a timed_out row of its own accord, so absence this late
    -- means the request vanished (worker restart) rather than that the target
    -- failed. Closed as 'partial', not 'error', for the same reason as the
    -- timeout branch: this is our bookkeeping losing the thread, and a job
    -- must not be auto-paused for pg_net's fault. It is still RECORDED and
    -- counted in the abandoned metric, which is the part no per-edge-function
    -- helper can do at all -- a function that never runs cannot report on
    -- itself.
    ELSIF r.started_at + make_interval(secs => (r.max_timeout_ms / 1000.0) + p_grace_seconds) < now()
      AND (r.started_at < now()-interval '30 minutes' OR NOT EXISTS(
        SELECT 1 FROM public.admin_automation_run_requests req
        JOIN net.http_request_queue pending ON pending.id=req.request_id WHERE req.run_id=r.id)) THEN
      UPDATE public.admin_automation_runs
      SET status = 'partial', finished_at = now(),
          error = 'no response recorded for ' || (r.n_req - r.n_resp) || ' of ' || r.n_req
                  || ' request(s) within timeout + grace — outcome unknown',
          summary = jsonb_build_object('requests', r.detail, 'abandoned', true, 'unverifiable', true)
      WHERE id = r.id;
      v_finalized := v_finalized + 1;
      v_abandoned := v_abandoned + 1;

    ELSE
      v_still_open := v_still_open + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'finalized', v_finalized, 'failed', v_failed, 'no_request', v_noop,
    'abandoned', v_abandoned, 'still_running', v_still_open
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_automation_tracking_gaps()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH scheduled AS (
    SELECT a.slug, a.last_run_at, j.command
    FROM public.admin_automations a
    JOIN cron.job j ON j.jobname = COALESCE(a.action->>'jobname', a.slug)
    WHERE a.enabled AND a.action->>'type' = 'cron' AND j.active
      -- at most daily, so "silent for 48h" is unambiguous
      AND a.schedule !~ '^\*|^@'
  )
  SELECT jsonb_build_object(
    'silent_automations', COALESCE((
      SELECT jsonb_agg(slug ORDER BY slug) FROM scheduled
      WHERE last_run_at IS NULL OR last_run_at < now() - interval '48 hours'
    ), '[]'::jsonb),
    'untracked_http_dispatchers', COALESCE((
      SELECT jsonb_agg(a.slug ORDER BY a.slug)
      FROM public.admin_automations a
      JOIN cron.job j ON j.jobname = COALESCE(a.action->>'jobname', a.slug)
      WHERE a.enabled AND a.action->>'type' = 'cron' AND j.active
        AND j.command NOT ILIKE '%admin\_automation\_run\_begin%'
        AND EXISTS (
          SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public'
            AND p.prosrc ~ '\mnet\.http_post\M'
            AND j.command ~* ('\m' || p.proname || '\s*\(')
        )
    ), '[]'::jsonb),
    'open_runs_over_1h', (
      SELECT count(*) FROM public.admin_automation_runs
      WHERE status = 'running' AND started_at < now() - interval '1 hour'
    ),
    -- Runs the reaper closed as "committed without issuing an HTTP request".
    -- That verdict is correct for a command that posts conditionally, and it
    -- is ALSO what a dropped filing looks like -- which is how a pg_net id
    -- sequence reset turned ~38% of all tracked runs into permanent greens on
    -- 2026-10-12 with nothing anywhere counting them. unverifiable_automations
    -- cannot see this: it reads summary->>'unverifiable', which a no_request
    -- run never sets, and requires EVERY recent run of a slug to be
    -- unverifiable while this defect leaves roughly half of them looking
    -- verified.
    --
    -- `finished` rides beside the count on purpose: zero no_request out of
    -- zero finished runs is a dead reaper, not a clean bill. A RATE rather
    -- than a zero-invariant, because conditional posters are legitimate.
    'no_request_24h', (
      SELECT jsonb_build_object(
        'finished', count(*),
        'no_request', count(*) FILTER (WHERE (summary->>'no_request')::boolean),
        'pct', round(100.0 * count(*) FILTER (WHERE (summary->>'no_request')::boolean)
                     / NULLIF(count(*), 0), 1)
      )
      FROM public.admin_automation_runs
      WHERE started_at > now() - interval '24 hours' AND finished_at IS NOT NULL
    ),
    -- Jobs whose every recent run ended unverifiable (client-side timeout or a
    -- lost request). These deliberately do NOT auto-pause -- absence of
    -- evidence is not evidence of failure -- so without this metric they would
    -- read as healthy while nobody has ever seen one of their outcomes. The
    -- fix is per-job: raise timeout_milliseconds in the registered command
    -- until the response fits inside it.
    -- Active crons that post HTTP but carry no command in the registry, so
    -- there is nothing for admin_automation_effective_command() to wrap. They
    -- get DISPATCH truth from the projector (a raised exception is recorded)
    -- but never RESPONSE truth — a 500 from their edge function stays
    -- invisible. All 18 are rows typed edge/edge_function by an older
    -- convention. Warn, don't fail: the remedy is to store their command in
    -- action.command, which is a per-row migration, not something to infer
    -- from the live cron here.
    'unwrapped_http_crons', COALESCE((
      SELECT jsonb_agg(a.slug ORDER BY a.slug)
      FROM public.admin_automations a
      JOIN cron.job j ON j.jobname = COALESCE(a.action->>'jobname', a.slug)
      WHERE a.enabled AND j.active
        AND j.command ~ '\mnet\.http_post\M'
        AND j.command NOT ILIKE '%admin\_automation\_run\_begin%'
    ), '[]'::jsonb),
    'unverifiable_automations', COALESCE((
      SELECT jsonb_agg(automation_slug ORDER BY automation_slug)
      FROM (
        SELECT automation_slug
        FROM public.admin_automation_runs
        WHERE started_at > now() - interval '24 hours' AND finished_at IS NOT NULL
        GROUP BY automation_slug
        HAVING count(*) >= 3
           AND count(*) FILTER (WHERE (summary->>'unverifiable')::boolean) = count(*)
      ) u
    ), '[]'::jsonb)
  );
$function$;

do $verify$
declare
  v_pk text;
  v_src text;
  v_run_a bigint;
  v_run_b bigint;
  v_probe_id bigint := 9000000000000;
  v_landed int;
begin
  -- 1. The key is the pair, not the pg_net id alone.
  select pg_get_constraintdef(oid) into v_pk
  from pg_constraint where conname = 'admin_automation_run_requests_pkey';
  if v_pk is distinct from 'PRIMARY KEY (run_id, request_id)' then
    raise exception 'filing table key is %, expected PRIMARY KEY (run_id, request_id)', v_pk;
  end if;

  -- 2. BEHAVIOURAL, not structural: one pg_net id must now be filable against
  --    two different runs. Under the old key the second insert raised 23505,
  --    which `on conflict do nothing` swallowed. Uses two already-finished run
  --    rows and never writes admin_automation_runs, because its finish trigger
  --    would reset consecutive_failures on a real automation.
  select id into v_run_a from public.admin_automation_runs
   where finished_at is not null order by id desc limit 1;
  select id into v_run_b from public.admin_automation_runs
   where finished_at is not null and id <> v_run_a order by id desc limit 1;
  if v_run_a is null or v_run_b is null then
    raise exception 'cannot probe: fewer than two finished runs exist';
  end if;

  insert into public.admin_automation_run_requests (request_id, run_id, url, timeout_ms)
  values (v_probe_id, v_run_a, 'https://example.invalid/pk-probe', 1000),
         (v_probe_id, v_run_b, 'https://example.invalid/pk-probe', 1000)
  on conflict (run_id, request_id) do nothing;

  select count(*) into v_landed from public.admin_automation_run_requests
   where request_id = v_probe_id;
  delete from public.admin_automation_run_requests where request_id = v_probe_id;

  if v_landed <> 2 then
    raise exception 'recycled-id probe filed % of 2 rows — the collision still drops filings', v_landed;
  end if;

  -- 3. The writer targets the new key. A leftover `on conflict (request_id)`
  --    raises 42P10 at runtime, inside the cron command, rolling back the
  --    dispatch itself.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'automation_http_post';
  if position('on conflict (run_id, request_id) do nothing' in v_src) = 0 then
    raise exception 'automation_http_post does not file on the (run_id, request_id) key';
  end if;
  if v_src ~ 'on conflict \(request_id\)' then
    raise exception 'automation_http_post still carries an on conflict (request_id) target';
  end if;

  -- 4. The reaper cannot attach a response that predates its request.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_automation_reap_runs';
  if position('resp.created >= req.created_at' in v_src) = 0 then
    raise exception 'admin_automation_reap_runs joins responses without a time bound';
  end if;

  -- 5. The sentinel reports the quantity whose invisibility was the defect,
  --    and reports it BESIDE the denominator.
  if not (public.admin_automation_tracking_gaps() ? 'no_request_24h') then
    raise exception 'admin_automation_tracking_gaps is missing no_request_24h';
  end if;
  if not (public.admin_automation_tracking_gaps()->'no_request_24h' ? 'finished') then
    raise exception 'no_request_24h reports a count with no denominator';
  end if;
end
$verify$;
