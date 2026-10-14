-- Membership administration must check the actual owner in the same transaction.
CREATE FUNCTION public.redirect_member_administration(p_actor uuid,p_action text,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT '{}',p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE saved public.redirect_workspace_members; rows jsonb; total bigint;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 IF p_action='list' THEN PERFORM pg_advisory_xact_lock_shared(471983093);
 ELSE PERFORM pg_advisory_xact_lock(471983093);END IF;
 PERFORM 1 FROM public.user_roles WHERE user_id=p_actor AND role='admin' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Current workspace owner access required' USING ERRCODE='42501';END IF;
 IF p_action IS NULL OR p_action NOT IN('list','create','update','delete') THEN RAISE EXCEPTION 'Invalid membership operation' USING ERRCODE='22023';END IF;
 IF p_action='list' THEN
  IF p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 10000000 THEN RAISE EXCEPTION 'Invalid member page' USING ERRCODE='22023';END IF;
  SELECT count(*) INTO total FROM public.redirect_workspace_members;
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]') INTO rows FROM(SELECT id,user_id,kind,label,role,active,created_at FROM public.redirect_workspace_members ORDER BY id OFFSET p_offset LIMIT 100) r;
  RETURN jsonb_build_object('data',rows,'count',total);
 END IF;
 IF p_action IN('update','delete') AND p_id IS NULL OR p_action='create' AND p_id IS NOT NULL THEN RAISE EXCEPTION 'Invalid member ID' USING ERRCODE='22023';END IF;
 IF p_action='delete' THEN
  DELETE FROM public.redirect_workspace_members WHERE id=p_id RETURNING * INTO saved;
  RETURN jsonb_build_object('id',p_id,'deleted',saved.id IS NOT NULL);
 END IF;
 IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR p_values='{}' OR EXISTS(SELECT FROM jsonb_object_keys(p_values) k WHERE k NOT IN('label','role','active','kind','user_id') OR (p_action='update' AND k IN('kind','user_id'))) THEN RAISE EXCEPTION 'Invalid membership fields' USING ERRCODE='22023';END IF;
 IF (p_action='create' OR p_values?'label') AND (jsonb_typeof(p_values->'label') IS DISTINCT FROM 'string' OR length(btrim(p_values->>'label')) NOT BETWEEN 1 AND 100) THEN RAISE EXCEPTION 'Member label must be 1–100 characters' USING ERRCODE='22023';END IF;
 IF p_values?'role' AND (jsonb_typeof(p_values->'role') IS DISTINCT FROM 'string' OR p_values->>'role' NOT IN('member','viewer')) OR p_values?'active' AND jsonb_typeof(p_values->'active') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Invalid member role or status' USING ERRCODE='22023';END IF;
 IF p_action='create' THEN
  IF jsonb_typeof(p_values->'kind') IS DISTINCT FROM 'string' OR p_values->>'kind' NOT IN('user','machine') OR (p_values->>'kind'='user' AND (jsonb_typeof(p_values->'user_id') IS DISTINCT FROM 'string' OR NOT EXISTS(SELECT FROM auth.users WHERE id=(p_values->>'user_id')::uuid))) OR (p_values->>'kind'='machine' AND coalesce(p_values->'user_id','null'::jsonb)<>'null'::jsonb) THEN RAISE EXCEPTION 'Choose an existing account UUID or a machine member' USING ERRCODE='22023';END IF;
  INSERT INTO public.redirect_workspace_members(label,role,active,kind,user_id) VALUES(btrim(p_values->>'label'),coalesce(p_values->>'role','member'),coalesce((p_values->>'active')::boolean,true),p_values->>'kind',nullif(p_values->>'user_id','')::uuid) RETURNING * INTO saved;
 ELSE
  UPDATE public.redirect_workspace_members SET label=CASE WHEN p_values?'label' THEN btrim(p_values->>'label') ELSE label END,role=CASE WHEN p_values?'role' THEN p_values->>'role' ELSE role END,active=CASE WHEN p_values?'active' THEN (p_values->>'active')::boolean ELSE active END WHERE id=p_id RETURNING * INTO saved;
  IF saved.id IS NULL THEN RAISE EXCEPTION 'Member not found' USING ERRCODE='P0002';END IF;
 END IF;
 RETURN to_jsonb(saved);
END $$;
REVOKE ALL ON FUNCTION public.redirect_member_administration(uuid,text,uuid,jsonb,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_member_administration(uuid,text,uuid,jsonb,integer) TO service_role;
