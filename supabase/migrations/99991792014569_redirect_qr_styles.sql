-- Saved appearance overrides are private; effective styles follow current link ACLs.
CREATE TABLE public.redirect_qr_styles(
 scope text PRIMARY KEY,domain_id uuid UNIQUE REFERENCES public.redirect_domains(id) ON DELETE CASCADE,
 style jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(style)='object' AND length(style::text)<=512),
 version uuid NOT NULL DEFAULT gen_random_uuid(),updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(scope=coalesce('domain:'||domain_id::text,'workspace'))
);
ALTER TABLE public.redirect_qr_styles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_qr_styles FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_qr_styles TO service_role;
CREATE TRIGGER redirect_qr_styles_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_qr_styles FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE FUNCTION public.redirect_qr_luminance(p_color text) RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT SET search_path=public,pg_temp AS $$
 SELECT sum(weight*CASE WHEN channel<=0.04045 THEN channel/12.92 ELSE power((channel+0.055)/1.055,2.4) END)
 FROM(SELECT weight,('x'||substr(p_color,position,2))::bit(8)::integer/255.0 AS channel FROM(VALUES(2,0.2126),(4,0.7152),(6,0.0722)) AS channels(position,weight)) AS linear;
$$;
CREATE FUNCTION public.redirect_qr_style_valid(p_style jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE dark double precision;light double precision;
BEGIN
 IF p_style IS NULL OR jsonb_typeof(p_style)<>'object' OR p_style-ARRAY['dots','border','center','foreground','background']::text[]<>'{}' OR coalesce(p_style->>'dots','') NOT IN('square','circle','joined') OR coalesce(p_style->>'border','') NOT IN('square','rounded','circle') OR coalesce(p_style->>'center','') NOT IN('square','circle') OR coalesce(p_style->>'foreground','') !~ '^#[a-fA-F0-9]{6}$' OR coalesce(p_style->>'background','') !~ '^#[a-fA-F0-9]{6}$' THEN RETURN false;END IF;
 dark:=public.redirect_qr_luminance(p_style->>'foreground');light:=public.redirect_qr_luminance(p_style->>'background');
 RETURN dark<light AND (light+0.05)/(dark+0.05)>=4.5;
END $$;
CREATE FUNCTION public.redirect_qr_effective_style(p_domain uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT '{"dots":"square","border":"square","center":"square","foreground":"#111111","background":"#ffffff"}'::jsonb
 ||coalesce((SELECT style FROM public.redirect_qr_styles WHERE scope='workspace'),'{}')
 ||coalesce((SELECT style FROM public.redirect_qr_styles WHERE domain_id=p_domain),'{}');
$$;
CREATE FUNCTION public.redirect_qr_style_resource(p_actor uuid,p_domain uuid DEFAULT NULL,p_values jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE key text:=coalesce('domain:'||p_domain::text,'workspace');r public.redirect_qr_styles;next_style jsonb;candidate uuid;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF p_domain IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_domains WHERE id=p_domain) THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 SELECT * INTO r FROM public.redirect_qr_styles WHERE scope=key FOR UPDATE;
 IF p_values IS NOT NULL AND p_values<>'null'::jsonb THEN
  IF jsonb_typeof(p_values)<>'object' OR NOT(p_values?'version') OR NOT(p_values?'style') OR p_values-ARRAY['version','style']::text[]<>'{}' OR jsonb_typeof(p_values->'style') NOT IN('object','null') THEN RAISE EXCEPTION 'Provide the current version and appearance overrides' USING ERRCODE='22023';END IF;
  IF r.version IS DISTINCT FROM (p_values->>'version')::uuid THEN RAISE EXCEPTION 'QR style changed; reload before saving' USING ERRCODE='23505';END IF;
  IF jsonb_typeof(p_values->'style')='object' AND (p_values->'style')-ARRAY['dots','border','center','foreground','background']::text[]<>'{}' THEN RAISE EXCEPTION 'Unknown QR appearance field' USING ERRCODE='22023';END IF;
  next_style:=CASE WHEN p_values->'style'='null'::jsonb THEN '{}'::jsonb ELSE jsonb_strip_nulls(coalesce(r.style,'{}')||(p_values->'style')) END;
  INSERT INTO public.redirect_qr_styles(scope,domain_id,style) VALUES(key,p_domain,next_style)
  ON CONFLICT(scope) DO UPDATE SET style=excluded.style,version=gen_random_uuid(),updated_at=clock_timestamp() RETURNING * INTO r;
  IF NOT public.redirect_qr_style_valid(public.redirect_qr_effective_style()) THEN RAISE EXCEPTION 'Use supported shapes and dark-on-light colors with at least 4.5:1 contrast' USING ERRCODE='22023';END IF;
  FOR candidate IN SELECT domain_id FROM public.redirect_qr_styles WHERE domain_id IS NOT NULL LOOP
   IF NOT public.redirect_qr_style_valid(public.redirect_qr_effective_style(candidate)) THEN RAISE EXCEPTION 'An effective domain QR style is invalid; adjust its overrides or choose stronger contrast' USING ERRCODE='22023';END IF;
  END LOOP;
 END IF;
 RETURN jsonb_build_object('version',r.version,'style',coalesce(r.style,'{}'),'effectiveStyle',public.redirect_qr_effective_style(p_domain),'domainId',p_domain);
END $$;
CREATE FUNCTION public.redirect_qr_styles_for_links(p_ids uuid[],p_token_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[];link public.redirects;link_id uuid;result jsonb:='[]';
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 allowed:=public.redirect_management_scope(p_token_id,'links:read');
 IF p_ids IS NULL OR cardinality(p_ids) NOT BETWEEN 1 AND 100 OR array_position(p_ids,NULL) IS NOT NULL OR cardinality(p_ids)<>(SELECT count(DISTINCT value) FROM unnest(p_ids) value) THEN RAISE EXCEPTION 'Choose 1–100 distinct link IDs' USING ERRCODE='22023';END IF;
 FOREACH link_id IN ARRAY p_ids LOOP
  SELECT * INTO link FROM public.redirects WHERE redirects.id=link_id AND type='SHORT' AND(allowed IS NULL OR redirects.id=ANY(allowed));
  IF link.id IS NULL THEN RAISE EXCEPTION 'Link not found' USING ERRCODE='P0002';END IF;
  result:=result||jsonb_build_array(jsonb_build_object('id',link.id,'style',public.redirect_qr_effective_style(link.domain_id),
   'source',CASE WHEN EXISTS(SELECT FROM public.redirect_qr_styles WHERE domain_id=link.domain_id AND style<>'{}') THEN 'domain' WHEN EXISTS(SELECT FROM public.redirect_qr_styles WHERE scope='workspace' AND style<>'{}') THEN 'workspace' ELSE 'default' END));
 END LOOP;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.redirect_qr_luminance(text),public.redirect_qr_style_valid(jsonb),public.redirect_qr_effective_style(uuid),public.redirect_qr_style_resource(uuid,uuid,jsonb),public.redirect_qr_styles_for_links(uuid[],uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_qr_luminance(text),public.redirect_qr_style_valid(jsonb),public.redirect_qr_effective_style(uuid),public.redirect_qr_style_resource(uuid,uuid,jsonb),public.redirect_qr_styles_for_links(uuid[],uuid) TO service_role;
