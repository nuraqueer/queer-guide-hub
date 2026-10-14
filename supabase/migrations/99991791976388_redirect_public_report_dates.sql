-- Public viewers may narrow dates, never the captured scope or other filters.
CREATE FUNCTION public.redirect_public_report_read(p_id uuid,p_version uuid,p_password_verified boolean,p_dates jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE s public.redirect_report_shares;ids uuid[];filters jsonb;key text;value text;
 earliest timestamptz;latest timestamptz;selected_start timestamptz;selected_end timestamptz;
BEGIN
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT * INTO s FROM public.redirect_report_shares WHERE id=p_id AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>clock_timestamp()) FOR SHARE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'Dashboard unavailable' USING ERRCODE='P0002';END IF;
 IF p_version IS DISTINCT FROM s.version OR (s.password_hash IS NOT NULL AND NOT coalesce(p_password_verified,false)) THEN RAISE EXCEPTION 'Dashboard access changed' USING ERRCODE='42501';END IF;
 ids:=public.redirect_report_share_ids(s.id);filters:=s.filters;
 IF p_dates IS NULL OR jsonb_typeof(p_dates)<>'object' OR p_dates-ARRAY['start','end']::text[]<>'{}' THEN RAISE EXCEPTION 'Only start and end dates are supported' USING ERRCODE='22023';END IF;
 earliest:=nullif(filters->>'start','')::timestamptz;latest:=nullif(filters->>'end','')::timestamptz;
 FOREACH key IN ARRAY ARRAY['start','end'] LOOP
  IF p_dates?key THEN
   value:=p_dates->>key;
   IF jsonb_typeof(p_dates->key)<>'string' OR value !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$' THEN RAISE EXCEPTION 'Use UTC ISO dates' USING ERRCODE='22023';END IF;
   filters:=jsonb_set(filters,ARRAY[key],to_jsonb(value::timestamptz));
  END IF;
 END LOOP;
 selected_start:=nullif(filters->>'start','')::timestamptz;selected_end:=nullif(filters->>'end','')::timestamptz;
 IF (earliest IS NOT NULL AND (selected_start IS NULL OR selected_start<earliest)) OR
    (latest IS NOT NULL AND (selected_end IS NULL OR selected_end>latest)) OR
    (selected_start IS NOT NULL AND selected_end IS NOT NULL AND selected_start>=selected_end) THEN
  RAISE EXCEPTION 'Choose dates within the published reporting period, with start before end' USING ERRCODE='22023';
 END IF;
 IF NOT s.include_conversions THEN filters:=filters||'{"event":"click"}'::jsonb;END IF;
 RETURN jsonb_build_object('title',s.title,'includeConversions',s.include_conversions,'linkCount',cardinality(ids),'scopeMode',s.scope_mode,'expiresAt',s.expires_at,
 'dateRange',jsonb_build_object('start',selected_start,'end',selected_end,'earliest',earliest,'latest',latest),
 'report',public.redirect_analytics_report(filters,ids));
END $$;
-- Preserve callers of the original service-only signature without ambiguity.
CREATE OR REPLACE FUNCTION public.redirect_public_report_read(p_id uuid,p_version uuid,p_password_verified boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT public.redirect_public_report_read(p_id,p_version,p_password_verified,'{}'::jsonb);
$$;
REVOKE ALL ON FUNCTION public.redirect_public_report_read(uuid,uuid,boolean,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_public_report_read(uuid,uuid,boolean,jsonb) TO service_role;
