-- Domain-root links reuse managed SHORT records and the full policy/visit pipeline.
ALTER TABLE public.redirects ADD COLUMN is_domain_root boolean NOT NULL DEFAULT false,
 ADD CONSTRAINT redirects_root_custom_short CHECK(NOT is_domain_root OR (type='SHORT' AND domain_id IS NOT NULL));
DROP INDEX public.redirects_domain_slug_unique;
CREATE UNIQUE INDEX redirects_domain_slug_unique ON public.redirects(domain_id,slug) WHERE type='SHORT' AND domain_id IS NOT NULL AND NOT is_domain_root;
CREATE UNIQUE INDEX redirects_domain_root_unique ON public.redirects(domain_id) WHERE is_domain_root;

CREATE FUNCTION public.redirect_root_binding_guard() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.is_domain_root AND (TG_OP='INSERT' OR NOT OLD.is_domain_root) THEN
  IF NEW.domain_id IS NULL OR public.redirect_public_domain((SELECT hostname FROM public.redirect_domains WHERE id=NEW.domain_id),true) IS NULL THEN RAISE EXCEPTION 'Choose a ready custom domain for its root link' USING ERRCODE='22023';END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER redirect_root_binding_guard BEFORE INSERT OR UPDATE ON public.redirects FOR EACH ROW EXECUTE FUNCTION public.redirect_root_binding_guard();
REVOKE ALL ON FUNCTION public.redirect_root_binding_guard() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_root_binding_guard() TO service_role;
CREATE OR REPLACE FUNCTION public.redirect_management_link(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',r.id,'slug',r.slug,'target',r.target,'statusCode',r.status_code,
  'startsAt',r.start_at,'clickLimit',r.click_limit,'isEnabled',r.is_enabled,'isArchived',coalesce(m.is_archived,false),'queryMode',r.query_mode,'queryOverride',r.query_override,'utmDefaults',r.utm_defaults,
  'notes',r.notes,'expiresAt',r.end_at,'clicks',r.click_count,'updatedAt',r.updated_at,
  'isDomainRoot',r.is_domain_root,'domainId',r.domain_id,'domainHostname',r.domain_hostname,
  'shortUrl',CASE WHEN r.domain_id IS NULL THEN 'https://queer.guide/go/'||r.slug ELSE 'https://'||r.domain_hostname||'/'||CASE WHEN r.is_domain_root THEN '' ELSE r.slug END END,'folderId',m.folder_id,'comment',coalesce(m.comment,''),
  'tagIds',coalesce((SELECT jsonb_agg(a.tag_id ORDER BY a.tag_id) FROM public.redirect_link_tag_assignments a WHERE a.redirect_key='redirects:'||r.id::text),'[]'::jsonb))
 FROM public.redirects r LEFT JOIN public.redirect_link_metadata m ON m.redirect_key='redirects:'||r.id::text
 WHERE r.id=p_id AND r.type='SHORT'
$$;

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
  ELSIF mode='upsert' THEN SELECT * INTO r FROM public.redirects WHERE type='SHORT' AND domain_id IS NOT DISTINCT FROM (d->>'domainId')::uuid AND CASE WHEN coalesce((d->>'isDomainRoot')::boolean,false) THEN is_domain_root ELSE NOT is_domain_root AND slug=d->>'slug' END FOR UPDATE;
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
    INSERT INTO public.redirects(type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by,domain_id,is_domain_root)
    VALUES('SHORT',d->>'slug',d->>'target','EXACT',302,true,'PRESERVE',true,p_actor_id,(d->>'domainId')::uuid,coalesce((d->>'isDomainRoot')::boolean,false)) RETURNING * INTO r;
   ELSE
    FOR attempt IN 1..5 LOOP
     INSERT INTO public.redirects(type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by,domain_id,is_domain_root)
     VALUES('SHORT',left(replace(gen_random_uuid()::text,'-',''),12),d->>'target','EXACT',302,true,'PRESERVE',true,p_actor_id,(d->>'domainId')::uuid,coalesce((d->>'isDomainRoot')::boolean,false))
     ON CONFLICT DO NOTHING RETURNING * INTO r;
     EXIT WHEN r.id IS NOT NULL;
    END LOOP;
    IF r.id IS NULL THEN RAISE EXCEPTION 'Could not allocate a slug' USING ERRCODE='23505'; END IF;
   END IF;
   created:=true;
  END IF;
  patch:='{}';
  FOR key IN SELECT unnest(ARRAY['isDomainRoot','startsAt','clickLimit','notes','domainId','slug','target','statusCode','isEnabled','queryMode','queryOverride','utmDefaults','expiresAt']) LOOP
   IF d?key THEN patch:=patch||jsonb_build_object(CASE key WHEN 'isDomainRoot' THEN 'is_domain_root' WHEN 'startsAt' THEN 'start_at' WHEN 'clickLimit' THEN 'click_limit' WHEN 'domainId' THEN 'domain_id' WHEN 'statusCode' THEN 'status_code' WHEN 'isEnabled' THEN 'is_enabled' WHEN 'queryMode' THEN 'query_mode' WHEN 'queryOverride' THEN 'query_override' WHEN 'utmDefaults' THEN 'utm_defaults' WHEN 'expiresAt' THEN 'end_at' ELSE key END,d->key); END IF;
  END LOOP;
  r:=jsonb_populate_record(r,patch);
  IF r.click_limit IS NOT NULL AND r.click_limit<1 OR (created OR d?'startsAt' OR d?'expiresAt') AND r.start_at IS NOT NULL AND r.end_at IS NOT NULL AND r.end_at<=r.start_at OR (created OR d?'notes') AND length(r.notes)>10000 THEN RAISE EXCEPTION 'Invalid schedule, visit limit or notes' USING ERRCODE='22023';END IF;
  UPDATE public.redirects SET is_domain_root=r.is_domain_root,start_at=r.start_at,click_limit=r.click_limit,notes=r.notes,domain_id=r.domain_id,slug=r.slug,target=r.target,status_code=r.status_code,is_enabled=r.is_enabled,
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



-- Owner CMS saves preserve complete records and SHORT/PATH conversion atomically.
CREATE OR REPLACE FUNCTION public.redirect_manual_record(p_actor uuid,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT NULL,p_expected_updated_at timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirects;creating boolean:=p_id IS NULL;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF NOT creating THEN SELECT * INTO r FROM public.redirects WHERE id=p_id FOR UPDATE;IF r.id IS NULL THEN RAISE EXCEPTION 'Redirect not found' USING ERRCODE='P0002';END IF;END IF;
 IF p_values IS NULL OR p_values='null'::jsonb THEN IF creating THEN RAISE EXCEPTION 'Provide redirect fields' USING ERRCODE='22023';END IF;RETURN to_jsonb(r);END IF;
 IF jsonb_typeof(p_values)<>'object' OR p_values='{}' OR p_values-ARRAY['type','slug','source_path','match_kind','target','status_code','is_enabled','start_at','end_at','query_mode','query_override','utm_defaults','click_limit','notes','domain_id','is_domain_root']::text[]<>'{}' THEN RAISE EXCEPTION 'Invalid redirect fields' USING ERRCODE='22023';END IF;
 IF NOT creating AND (p_expected_updated_at IS NULL OR p_expected_updated_at IS DISTINCT FROM r.updated_at) THEN RAISE EXCEPTION 'Redirect changed; reload before saving' USING ERRCODE='23505';END IF;
 IF creating THEN
  IF p_expected_updated_at IS NOT NULL THEN RAISE EXCEPTION 'Unexpected record version' USING ERRCODE='22023';END IF;
  r:=jsonb_populate_record(NULL::public.redirects,'{"is_domain_root":false,"type":"SHORT","match_kind":"EXACT","status_code":301,"is_enabled":true,"query_mode":"PRESERVE"}'::jsonb);
 END IF;
 r:=jsonb_populate_record(r,p_values);
 IF r.type IS NULL OR r.target IS NULL OR length(r.target) NOT BETWEEN 1 AND 8192 OR r.status_code IS NULL OR r.status_code NOT IN(301,302,307,308) OR r.is_enabled IS NULL OR r.query_mode IS NULL OR r.click_limit<1 OR (creating OR p_values?'notes') AND length(r.notes)>10000 OR (creating OR p_values?'start_at' OR p_values?'end_at') AND r.start_at IS NOT NULL AND r.end_at IS NOT NULL AND r.end_at<=r.start_at THEN RAISE EXCEPTION 'Invalid redirect settings' USING ERRCODE='22023';END IF;
 IF r.type='SHORT' THEN
  IF coalesce(r.is_domain_root,false) AND r.slug IS NULL THEN r.slug:=left(replace(gen_random_uuid()::text,'-',''),12);END IF;
  IF r.slug IS NULL OR r.slug!~'^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$' THEN RAISE EXCEPTION 'A valid short-link slug is required' USING ERRCODE='22023';END IF;
  r.source_path:=NULL;r.match_kind:='EXACT';
 ELSE
  IF p_values->>'domain_id' IS NOT NULL OR r.source_path IS NULL OR r.source_path NOT LIKE '/%' OR r.source_path LIKE '//%' OR r.source_path LIKE '%..%' OR length(r.source_path)>8192 OR r.match_kind IS NULL OR r.match_kind::text NOT IN('EXACT','WILDCARD','REGEX') THEN RAISE EXCEPTION 'Invalid path settings' USING ERRCODE='22023';END IF;
  r.slug:=NULL;r.domain_id:=NULL;r.is_domain_root:=false;
 END IF;
 IF creating THEN
  INSERT INTO public.redirects(type,slug,source_path,match_kind,target,status_code,is_enabled,start_at,end_at,preserve_query,query_mode,query_override,utm_defaults,click_limit,notes,domain_id,is_domain_root,created_by)
  VALUES(r.type,r.slug,r.source_path,r.match_kind,r.target,r.status_code,r.is_enabled,r.start_at,r.end_at,r.query_mode<>'DROP',r.query_mode,r.query_override,r.utm_defaults,r.click_limit,r.notes,r.domain_id,r.is_domain_root,p_actor) RETURNING * INTO r;
 ELSE
  UPDATE public.redirects SET is_domain_root=r.is_domain_root,type=r.type,slug=r.slug,source_path=r.source_path,match_kind=r.match_kind,target=r.target,status_code=r.status_code,is_enabled=r.is_enabled,start_at=r.start_at,end_at=r.end_at,preserve_query=r.query_mode<>'DROP',query_mode=r.query_mode,query_override=r.query_override,utm_defaults=r.utm_defaults,click_limit=r.click_limit,notes=r.notes,domain_id=r.domain_id,updated_at=clock_timestamp() WHERE id=p_id RETURNING * INTO r;
 END IF;
 IF creating OR p_values?'end_at' THEN
  UPDATE public.redirect_link_policies SET policy=CASE WHEN r.end_at IS NULL THEN policy-'expires_at' ELSE policy||jsonb_build_object('expires_at',r.end_at) END,updated_at=clock_timestamp() WHERE redirect_id=r.id;
 END IF;
 RETURN to_jsonb(r);
END $$;
REVOKE ALL ON FUNCTION public.redirect_manual_record(uuid,uuid,jsonb,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_manual_record(uuid,uuid,jsonb,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.record_redirect_visit(p_redirect_id uuid,p_path text,p_query text,p_referer text,p_user_agent text,p_country text,p_ip_hash text,p_status integer,p_variant_id text,p_destination text,p_metadata jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE visit_id uuid:=gen_random_uuid();updated uuid;bound_domain uuid;bound_host text;bound_root boolean;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
 IF jsonb_typeof(p_metadata)<>'object' OR length(p_metadata::text)>4096 THEN RAISE EXCEPTION 'Invalid visitor metadata' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT domain_id,domain_hostname,is_domain_root INTO bound_domain,bound_host,bound_root FROM public.redirects WHERE id=p_redirect_id;
 IF bound_root IS DISTINCT FROM (p_path='/') THEN RETURN NULL;END IF;
 IF bound_domain IS NULL AND coalesce(p_metadata->>'domain','queer.guide') NOT IN('queer.guide','www.queer.guide') THEN RETURN NULL;END IF;
 IF bound_domain IS NOT NULL AND (bound_host IS DISTINCT FROM p_metadata->>'domain' OR public.redirect_public_domain(bound_host) IS NULL) THEN RETURN NULL;END IF;
 UPDATE public.redirects SET click_count=click_count+1 WHERE id=p_redirect_id AND domain_id IS NOT DISTINCT FROM bound_domain AND is_domain_root=bound_root AND is_enabled
 AND (start_at IS NULL OR start_at<=now()) AND (end_at IS NULL OR end_at>now()) AND (click_limit IS NULL OR click_count<click_limit)
 RETURNING id INTO updated;
 IF updated IS NULL THEN RETURN NULL; END IF;
 INSERT INTO public.redirect_events(redirect_id,path,query,referer,user_agent,country,ip_hash,status,variant_id,destination_url,click_id,visitor)
 VALUES(p_redirect_id,p_path,p_query,p_referer,left(p_user_agent,256),CASE WHEN p_country~'^[A-Za-z]{2}$' THEN upper(p_country) ELSE NULL END,p_ip_hash,p_status,p_variant_id,p_destination,visit_id,p_metadata);
 RETURN visit_id;
END $$;
REVOKE ALL ON FUNCTION public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text,jsonb) TO service_role;
