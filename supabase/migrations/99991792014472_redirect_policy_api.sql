-- Keep every supported policy writer in redirect-row → policy-row lock order.
CREATE OR REPLACE FUNCTION public.set_redirect_link_policy(p_redirect_id uuid,p_policy jsonb,p_password_hash jsonb,p_change_password boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE saved public.redirect_link_policies;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  PERFORM 1 FROM public.redirects WHERE id=p_redirect_id AND type='SHORT' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Managed short link not found' USING ERRCODE='P0002';
  END IF;
  INSERT INTO public.redirect_link_policies(redirect_id,policy,password_hash)
  VALUES (p_redirect_id,p_policy - 'expires_at',CASE WHEN p_change_password THEN p_password_hash ELSE NULL END)
  ON CONFLICT (redirect_id) DO UPDATE SET policy=excluded.policy,
    password_hash=CASE WHEN p_change_password THEN excluded.password_hash ELSE redirect_link_policies.password_hash END,
    updated_at=clock_timestamp() RETURNING * INTO saved;
  UPDATE public.redirects SET end_at=nullif(p_policy->>'expires_at','')::timestamptz, updated_at=clock_timestamp() WHERE id=p_redirect_id;
  RETURN jsonb_build_object('policy', saved.policy || jsonb_strip_nulls(jsonb_build_object('expires_at',nullif(p_policy->>'expires_at',''))),'has_password',saved.has_password);
END $$;
REVOKE ALL ON FUNCTION public.set_redirect_link_policy(uuid,jsonb,jsonb,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_redirect_link_policy(uuid,jsonb,jsonb,boolean) TO service_role;


CREATE FUNCTION public.redirect_policy_resource(p_redirect_id uuid,p_action text,p_patch jsonb DEFAULT '{}',p_password_hash jsonb DEFAULT NULL,p_change_password boolean DEFAULT false,p_token_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[]; link public.redirects; saved public.redirect_link_policies; merged jsonb; setting record;
BEGIN
 IF p_action IS NULL OR p_action NOT IN('get','patch') THEN RAISE EXCEPTION 'Invalid policy action' USING ERRCODE='22023'; END IF;
 allowed:=public.redirect_management_scope(p_token_id,CASE WHEN p_action='get' THEN 'links:read' ELSE 'links:write' END);
 IF allowed IS NOT NULL AND NOT(p_redirect_id=ANY(allowed)) THEN RAISE EXCEPTION 'Link is outside credential scope' USING ERRCODE='42501'; END IF;
 SELECT * INTO link FROM public.redirects WHERE id=p_redirect_id AND type='SHORT' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Managed short link not found' USING ERRCODE='P0002'; END IF;
 SELECT * INTO saved FROM public.redirect_link_policies WHERE redirect_id=p_redirect_id;
 merged:=coalesce(saved.policy,'{}')-'expires_at';
 IF p_action='patch' THEN
  IF p_patch IS NULL OR jsonb_typeof(p_patch)<>'object' OR p_patch-ARRAY['preview','cloaked','track_conversions','device_targets','geo_targets','experiment','expires_at','expired_target']::text[]<>'{}' THEN RAISE EXCEPTION 'Invalid policy fields' USING ERRCODE='22023'; END IF;
  FOR setting IN SELECT key,value FROM jsonb_each(p_patch-'expires_at') LOOP
   merged:=CASE WHEN setting.value='null'::jsonb THEN merged-setting.key ELSE merged||jsonb_build_object(setting.key,setting.value) END;
  END LOOP;
  INSERT INTO public.redirect_link_policies(redirect_id,policy,password_hash)
  VALUES(p_redirect_id,merged,CASE WHEN p_change_password THEN nullif(p_password_hash,'null'::jsonb) ELSE NULL END)
  ON CONFLICT(redirect_id) DO UPDATE SET policy=excluded.policy,password_hash=CASE WHEN p_change_password THEN excluded.password_hash ELSE redirect_link_policies.password_hash END,updated_at=clock_timestamp()
  RETURNING * INTO saved;
  UPDATE public.redirects SET end_at=CASE WHEN p_patch?'expires_at' THEN (p_patch->>'expires_at')::timestamptz ELSE end_at END,updated_at=clock_timestamp() WHERE id=p_redirect_id RETURNING * INTO link;
 END IF;
 RETURN jsonb_build_object('policy',(coalesce(saved.policy,'{}')-'expires_at')||jsonb_strip_nulls(jsonb_build_object('expires_at',link.end_at)),'hasPassword',coalesce(saved.has_password,false));
END $$;
REVOKE ALL ON FUNCTION public.redirect_policy_resource(uuid,text,jsonb,jsonb,boolean,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_policy_resource(uuid,text,jsonb,jsonb,boolean,uuid) TO service_role;

CREATE TABLE public.redirect_policy_password_limits(bucket text PRIMARY KEY,window_started_at timestamptz NOT NULL,attempts integer NOT NULL CHECK(attempts BETWEEN 1 AND 101));
ALTER TABLE public.redirect_policy_password_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_policy_password_limits FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_policy_password_limits TO service_role;
CREATE FUNCTION public.reserve_redirect_policy_password(p_redirect_id uuid,p_token_id uuid DEFAULT NULL,p_actor_id uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[]; key text; cap integer; used integer; started timestamptz; now_at timestamptz:=clock_timestamp();
BEGIN
 allowed:=public.redirect_management_scope(p_token_id,'links:write');
 IF allowed IS NOT NULL AND NOT(p_redirect_id=ANY(allowed)) THEN RAISE EXCEPTION 'Link is outside credential scope' USING ERRCODE='42501'; END IF;
 IF p_token_id IS NULL AND p_actor_id IS NULL THEN RAISE EXCEPTION 'Actor is required' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM public.redirects WHERE id=p_redirect_id AND type='SHORT' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Managed short link not found' USING ERRCODE='P0002'; END IF;
 FOREACH key IN ARRAY ARRAY['global','actor:'||coalesce(p_token_id,p_actor_id)::text,'link:'||p_redirect_id::text] LOOP
  cap:=CASE WHEN key='global' THEN 100 ELSE 20 END;
  INSERT INTO public.redirect_policy_password_limits AS r VALUES(key,now_at,1) ON CONFLICT(bucket) DO UPDATE SET
   window_started_at=CASE WHEN r.window_started_at<=now_at-interval '1 hour' THEN now_at ELSE r.window_started_at END,
   attempts=CASE WHEN r.window_started_at<=now_at-interval '1 hour' THEN 1 ELSE least(r.attempts+1,cap+1) END
  RETURNING attempts,window_started_at INTO used,started;
  IF used>cap THEN RETURN greatest(1,ceil(extract(epoch FROM started+interval '1 hour'-clock_timestamp()))::integer); END IF;
 END LOOP;
 DELETE FROM public.redirect_policy_password_limits WHERE bucket IN(SELECT bucket FROM public.redirect_policy_password_limits WHERE window_started_at<now_at-interval '1 day' LIMIT 100 FOR UPDATE SKIP LOCKED);
 RETURN 0;
END $$;
REVOKE ALL ON FUNCTION public.reserve_redirect_policy_password(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_redirect_policy_password(uuid,uuid,uuid) TO service_role;
