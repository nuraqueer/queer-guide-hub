-- Resolve only after a genuinely later completed successful run. Failures still
-- use the existing reporter and reopen the same fingerprint on recurrence.
CREATE OR REPLACE FUNCTION public.automation_failure_feedback_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.finished_at IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.finished_at IS NOT NULL AND OLD.status IS NOT DISTINCT FROM NEW.status THEN RETURN NEW; END IF;
  IF NEW.status IN ('error', 'partial') THEN
    PERFORM public.report_automation_failure(NEW);
  ELSIF NEW.status = 'success' AND NOT EXISTS (
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

-- Backfill verified recovery from the latest completed run, not any historical success.
WITH latest AS (
  SELECT DISTINCT ON (automation_slug) automation_slug,id,status,started_at,finished_at
  FROM public.admin_automation_runs WHERE finished_at IS NOT NULL ORDER BY automation_slug,started_at DESC,id DESC
)
UPDATE public.community_submissions c
SET feedback_status='done',resolution='fixed',resolved_at=l.finished_at,
  data=c.data || jsonb_build_object('recovery',jsonb_build_object('run_id',l.id,'verified_at',l.finished_at))
FROM latest l WHERE c.content_type='api_error' AND c.fingerprint='automation:'||l.automation_slug
  AND c.feedback_status IS DISTINCT FROM 'done' AND l.status='success'
  AND (c.data->>'reported_at')::timestamptz<l.started_at;

-- Keep cron requests within the gateway budget; the handlers also enforce caps.
UPDATE public.admin_automations
SET action=jsonb_set(action,'{command}',to_jsonb(replace(action->>'command',
    CASE slug WHEN 'ev_fill_lgbtnetwork' THEN '"batch_size":250' WHEN 'ev_fill_gaytravel4u' THEN '"batch_size":150' ELSE '"batch_size":30' END,
    CASE slug WHEN 'pipeline_geo_validate' THEN '"batch_size":5' ELSE '"batch_size":25' END))),updated_at=now()
WHERE slug IN ('ev_fill_lgbtnetwork','ev_fill_gaytravel4u','pipeline_geo_validate');
SELECT public.sync_automations_to_cron(true);

