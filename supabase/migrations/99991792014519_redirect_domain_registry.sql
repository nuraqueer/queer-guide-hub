-- Private workspace domain registry; ownership proof does not activate routing.
CREATE TABLE public.redirect_domains(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),hostname text NOT NULL UNIQUE,
 verification_token text NOT NULL DEFAULT replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),
 ownership_state text NOT NULL DEFAULT 'pending' CHECK(ownership_state IN('pending','verified','lost')),
 verified_at timestamptz,verified_until timestamptz,last_checked_at timestamptz,next_check_at timestamptz,
 last_check text CHECK(last_check IN('verified','missing','unavailable')),verification_attempt uuid,
 root_url text,not_found_url text,expired_url text,disabled boolean NOT NULL DEFAULT false,
 provider_id text,version uuid NOT NULL DEFAULT gen_random_uuid(),created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(length(hostname) BETWEEN 4 AND 239 AND hostname=lower(hostname) AND hostname ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'),
 CHECK(hostname !~ '(^|\.)(queer\.guide|supabase\.co|workers\.dev|pages\.dev|cloudflare\.com|localhost|local|internal|home|test|invalid|example|onion)$'),
 CHECK(verification_token ~ '^[a-f0-9]{64}$')
);
ALTER TABLE public.redirect_domains ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_domains FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_domains TO service_role;
CREATE TRIGGER redirect_domains_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_domains FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE FUNCTION public.redirect_domain_actor(p_actor uuid) RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 PERFORM 1 FROM public.user_roles WHERE user_id=p_actor AND role='admin' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Workspace owner access required' USING ERRCODE='42501';END IF;
END $$;
CREATE FUNCTION public.redirect_domain_json(p_id uuid) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',id,'hostname',hostname,'version',version,'disabled',disabled,'ownershipState',ownership_state,
 'ownershipVerified',ownership_state='verified' AND verified_until>clock_timestamp(),'verifiedAt',verified_at,'verifiedUntil',verified_until,
 'lastCheckedAt',last_checked_at,'lastCheck',last_check,'nextCheckAt',next_check_at,
 'rootUrl',root_url,'notFoundUrl',not_found_url,'expiredUrl',expired_url,'providerConnected',provider_id IS NOT NULL,
 'verification',jsonb_build_object('type','TXT','name','_qg-redirect.'||hostname,'value','qg-redirect='||verification_token))
 FROM public.redirect_domains WHERE id=p_id;
$$;
CREATE FUNCTION public.redirect_domain_public_host(p_host text) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
 IF p_host ~ '^([0-9]{1,3}\.){3}[0-9]{1,3}$' THEN
  RETURN NOT(p_host::inet <<= ANY(ARRAY['0.0.0.0/8','10.0.0.0/8','127.0.0.0/8','169.254.0.0/16','172.16.0.0/12','192.168.0.0/16','100.64.0.0/10','224.0.0.0/3']::inet[]));
 END IF;
 RETURN p_host ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$';
EXCEPTION WHEN invalid_text_representation THEN RETURN false;
END $$;
CREATE FUNCTION public.redirect_domain_destination(p_url text,p_hostname text) RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT p_url IS NULL OR (
 length(p_url) BETWEEN 10 AND 8192 AND p_url !~ '[[:space:]\\]' AND
 p_url ~ '^https?://[^/:?#]+(:[0-9]{1,5})?([/?#]|$)' AND public.redirect_domain_public_host(substring(p_url FROM '^https?://([^/:?#]+)')) AND
 substring(p_url FROM '^https?://([^/:?#]+)')<>p_hostname AND
 substring(p_url FROM '^https?://([^/:?#]+)') !~ '(^|\.)(localhost|local|internal|home|test|invalid|example|onion)$' AND
 NOT EXISTS(SELECT FROM public.redirect_domains WHERE hostname=substring(p_url FROM '^https?://([^/:?#]+)')) AND
 p_url !~ '^https?://(www\.)?queer\.guide(:[0-9]+)?/go(/|[?#]|$)');
$$;
CREATE FUNCTION public.redirect_domain_resource(p_action text,p_actor uuid,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT '{}',p_limit integer DEFAULT 50,p_after uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_domains;result jsonb;field text;retry integer;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF p_action='list' THEN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid domain page' USING ERRCODE='22023';END IF;
  WITH page AS MATERIALIZED(SELECT id FROM public.redirect_domains WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit+1),shown AS(SELECT id FROM page ORDER BY id LIMIT p_limit)
  SELECT jsonb_build_object('data',coalesce(jsonb_agg(public.redirect_domain_json(id) ORDER BY id),'[]'),'count',(SELECT count(*) FROM public.redirect_domains),'nextCursor',CASE WHEN(SELECT count(*) FROM page)>p_limit THEN max(id::text) ELSE NULL END) INTO result FROM shown;RETURN result;
 END IF;
 IF p_action IS NULL OR p_action NOT IN('get','create','patch','delete','rotate','reserve') THEN RAISE EXCEPTION 'Invalid domain action' USING ERRCODE='22023';END IF;
 IF p_action<>'create' THEN SELECT * INTO r FROM public.redirect_domains WHERE id=p_id FOR UPDATE;IF r.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;END IF;
 IF p_action='get' THEN RETURN public.redirect_domain_json(r.id);END IF;
 IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' THEN RAISE EXCEPTION 'Invalid domain fields' USING ERRCODE='22023';END IF;
 IF p_action<>'create' AND (p_values->>'version')::uuid IS DISTINCT FROM r.version THEN RAISE EXCEPTION 'Domain changed; reload before continuing' USING ERRCODE='23505';END IF;
 IF p_action IN('delete','rotate','reserve') AND p_values-ARRAY['version']::text[]<>'{}' THEN RAISE EXCEPTION 'Provide only the current domain version' USING ERRCODE='22023';END IF;
 IF p_action='delete' THEN
  IF r.provider_id IS NOT NULL THEN RAISE EXCEPTION 'Disconnect the provider hostname before removing this domain' USING ERRCODE='22023';END IF;
  DELETE FROM public.redirect_domains WHERE id=r.id;RETURN jsonb_build_object('id',r.id,'deleted',true);
 END IF;
 IF p_action='rotate' THEN
  UPDATE public.redirect_domains SET verification_token=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),ownership_state='pending',verified_at=NULL,verified_until=NULL,verification_attempt=NULL,version=gen_random_uuid(),updated_at=clock_timestamp() WHERE id=r.id;
  RETURN public.redirect_domain_json(r.id);
 END IF;
 IF p_action='reserve' THEN
  IF r.disabled THEN RAISE EXCEPTION 'Enable this domain before checking ownership' USING ERRCODE='22023';END IF;
  IF r.next_check_at>clock_timestamp() THEN RETURN jsonb_build_object('retryAfter',greatest(1,ceil(extract(epoch FROM r.next_check_at-clock_timestamp()))::integer));END IF;
  retry:=public.redirect_report_budget('domain-check-global',100,3600);IF retry=0 THEN retry:=public.redirect_report_budget('domain-check:'||p_actor::text,30,3600);END IF;
  IF retry>0 THEN RETURN jsonb_build_object('retryAfter',retry);END IF;
  UPDATE public.redirect_domains SET verification_attempt=gen_random_uuid(),next_check_at=clock_timestamp()+interval '1 minute' WHERE id=r.id RETURNING * INTO r;
  RETURN jsonb_build_object('domain',public.redirect_domain_json(r.id),'attempt',r.verification_attempt);
 END IF;
 IF p_values-ARRAY['hostname','version','rootUrl','notFoundUrl','expiredUrl','disabled']::text[]<>'{}' OR (p_action='patch' AND p_values?'hostname') THEN RAISE EXCEPTION 'Invalid domain fields' USING ERRCODE='22023';END IF;
 IF p_action='create' THEN
  IF p_values?'version' THEN RAISE EXCEPTION 'Do not provide a creation version' USING ERRCODE='22023';END IF;
  INSERT INTO public.redirect_domains(hostname,created_by) VALUES(p_values->>'hostname',p_actor) RETURNING * INTO r;
 END IF;
 FOREACH field IN ARRAY ARRAY['rootUrl','notFoundUrl','expiredUrl'] LOOP
  IF p_values?field AND (jsonb_typeof(p_values->field) NOT IN('string','null') OR NOT public.redirect_domain_destination(p_values->>field,r.hostname)) THEN RAISE EXCEPTION 'Choose a public HTTP(S) destination outside redirect domains' USING ERRCODE='22023';END IF;
 END LOOP;
 IF p_values?'disabled' AND jsonb_typeof(p_values->'disabled')<>'boolean' THEN RAISE EXCEPTION 'Invalid domain state' USING ERRCODE='22023';END IF;
 UPDATE public.redirect_domains SET root_url=CASE WHEN p_values?'rootUrl' THEN p_values->>'rootUrl' ELSE root_url END,
 not_found_url=CASE WHEN p_values?'notFoundUrl' THEN p_values->>'notFoundUrl' ELSE not_found_url END,
 expired_url=CASE WHEN p_values?'expiredUrl' THEN p_values->>'expiredUrl' ELSE expired_url END,
 disabled=CASE WHEN p_values?'disabled' THEN (p_values->>'disabled')::boolean ELSE disabled END,
 verification_attempt=NULL,version=gen_random_uuid(),updated_at=clock_timestamp() WHERE id=r.id;
 RETURN public.redirect_domain_json(r.id);
END $$;
CREATE FUNCTION public.redirect_domain_check_result(p_actor uuid,p_id uuid,p_version uuid,p_attempt uuid,p_outcome text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_domains;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO r FROM public.redirect_domains WHERE id=p_id FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF r.disabled OR r.next_check_at IS NULL OR r.next_check_at<=clock_timestamp() OR p_version IS DISTINCT FROM r.version OR p_attempt IS NULL OR p_attempt IS DISTINCT FROM r.verification_attempt THEN RAISE EXCEPTION 'Domain changed; check ownership again' USING ERRCODE='23505';END IF;
 IF p_outcome IS NULL OR p_outcome NOT IN('verified','missing','unavailable') THEN RAISE EXCEPTION 'Invalid DNS result' USING ERRCODE='22023';END IF;
 UPDATE public.redirect_domains SET ownership_state=CASE WHEN p_outcome='verified' THEN 'verified' WHEN p_outcome='missing' AND verified_at IS NOT NULL THEN 'lost' WHEN p_outcome='missing' THEN 'pending' ELSE ownership_state END,
 verified_at=CASE WHEN p_outcome='verified' THEN clock_timestamp() ELSE verified_at END,
 verified_until=CASE WHEN p_outcome='verified' THEN clock_timestamp()+interval '24 hours' WHEN p_outcome='missing' THEN NULL ELSE verified_until END,
 last_checked_at=clock_timestamp(),last_check=p_outcome,verification_attempt=NULL,version=gen_random_uuid(),updated_at=clock_timestamp() WHERE id=r.id;
 RETURN public.redirect_domain_json(r.id);
END $$;
REVOKE ALL ON FUNCTION public.redirect_domain_actor(uuid),public.redirect_domain_json(uuid),public.redirect_domain_public_host(text),public.redirect_domain_destination(text,text),public.redirect_domain_resource(text,uuid,uuid,jsonb,integer,uuid),public.redirect_domain_check_result(uuid,uuid,uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_domain_actor(uuid),public.redirect_domain_json(uuid),public.redirect_domain_public_host(text),public.redirect_domain_destination(text,text),public.redirect_domain_resource(text,uuid,uuid,jsonb,integer,uuid),public.redirect_domain_check_result(uuid,uuid,uuid,uuid,text) TO service_role;
