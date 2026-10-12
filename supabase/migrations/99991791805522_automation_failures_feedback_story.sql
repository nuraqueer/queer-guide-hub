-- The admin feedback default view is Stories; error rows need a story membership to be visible.
CREATE OR REPLACE FUNCTION public.report_automation_failure(p_run public.admin_automation_runs)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_message text; v_data jsonb; v_status integer; v_submission uuid;
  v_story uuid := '9b68f04b-29b9-4e57-9d39-c4f53c80a415';
BEGIN
  IF p_run.finished_at IS NULL OR p_run.status NOT IN ('error','partial') THEN RETURN; END IF;
  v_message := coalesce((SELECT nullif(request->>'body','')
    FROM jsonb_array_elements(coalesce(p_run.summary->'requests','[]'::jsonb)) request
    WHERE (request->>'status_code')::integer>=400 LIMIT 1),
    p_run.error, 'Automation failed');
  -- Do not copy headers, payloads, or raw request URLs into feedback.
  v_message := left(regexp_replace(v_message, '(Bearer[[:space:]]+|[?&](key|token|secret|api_key)=)[^[:space:]&"'']+', '\1[redacted]', 'gi'), 2000);
  v_status := (SELECT nullif(request->>'status_code','')::integer
    FROM jsonb_array_elements(coalesce(p_run.summary->'requests','[]'::jsonb)) request
    WHERE (request->>'status_code')::integer>=400 LIMIT 1);
  v_data := jsonb_build_object('service','automation','function_name',p_run.automation_slug,
    'message',v_message,'severity',CASE WHEN p_run.status='partial' THEN 'WARN' ELSE 'ERROR' END,'status_code',v_status,'endpoint','/admin/automation',
    'reported_at',p_run.finished_at,'metadata',jsonb_build_object('automation_id',p_run.automation_id,
      'run_id',p_run.id,'run_status',p_run.status,'cron_runid',p_run.cron_runid,'auto_paused',coalesce((p_run.summary->>'auto_paused')::boolean,false)));
  INSERT INTO public.community_submissions(content_type,data,fingerprint,occurrence_count,last_seen_at,feedback_status,labels)
  VALUES('api_error',v_data,'automation:'||p_run.automation_slug,1,p_run.finished_at,'new',ARRAY['automation'])
  ON CONFLICT(fingerprint) WHERE content_type='api_error' AND fingerprint IS NOT NULL
  DO UPDATE SET occurrence_count=public.community_submissions.occurrence_count+1,
    last_seen_at=excluded.last_seen_at, data=excluded.data,
    feedback_status=CASE WHEN public.community_submissions.feedback_status='done' THEN 'new' ELSE public.community_submissions.feedback_status END,
    resolution=CASE WHEN public.community_submissions.feedback_status='done' THEN NULL ELSE public.community_submissions.resolution END,
    resolved_at=CASE WHEN public.community_submissions.feedback_status='done' THEN NULL ELSE public.community_submissions.resolved_at END
  WHERE coalesce((public.community_submissions.data->'metadata'->>'run_id')::bigint,0)<p_run.id;
  SELECT id INTO v_submission FROM public.community_submissions
    WHERE content_type='api_error' AND fingerprint='automation:'||p_run.automation_slug;
  INSERT INTO public.feedback_stories(id,title,summary,labels,origin)
  VALUES(v_story,'Automation failures',
    'Failures and uncertain outcomes from scheduled automations. Each member shows the latest error, automation name, run ID and occurrence count.',
    ARRAY['automation','system-generated'],'manual') ON CONFLICT(id) DO NOTHING;
  INSERT INTO public.feedback_story_members(story_id,submission_id)
  VALUES(v_story,v_submission) ON CONFLICT DO NOTHING;
  UPDATE public.feedback_stories SET status='open',resolved_at=NULL,archived_at=NULL,
    archive_reason=NULL,updated_at=now()
  WHERE id=v_story AND status IN('resolved','archived');
END $fn$;

REVOKE ALL ON FUNCTION public.report_automation_failure(public.admin_automation_runs) FROM PUBLIC,anon,authenticated;
INSERT INTO public.feedback_stories(id,title,summary,labels,origin)
VALUES('9b68f04b-29b9-4e57-9d39-c4f53c80a415','Automation failures',
 'Failures and uncertain outcomes from scheduled automations. Each member shows the latest error, automation name, run ID and occurrence count.',
 ARRAY['automation','system-generated'],'manual') ON CONFLICT(id) DO NOTHING;
INSERT INTO public.feedback_story_members(story_id,submission_id)
SELECT '9b68f04b-29b9-4e57-9d39-c4f53c80a415',id FROM public.community_submissions
WHERE content_type='api_error' AND fingerprint LIKE 'automation:%' ON CONFLICT DO NOTHING;
