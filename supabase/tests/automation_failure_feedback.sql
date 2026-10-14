-- Run against the repaired database. All test writes and queued HTTP requests roll back.
BEGIN;
DO $test$
DECLARE a uuid; r bigint; n int; before_count int; payload jsonb;
BEGIN
  SELECT id INTO a FROM public.admin_automations WHERE slug='cron_failure_sweep';
  SELECT coalesce(max(occurrence_count),0) INTO before_count FROM public.community_submissions
    WHERE fingerprint='automation:cron_failure_sweep' AND content_type='api_error';
  INSERT INTO public.admin_automation_runs(automation_id,automation_slug,status,started_at)
    VALUES(a,'cron_failure_sweep','running',now()) RETURNING id INTO r;
  UPDATE public.admin_automation_runs SET status='error',finished_at=now(),
    error='Regression test Bearer secret-value',summary='{}'::jsonb WHERE id=r;
  SELECT occurrence_count,data INTO n,payload FROM public.community_submissions
    WHERE fingerprint='automation:cron_failure_sweep' AND content_type='api_error';
  IF NOT EXISTS(SELECT 1 FROM public.feedback_story_members m JOIN public.community_submissions e ON e.id=m.submission_id
    WHERE m.story_id='9b68f04b-29b9-4e57-9d39-c4f53c80a415' AND e.fingerprint='automation:cron_failure_sweep')
    THEN RAISE EXCEPTION 'error not linked to visible feedback story'; END IF;
  IF n<>before_count+1 THEN RAISE EXCEPTION 'failure did not reach feedback'; END IF;
  IF payload->>'message' LIKE '%secret-value%' THEN RAISE EXCEPTION 'credential not redacted'; END IF;
  PERFORM public.report_automation_failure(x) FROM public.admin_automation_runs x WHERE id=r;
  UPDATE public.admin_automation_runs SET summary='{"auto_paused":true}' WHERE id=r;
  IF (SELECT occurrence_count FROM public.community_submissions WHERE fingerprint='automation:cron_failure_sweep' AND content_type='api_error')<>n
    THEN RAISE EXCEPTION 'duplicate finalization counted twice'; END IF;
  UPDATE public.community_submissions SET feedback_status='done',resolution='fixed',resolved_at=now()
    WHERE fingerprint='automation:cron_failure_sweep' AND content_type='api_error';
  INSERT INTO public.admin_automation_runs(automation_id,automation_slug,status,started_at,finished_at,error)
    VALUES(a,'cron_failure_sweep','error',now(),now(),'Regression test recurrence');
  IF NOT EXISTS(SELECT 1 FROM public.community_submissions WHERE fingerprint='automation:cron_failure_sweep'
    AND content_type='api_error' AND feedback_status='new' AND resolution IS NULL AND resolved_at IS NULL)
    THEN RAISE EXCEPTION 'recurrence did not reopen resolved feedback'; END IF;
END $test$;
ROLLBACK;
