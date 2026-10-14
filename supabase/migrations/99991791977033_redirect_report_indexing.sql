-- An explicit, reviewed choice; never infer indexing from public sharing.
ALTER TABLE public.redirect_report_shares ADD COLUMN allow_indexing boolean NOT NULL DEFAULT false;
ALTER TABLE public.redirect_report_shares ADD CONSTRAINT redirect_report_indexing_password CHECK(NOT allow_indexing OR password_hash IS NULL);
CREATE OR REPLACE FUNCTION public.redirect_report_share_resource(p_action text,p_actor uuid,p_principal uuid,p_report uuid,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT '{}',p_password_hash jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_saved_reports;s public.redirect_report_shares;ids uuid[];allowed uuid[];requires_owner boolean;result jsonb;
BEGIN
 IF p_action IS NULL OR p_action NOT IN('list','create','revoke') THEN RAISE EXCEPTION 'Invalid share action' USING ERRCODE='22023';END IF;
 PERFORM public.redirect_report_actor(p_actor,p_principal,p_action<>'list');
 SELECT * INTO r FROM public.redirect_saved_reports WHERE id=p_report AND owner_user_id=p_actor;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Report not found' USING ERRCODE='P0002';END IF;
 IF p_action='list' THEN
  SELECT jsonb_build_object('data',coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'scopeMode',scope_mode,'linkCount',cardinality(link_ids),'allowIndexing',allow_indexing,'includeConversions',include_conversions,'hasPassword',password_hash IS NOT NULL,'createdAt',created_at,'expiresAt',expires_at,'revokedAt',revoked_at) ORDER BY created_at DESC,id),'[]'::jsonb)) INTO result FROM public.redirect_report_shares WHERE report_id=r.id;
  RETURN result;
 END IF;
 IF p_action='revoke' THEN
  UPDATE public.redirect_report_shares SET revoked_at=coalesce(revoked_at,clock_timestamp()),version=gen_random_uuid() WHERE id=p_id AND report_id=r.id RETURNING * INTO s;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Share not found' USING ERRCODE='P0002';END IF;
  RETURN jsonb_build_object('id',s.id,'revoked',true);
 END IF;
 IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR p_values-ARRAY['title','reportVersion','includeConversions','expiresAt','scopeMode','allowIndexing']::text[]<>'{}' THEN RAISE EXCEPTION 'Invalid share fields' USING ERRCODE='22023';END IF;
 IF (p_values->>'reportVersion')::uuid IS DISTINCT FROM r.version THEN RAISE EXCEPTION 'Report changed; review before sharing' USING ERRCODE='23505';END IF;
 requires_owner:=NOT(r.filters?'linkIds' AND jsonb_array_length(r.filters->'linkIds')=1 AND NOT(r.filters?'folderId') AND NOT(r.filters?'tagId'));
 IF requires_owner AND p_principal IS NOT NULL THEN RAISE EXCEPTION 'Workspace owners must publish folder or multi-link reports' USING ERRCODE='42501';END IF;
 IF p_principal IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_workspace_members WHERE id=p_principal AND role='member') THEN RAISE EXCEPTION 'Edit access is required to publish' USING ERRCODE='42501';END IF;
 allowed:=public.redirect_management_scope(p_principal,'links:write');
 SELECT coalesce(array_agg(d.id),ARRAY[]::uuid[]) INTO ids FROM public.redirects d LEFT JOIN public.redirect_link_metadata m ON m.redirect_key='redirects:'||d.id::text
 WHERE d.type='SHORT' AND (allowed IS NULL OR d.id=ANY(allowed))
 AND (NOT(r.filters?'linkIds') OR d.id IN(SELECT value::uuid FROM jsonb_array_elements_text(r.filters->'linkIds')))
 AND (NOT(r.filters?'folderId') OR m.folder_id=(r.filters->>'folderId')::uuid)
 AND (NOT(r.filters?'tagId') OR EXISTS(SELECT FROM public.redirect_link_tag_assignments t WHERE t.redirect_key='redirects:'||d.id::text AND t.tag_id=(r.filters->>'tagId')::uuid));
 IF cardinality(ids)=0 AND coalesce(p_values->>'scopeMode','snapshot')<>'folder' THEN RAISE EXCEPTION 'Choose links you can edit before publishing' USING ERRCODE='42501';END IF;
 IF (p_values->>'scopeMode')='folder' AND (p_principal IS NOT NULL OR NOT(r.filters?'folderId') OR r.filters?'linkIds') THEN RAISE EXCEPTION 'Dynamic folder sharing requires a workspace owner and folder filter' USING ERRCODE='42501';END IF;
 IF NOT coalesce((p_values->>'includeConversions')::boolean,false) AND r.filters->>'event' IN('lead','sale') THEN RAISE EXCEPTION 'Enable conversion sharing or choose a click report' USING ERRCODE='22023';END IF;
 IF coalesce((p_values->>'allowIndexing')::boolean,false) AND nullif(p_password_hash,'null'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'Password-protected dashboards cannot be indexed' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.redirect_report_shares WHERE report_id=r.id AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>clock_timestamp()))>=20 THEN RAISE EXCEPTION 'Revoke an existing share before creating another' USING ERRCODE='22023';END IF;
 INSERT INTO public.redirect_report_shares(report_id,owner_user_id,title,filters,link_ids,requires_workspace_owner,scope_mode,include_conversions,password_hash,expires_at,allow_indexing)
 VALUES(r.id,p_actor,btrim(p_values->>'title'),r.filters,ids,requires_owner,coalesce(p_values->>'scopeMode','snapshot'),coalesce((p_values->>'includeConversions')::boolean,false),nullif(p_password_hash,'null'::jsonb),(p_values->>'expiresAt')::timestamptz,coalesce((p_values->>'allowIndexing')::boolean,false)) RETURNING * INTO s;
 RETURN jsonb_build_object('id',s.id,'title',s.title,'linkCount',cardinality(s.link_ids),'scopeMode',s.scope_mode,'allowIndexing',s.allow_indexing,'includeConversions',s.include_conversions,'hasPassword',s.password_hash IS NOT NULL,'expiresAt',s.expires_at);
END $$;

CREATE OR REPLACE FUNCTION public.redirect_public_report_read(p_id uuid,p_version uuid,p_password_verified boolean,p_dates jsonb)
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
 RETURN jsonb_build_object('allowIndexing',s.allow_indexing AND s.password_hash IS NULL,'title',s.title,'includeConversions',s.include_conversions,'linkCount',cardinality(ids),'scopeMode',s.scope_mode,'expiresAt',s.expires_at,
 'dateRange',jsonb_build_object('start',selected_start,'end',selected_end,'earliest',earliest,'latest',latest),
 'report',public.redirect_analytics_report(filters,ids));
END $$;
