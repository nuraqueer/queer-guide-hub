-- Management facets use visible links, independent of domain readiness/registry.
CREATE FUNCTION public.redirect_linked_domains(p_token_id uuid DEFAULT NULL,p_limit integer DEFAULT 100,p_after uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[];result jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 allowed:=public.redirect_management_scope(p_token_id,'links:read');
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid domain page' USING ERRCODE='22023';END IF;
 WITH visible AS MATERIALIZED(
  SELECT r.domain_id,r.domain_hostname FROM public.redirects r WHERE r.type='SHORT' AND(allowed IS NULL OR r.id=ANY(allowed))
 ),domains AS MATERIALIZED(
  SELECT domain_id AS id,domain_hostname AS hostname,count(*) AS link_count FROM visible WHERE domain_id IS NOT NULL GROUP BY domain_id,domain_hostname
 ),page AS MATERIALIZED(SELECT * FROM domains WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit+1),
 shown AS MATERIALIZED(SELECT * FROM page ORDER BY id LIMIT p_limit)
 SELECT jsonb_build_object('data',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'hostname',hostname,'linkCount',link_count) ORDER BY id) FROM shown),'[]'::jsonb),
 'revision',md5((SELECT count(*)::text FROM visible WHERE domain_id IS NULL)||'|'||coalesce((SELECT string_agg(id::text||':'||hostname||':'||link_count::text,',' ORDER BY id) FROM domains),'')),
 'count',(SELECT count(*) FROM domains),'builtinCount',(SELECT count(*) FROM visible WHERE domain_id IS NULL),
 'nextCursor',CASE WHEN(SELECT count(*) FROM page)>p_limit THEN(SELECT max(id::text) FROM shown) ELSE NULL END) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.redirect_linked_domains(uuid,integer,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_linked_domains(uuid,integer,uuid) TO service_role;
