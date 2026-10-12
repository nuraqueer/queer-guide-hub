-- Recovery record: already applied in production. Do not re-run.
-- Recovered verbatim from supabase_migrations.schema_migrations.statements.
-- Recorded SQL MD5: b0e5280fc7de8770c553dfe86dd19450

-- HTTP 200 is not success when the handler explicitly reports success:false.
CREATE OR REPLACE FUNCTION private.automation_response_failed(p_body text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
BEGIN
  RETURN COALESCE((p_body::jsonb)->>'success'='false',false);
EXCEPTION WHEN invalid_text_representation THEN RETURN false;
END $$;
REVOKE ALL ON FUNCTION private.automation_response_failed(text) FROM PUBLIC,anon,authenticated;

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
    -- Joined ON THE REQUEST ID. This is the whole point of the link table.
    LEFT JOIN net._http_response resp ON resp.id = req.request_id
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

CREATE OR REPLACE FUNCTION public.automation_failure_feedback_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.finished_at IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.finished_at IS NOT NULL AND OLD.status IS NOT DISTINCT FROM NEW.status THEN RETURN NEW; END IF;
  IF NEW.status IN ('error', 'partial') THEN
    PERFORM public.report_automation_failure(NEW);
  ELSIF NEW.status = 'success' AND (NEW.summary->>'no_request') IS DISTINCT FROM 'true' AND NOT EXISTS (
    SELECT 1 FROM public.admin_automation_runs r
    WHERE r.automation_id = NEW.automation_id AND r.started_at > NEW.started_at
      AND r.finished_at IS NOT NULL AND r.status IN ('error', 'partial')
  ) THEN
    UPDATE public.community_submissions c
    SET feedback_status = 'done', resolution = 'fixed', resolved_at = NEW.finished_at,
      data = c.data || jsonb_build_object('recovery', jsonb_build_object('run_id', NEW.id, 'verified_at', NEW.finished_at))
    WHERE c.content_type = 'api_error' AND c.fingerprint = 'automation:' || NEW.automation_slug
      AND c.feedback_status IS DISTINCT FROM 'done'
      AND (c.data->>'reported_at')::timestamptz < NEW.started_at;
    IF NOT EXISTS (
      SELECT 1 FROM public.feedback_story_members m JOIN public.community_submissions c ON c.id=m.submission_id
      JOIN public.feedback_stories s ON s.id=m.story_id
      WHERE s.labels @> ARRAY['automation','system-generated']::text[] AND c.feedback_status IS DISTINCT FROM 'done'
    ) THEN
      UPDATE public.feedback_stories SET status='resolved', resolved_at=NEW.finished_at
      WHERE labels @> ARRAY['automation','system-generated']::text[] AND status <> 'resolved';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.automation_failure_feedback_trigger() FROM PUBLIC, anon, authenticated;



