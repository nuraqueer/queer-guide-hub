-- The existing app administrators remain Redirects workspace owners. Membership
-- is explicit; ordinary authenticated accounts gain no access automatically.
CREATE TABLE public.redirect_workspace_members (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN('user','machine')),
 label text NOT NULL CHECK(length(btrim(label)) BETWEEN 1 AND 100),
 role text NOT NULL DEFAULT 'member' CHECK(role IN('member','viewer')),
 active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((kind='user')=(user_id IS NOT NULL))
);
ALTER TABLE public.redirect_link_folders ADD COLUMN default_permission text NOT NULL DEFAULT 'edit' CHECK(default_permission IN('none','view','edit'));
CREATE TABLE public.redirect_folder_members (
 folder_id uuid NOT NULL REFERENCES public.redirect_link_folders(id) ON DELETE CASCADE,
 member_id uuid NOT NULL REFERENCES public.redirect_workspace_members(id) ON DELETE CASCADE,
 permission text NOT NULL CHECK(permission IN('none','view','edit','owner')),
 PRIMARY KEY(folder_id,member_id)
);
CREATE INDEX redirect_folder_members_member_idx ON public.redirect_folder_members(member_id);
ALTER TABLE public.redirect_api_tokens ADD COLUMN member_id uuid REFERENCES public.redirect_workspace_members(id) ON DELETE CASCADE;
CREATE INDEX redirect_tokens_member_idx ON public.redirect_api_tokens(member_id);
ALTER TABLE public.redirect_workspace_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redirect_folder_members ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_workspace_members,public.redirect_folder_members FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_workspace_members,public.redirect_folder_members TO service_role;

-- Shared ACL lock for reads; exclusive for management writes and ACL changes.
-- Statement triggers acquire it before row locks, including FK cascades.
CREATE FUNCTION public.redirect_acl_change_lock() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN PERFORM pg_advisory_xact_lock(471983093);RETURN NULL;END $$;
REVOKE ALL ON FUNCTION public.redirect_acl_change_lock() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER redirect_member_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_workspace_members FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE TRIGGER redirect_folder_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_link_folders FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE TRIGGER redirect_override_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_folder_members FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE TRIGGER redirect_metadata_acl_insert BEFORE INSERT OR DELETE ON public.redirect_link_metadata FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE TRIGGER redirect_metadata_acl_update BEFORE UPDATE OF folder_id ON public.redirect_link_metadata FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE TRIGGER redirect_token_member_bind_lock BEFORE INSERT OR UPDATE OF member_id ON public.redirect_api_tokens FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();

CREATE FUNCTION public.redirect_principal_member(p_principal uuid) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE found_token boolean; member uuid;
BEGIN
 IF p_principal IS NULL THEN RETURN NULL;END IF;
 SELECT t.member_id,true INTO member,found_token FROM public.redirect_api_tokens t WHERE id=p_principal;
 IF found_token THEN RETURN member;END IF;
 SELECT id INTO member FROM public.redirect_workspace_members WHERE id=p_principal AND kind='user';
 RETURN member;
END $$;
CREATE FUNCTION public.redirect_folder_rank(p_member uuid,p_folder uuid) RETURNS integer LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE workspace_role text; active_member boolean; setting text; score integer;
BEGIN
 IF p_member IS NULL THEN RETURN 3;END IF;
 SELECT role,active INTO workspace_role,active_member FROM public.redirect_workspace_members WHERE id=p_member;
 IF NOT coalesce(active_member,false) THEN RETURN 0;END IF;
 IF p_folder IS NULL THEN score:=2;
 ELSE
  SELECT coalesce(a.permission,f.default_permission) INTO setting FROM public.redirect_link_folders f LEFT JOIN public.redirect_folder_members a ON a.folder_id=f.id AND a.member_id=p_member WHERE f.id=p_folder;
  score:=CASE setting WHEN 'owner' THEN 3 WHEN 'edit' THEN 2 WHEN 'view' THEN 1 ELSE 0 END;
 END IF;
 RETURN CASE WHEN workspace_role='viewer' THEN least(score,1) ELSE score END;
END $$;
CREATE OR REPLACE FUNCTION public.redirect_management_scope(p_token_id uuid,p_scope text)
RETURNS uuid[] LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE t public.redirect_api_tokens; member public.redirect_workspace_members; member_key uuid; ids uuid[]; required_rank integer;
BEGIN
 IF p_scope IS NULL OR p_scope NOT IN('links:read','links:write','events:read','workspace:read','workspace:write','conversions:write') THEN RAISE EXCEPTION 'Invalid permission scope' USING ERRCODE='22023';END IF;
 IF p_scope LIKE '%:write' THEN PERFORM pg_advisory_xact_lock(471983093);ELSE PERFORM pg_advisory_xact_lock_shared(471983093);END IF;
 IF p_token_id IS NULL THEN RETURN NULL;END IF;
 SELECT * INTO t FROM public.redirect_api_tokens WHERE id=p_token_id FOR SHARE;
 IF t.id IS NOT NULL THEN
  IF t.revoked_at IS NOT NULL OR t.expires_at<=clock_timestamp() OR NOT(p_scope=ANY(t.scopes)) THEN RAISE EXCEPTION 'Credential expired, revoked or missing scope' USING ERRCODE='42501';END IF;
  IF p_scope LIKE 'workspace:%' AND t.redirect_ids IS NOT NULL THEN RAISE EXCEPTION 'Workspace permissions require an unrestricted credential' USING ERRCODE='42501';END IF;
  IF t.member_id IS NULL THEN RETURN t.redirect_ids;END IF;
  member_key:=t.member_id;
 ELSE
  IF p_scope<>ALL(ARRAY['links:read','links:write','events:read','workspace:read','workspace:write']) THEN RAISE EXCEPTION 'Session scope is not allowed' USING ERRCODE='42501';END IF;
  member_key:=p_token_id;
 END IF;
 SELECT * INTO member FROM public.redirect_workspace_members WHERE id=member_key AND active AND (t.id IS NOT NULL OR kind='user') FOR SHARE;
 IF member.id IS NULL THEN RAISE EXCEPTION 'Redirects workspace membership is inactive or missing' USING ERRCODE='42501';END IF;
 required_rank:=CASE WHEN p_scope LIKE '%:write' THEN 2 ELSE 1 END;
 SELECT coalesce(array_agg(r.id),ARRAY[]::uuid[]) INTO ids
 FROM public.redirects r LEFT JOIN public.redirect_link_metadata m ON m.redirect_key='redirects:'||r.id::text
 LEFT JOIN public.redirect_link_folders f ON f.id=m.folder_id
 LEFT JOIN public.redirect_folder_members a ON a.folder_id=f.id AND a.member_id=member.id
 WHERE (r.type='SHORT' OR m.folder_id IS NOT NULL) AND (t.redirect_ids IS NULL OR r.id=ANY(t.redirect_ids))
 AND least(CASE WHEN member.role='viewer' THEN 1 ELSE 3 END,
  CASE WHEN m.folder_id IS NULL THEN 2 ELSE CASE coalesce(a.permission,f.default_permission) WHEN 'owner' THEN 3 WHEN 'edit' THEN 2 WHEN 'view' THEN 1 ELSE 0 END END)>=required_rank;
 RETURN ids;
END $$;
CREATE FUNCTION public.redirect_session_principal(p_user_id uuid,p_scope text) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE member public.redirect_workspace_members;
BEGIN
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT * INTO member FROM public.redirect_workspace_members WHERE user_id=p_user_id AND kind='user' AND active;
 IF member.id IS NULL THEN RAISE EXCEPTION 'Redirects workspace access is required' USING ERRCODE='42501';END IF;
 IF p_scope<>ALL(ARRAY['links:read','links:write','events:read','workspace:read','workspace:write']) THEN RAISE EXCEPTION 'Session scope is not allowed' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('id',member.id,'label',member.label,'role',member.role);
END $$;
CREATE FUNCTION public.redirect_can_create_in_folder(p_principal uuid,p_folder uuid) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE member uuid; selected uuid[];
BEGIN
 IF p_principal IS NOT NULL THEN SELECT redirect_ids INTO selected FROM public.redirect_api_tokens WHERE id=p_principal;IF selected IS NOT NULL THEN RETURN false;END IF;END IF;
 member:=public.redirect_principal_member(p_principal);
 RETURN public.redirect_folder_rank(member,p_folder)>=2;
END $$;
CREATE FUNCTION public.redirect_can_write_link(p_principal uuid,p_link uuid) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE member uuid; folder uuid; scopes text[];
BEGIN
 IF p_principal IS NOT NULL THEN SELECT t.scopes INTO scopes FROM public.redirect_api_tokens t WHERE id=p_principal;IF scopes IS NOT NULL AND NOT('links:write'=ANY(scopes)) THEN RETURN false;END IF;END IF;
 member:=public.redirect_principal_member(p_principal);
 SELECT folder_id INTO folder FROM public.redirect_link_metadata WHERE redirect_key='redirects:'||p_link::text;
 RETURN public.redirect_folder_rank(member,folder)>=2;
END $$;
REVOKE ALL ON FUNCTION public.redirect_principal_member(uuid),public.redirect_folder_rank(uuid,uuid),public.redirect_session_principal(uuid,text),public.redirect_can_create_in_folder(uuid,uuid),public.redirect_can_write_link(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_principal_member(uuid),public.redirect_folder_rank(uuid,uuid),public.redirect_session_principal(uuid,text),public.redirect_can_create_in_folder(uuid,uuid),public.redirect_can_write_link(uuid,uuid) TO service_role;

CREATE FUNCTION public.redirect_scoped_analytics(p_action text,p_filters jsonb DEFAULT '{}',p_snapshot timestamptz DEFAULT NULL,p_before_at timestamptz DEFAULT NULL,p_before_id text DEFAULT NULL,p_limit integer DEFAULT 50,p_token_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[];
BEGIN
 allowed:=public.redirect_management_scope(p_token_id,'events:read');
 IF p_action='report' THEN RETURN public.redirect_analytics_report(p_filters,allowed);
 ELSIF p_action='events' THEN RETURN public.redirect_analytics_page(p_filters,p_snapshot,p_before_at,p_before_id,p_limit,allowed);
 ELSE RAISE EXCEPTION 'Invalid analytics action' USING ERRCODE='22023';END IF;
END $$;
REVOKE ALL ON FUNCTION public.redirect_scoped_analytics(text,jsonb,timestamptz,timestamptz,text,integer,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_scoped_analytics(text,jsonb,timestamptz,timestamptz,text,integer,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.redirect_management_link(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',r.id,'slug',r.slug,'target',r.target,'statusCode',r.status_code,
  'startsAt',r.start_at,'clickLimit',r.click_limit,'isEnabled',r.is_enabled,'isArchived',coalesce(m.is_archived,false),'queryMode',r.query_mode,'queryOverride',r.query_override,'utmDefaults',r.utm_defaults,
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
  ELSIF mode='upsert' THEN SELECT * INTO r FROM public.redirects WHERE slug=d->>'slug' AND type='SHORT' FOR UPDATE;
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

CREATE OR REPLACE FUNCTION public.record_redirect_conversion(p_event jsonb,p_token_id uuid DEFAULT NULL,p_registered_at timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE
 visit public.redirect_events; token public.redirect_api_tokens; saved public.redirect_link_conversions;
 event_click uuid := nullif(p_event->>'clickId','')::uuid;
 customer text := nullif(p_event->>'customerExternalId','');
 event_kind text := p_event->>'kind'; event_key text := p_event->>'eventId';
 event_amount numeric := nullif(p_event->>'amount','')::numeric;
 event_currency text := nullif(p_event->>'currency','');
 event_time timestamptz := coalesce(nullif(p_event->>'occurredAt','')::timestamptz,now());
 inserted uuid;
BEGIN
 IF current_user <> 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
 IF event_kind IS NULL OR event_kind NOT IN ('lead','sale') OR customer IS NULL OR length(customer)>256
 OR event_key IS NULL OR length(event_key) NOT BETWEEN 1 AND 256
 OR coalesce(length(p_event->>'eventName'),0) NOT BETWEEN 1 AND 120
 OR jsonb_typeof(coalesce(p_event->'metadata','{}')) <> 'object'
 OR length(coalesce(p_event->'metadata','{}')::text)>8192
 OR event_time>now()+interval '5 minutes'
 OR (event_kind='lead' AND (event_amount IS NOT NULL OR event_currency IS NOT NULL))
 OR (event_kind='sale' AND (event_amount IS NULL OR event_amount<0 OR event_amount>=1e12 OR event_amount<>round(event_amount,6) OR event_amount::text IN ('NaN','Infinity','-Infinity') OR event_currency IS NULL OR event_currency !~ '^[A-Z]{3}$'))
 THEN RAISE EXCEPTION 'Invalid conversion event' USING ERRCODE='22023'; END IF;
 IF event_click IS NULL THEN SELECT click_id INTO event_click FROM public.redirect_link_customers WHERE customer_key=customer; END IF;
 SELECT * INTO visit FROM public.redirect_events WHERE click_id=event_click;
 IF visit.id IS NULL THEN RAISE EXCEPTION 'Attributed click not found' USING ERRCODE='P0002'; END IF;
 IF event_time<visit.ts THEN RAISE EXCEPTION 'Conversion precedes click' USING ERRCODE='22023'; END IF;
 IF p_registered_at IS NOT NULL AND (event_kind<>'lead' OR visit.ts>p_registered_at OR visit.ts<p_registered_at-interval '30 days') THEN
  RAISE EXCEPTION 'Signup is not attributable to this click' USING ERRCODE='22023';
 END IF;
 IF p_token_id IS NOT NULL AND NOT(visit.redirect_id=ANY(coalesce(public.redirect_management_scope(p_token_id,'conversions:write'),ARRAY[visit.redirect_id]))) THEN
  RAISE EXCEPTION 'Credential cannot attribute this link' USING ERRCODE='42501';
 END IF;
 INSERT INTO public.redirect_link_conversions(click_id,kind,amount,currency,customer_key,provider_event_id,metadata,event_name,occurred_at)
 VALUES(event_click,event_kind,event_amount,event_currency,customer,event_key,coalesce(p_event->'metadata','{}'),p_event->>'eventName',event_time)
 ON CONFLICT(provider_event_id) DO NOTHING RETURNING id INTO inserted;
 SELECT * INTO saved FROM public.redirect_link_conversions WHERE provider_event_id=event_key;
 IF inserted IS NULL AND (saved.click_id IS DISTINCT FROM event_click OR saved.kind IS DISTINCT FROM event_kind
  OR saved.amount IS DISTINCT FROM event_amount OR saved.currency IS DISTINCT FROM event_currency
  OR saved.customer_key IS DISTINCT FROM customer OR saved.event_name IS DISTINCT FROM (p_event->>'eventName')
  OR saved.metadata IS DISTINCT FROM coalesce(p_event->'metadata','{}')
  OR (p_event ? 'occurredAt' AND saved.occurred_at IS DISTINCT FROM event_time)) THEN
  RAISE EXCEPTION 'Event ID was already used with different data' USING ERRCODE='23505';
 END IF;
 INSERT INTO public.redirect_link_customers(customer_key,click_id) VALUES(customer,event_click) ON CONFLICT(customer_key) DO NOTHING;
 RETURN jsonb_build_object('id',saved.id,'clickId',saved.click_id,'kind',saved.kind,'duplicate',inserted IS NULL);
END $$;

CREATE OR REPLACE FUNCTION public.set_redirect_link_metadata(p_redirect_key text, p_folder_id uuid, p_tag_ids uuid[], p_comment text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(471983093);
  IF NOT public.has_role_jwt('admin'::public.app_role) THEN RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_tag_ids) t WHERE NOT EXISTS (SELECT FROM public.redirect_link_tags WHERE id = t)) THEN
    RAISE EXCEPTION 'Unknown tag' USING ERRCODE = '23503';
  END IF;
  INSERT INTO public.redirect_link_metadata(redirect_key, folder_id, comment)
  VALUES (p_redirect_key, p_folder_id, coalesce(p_comment,''))
  ON CONFLICT (redirect_key) DO UPDATE SET folder_id=excluded.folder_id, comment=excluded.comment, updated_at=now();
  DELETE FROM public.redirect_link_tag_assignments WHERE redirect_key=p_redirect_key;
  INSERT INTO public.redirect_link_tag_assignments(redirect_key,tag_id)
  SELECT p_redirect_key, t FROM (SELECT DISTINCT unnest(coalesce(p_tag_ids,ARRAY[]::uuid[])) AS t) tags;
END $$;

CREATE OR REPLACE FUNCTION public.create_redirect_campaign_link(p_slug text, p_target text, p_folder_id uuid DEFAULT NULL, p_tag_ids uuid[] DEFAULT ARRAY[]::uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE saved public.redirects;
BEGIN
  PERFORM pg_advisory_xact_lock(471983093);
  IF NOT public.has_role_jwt('admin'::public.app_role) THEN RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'; END IF;
  IF lower(btrim(p_slug)) !~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$' OR length(p_target) NOT BETWEEN 1 AND 8192 THEN
    RAISE EXCEPTION 'Invalid short link';
  END IF;
  INSERT INTO public.redirects(type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by)
  VALUES ('SHORT',lower(btrim(p_slug)),p_target,'EXACT',302,true,'PRESERVE',true,auth.uid()) RETURNING * INTO saved;
  PERFORM public.set_redirect_link_metadata('redirects:' || saved.id::text, p_folder_id, p_tag_ids, '');
  RETURN to_jsonb(saved);
END $$;

CREATE OR REPLACE FUNCTION public.bulk_redirect_organization(p_keys text[],p_action text,p_value uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE key text; changed integer:=0;
BEGIN
  PERFORM pg_advisory_xact_lock(471983093);
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

CREATE OR REPLACE FUNCTION public.redirect_workspace_resource(p_kind text,p_action text,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT '{}',p_limit integer DEFAULT 50,p_after uuid DEFAULT NULL,p_token_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE table_name text; scope_ids uuid[]; rows jsonb; count_value bigint; result jsonb; changed uuid; member uuid; member_role text;
BEGIN
 IF p_kind NOT IN('folders','tags','templates') OR p_action NOT IN('list','get','create','update','delete') OR p_kind IS NULL OR p_action IS NULL THEN RAISE EXCEPTION 'Invalid workspace operation' USING ERRCODE='22023'; END IF;
 scope_ids:=public.redirect_management_scope(p_token_id,CASE WHEN p_action IN('list','get') THEN 'workspace:read' ELSE 'workspace:write' END);
 member:=public.redirect_principal_member(p_token_id);
 IF member IS NOT NULL THEN
  SELECT role INTO member_role FROM public.redirect_workspace_members WHERE id=member;
  IF p_action NOT IN('list','get') AND (p_kind<>'folders' OR member_role='viewer' OR (p_action<>'create' AND public.redirect_folder_rank(member,p_id)<3)) THEN RAISE EXCEPTION 'Folder owner access is required' USING ERRCODE='42501';END IF;
  IF p_action='delete' AND EXISTS(SELECT FROM public.redirect_link_metadata WHERE folder_id=p_id) THEN RAISE EXCEPTION 'Move links before deleting this folder' USING ERRCODE='22023';END IF;
 END IF;
 table_name:=CASE p_kind WHEN 'folders' THEN 'redirect_link_folders' WHEN 'tags' THEN 'redirect_link_tags' ELSE 'redirect_utm_templates' END;
 IF p_action='list' THEN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid resource page' USING ERRCODE='22023'; END IF;
  EXECUTE format('WITH records AS MATERIALIZED(SELECT * FROM public.%I WHERE $3 IS NULL OR $4<>''folders'' OR public.redirect_folder_rank($3,id)>=1), page AS(SELECT * FROM records WHERE $1 IS NULL OR id>$1 ORDER BY id LIMIT $2+1) SELECT (SELECT count(*) FROM records),coalesce(jsonb_agg(to_jsonb(page) ORDER BY id),''[]''::jsonb) FROM page',table_name)
   INTO count_value,rows USING p_after,p_limit,member,p_kind;
  SELECT coalesce(jsonb_agg(value ORDER BY ordinal),'[]'::jsonb) INTO result FROM jsonb_array_elements(rows) WITH ORDINALITY e(value,ordinal) WHERE ordinal<=p_limit;
  RETURN jsonb_build_object('data',result,'count',count_value,'nextCursor',CASE WHEN jsonb_array_length(rows)>p_limit THEN result->(p_limit-1)->>'id' ELSE NULL END);
 END IF;
 IF p_action='get' THEN
  EXECUTE format('SELECT to_jsonb(r) FROM public.%I r WHERE id=$1',table_name) INTO result USING p_id;
  IF result IS NULL OR (member IS NOT NULL AND p_kind='folders' AND public.redirect_folder_rank(member,p_id)<1) THEN RAISE EXCEPTION 'Resource not found' USING ERRCODE='P0002'; END IF;
  RETURN result;
 END IF;
 IF p_action IN('update','delete') THEN
  EXECUTE format('SELECT id FROM public.%I WHERE id=$1 FOR UPDATE',table_name) INTO changed USING p_id;
  IF changed IS NULL THEN RAISE EXCEPTION 'Resource not found' USING ERRCODE='P0002'; END IF;
 END IF;
 IF p_action='delete' THEN
  EXECUTE format('DELETE FROM public.%I WHERE id=$1',table_name) USING p_id;
  RETURN jsonb_build_object('id',p_id,'deleted',true);
 END IF;
 IF p_action='create' THEN
  IF p_kind='folders' THEN INSERT INTO public.redirect_link_folders(name,description) VALUES(p_values->>'name',coalesce(p_values->>'description','')) RETURNING to_jsonb(redirect_link_folders.*) INTO result;
  ELSIF p_kind='tags' THEN INSERT INTO public.redirect_link_tags(name,color) VALUES(p_values->>'name',coalesce(p_values->>'color','gray')) RETURNING to_jsonb(redirect_link_tags.*) INTO result;
  ELSE INSERT INTO public.redirect_utm_templates(name,parameters) VALUES(p_values->>'name',coalesce(p_values->'parameters','{}')) RETURNING to_jsonb(redirect_utm_templates.*) INTO result;
  END IF;
 ELSE
  IF p_kind='folders' THEN UPDATE public.redirect_link_folders SET name=CASE WHEN p_values?'name' THEN p_values->>'name' ELSE name END,description=CASE WHEN p_values?'description' THEN p_values->>'description' ELSE description END WHERE id=p_id RETURNING to_jsonb(redirect_link_folders.*) INTO result;
  ELSIF p_kind='tags' THEN UPDATE public.redirect_link_tags SET name=CASE WHEN p_values?'name' THEN p_values->>'name' ELSE name END,color=CASE WHEN p_values?'color' THEN p_values->>'color' ELSE color END WHERE id=p_id RETURNING to_jsonb(redirect_link_tags.*) INTO result;
  ELSE UPDATE public.redirect_utm_templates SET name=CASE WHEN p_values?'name' THEN p_values->>'name' ELSE name END,parameters=CASE WHEN p_values?'parameters' THEN p_values->'parameters' ELSE parameters END WHERE id=p_id RETURNING to_jsonb(redirect_utm_templates.*) INTO result;
  END IF;
 END IF;
 IF p_action='create' AND p_kind='folders' AND member IS NOT NULL THEN INSERT INTO public.redirect_folder_members(folder_id,member_id,permission) VALUES((result->>'id')::uuid,member,'owner');END IF;
 RETURN result;
END $$;

-- Called through the verified principal bridge. Credentials cannot administer
-- workspace membership; folder owners may administer their own folder access.
CREATE FUNCTION public.redirect_folder_access(p_folder uuid,p_values jsonb DEFAULT NULL,p_token_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE member uuid; entry jsonb;
BEGIN
 PERFORM public.redirect_management_scope(p_token_id,CASE WHEN p_values IS NULL THEN 'workspace:read' ELSE 'workspace:write' END);
 member:=public.redirect_principal_member(p_token_id);
 IF public.redirect_folder_rank(member,p_folder)<3 THEN RAISE EXCEPTION 'Folder owner access is required' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT FROM public.redirect_link_folders WHERE id=p_folder) THEN RAISE EXCEPTION 'Folder not found' USING ERRCODE='P0002';END IF;
 IF p_values IS NOT NULL THEN
  IF jsonb_typeof(p_values)<>'object' OR EXISTS(SELECT FROM jsonb_object_keys(p_values) k WHERE k NOT IN('defaultPermission','overrides')) THEN RAISE EXCEPTION 'Invalid access settings' USING ERRCODE='22023';END IF;
  IF p_values?'defaultPermission' THEN
   IF (p_values->>'defaultPermission') IS NULL OR p_values->>'defaultPermission' NOT IN('none','view','edit') THEN RAISE EXCEPTION 'Invalid default permission' USING ERRCODE='22023';END IF;
   UPDATE public.redirect_link_folders SET default_permission=p_values->>'defaultPermission' WHERE id=p_folder;
  END IF;
  IF p_values?'overrides' THEN
   IF jsonb_typeof(p_values->'overrides')<>'array' OR jsonb_array_length(p_values->'overrides')>100 THEN RAISE EXCEPTION 'Provide up to 100 overrides' USING ERRCODE='22023';END IF;
   FOR entry IN SELECT value FROM jsonb_array_elements(p_values->'overrides') LOOP
    IF jsonb_typeof(entry)<>'object' OR EXISTS(SELECT FROM jsonb_object_keys(entry) k WHERE k NOT IN('memberId','permission')) OR NOT(entry?'memberId') OR NOT(entry?'permission') THEN RAISE EXCEPTION 'Invalid override' USING ERRCODE='22023';END IF;
    IF entry->'permission'='null'::jsonb THEN DELETE FROM public.redirect_folder_members WHERE folder_id=p_folder AND member_id=(entry->>'memberId')::uuid;
    ELSE
     IF entry->>'permission' NOT IN('none','view','edit','owner') THEN RAISE EXCEPTION 'Invalid permission' USING ERRCODE='22023';END IF;
     INSERT INTO public.redirect_folder_members(folder_id,member_id,permission) VALUES(p_folder,(entry->>'memberId')::uuid,entry->>'permission') ON CONFLICT(folder_id,member_id) DO UPDATE SET permission=excluded.permission;
    END IF;
   END LOOP;
  END IF;
 END IF;
 RETURN jsonb_build_object('folderId',p_folder,'defaultPermission',(SELECT default_permission FROM public.redirect_link_folders WHERE id=p_folder),
  'members',coalesce((SELECT jsonb_agg(jsonb_build_object('id',m.id,'label',m.label,'kind',m.kind,'role',m.role,'active',m.active,'permission',a.permission) ORDER BY m.label,m.id) FROM public.redirect_workspace_members m LEFT JOIN public.redirect_folder_members a ON a.member_id=m.id AND a.folder_id=p_folder),'[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.redirect_folder_access(uuid,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_folder_access(uuid,jsonb,uuid) TO service_role;
