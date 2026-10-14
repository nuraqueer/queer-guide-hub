-- Hostname namespaces and live routing proof; registry and provider state stay private.
ALTER TABLE public.redirect_domains ADD COLUMN routing_seen_at timestamptz,
 ADD COLUMN routing_provider_id text, ADD COLUMN routing_protocol integer;
ALTER TABLE public.redirects ADD COLUMN domain_id uuid REFERENCES public.redirect_domains(id) ON DELETE RESTRICT,
 ADD COLUMN domain_hostname text,
 ADD CONSTRAINT redirects_domain_short CHECK(domain_id IS NULL OR type='SHORT'),
 ADD CONSTRAINT redirects_domain_pair CHECK((domain_id IS NULL)=(domain_hostname IS NULL));
ALTER TABLE public.redirects DROP CONSTRAINT IF EXISTS redirects_slug_key;
DROP INDEX IF EXISTS public.idx_redirects_slug_unique;
CREATE UNIQUE INDEX redirects_builtin_slug_unique ON public.redirects(slug) WHERE type='SHORT' AND domain_id IS NULL;
CREATE UNIQUE INDEX redirects_domain_slug_unique ON public.redirects(domain_id,slug) WHERE type='SHORT' AND domain_id IS NOT NULL;

-- The caller must first verify the domain-separated relay MAC. No ownership
-- challenge or provider credentials leave this service-only context.
CREATE FUNCTION public.redirect_public_domain(p_hostname text,p_require_route boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE d public.redirect_domains;j public.redirect_domain_jobs;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT * INTO d FROM public.redirect_domains WHERE hostname=p_hostname FOR SHARE;
 IF d.id IS NULL OR d.disabled OR d.provider_id IS NULL OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() THEN RETURN NULL;END IF;
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE domain_id=d.id FOR SHARE;
 IF j.domain_id IS NULL OR NOT j.desired OR j.state IN('failed','review','disconnected') OR j.provider_status IS DISTINCT FROM 'active' OR j.ssl_status IS DISTINCT FROM 'active' OR j.checked_at IS NULL OR j.checked_at<=clock_timestamp()-interval '15 minutes' THEN RETURN NULL;END IF;
 PERFORM 1 FROM public.user_roles WHERE user_id=j.requested_by AND role='admin' FOR SHARE;
 IF NOT FOUND THEN RETURN NULL;END IF;
 IF p_require_route AND (d.routing_protocol IS DISTINCT FROM 1 OR d.routing_provider_id IS DISTINCT FROM d.provider_id OR d.routing_seen_at IS NULL OR d.routing_seen_at<=clock_timestamp()-interval '24 hours') THEN RETURN NULL;END IF;
 RETURN jsonb_build_object('id',d.id,'hostname',d.hostname,'rootUrl',d.root_url,'notFoundUrl',d.not_found_url,'expiredUrl',d.expired_url,'needsRouteRefresh',d.routing_protocol IS DISTINCT FROM 1 OR d.routing_provider_id IS DISTINCT FROM d.provider_id OR d.routing_seen_at IS NULL OR d.routing_seen_at<clock_timestamp()-interval '6 hours');
END $$;

CREATE FUNCTION public.record_redirect_domain_route(p_hostname text) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE context jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 -- Acquire exclusive ACL lock first: the registry update also takes this lock.
 PERFORM pg_advisory_xact_lock(471983093);
 context:=public.redirect_public_domain(p_hostname);
 IF context IS NULL THEN RETURN false;END IF;
 UPDATE public.redirect_domains SET routing_seen_at=clock_timestamp(),routing_provider_id=provider_id,routing_protocol=1 WHERE id=(context->>'id')::uuid;
 RETURN true;
END $$;

CREATE FUNCTION public.redirect_link_domain_binding() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE host text;
BEGIN
 IF TG_OP='UPDATE' AND NEW.domain_id IS NOT DISTINCT FROM OLD.domain_id THEN
  NEW.domain_hostname:=OLD.domain_hostname;RETURN NEW;
 END IF;
 IF NEW.domain_id IS NULL THEN NEW.domain_hostname:=NULL;RETURN NEW;END IF;
 SELECT hostname INTO host FROM public.redirect_domains WHERE id=NEW.domain_id;
 IF host IS NULL OR public.redirect_public_domain(host,true) IS NULL THEN RAISE EXCEPTION 'Choose a domain with current ownership, TLS and routing proof' USING ERRCODE='22023';END IF;
 NEW.domain_hostname:=host;RETURN NEW;
END $$;
CREATE TRIGGER redirect_link_domain_binding BEFORE INSERT OR UPDATE ON public.redirects FOR EACH ROW EXECUTE FUNCTION public.redirect_link_domain_binding();
REVOKE ALL ON FUNCTION public.redirect_public_domain(text,boolean),public.record_redirect_domain_route(text),public.redirect_link_domain_binding() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_public_domain(text,boolean),public.record_redirect_domain_route(text),public.redirect_link_domain_binding() TO service_role;

CREATE OR REPLACE FUNCTION public.redirect_management_link(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',r.id,'slug',r.slug,'target',r.target,'statusCode',r.status_code,
  'startsAt',r.start_at,'clickLimit',r.click_limit,'isEnabled',r.is_enabled,'isArchived',coalesce(m.is_archived,false),'queryMode',r.query_mode,'queryOverride',r.query_override,'utmDefaults',r.utm_defaults,
  'expiresAt',r.end_at,'clicks',r.click_count,'updatedAt',r.updated_at,
  'domainId',r.domain_id,'domainHostname',r.domain_hostname,
  'shortUrl',CASE WHEN r.domain_id IS NULL THEN 'https://queer.guide/go/'||r.slug ELSE 'https://'||r.domain_hostname||'/'||r.slug END,'folderId',m.folder_id,'comment',coalesce(m.comment,''),
  'tagIds',coalesce((SELECT jsonb_agg(a.tag_id ORDER BY a.tag_id) FROM public.redirect_link_tag_assignments a WHERE a.redirect_key='redirects:'||r.id::text),'[]'::jsonb))
 FROM public.redirects r LEFT JOIN public.redirect_link_metadata m ON m.redirect_key='redirects:'||r.id::text
 WHERE r.id=p_id AND r.type='SHORT'
$$;

CREATE OR REPLACE FUNCTION public.redirect_management_list(p_filters jsonb DEFAULT '{}',p_limit integer DEFAULT 50,p_after uuid DEFAULT NULL,p_token_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[]; result jsonb;
BEGIN
 allowed:=public.redirect_management_scope(p_token_id,'links:read');
 IF p_limit IS NULL OR p_limit NOT BETWEEN 0 AND 100 OR p_filters IS NULL OR jsonb_typeof(p_filters)<>'object' THEN RAISE EXCEPTION 'Invalid link page' USING ERRCODE='22023'; END IF;
 WITH filtered AS MATERIALIZED (
  SELECT r.id FROM public.redirects r LEFT JOIN public.redirect_link_metadata m ON m.redirect_key='redirects:'||r.id::text
  WHERE r.type='SHORT' AND (allowed IS NULL OR r.id=ANY(allowed))
   AND (NOT(p_filters?'domainId') OR r.domain_id IS NOT DISTINCT FROM (p_filters->>'domainId')::uuid)
   AND (NOT(p_filters?'ids') OR r.id IN(SELECT value::uuid FROM jsonb_array_elements_text(p_filters->'ids')))
   AND (NOT(p_filters?'search') OR strpos(lower(coalesce(r.slug,'')||' '||r.target),lower(p_filters->>'search'))>0)
   AND (NOT(p_filters?'isArchived') OR coalesce(m.is_archived,false)=(p_filters->>'isArchived')::boolean)
   AND (NOT(p_filters?'isEnabled') OR r.is_enabled=(p_filters->>'isEnabled')::boolean)
   AND (NOT(p_filters?'folderId') OR m.folder_id=(p_filters->>'folderId')::uuid)
   AND (NOT(p_filters?'tagId') OR EXISTS(SELECT FROM public.redirect_link_tag_assignments a WHERE a.redirect_key='redirects:'||r.id::text AND a.tag_id=(p_filters->>'tagId')::uuid))
 ), page AS MATERIALIZED(SELECT id FROM filtered WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit+1),
 shown AS MATERIALIZED(SELECT id FROM page ORDER BY id LIMIT p_limit)
 SELECT jsonb_build_object('count',(SELECT count(*) FROM filtered),
  'data',coalesce((SELECT jsonb_agg(public.redirect_management_link(id)||jsonb_build_object('canEdit',public.redirect_can_write_link(p_token_id,id)) ORDER BY id) FROM shown),'[]'::jsonb),
  'nextCursor',CASE WHEN p_limit>0 AND (SELECT count(*) FROM page)>p_limit THEN (SELECT max(id::text) FROM shown) ELSE NULL END) INTO result;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.redirect_management_mutate(p_operations jsonb,p_token_id uuid DEFAULT NULL,p_actor_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[]; op jsonb; d jsonb; mode text; r public.redirects; patch jsonb;
 key text; folder uuid; tags uuid[]; comment_value text; created boolean; output jsonb:='[]'; attempt integer;
BEGIN
 allowed:=public.redirect_management_scope(p_token_id,'links:write');
 IF p_token_id IS NOT NULL THEN SELECT coalesce((SELECT created_by FROM public.redirect_api_tokens WHERE id=p_token_id),(SELECT user_id FROM public.redirect_workspace_members WHERE id=p_token_id)) INTO p_actor_id; END IF;
 IF p_operations IS NULL OR jsonb_typeof(p_operations)<>'array' OR jsonb_array_length(p_operations) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Provide 1–100 operations' USING ERRCODE='22023'; END IF;
 -- Serialize API batches to give upserts and mixed batches deterministic atomic behavior.
 PERFORM pg_advisory_xact_lock(471983092);
 FOR op IN SELECT value FROM jsonb_array_elements(p_operations) LOOP
  mode:=op->>'operation'; d:=coalesce(op->'data','{}'); created:=false; r:=NULL;
  IF mode NOT IN('create','update','upsert','delete') OR mode IS NULL THEN RAISE EXCEPTION 'Invalid operation' USING ERRCODE='22023'; END IF;
  IF mode IN('update','delete') THEN SELECT * INTO r FROM public.redirects WHERE id=(op->>'id')::uuid AND type='SHORT' FOR UPDATE;
  ELSIF mode='upsert' THEN SELECT * INTO r FROM public.redirects WHERE slug=d->>'slug' AND type='SHORT' AND domain_id IS NOT DISTINCT FROM (d->>'domainId')::uuid FOR UPDATE;
  END IF;
  IF mode IN('update','delete') AND r.id IS NULL THEN RAISE EXCEPTION 'Link not found' USING ERRCODE='P0002'; END IF;
  IF allowed IS NOT NULL AND r.id IS NOT NULL AND NOT(r.id=ANY(allowed)) THEN RAISE EXCEPTION 'Link is outside credential scope' USING ERRCODE='42501';END IF;
  IF r.id IS NULL AND NOT public.redirect_can_create_in_folder(p_token_id,(d->>'folderId')::uuid) THEN RAISE EXCEPTION 'Cannot create links in this folder' USING ERRCODE='42501';END IF;
  IF d?'folderId' AND public.redirect_folder_rank(public.redirect_principal_member(p_token_id),(d->>'folderId')::uuid)<2 THEN RAISE EXCEPTION 'Destination folder requires edit access' USING ERRCODE='42501';END IF;
  IF mode='delete' THEN
   DELETE FROM public.redirect_link_metadata WHERE redirect_key='redirects:'||r.id::text;
   DELETE FROM public.redirects WHERE id=r.id;
   output:=output||jsonb_build_array(jsonb_build_object('operation',mode,'id',r.id,'deleted',true));
   CONTINUE;
  END IF;
  IF r.id IS NULL THEN
   IF length(d->>'target') NOT BETWEEN 1 AND 8192 OR d->>'target' IS NULL THEN RAISE EXCEPTION 'Destination required' USING ERRCODE='22023'; END IF;
   IF d?'slug' THEN
    INSERT INTO public.redirects(type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by,domain_id)
    VALUES('SHORT',d->>'slug',d->>'target','EXACT',302,true,'PRESERVE',true,p_actor_id,(d->>'domainId')::uuid) RETURNING * INTO r;
   ELSE
    FOR attempt IN 1..5 LOOP
     INSERT INTO public.redirects(type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by,domain_id)
     VALUES('SHORT',left(replace(gen_random_uuid()::text,'-',''),12),d->>'target','EXACT',302,true,'PRESERVE',true,p_actor_id,(d->>'domainId')::uuid)
     ON CONFLICT DO NOTHING RETURNING * INTO r;
     EXIT WHEN r.id IS NOT NULL;
    END LOOP;
    IF r.id IS NULL THEN RAISE EXCEPTION 'Could not allocate a slug' USING ERRCODE='23505'; END IF;
   END IF;
   created:=true;
  END IF;
  patch:='{}';
  FOR key IN SELECT unnest(ARRAY['domainId','slug','target','statusCode','isEnabled','queryMode','queryOverride','utmDefaults','expiresAt']) LOOP
   IF d?key THEN patch:=patch||jsonb_build_object(CASE key WHEN 'domainId' THEN 'domain_id' WHEN 'statusCode' THEN 'status_code' WHEN 'isEnabled' THEN 'is_enabled' WHEN 'queryMode' THEN 'query_mode' WHEN 'queryOverride' THEN 'query_override' WHEN 'utmDefaults' THEN 'utm_defaults' WHEN 'expiresAt' THEN 'end_at' ELSE key END,d->key); END IF;
  END LOOP;
  r:=jsonb_populate_record(r,patch);
  UPDATE public.redirects SET domain_id=r.domain_id,slug=r.slug,target=r.target,status_code=r.status_code,is_enabled=r.is_enabled,
   query_mode=r.query_mode,preserve_query=r.query_mode<>'DROP',query_override=r.query_override,utm_defaults=r.utm_defaults,end_at=r.end_at,updated_at=clock_timestamp() WHERE id=r.id;
  IF d?'expiresAt' THEN
   UPDATE public.redirect_link_policies SET policy=CASE WHEN r.end_at IS NULL THEN policy-'expires_at' ELSE policy||jsonb_build_object('expires_at',r.end_at) END,updated_at=clock_timestamp() WHERE redirect_id=r.id;
  END IF;
  key:='redirects:'||r.id::text;
  IF created OR d?'folderId' OR d?'tagIds' OR d?'comment' THEN
   SELECT m.folder_id,m.comment INTO folder,comment_value FROM public.redirect_link_metadata m WHERE m.redirect_key=key;
   IF d?'folderId' THEN folder:=(d->>'folderId')::uuid; END IF;
   IF d?'comment' THEN comment_value:=d->>'comment'; END IF;
   IF d?'tagIds' THEN SELECT coalesce(array_agg(DISTINCT value::uuid),ARRAY[]::uuid[]) INTO tags FROM jsonb_array_elements_text(d->'tagIds');
   ELSE SELECT coalesce(array_agg(tag_id),ARRAY[]::uuid[]) INTO tags FROM public.redirect_link_tag_assignments WHERE redirect_key=key;
   END IF;
   INSERT INTO public.redirect_link_metadata(redirect_key,folder_id,comment) VALUES(key,folder,coalesce(comment_value,''))
    ON CONFLICT(redirect_key) DO UPDATE SET folder_id=excluded.folder_id,comment=excluded.comment,updated_at=clock_timestamp();
   DELETE FROM public.redirect_link_tag_assignments WHERE redirect_key=key;
   INSERT INTO public.redirect_link_tag_assignments(redirect_key,tag_id) SELECT key,unnest(tags);
  END IF;
  IF d?'isArchived' THEN
   INSERT INTO public.redirect_link_metadata(redirect_key,is_archived) VALUES(key,(d->>'isArchived')::boolean)
   ON CONFLICT(redirect_key) DO UPDATE SET is_archived=excluded.is_archived,updated_at=clock_timestamp();
  END IF;
  output:=output||jsonb_build_array(jsonb_build_object('operation',mode,'created',created,'link',public.redirect_management_link(r.id)));
 END LOOP;
 RETURN output;
END $$;


CREATE OR REPLACE FUNCTION public.record_redirect_visit(p_redirect_id uuid,p_path text,p_query text,p_referer text,p_user_agent text,p_country text,p_ip_hash text,p_status integer,p_variant_id text,p_destination text,p_metadata jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE visit_id uuid:=gen_random_uuid();updated uuid;bound_domain uuid;bound_host text;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
 IF jsonb_typeof(p_metadata)<>'object' OR length(p_metadata::text)>4096 THEN RAISE EXCEPTION 'Invalid visitor metadata' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT domain_id,domain_hostname INTO bound_domain,bound_host FROM public.redirects WHERE id=p_redirect_id;
 IF bound_domain IS NULL AND coalesce(p_metadata->>'domain','queer.guide') NOT IN('queer.guide','www.queer.guide') THEN RETURN NULL;END IF;
 IF bound_domain IS NOT NULL AND (bound_host IS DISTINCT FROM p_metadata->>'domain' OR public.redirect_public_domain(bound_host) IS NULL) THEN RETURN NULL;END IF;
 UPDATE public.redirects SET click_count=click_count+1 WHERE id=p_redirect_id AND domain_id IS NOT DISTINCT FROM bound_domain AND is_enabled
 AND (start_at IS NULL OR start_at<=now()) AND (end_at IS NULL OR end_at>now()) AND (click_limit IS NULL OR click_count<click_limit)
 RETURNING id INTO updated;
 IF updated IS NULL THEN RETURN NULL; END IF;
 INSERT INTO public.redirect_events(redirect_id,path,query,referer,user_agent,country,ip_hash,status,variant_id,destination_url,click_id,visitor)
 VALUES(p_redirect_id,p_path,p_query,p_referer,left(p_user_agent,256),CASE WHEN p_country~'^[A-Za-z]{2}$' THEN upper(p_country) ELSE NULL END,p_ip_hash,p_status,p_variant_id,p_destination,visit_id,p_metadata);
 RETURN visit_id;
END $$;
REVOKE ALL ON FUNCTION public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text,jsonb) TO service_role;


-- Renew only a previously owner-verified, still-connected domain, using the
-- same nonce, global/actor budgets and version guard as the explicit DNS check.
CREATE FUNCTION public.reserve_redirect_domain_renewal(p_id uuid,p_lease uuid,p_operation uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE d public.redirect_domains;j public.redirect_domain_jobs;reserved jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE domain_id=p_id FOR UPDATE;
 SELECT * INTO d FROM public.redirect_domains WHERE id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR d.id IS NULL OR j.state<>'leased' OR j.lease IS DISTINCT FROM p_lease OR j.operation IS DISTINCT FROM p_operation OR j.lease_until<=clock_timestamp() OR NOT j.desired OR d.provider_id IS NULL OR d.disabled OR d.verified_at IS NULL OR d.verified_until>clock_timestamp()+interval '6 hours' THEN RETURN NULL;END IF;
 IF NOT EXISTS(SELECT FROM public.user_roles WHERE user_id=j.requested_by AND role='admin') THEN RETURN NULL;END IF;
 reserved:=public.redirect_domain_resource('reserve',j.requested_by,d.id,jsonb_build_object('version',d.version));
 IF reserved?'retryAfter' THEN RETURN NULL;END IF;
 RETURN jsonb_build_object('actor',j.requested_by,'version',d.version,'attempt',reserved->'attempt','verification',reserved#>'{domain,verification}');
END $$;
REVOKE ALL ON FUNCTION public.reserve_redirect_domain_renewal(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_redirect_domain_renewal(uuid,uuid,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.redirect_domain_json(p_id uuid) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',id,'hostname',hostname,'version',version,'disabled',disabled,'ownershipState',ownership_state,
 'ownershipVerified',ownership_state='verified' AND verified_until>clock_timestamp(),'verifiedAt',verified_at,'verifiedUntil',verified_until,
 'lastCheckedAt',last_checked_at,'lastCheck',last_check,'nextCheckAt',next_check_at,
 'rootUrl',root_url,'notFoundUrl',not_found_url,'expiredUrl',expired_url,'providerConnected',provider_id IS NOT NULL,
 'routingReady',public.redirect_public_domain(hostname,true) IS NOT NULL,'routingSeenAt',routing_seen_at,
 'verification',jsonb_build_object('type','TXT','name','_qg-redirect.'||hostname,'value','qg-redirect='||verification_token))||public.redirect_domain_provider_json(id)
 FROM public.redirect_domains WHERE id=p_id;
$$;

-- Old service-only entry points share the live checks too. Without a signed
-- branded context they may record only the default namespace, never a custom host.
CREATE OR REPLACE FUNCTION public.record_redirect_visit(p_redirect_id uuid,p_path text,p_query text,p_referer text,p_user_agent text,p_country text,p_ip_hash text,p_status integer,p_variant_id text,p_destination text)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT public.record_redirect_visit(p_redirect_id,p_path,p_query,p_referer,p_user_agent,p_country,p_ip_hash,p_status,p_variant_id,p_destination,'{}'::jsonb)
$$;
CREATE OR REPLACE FUNCTION public.record_redirect_click(p_redirect_id uuid,p_path text,p_query text DEFAULT NULL,p_referer text DEFAULT NULL,p_user_agent text DEFAULT NULL,p_country text DEFAULT NULL,p_ip_hash text DEFAULT NULL,p_status integer DEFAULT 301)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM public.record_redirect_visit(p_redirect_id,p_path,p_query,p_referer,p_user_agent,p_country,p_ip_hash,p_status,NULL,NULL,'{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.record_redirect_click(uuid,text,text,text,text,text,text,integer),public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_redirect_click(uuid,text,text,text,text,text,text,integer),public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text) TO service_role;
