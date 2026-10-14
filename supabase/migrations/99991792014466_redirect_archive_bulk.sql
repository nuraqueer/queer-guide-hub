ALTER TABLE public.redirect_link_metadata ADD COLUMN is_archived boolean NOT NULL DEFAULT false;
CREATE INDEX redirect_link_metadata_archived_idx ON public.redirect_link_metadata(redirect_key) WHERE is_archived;
CREATE FUNCTION public.bulk_redirect_organization(p_keys text[],p_action text,p_value uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE key text; changed integer:=0;
BEGIN
 IF NOT public.has_role_jwt('admin'::public.app_role) THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='42501'; END IF;
 IF p_keys IS NULL OR cardinality(p_keys) NOT BETWEEN 1 AND 100 OR EXISTS(SELECT FROM unnest(p_keys) k WHERE k IS NULL OR length(k) NOT BETWEEN 1 AND 4096) THEN RAISE EXCEPTION 'Select 1–100 redirects' USING ERRCODE='22023'; END IF;
 IF p_action IS NULL OR p_action NOT IN('archive','restore','folder','add-tag','remove-tag') THEN RAISE EXCEPTION 'Invalid bulk action' USING ERRCODE='22023'; END IF;
 IF p_action='folder' AND p_value IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_link_folders WHERE id=p_value) THEN RAISE EXCEPTION 'Folder not found' USING ERRCODE='23503'; END IF;
 IF p_action IN('add-tag','remove-tag') AND (p_value IS NULL OR NOT EXISTS(SELECT FROM public.redirect_link_tags WHERE id=p_value)) THEN RAISE EXCEPTION 'Tag not found' USING ERRCODE='23503'; END IF;
 PERFORM pg_advisory_xact_lock(471983092);
 FOR key IN SELECT DISTINCT k FROM unnest(p_keys) k ORDER BY k LOOP
  IF key LIKE 'redirects:%' THEN
   PERFORM 1 FROM public.redirects WHERE id::text=substring(key from 11) FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Redirect no longer exists' USING ERRCODE='P0002'; END IF;
  END IF;
  INSERT INTO public.redirect_link_metadata(redirect_key) VALUES(key) ON CONFLICT DO NOTHING;
  IF p_action IN('archive','restore') THEN UPDATE public.redirect_link_metadata SET is_archived=p_action='archive',updated_at=clock_timestamp() WHERE redirect_key=key;
  ELSIF p_action='folder' THEN UPDATE public.redirect_link_metadata SET folder_id=p_value,updated_at=clock_timestamp() WHERE redirect_key=key;
  ELSIF p_action='add-tag' THEN INSERT INTO public.redirect_link_tag_assignments(redirect_key,tag_id) VALUES(key,p_value) ON CONFLICT DO NOTHING;
  ELSE DELETE FROM public.redirect_link_tag_assignments WHERE redirect_key=key AND tag_id=p_value;
  END IF;
  changed:=changed+1;
 END LOOP;
 RETURN changed;
END $$;
REVOKE ALL ON FUNCTION public.bulk_redirect_organization(text[],text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bulk_redirect_organization(text[],text,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.redirect_management_link(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',r.id,'slug',r.slug,'target',r.target,'statusCode',r.status_code,
  'isEnabled',r.is_enabled,'isArchived',coalesce(m.is_archived,false),'queryMode',r.query_mode,'queryOverride',r.query_override,'utmDefaults',r.utm_defaults,
  'expiresAt',r.end_at,'clicks',r.click_count,'updatedAt',r.updated_at,
  'shortUrl','https://queer.guide/go/'||r.slug,'folderId',m.folder_id,'comment',coalesce(m.comment,''),
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
   AND (NOT(p_filters?'ids') OR r.id IN(SELECT value::uuid FROM jsonb_array_elements_text(p_filters->'ids')))
   AND (NOT(p_filters?'search') OR strpos(lower(coalesce(r.slug,'')||' '||r.target),lower(p_filters->>'search'))>0)
   AND (NOT(p_filters?'isArchived') OR coalesce(m.is_archived,false)=(p_filters->>'isArchived')::boolean)
   AND (NOT(p_filters?'isEnabled') OR r.is_enabled=(p_filters->>'isEnabled')::boolean)
   AND (NOT(p_filters?'folderId') OR m.folder_id=(p_filters->>'folderId')::uuid)
   AND (NOT(p_filters?'tagId') OR EXISTS(SELECT FROM public.redirect_link_tag_assignments a WHERE a.redirect_key='redirects:'||r.id::text AND a.tag_id=(p_filters->>'tagId')::uuid))
 ), page AS MATERIALIZED(SELECT id FROM filtered WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit+1),
 shown AS MATERIALIZED(SELECT id FROM page ORDER BY id LIMIT p_limit)
 SELECT jsonb_build_object('count',(SELECT count(*) FROM filtered),
  'data',coalesce((SELECT jsonb_agg(public.redirect_management_link(id) ORDER BY id) FROM shown),'[]'::jsonb),
  'nextCursor',CASE WHEN p_limit>0 AND (SELECT count(*) FROM page)>p_limit THEN (SELECT max(id::text) FROM shown) ELSE NULL END) INTO result;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.redirect_management_mutate(p_operations jsonb,p_token_id uuid DEFAULT NULL,p_actor_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[]; op jsonb; d jsonb; mode text; r public.redirects; patch jsonb;
 key text; folder uuid; tags uuid[]; comment_value text; created boolean; output jsonb:='[]'; attempt integer;
BEGIN
 allowed:=public.redirect_management_scope(p_token_id,'links:write');
 IF p_token_id IS NOT NULL THEN SELECT created_by INTO p_actor_id FROM public.redirect_api_tokens WHERE id=p_token_id; END IF;
 IF p_operations IS NULL OR jsonb_typeof(p_operations)<>'array' OR jsonb_array_length(p_operations) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Provide 1–100 operations' USING ERRCODE='22023'; END IF;
 -- Serialize API batches to give upserts and mixed batches deterministic atomic behavior.
 PERFORM pg_advisory_xact_lock(471983092);
 FOR op IN SELECT value FROM jsonb_array_elements(p_operations) LOOP
  mode:=op->>'operation'; d:=coalesce(op->'data','{}'); created:=false; r:=NULL;
  IF mode NOT IN('create','update','upsert','delete') OR mode IS NULL THEN RAISE EXCEPTION 'Invalid operation' USING ERRCODE='22023'; END IF;
  IF mode IN('update','delete') THEN SELECT * INTO r FROM public.redirects WHERE id=(op->>'id')::uuid AND type='SHORT' FOR UPDATE;
  ELSIF mode='upsert' THEN SELECT * INTO r FROM public.redirects WHERE slug=d->>'slug' AND type='SHORT' FOR UPDATE;
  END IF;
  IF mode IN('update','delete') AND r.id IS NULL THEN RAISE EXCEPTION 'Link not found' USING ERRCODE='P0002'; END IF;
  IF allowed IS NOT NULL AND (r.id IS NULL OR NOT(r.id=ANY(allowed))) THEN RAISE EXCEPTION 'Link is outside credential scope' USING ERRCODE='42501'; END IF;
  IF mode='delete' THEN
   DELETE FROM public.redirect_link_metadata WHERE redirect_key='redirects:'||r.id::text;
   DELETE FROM public.redirects WHERE id=r.id;
   output:=output||jsonb_build_array(jsonb_build_object('operation',mode,'id',r.id,'deleted',true));
   CONTINUE;
  END IF;
  IF r.id IS NULL THEN
   IF length(d->>'target') NOT BETWEEN 1 AND 8192 OR d->>'target' IS NULL THEN RAISE EXCEPTION 'Destination required' USING ERRCODE='22023'; END IF;
   IF d?'slug' THEN
    INSERT INTO public.redirects(type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by)
    VALUES('SHORT',d->>'slug',d->>'target','EXACT',302,true,'PRESERVE',true,p_actor_id) RETURNING * INTO r;
   ELSE
    FOR attempt IN 1..5 LOOP
     INSERT INTO public.redirects(type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by)
     VALUES('SHORT',left(replace(gen_random_uuid()::text,'-',''),12),d->>'target','EXACT',302,true,'PRESERVE',true,p_actor_id)
     ON CONFLICT DO NOTHING RETURNING * INTO r;
     EXIT WHEN r.id IS NOT NULL;
    END LOOP;
    IF r.id IS NULL THEN RAISE EXCEPTION 'Could not allocate a slug' USING ERRCODE='23505'; END IF;
   END IF;
   created:=true;
  END IF;
  patch:='{}';
  FOR key IN SELECT unnest(ARRAY['slug','target','statusCode','isEnabled','queryMode','queryOverride','utmDefaults','expiresAt']) LOOP
   IF d?key THEN patch:=patch||jsonb_build_object(CASE key WHEN 'statusCode' THEN 'status_code' WHEN 'isEnabled' THEN 'is_enabled' WHEN 'queryMode' THEN 'query_mode' WHEN 'queryOverride' THEN 'query_override' WHEN 'utmDefaults' THEN 'utm_defaults' WHEN 'expiresAt' THEN 'end_at' ELSE key END,d->key); END IF;
  END LOOP;
  r:=jsonb_populate_record(r,patch);
  UPDATE public.redirects SET slug=r.slug,target=r.target,status_code=r.status_code,is_enabled=r.is_enabled,
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
REVOKE ALL ON FUNCTION public.redirect_management_scope(uuid,text),public.redirect_management_link(uuid),public.redirect_management_list(jsonb,integer,uuid,uuid),public.redirect_management_mutate(jsonb,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_management_scope(uuid,text),public.redirect_management_link(uuid),public.redirect_management_list(jsonb,integer,uuid,uuid),public.redirect_management_mutate(jsonb,uuid,uuid) TO service_role;
