CREATE TABLE public.redirect_saved_reports(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),owner_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 name text NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 100),filters jsonb NOT NULL CHECK(jsonb_typeof(filters)='object' AND octet_length(filters::text)<=32768),
 version uuid NOT NULL DEFAULT gen_random_uuid(),created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX redirect_reports_owner_idx ON public.redirect_saved_reports(owner_user_id,id);
CREATE TABLE public.redirect_report_shares(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),report_id uuid NOT NULL REFERENCES public.redirect_saved_reports(id) ON DELETE CASCADE,
 owner_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,title text NOT NULL CHECK(length(btrim(title)) BETWEEN 1 AND 100),
 filters jsonb NOT NULL CHECK(jsonb_typeof(filters)='object' AND octet_length(filters::text)<=32768),link_ids uuid[] NOT NULL,requires_workspace_owner boolean NOT NULL,
 scope_mode text NOT NULL DEFAULT 'snapshot' CHECK(scope_mode IN('snapshot','folder')),
 include_conversions boolean NOT NULL DEFAULT false,password_hash jsonb,
 version uuid NOT NULL DEFAULT gen_random_uuid(),created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz,revoked_at timestamptz,
 CHECK(expires_at IS NULL OR expires_at>created_at),CHECK(scope_mode='snapshot' OR (filters?'folderId' AND requires_workspace_owner)),CHECK(cardinality(link_ids)>0 OR scope_mode='folder')
);
CREATE INDEX redirect_report_shares_report_idx ON public.redirect_report_shares(report_id,id);
CREATE INDEX redirect_report_shares_owner_idx ON public.redirect_report_shares(owner_user_id);
CREATE TABLE public.redirect_report_budgets(
 bucket text PRIMARY KEY,window_at timestamptz NOT NULL,attempts integer NOT NULL
);
ALTER TABLE public.redirect_saved_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redirect_report_shares ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redirect_report_budgets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_saved_reports,public.redirect_report_shares,public.redirect_report_budgets FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_saved_reports,public.redirect_report_shares,public.redirect_report_budgets TO service_role;
CREATE TRIGGER redirect_reports_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_saved_reports FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE TRIGGER redirect_shares_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_report_shares FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();

CREATE FUNCTION public.redirect_report_actor(p_actor uuid,p_principal uuid,p_write boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
 IF p_write THEN PERFORM pg_advisory_xact_lock(471983093);ELSE PERFORM pg_advisory_xact_lock_shared(471983093);END IF;
 IF p_actor IS NULL THEN RAISE EXCEPTION 'Account session required' USING ERRCODE='42501';END IF;
 IF p_principal IS NULL THEN
  PERFORM 1 FROM public.user_roles WHERE user_id=p_actor AND role='admin' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Workspace access required' USING ERRCODE='42501';END IF;
 ELSE
  PERFORM public.redirect_management_scope(p_principal,'events:read');
  IF NOT EXISTS(SELECT FROM public.redirect_workspace_members WHERE id=p_principal AND user_id=p_actor AND kind='user' AND active) THEN RAISE EXCEPTION 'Account session required' USING ERRCODE='42501';END IF;
 END IF;
END $$;
CREATE FUNCTION public.redirect_saved_report_resource(p_action text,p_actor uuid,p_principal uuid,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT '{}',p_limit integer DEFAULT 50,p_after uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_saved_reports;result jsonb;allowed uuid[];
BEGIN
 IF p_action IS NULL OR p_action NOT IN('list','get','create','patch','delete','run') THEN RAISE EXCEPTION 'Invalid report action' USING ERRCODE='22023';END IF;
 PERFORM public.redirect_report_actor(p_actor,p_principal,p_action IN('create','patch','delete'));
 IF p_action='list' THEN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid report page' USING ERRCODE='22023';END IF;
  WITH all_rows AS MATERIALIZED(SELECT * FROM public.redirect_saved_reports WHERE owner_user_id=p_actor),
  page AS MATERIALIZED(SELECT * FROM all_rows WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit+1),shown AS(SELECT * FROM page ORDER BY id LIMIT p_limit)
  SELECT jsonb_build_object('data',coalesce(jsonb_agg(to_jsonb(shown) ORDER BY id),'[]'::jsonb),'count',(SELECT count(*) FROM all_rows),'nextCursor',CASE WHEN(SELECT count(*) FROM page)>p_limit THEN max(id::text) ELSE NULL END) INTO result FROM shown;
  RETURN result;
 END IF;
 IF p_action<>'create' THEN
  SELECT * INTO r FROM public.redirect_saved_reports WHERE id=p_id AND owner_user_id=p_actor;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Report not found' USING ERRCODE='P0002';END IF;
 END IF;
 IF p_action='get' THEN RETURN to_jsonb(r);END IF;
 IF p_action='run' THEN allowed:=public.redirect_management_scope(p_principal,'events:read');RETURN public.redirect_analytics_report(r.filters,allowed);END IF;
 IF p_action='delete' THEN DELETE FROM public.redirect_saved_reports WHERE id=r.id;RETURN jsonb_build_object('id',r.id,'deleted',true);END IF;
 IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR p_values-ARRAY['name','filters','version']::text[]<>'{}' THEN RAISE EXCEPTION 'Invalid report fields' USING ERRCODE='22023';END IF;
 IF p_action='patch' AND (p_values->>'version')::uuid IS DISTINCT FROM r.version THEN RAISE EXCEPTION 'Report changed; reload before saving' USING ERRCODE='23505';END IF;
 IF p_action='create' THEN
  INSERT INTO public.redirect_saved_reports(owner_user_id,name,filters) VALUES(p_actor,btrim(p_values->>'name'),p_values->'filters') RETURNING * INTO r;
 ELSE
  UPDATE public.redirect_saved_reports SET name=CASE WHEN p_values?'name' THEN btrim(p_values->>'name') ELSE name END,filters=CASE WHEN p_values?'filters' THEN p_values->'filters' ELSE filters END,version=gen_random_uuid(),updated_at=clock_timestamp() WHERE id=r.id RETURNING * INTO r;
 END IF;
 -- Validate SQL filter semantics without exposing any unscoped data.
 PERFORM public.redirect_analytics_report(r.filters,ARRAY[]::uuid[]);
 RETURN to_jsonb(r);
END $$;
CREATE FUNCTION public.redirect_report_budget(p_bucket text,p_limit integer,p_seconds integer) RETURNS integer
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE n integer;started timestamptz;now_at timestamptz:=clock_timestamp();
BEGIN
 INSERT INTO public.redirect_report_budgets AS b VALUES(p_bucket,now_at,1) ON CONFLICT(bucket) DO UPDATE SET
 window_at=CASE WHEN b.window_at<=now_at-make_interval(secs=>p_seconds) THEN now_at ELSE b.window_at END,
 attempts=CASE WHEN b.window_at<=now_at-make_interval(secs=>p_seconds) THEN 1 ELSE least(b.attempts+1,p_limit+1) END RETURNING attempts,window_at INTO n,started;
 RETURN CASE WHEN n>p_limit THEN greatest(1,ceil(extract(epoch FROM started+make_interval(secs=>p_seconds)-clock_timestamp()))::integer) ELSE 0 END;
END $$;
CREATE FUNCTION public.reserve_redirect_report_password(p_actor uuid,p_principal uuid) RETURNS integer
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE retry integer;
BEGIN
 PERFORM public.redirect_report_actor(p_actor,p_principal,true);
 retry:=public.redirect_report_budget('password-write-global',100,3600);IF retry>0 THEN RETURN retry;END IF;
 RETURN public.redirect_report_budget('password-write:'||p_actor::text,20,3600);
END $$;
CREATE FUNCTION public.redirect_report_share_resource(p_action text,p_actor uuid,p_principal uuid,p_report uuid,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT '{}',p_password_hash jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_saved_reports;s public.redirect_report_shares;ids uuid[];allowed uuid[];requires_owner boolean;result jsonb;
BEGIN
 IF p_action IS NULL OR p_action NOT IN('list','create','revoke') THEN RAISE EXCEPTION 'Invalid share action' USING ERRCODE='22023';END IF;
 PERFORM public.redirect_report_actor(p_actor,p_principal,p_action<>'list');
 SELECT * INTO r FROM public.redirect_saved_reports WHERE id=p_report AND owner_user_id=p_actor;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Report not found' USING ERRCODE='P0002';END IF;
 IF p_action='list' THEN
  SELECT jsonb_build_object('data',coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'scopeMode',scope_mode,'linkCount',cardinality(link_ids),'includeConversions',include_conversions,'hasPassword',password_hash IS NOT NULL,'createdAt',created_at,'expiresAt',expires_at,'revokedAt',revoked_at) ORDER BY created_at DESC,id),'[]'::jsonb)) INTO result FROM public.redirect_report_shares WHERE report_id=r.id;
  RETURN result;
 END IF;
 IF p_action='revoke' THEN
  UPDATE public.redirect_report_shares SET revoked_at=coalesce(revoked_at,clock_timestamp()),version=gen_random_uuid() WHERE id=p_id AND report_id=r.id RETURNING * INTO s;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Share not found' USING ERRCODE='P0002';END IF;
  RETURN jsonb_build_object('id',s.id,'revoked',true);
 END IF;
 IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR p_values-ARRAY['title','reportVersion','includeConversions','expiresAt','scopeMode']::text[]<>'{}' THEN RAISE EXCEPTION 'Invalid share fields' USING ERRCODE='22023';END IF;
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
 IF (SELECT count(*) FROM public.redirect_report_shares WHERE report_id=r.id AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>clock_timestamp()))>=20 THEN RAISE EXCEPTION 'Revoke an existing share before creating another' USING ERRCODE='22023';END IF;
 INSERT INTO public.redirect_report_shares(report_id,owner_user_id,title,filters,link_ids,requires_workspace_owner,scope_mode,include_conversions,password_hash,expires_at)
 VALUES(r.id,p_actor,btrim(p_values->>'title'),r.filters,ids,requires_owner,coalesce(p_values->>'scopeMode','snapshot'),coalesce((p_values->>'includeConversions')::boolean,false),nullif(p_password_hash,'null'::jsonb),(p_values->>'expiresAt')::timestamptz) RETURNING * INTO s;
 RETURN jsonb_build_object('id',s.id,'title',s.title,'linkCount',cardinality(s.link_ids),'scopeMode',s.scope_mode,'includeConversions',s.include_conversions,'hasPassword',s.password_hash IS NOT NULL,'expiresAt',s.expires_at);
END $$;

CREATE FUNCTION public.redirect_report_share_ids(p_id uuid) RETURNS uuid[]
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE s public.redirect_report_shares;principal uuid;allowed uuid[];ids uuid[];owner boolean:=false;
BEGIN
 SELECT * INTO s FROM public.redirect_report_shares WHERE id=p_id;
 PERFORM 1 FROM public.user_roles WHERE user_id=s.owner_user_id AND role='admin' FOR SHARE;
 owner:=FOUND;
 IF NOT owner THEN
  IF s.requires_workspace_owner THEN RAISE EXCEPTION 'Dashboard unavailable' USING ERRCODE='P0002';END IF;
  SELECT id INTO principal FROM public.redirect_workspace_members WHERE user_id=s.owner_user_id AND active AND kind='user' AND role='member' FOR SHARE;
  IF principal IS NULL THEN RAISE EXCEPTION 'Dashboard unavailable' USING ERRCODE='P0002';END IF;
  allowed:=public.redirect_management_scope(principal,'events:read');
 END IF;
 SELECT coalesce(array_agg(d.id),ARRAY[]::uuid[]) INTO ids FROM public.redirects d LEFT JOIN public.redirect_link_metadata m ON m.redirect_key='redirects:'||d.id::text
 WHERE d.type='SHORT' AND (s.scope_mode='folder' OR d.id=ANY(s.link_ids))
 AND (allowed IS NULL OR d.id=ANY(allowed)) AND (owner OR public.redirect_folder_rank(principal,m.folder_id)>=2)
 AND (NOT(s.filters?'folderId') OR m.folder_id=(s.filters->>'folderId')::uuid)
 AND (NOT(s.filters?'tagId') OR EXISTS(SELECT FROM public.redirect_link_tag_assignments t WHERE t.redirect_key='redirects:'||d.id::text AND t.tag_id=(s.filters->>'tagId')::uuid))
 AND (NOT(s.filters?'linkIds') OR d.id IN(SELECT value::uuid FROM jsonb_array_elements_text(s.filters->'linkIds')));
 IF NOT owner AND cardinality(ids)=0 THEN RAISE EXCEPTION 'Dashboard unavailable' USING ERRCODE='P0002';END IF;
 RETURN ids;
END $$;
CREATE FUNCTION public.redirect_public_report_check(p_id uuid,p_client_hash text,p_password_attempt boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE s public.redirect_report_shares;retry integer;bucket text;
BEGIN
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT * INTO s FROM public.redirect_report_shares WHERE id=p_id AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>clock_timestamp()) FOR SHARE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'Dashboard unavailable' USING ERRCODE='P0002';END IF;
 PERFORM public.redirect_report_share_ids(s.id);
 IF p_client_hash IS NULL OR p_client_hash !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid client hash' USING ERRCODE='22023';END IF;
 FOREACH bucket IN ARRAY ARRAY['view-global:'||s.id::text,'view:'||s.id::text||':'||p_client_hash] LOOP
  retry:=public.redirect_report_budget(bucket,CASE WHEN bucket LIKE 'view-global:%' THEN 2000 ELSE 60 END,900);IF retry>0 THEN RETURN jsonb_build_object('retryAfter',retry);END IF;
 END LOOP;
 IF p_password_attempt AND s.password_hash IS NOT NULL THEN
  retry:=public.redirect_report_budget('password-global:'||s.id::text,1000,900);IF retry>0 THEN RETURN jsonb_build_object('retryAfter',retry);END IF;
  retry:=public.redirect_report_budget('password:'||s.id::text||':'||p_client_hash,10,900);IF retry>0 THEN RETURN jsonb_build_object('retryAfter',retry);END IF;
 END IF;
 DELETE FROM public.redirect_report_budgets target WHERE target.bucket IN(SELECT b.bucket FROM public.redirect_report_budgets b WHERE window_at<clock_timestamp()-interval '1 day' ORDER BY window_at LIMIT 100 FOR UPDATE SKIP LOCKED);
 RETURN jsonb_build_object('id',s.id,'version',s.version,'passwordHash',s.password_hash);
END $$;
CREATE FUNCTION public.redirect_public_report_read(p_id uuid,p_version uuid,p_password_verified boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE s public.redirect_report_shares;ids uuid[];filters jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT * INTO s FROM public.redirect_report_shares WHERE id=p_id AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>clock_timestamp()) FOR SHARE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'Dashboard unavailable' USING ERRCODE='P0002';END IF;
 IF p_version IS DISTINCT FROM s.version OR (s.password_hash IS NOT NULL AND NOT coalesce(p_password_verified,false)) THEN RAISE EXCEPTION 'Dashboard access changed' USING ERRCODE='42501';END IF;
 ids:=public.redirect_report_share_ids(s.id);filters:=s.filters;
 IF NOT s.include_conversions THEN filters:=filters||'{"event":"click"}'::jsonb;END IF;
 RETURN jsonb_build_object('title',s.title,'includeConversions',s.include_conversions,'linkCount',cardinality(ids),'scopeMode',s.scope_mode,'expiresAt',s.expires_at,'report',public.redirect_analytics_report(filters,ids));
END $$;
CREATE INDEX redirect_report_budget_age ON public.redirect_report_budgets(window_at);
REVOKE ALL ON FUNCTION public.redirect_report_actor(uuid,uuid,boolean),public.redirect_saved_report_resource(text,uuid,uuid,uuid,jsonb,integer,uuid),public.redirect_report_budget(text,integer,integer),public.reserve_redirect_report_password(uuid,uuid),public.redirect_report_share_resource(text,uuid,uuid,uuid,uuid,jsonb,jsonb),public.redirect_report_share_ids(uuid),public.redirect_public_report_check(uuid,text,boolean),public.redirect_public_report_read(uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_report_actor(uuid,uuid,boolean),public.redirect_saved_report_resource(text,uuid,uuid,uuid,jsonb,integer,uuid),public.redirect_report_budget(text,integer,integer),public.reserve_redirect_report_password(uuid,uuid),public.redirect_report_share_resource(text,uuid,uuid,uuid,uuid,jsonb,jsonb),public.redirect_report_share_ids(uuid),public.redirect_public_report_check(uuid,text,boolean),public.redirect_public_report_read(uuid,uuid,boolean) TO service_role;
