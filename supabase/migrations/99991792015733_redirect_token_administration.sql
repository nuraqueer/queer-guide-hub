CREATE FUNCTION public.redirect_token_metadata(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',id,'name',name,'prefix',prefix,'scopes',scopes,'redirect_ids',redirect_ids,'member_id',member_id,'created_at',created_at,'expires_at',expires_at,'revoked_at',revoked_at,'last_used_at',last_used_at) FROM public.redirect_api_tokens WHERE id=p_id;
$$;
REVOKE ALL ON FUNCTION public.redirect_token_metadata(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_token_metadata(uuid) TO service_role;

CREATE FUNCTION public.redirect_token_administration(p_actor uuid,p_action text,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT '{}',p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE scopes_value text[]; ids uuid[]; member uuid; expiry timestamptz; saved_id uuid; rows jsonb; total bigint;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 IF p_action='list' THEN PERFORM pg_advisory_xact_lock_shared(471983093);ELSE PERFORM pg_advisory_xact_lock(471983093);END IF;
 PERFORM 1 FROM public.user_roles WHERE user_id=p_actor AND role='admin' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Current workspace owner access required' USING ERRCODE='42501';END IF;
 IF p_action IS NULL OR p_action NOT IN('list','create','revoke') OR (p_action='revoke' AND p_id IS NULL) OR (p_action<>'revoke' AND p_id IS NOT NULL) THEN RAISE EXCEPTION 'Invalid credential operation' USING ERRCODE='22023';END IF;
 IF p_action='list' THEN
  IF p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 10000000 THEN RAISE EXCEPTION 'Invalid credential page' USING ERRCODE='22023';END IF;
  SELECT count(*) INTO total FROM public.redirect_api_tokens;
  SELECT coalesce(jsonb_agg(public.redirect_token_metadata(r.id) ORDER BY r.created_at DESC,r.id DESC),'[]') INTO rows FROM(SELECT id,created_at FROM public.redirect_api_tokens ORDER BY created_at DESC,id DESC OFFSET p_offset LIMIT 100) r;
  RETURN jsonb_build_object('data',rows,'count',total);
 END IF;
 IF p_action='revoke' THEN
  UPDATE public.redirect_api_tokens SET revoked_at=clock_timestamp() WHERE id=p_id AND revoked_at IS NULL RETURNING id INTO saved_id;
  RETURN jsonb_build_object('revoked',saved_id IS NOT NULL);
 END IF;
 IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR EXISTS(SELECT FROM jsonb_object_keys(p_values) k WHERE k NOT IN('name','expires_at','scopes','redirect_ids','member_id','token_hash','prefix')) THEN RAISE EXCEPTION 'Invalid credential fields' USING ERRCODE='22023';END IF;
 IF jsonb_typeof(p_values->'name') IS DISTINCT FROM 'string' OR length(btrim(p_values->>'name')) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Provide a credential name (1–100 characters)' USING ERRCODE='22023';END IF;
 IF jsonb_typeof(p_values->'token_hash') IS DISTINCT FROM 'string' OR p_values->>'token_hash' !~ '^[a-f0-9]{64}$' OR jsonb_typeof(p_values->'prefix') IS DISTINCT FROM 'string' OR p_values->>'prefix' !~ '^qg_redirect_[a-f0-9]{8}$' THEN RAISE EXCEPTION 'Invalid server credential digest' USING ERRCODE='22023';END IF;
 IF jsonb_typeof(p_values->'expires_at') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'Invalid credential expiry' USING ERRCODE='22023';END IF;
 expiry:=(p_values->>'expires_at')::timestamptz;
 IF NOT isfinite(expiry) OR expiry<=clock_timestamp() OR expiry>clock_timestamp()+interval '366 days' THEN RAISE EXCEPTION 'Credentials must expire within one year' USING ERRCODE='22023';END IF;
 IF jsonb_typeof(p_values->'scopes') IS DISTINCT FROM 'array' OR jsonb_array_length(p_values->'scopes') NOT BETWEEN 1 AND 6 OR EXISTS(SELECT FROM jsonb_array_elements(p_values->'scopes') e WHERE jsonb_typeof(e)<>'string') THEN RAISE EXCEPTION 'Invalid credential permissions' USING ERRCODE='22023';END IF;
 SELECT array_agg(DISTINCT value ORDER BY value) INTO scopes_value FROM jsonb_array_elements_text(p_values->'scopes');
 IF NOT(scopes_value<@ARRAY['links:read','links:write','workspace:read','workspace:write','events:read','conversions:write']::text[]) THEN RAISE EXCEPTION 'Invalid credential permissions' USING ERRCODE='22023';END IF;
 IF coalesce(p_values->'redirect_ids','null'::jsonb)<>'null'::jsonb THEN
  IF jsonb_typeof(p_values->'redirect_ids')<>'array' OR jsonb_array_length(p_values->'redirect_ids') NOT BETWEEN 1 AND 100 OR EXISTS(SELECT FROM jsonb_array_elements(p_values->'redirect_ids') e WHERE jsonb_typeof(e)<>'string') THEN RAISE EXCEPTION 'Invalid link scope' USING ERRCODE='22023';END IF;
  SELECT array_agg(DISTINCT value::uuid ORDER BY value::uuid) INTO ids FROM jsonb_array_elements_text(p_values->'redirect_ids');
  IF 'workspace:read'=ANY(scopes_value) OR 'workspace:write'=ANY(scopes_value) THEN RAISE EXCEPTION 'Workspace permissions require an unrestricted credential' USING ERRCODE='22023';END IF;
  PERFORM 1 FROM public.redirects WHERE id=ANY(ids) AND type='SHORT' ORDER BY id FOR SHARE;
  IF (SELECT count(*) FROM public.redirects WHERE id=ANY(ids) AND type='SHORT')<>cardinality(ids) THEN RAISE EXCEPTION 'One or more managed links were not found' USING ERRCODE='22023';END IF;
 END IF;
 IF coalesce(p_values->'member_id','null'::jsonb)<>'null'::jsonb THEN
  IF jsonb_typeof(p_values->'member_id')<>'string' THEN RAISE EXCEPTION 'Invalid member binding' USING ERRCODE='22023';END IF;
  member:=(p_values->>'member_id')::uuid;
  PERFORM 1 FROM public.redirect_workspace_members WHERE id=member AND active FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Active workspace member required' USING ERRCODE='22023';END IF;
 END IF;
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,redirect_ids,member_id,created_by,expires_at) VALUES(btrim(p_values->>'name'),p_values->>'token_hash',p_values->>'prefix',scopes_value,ids,member,p_actor,expiry) RETURNING id INTO saved_id;
 RETURN public.redirect_token_metadata(saved_id);
END $$;
REVOKE ALL ON FUNCTION public.redirect_token_administration(uuid,text,uuid,jsonb,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_token_administration(uuid,text,uuid,jsonb,integer) TO service_role;

CREATE OR REPLACE FUNCTION public.authenticate_redirect_api_token(p_hash text,p_scope text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE t public.redirect_api_tokens;
BEGIN
 IF current_user <> 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 IF p_scope LIKE '%:write' THEN PERFORM pg_advisory_xact_lock(471983093);
 ELSE PERFORM pg_advisory_xact_lock_shared(471983093);END IF;
 SELECT * INTO t FROM public.redirect_api_tokens WHERE token_hash=p_hash
 AND revoked_at IS NULL AND expires_at>clock_timestamp() AND p_scope=ANY(scopes) FOR UPDATE;
 IF t.id IS NULL THEN RETURN NULL;END IF;
 BEGIN
  PERFORM public.redirect_management_scope(t.id,p_scope);
 EXCEPTION WHEN insufficient_privilege THEN
  -- Permission revocation is an authentication denial, just like expiry.
  -- Resource functions still raise 42501 on later scope changes.
  RETURN NULL;
 END;
 UPDATE public.redirect_api_tokens SET last_used_at=now() WHERE id=t.id;
 RETURN jsonb_build_object('id',t.id,'redirect_ids',t.redirect_ids,'scopes',t.scopes);
END $$;
REVOKE ALL ON FUNCTION public.redirect_management_scope(uuid,text),public.authenticate_redirect_api_token(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_management_scope(uuid,text),public.authenticate_redirect_api_token(text,text) TO service_role;
