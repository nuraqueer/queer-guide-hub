-- Interactive defaults never rewrite existing links or API omission semantics.
CREATE TABLE public.redirect_domain_preferences(
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 domain_id uuid REFERENCES public.redirect_domains(id) ON DELETE SET NULL,
 version uuid NOT NULL DEFAULT gen_random_uuid(),updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.redirect_domain_preferences(singleton) VALUES(true);
ALTER TABLE public.redirect_domain_preferences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_domain_preferences FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_domain_preferences TO service_role;
CREATE TRIGGER redirect_domain_preference_acl BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_domain_preferences FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE FUNCTION public.redirect_domain_preference_stamp() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN NEW.version:=gen_random_uuid();NEW.updated_at:=clock_timestamp();RETURN NEW;END $$;
CREATE TRIGGER redirect_domain_preference_stamp BEFORE UPDATE ON public.redirect_domain_preferences FOR EACH ROW EXECUTE FUNCTION public.redirect_domain_preference_stamp();
CREATE FUNCTION public.redirect_domain_preference(p_actor uuid,p_values jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE pref public.redirect_domain_preferences;host text;
BEGIN
 IF p_values='null'::jsonb THEN p_values:=NULL;END IF;
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO pref FROM public.redirect_domain_preferences WHERE singleton FOR UPDATE;
 IF p_values IS NOT NULL THEN
  IF jsonb_typeof(p_values)<>'object' OR p_values-ARRAY['domainId','version']::text[]<>'{}' OR NOT(p_values?'domainId') OR (p_values->>'version')::uuid IS DISTINCT FROM pref.version THEN RAISE EXCEPTION 'Primary domain changed; refresh before saving' USING ERRCODE='23505';END IF;
  IF p_values->>'domainId' IS NOT NULL THEN
   SELECT hostname INTO host FROM public.redirect_domains WHERE id=(p_values->>'domainId')::uuid;
   IF host IS NULL OR public.redirect_public_domain(host,true) IS NULL THEN RAISE EXCEPTION 'Choose a domain with current ownership, TLS and routing proof' USING ERRCODE='22023';END IF;
  END IF;
  UPDATE public.redirect_domain_preferences SET domain_id=(p_values->>'domainId')::uuid WHERE singleton RETURNING * INTO pref;
 END IF;
 SELECT hostname INTO host FROM public.redirect_domains WHERE id=pref.domain_id;
 RETURN jsonb_build_object('domainId',pref.domain_id,'hostname',host,'version',pref.version,'ready',pref.domain_id IS NULL OR public.redirect_public_domain(host,true) IS NOT NULL);
END $$;
CREATE FUNCTION public.redirect_domain_choices(p_token_id uuid DEFAULT NULL,p_limit integer DEFAULT 100,p_after uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[];wide boolean;primary_id uuid;result jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 allowed:=public.redirect_management_scope(p_token_id,'links:read');
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid domain page' USING ERRCODE='22023';END IF;
 wide:=allowed IS NULL OR public.redirect_can_create_in_folder(p_token_id,NULL);
 IF wide THEN SELECT domain_id INTO primary_id FROM public.redirect_domain_preferences WHERE singleton;END IF;
 WITH ready AS MATERIALIZED(
  SELECT d.id,d.hostname FROM public.redirect_domains d
  WHERE (wide OR EXISTS(SELECT FROM public.redirects r WHERE r.domain_id=d.id AND r.id=ANY(allowed)))
   AND public.redirect_public_domain(d.hostname,true) IS NOT NULL
 ),page AS MATERIALIZED(SELECT * FROM ready WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit+1),
 shown AS MATERIALIZED(SELECT * FROM page ORDER BY id LIMIT p_limit)
 SELECT jsonb_build_object('data',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'hostname',hostname) ORDER BY id) FROM shown),'[]'::jsonb),
 'count',(SELECT count(*) FROM ready),'primaryDomainId',primary_id,'primaryUnavailable',primary_id IS NOT NULL AND NOT EXISTS(SELECT FROM ready WHERE id=primary_id),
 'nextCursor',CASE WHEN(SELECT count(*) FROM page)>p_limit THEN(SELECT max(id::text) FROM shown) ELSE NULL END) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.redirect_domain_preference_stamp(),public.redirect_domain_preference(uuid,jsonb),public.redirect_domain_choices(uuid,integer,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_domain_preference_stamp(),public.redirect_domain_preference(uuid,jsonb),public.redirect_domain_choices(uuid,integer,uuid) TO service_role;
