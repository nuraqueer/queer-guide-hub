CREATE TABLE public.redirect_customer_profiles (
 customer_key text PRIMARY KEY REFERENCES public.redirect_link_customers(customer_key) ON DELETE CASCADE,
 name text CHECK(name IS NULL OR length(name) BETWEEN 1 AND 120 AND name !~ '[[:cntrl:]]'),
 email text CHECK(email IS NULL OR length(email)<=254 AND email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
 avatar_url text CHECK(avatar_url IS NULL OR length(avatar_url)<=2048 AND avatar_url ~ '^https://' AND avatar_url !~ '[[:space:]\\]' AND avatar_url !~ '^https://[^/]*@'),
 version uuid NOT NULL DEFAULT gen_random_uuid(), updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.redirect_customer_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_customer_profiles FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_customer_profiles TO service_role;

-- Serialize profile scope checks with new customer attribution, without global event locks.
CREATE FUNCTION public.redirect_customer_identity_lock() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE keys text[]; v_customer text;
BEGIN
 keys:=ARRAY[CASE WHEN TG_OP='DELETE' THEN OLD.customer_key ELSE NEW.customer_key END];
 IF TG_OP='UPDATE' THEN keys:=keys||OLD.customer_key;END IF;
 FOR v_customer IN SELECT DISTINCT entry FROM unnest(keys) AS entry WHERE entry IS NOT NULL ORDER BY entry LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended('redirect-customer:'||v_customer,0));
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
CREATE TRIGGER redirect_customer_conversion_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_link_conversions FOR EACH ROW EXECUTE FUNCTION public.redirect_customer_identity_lock();
CREATE TRIGGER redirect_customer_anchor_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_link_customers FOR EACH ROW EXECUTE FUNCTION public.redirect_customer_identity_lock();

CREATE FUNCTION public.redirect_customer_access(p_customer text,p_actor uuid,p_principal uuid,p_write boolean DEFAULT false)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[];ids uuid[];editable boolean;
BEGIN
 IF p_write THEN PERFORM pg_advisory_xact_lock(471983093);ELSE PERFORM pg_advisory_xact_lock_shared(471983093);END IF;
 IF p_customer IS NULL OR length(p_customer) NOT BETWEEN 1 AND 256 OR btrim(p_customer)='' OR p_customer ~ '[[:cntrl:]]' THEN RAISE EXCEPTION 'Provide a customer ID' USING ERRCODE='22023';END IF;
 IF p_principal IS NULL THEN
  IF NOT EXISTS(SELECT FROM public.user_roles WHERE user_id=p_actor AND role='admin') THEN RAISE EXCEPTION 'Workspace access required' USING ERRCODE='42501';END IF;
 ELSIF NOT EXISTS(SELECT FROM public.redirect_api_tokens WHERE id=p_principal) AND NOT EXISTS(SELECT FROM public.redirect_workspace_members WHERE id=p_principal AND user_id=p_actor AND active AND kind='user') THEN
  RAISE EXCEPTION 'Account does not match membership' USING ERRCODE='42501';
 END IF;
 allowed:=public.redirect_management_scope(p_principal,'events:read');
 PERFORM pg_advisory_xact_lock(hashtextextended('redirect-customer:'||p_customer,0));
 SELECT array_agg(DISTINCT redirect_id) INTO ids FROM (
  SELECT e.redirect_id FROM public.redirect_events e JOIN public.redirect_link_conversions c ON c.click_id=e.click_id WHERE c.customer_key=p_customer
  UNION SELECT e.redirect_id FROM public.redirect_events e JOIN public.redirect_link_customers c ON c.click_id=e.click_id WHERE c.customer_key=p_customer
 ) links;
 IF ids IS NULL OR(allowed IS NOT NULL AND NOT(ids&&allowed)) THEN RAISE EXCEPTION 'Customer not found' USING ERRCODE='P0002';END IF;
 SELECT coalesce(bool_and((allowed IS NULL OR id=ANY(allowed)) AND public.redirect_can_write_link(p_principal,id)),false) INTO editable FROM unnest(ids) AS id;
 IF p_write THEN
  allowed:=public.redirect_management_scope(p_principal,'links:write');
  IF NOT editable OR(allowed IS NOT NULL AND NOT(ids<@allowed)) THEN RAISE EXCEPTION 'Edit access to every customer link is required' USING ERRCODE='42501';END IF;
 END IF;
 RETURN editable;
END $$;

CREATE FUNCTION public.redirect_customer_profile(p_action text,p_customer text,p_actor uuid,p_principal uuid,p_values jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE profile public.redirect_customer_profiles;editable boolean;expected uuid;
BEGIN
 IF p_action IS NULL OR p_action NOT IN('get','patch','clear') THEN RAISE EXCEPTION 'Invalid customer action' USING ERRCODE='22023';END IF;
 editable:=public.redirect_customer_access(p_customer,p_actor,p_principal,p_action<>'get');
 IF p_action='get' THEN SELECT * INTO profile FROM public.redirect_customer_profiles WHERE customer_key=p_customer;
 ELSE
  IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR NOT(p_values?'version') OR p_values-ARRAY['version','name','email','avatarUrl']::text[]<>'{}' OR
    (p_values->'version'<>'null'::jsonb AND(jsonb_typeof(p_values->'version')<>'string' OR(p_values->>'version')!~*'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$')) THEN RAISE EXCEPTION 'Provide current profile fields and version' USING ERRCODE='22023';END IF;
  IF p_action='clear' AND p_values-ARRAY['version']::text[]<>'{}' THEN RAISE EXCEPTION 'Clear accepts only version' USING ERRCODE='22023';END IF;
  IF p_action='patch' AND p_values-ARRAY['version']::text[]='{}' THEN RAISE EXCEPTION 'Provide profile changes' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT FROM jsonb_each(p_values-ARRAY['version']::text[]) WHERE value<>'null'::jsonb AND jsonb_typeof(value)<>'string') THEN RAISE EXCEPTION 'Profile fields must be strings or null' USING ERRCODE='22023';END IF;
  expected:=(p_values->>'version')::uuid;
  SELECT * INTO profile FROM public.redirect_customer_profiles WHERE customer_key=p_customer FOR UPDATE;
  IF profile.version IS DISTINCT FROM expected THEN RAISE EXCEPTION 'Customer profile changed; reload before saving' USING ERRCODE='23505';END IF;
  IF profile.customer_key IS NULL THEN
   -- A removed original visit erases identity; explicit re-enrichment may anchor to a remaining recorded conversion.
   INSERT INTO public.redirect_link_customers(customer_key,click_id) SELECT p_customer,click_id FROM public.redirect_link_conversions WHERE customer_key=p_customer ORDER BY occurred_at,id LIMIT 1 ON CONFLICT(customer_key) DO NOTHING;
   INSERT INTO public.redirect_customer_profiles(customer_key) VALUES(p_customer);
  END IF;
  UPDATE public.redirect_customer_profiles SET
   name=CASE WHEN p_action='clear' THEN NULL WHEN p_values?'name' THEN nullif(btrim(p_values->>'name'),'') ELSE name END,
   email=CASE WHEN p_action='clear' THEN NULL WHEN p_values?'email' THEN nullif(btrim(p_values->>'email'),'') ELSE email END,
   avatar_url=CASE WHEN p_action='clear' THEN NULL WHEN p_values?'avatarUrl' THEN nullif(btrim(p_values->>'avatarUrl'),'') ELSE avatar_url END,
   version=gen_random_uuid(),updated_at=clock_timestamp() WHERE customer_key=p_customer RETURNING * INTO profile;
 END IF;
 RETURN jsonb_build_object('customerExternalId',p_customer,'name',profile.name,'email',profile.email,'avatarUrl',profile.avatar_url,'version',profile.version,'updatedAt',profile.updated_at,'canEdit',editable);
END $$;

CREATE FUNCTION public.redirect_customer_events(p_customer text,p_actor uuid,p_principal uuid,p_after_at timestamptz DEFAULT NULL,p_after_id text DEFAULT NULL,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[];result jsonb;
BEGIN
 PERFORM public.redirect_customer_access(p_customer,p_actor,p_principal,false);
 allowed:=public.redirect_management_scope(p_principal,'events:read');
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR(p_after_at IS NULL)<>(p_after_id IS NULL) OR(p_after_id IS NOT NULL AND p_after_id!~*'^(click|conversion):[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$') THEN RAISE EXCEPTION 'Invalid customer event page' USING ERRCODE='22023';END IF;
 WITH visits AS (
  SELECT DISTINCT click_id FROM public.redirect_link_conversions WHERE customer_key=p_customer
  UNION SELECT click_id FROM public.redirect_link_customers WHERE customer_key=p_customer
 ), journey AS (
  SELECT 'click:'||e.click_id AS id,'click' AS kind,e.ts AS occurred_at,coalesce(e.path,'/go/'||r.slug,r.source_path) AS source,'Visit' AS event_name,NULL::text AS amount,NULL::text AS currency,e.click_id
  FROM visits v JOIN public.redirect_events e ON e.click_id=v.click_id JOIN public.redirects r ON r.id=e.redirect_id WHERE allowed IS NULL OR e.redirect_id=ANY(allowed)
  UNION ALL
  SELECT 'conversion:'||c.id,c.kind,c.occurred_at,coalesce(e.path,'/go/'||r.slug,r.source_path),c.event_name,c.amount::text,c.currency,c.click_id
  FROM public.redirect_link_conversions c JOIN public.redirect_events e ON e.click_id=c.click_id JOIN public.redirects r ON r.id=e.redirect_id
  WHERE c.customer_key=p_customer AND(allowed IS NULL OR e.redirect_id=ANY(allowed))
 ), page AS(SELECT * FROM journey WHERE p_after_at IS NULL OR(occurred_at,id)>(p_after_at,p_after_id) ORDER BY occurred_at,id LIMIT p_limit+1),
 shown AS(SELECT * FROM page ORDER BY occurred_at,id LIMIT p_limit)
 SELECT jsonb_build_object('data',coalesce((SELECT jsonb_agg(to_jsonb(shown) ORDER BY occurred_at,id) FROM shown),'[]'::jsonb),'nextCursor',CASE WHEN(SELECT count(*) FROM page)>p_limit THEN(SELECT jsonb_build_object('at',occurred_at,'id',id) FROM shown ORDER BY occurred_at DESC,id DESC LIMIT 1) ELSE NULL END) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.redirect_customer_identity_lock(),public.redirect_customer_access(text,uuid,uuid,boolean),public.redirect_customer_profile(text,text,uuid,uuid,jsonb),public.redirect_customer_events(text,uuid,uuid,timestamptz,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_customer_identity_lock(),public.redirect_customer_access(text,uuid,uuid,boolean),public.redirect_customer_profile(text,text,uuid,uuid,jsonb),public.redirect_customer_events(text,uuid,uuid,timestamptz,text,integer) TO service_role;
