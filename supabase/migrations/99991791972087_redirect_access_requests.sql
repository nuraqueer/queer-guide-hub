CREATE TABLE public.redirect_access_requests (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 folder_id uuid NOT NULL REFERENCES public.redirect_link_folders(id) ON DELETE CASCADE,
 member_id uuid NOT NULL REFERENCES public.redirect_workspace_members(id) ON DELETE CASCADE,
 message text NOT NULL DEFAULT '' CHECK(length(message)<=1000),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','approved','denied','cancelled')),
 granted_permission text CHECK(granted_permission IN('edit','owner')),
 decided_by uuid,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX redirect_access_one_pending ON public.redirect_access_requests(folder_id,member_id) WHERE status='pending';
CREATE INDEX redirect_access_folder_idx ON public.redirect_access_requests(folder_id);
CREATE INDEX redirect_access_member_idx ON public.redirect_access_requests(member_id,created_at);
CREATE TABLE public.redirect_access_mail (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL REFERENCES public.redirect_access_requests(id) ON DELETE CASCADE,
 recipient_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 recipient_email text NOT NULL CHECK(length(recipient_email) BETWEEN 3 AND 320),
 event text NOT NULL CHECK(event IN('requested','approved','denied')),
 state text NOT NULL DEFAULT 'queued' CHECK(state IN('queued','leased','sent','failed','cancelled')),
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 8),
 next_attempt_at timestamptz NOT NULL DEFAULT now(),lease_id uuid,lease_until timestamptz,
 first_attempt_at timestamptz,from_address text,provider_id text,last_error text,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(request_id,recipient_user_id,event)
);
CREATE INDEX redirect_access_mail_recipient_idx ON public.redirect_access_mail(recipient_user_id);
CREATE INDEX redirect_access_mail_due_idx ON public.redirect_access_mail(next_attempt_at) WHERE state IN('queued','leased');
ALTER TABLE public.redirect_access_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redirect_access_mail ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_access_requests,public.redirect_access_mail FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_access_requests,public.redirect_access_mail TO service_role;
CREATE TRIGGER redirect_access_request_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_access_requests FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();

CREATE FUNCTION public.redirect_folder_owners(p_folder uuid) RETURNS TABLE(user_id uuid)
LANGUAGE sql SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT r.user_id FROM public.user_roles r WHERE r.role='admin'
 UNION SELECT m.user_id FROM public.redirect_folder_members f JOIN public.redirect_workspace_members m ON m.id=f.member_id
 WHERE f.folder_id=p_folder AND f.permission='owner' AND m.kind='user' AND m.active AND m.role='member'
$$;
-- Auth email columns are unavailable to service_role by default. This narrow,
-- service-only lookup avoids granting access to the Auth users table.
CREATE FUNCTION public.redirect_access_recipient(p_user uuid) RETURNS TABLE(email text)
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT u.email::text FROM auth.users u WHERE u.id=p_user AND u.email_confirmed_at IS NOT NULL AND u.email IS NOT NULL
$$;
REVOKE ALL ON FUNCTION public.redirect_access_recipient(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_access_recipient(uuid) TO service_role;
CREATE FUNCTION public.redirect_access_notify(p_request uuid,p_event text) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_access_requests; recipient uuid; url text;
BEGIN
 SELECT * INTO STRICT r FROM public.redirect_access_requests WHERE id=p_request;
 url:='/links-workspace?accessRequests='||CASE WHEN p_event='requested' THEN 'review' ELSE 'mine' END;
 FOR recipient IN SELECT user_id FROM public.redirect_folder_owners(r.folder_id) WHERE p_event='requested'
 UNION SELECT user_id FROM public.redirect_workspace_members WHERE id=r.member_id AND p_event IN('approved','denied') LOOP
  INSERT INTO public.notifications(user_id,type,title,content,action_url,related_id,metadata)
  VALUES(recipient,'system',CASE WHEN p_event='requested' THEN 'Link folder edit request' ELSE 'Link folder access request updated' END,
   'Open the link workspace to review this access request.',url,r.id,jsonb_build_object('redirect_access_request',r.id,'event',p_event));
  INSERT INTO public.redirect_access_mail(request_id,recipient_user_id,recipient_email,event)
  SELECT r.id,recipient,u.email,p_event FROM public.redirect_access_recipient(recipient) u
  ON CONFLICT(request_id,recipient_user_id,event) DO NOTHING;
 END LOOP;
END $$;
CREATE FUNCTION public.redirect_access_request(p_action text,p_principal uuid,p_id uuid DEFAULT NULL,p_folder uuid DEFAULT NULL,p_message text DEFAULT '',p_permission text DEFAULT 'edit',p_actor uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE member public.redirect_workspace_members;r public.redirect_access_requests; last_at timestamptz; rate integer; actor uuid;
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 PERFORM public.redirect_management_scope(p_principal,'workspace:read');
 IF p_principal IS NOT NULL THEN
  SELECT * INTO member FROM public.redirect_workspace_members WHERE id=p_principal AND active AND kind='user';
  IF member.id IS NULL THEN RAISE EXCEPTION 'Account session required' USING ERRCODE='42501';END IF;
 END IF;
 IF p_action='create' THEN
  IF member.id IS NULL OR public.redirect_folder_rank(member.id,p_folder)<>1 THEN RAISE EXCEPTION 'A view-only folder is required' USING ERRCODE='42501';END IF;
  IF p_message IS NULL OR length(p_message)>1000 THEN RAISE EXCEPTION 'Message exceeds 1,000 characters' USING ERRCODE='22023';END IF;
  SELECT * INTO r FROM public.redirect_access_requests WHERE folder_id=p_folder AND member_id=member.id AND status='pending';
  IF r.id IS NOT NULL THEN RETURN to_jsonb(r)||jsonb_build_object('duplicate',true);END IF;
  SELECT max(created_at),count(*) INTO last_at,rate FROM public.redirect_access_requests WHERE member_id=member.id AND created_at>clock_timestamp()-interval '1 day' AND folder_id=p_folder;
  IF rate>0 THEN RETURN jsonb_build_object('retryAfter',greatest(1,ceil(extract(epoch FROM last_at+interval '1 day'-clock_timestamp()))::int));END IF;
  SELECT count(*) INTO rate FROM public.redirect_access_requests WHERE member_id=member.id AND created_at>clock_timestamp()-interval '1 day';
  IF rate>=10 THEN RETURN jsonb_build_object('retryAfter',86400);END IF;
  IF NOT EXISTS(SELECT FROM public.redirect_folder_owners(p_folder)) THEN RAISE EXCEPTION 'No folder administrator is available; contact a workspace administrator' USING ERRCODE='22023';END IF;
  INSERT INTO public.redirect_access_requests(folder_id,member_id,message) VALUES(p_folder,member.id,btrim(p_message)) RETURNING * INTO r;
  PERFORM public.redirect_access_notify(r.id,'requested');
  RETURN to_jsonb(r);
 END IF;
 SELECT * INTO r FROM public.redirect_access_requests WHERE id=p_id FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Request not found' USING ERRCODE='P0002';END IF;
 IF p_action='cancel' THEN
  IF member.id IS NULL OR r.member_id<>member.id THEN RAISE EXCEPTION 'Request not found' USING ERRCODE='P0002';END IF;
 ELSIF p_action IN('approve','deny') THEN
  IF public.redirect_folder_rank(member.id,r.folder_id)<3 THEN RAISE EXCEPTION 'Folder owner access is required' USING ERRCODE='42501';END IF;
 ELSE RAISE EXCEPTION 'Invalid request action' USING ERRCODE='22023';END IF;
 IF r.status<>'pending' THEN RAISE EXCEPTION 'Request was already resolved' USING ERRCODE='23505';END IF;
 IF p_action='approve' THEN
  IF p_permission IS NULL OR p_permission NOT IN('edit','owner') THEN RAISE EXCEPTION 'Choose edit or owner access' USING ERRCODE='22023';END IF;
  IF NOT EXISTS(SELECT FROM public.redirect_workspace_members WHERE id=r.member_id AND active AND role='member') THEN RAISE EXCEPTION 'A workspace administrator must activate or upgrade the viewer membership before approval' USING ERRCODE='22023';END IF;
  INSERT INTO public.redirect_folder_members(folder_id,member_id,permission) VALUES(r.folder_id,r.member_id,p_permission) ON CONFLICT(folder_id,member_id) DO UPDATE SET permission=excluded.permission;
 END IF;
 actor:=coalesce(member.user_id,p_actor);
 UPDATE public.redirect_access_requests SET status=CASE p_action WHEN 'approve' THEN 'approved' WHEN 'deny' THEN 'denied' ELSE 'cancelled' END,
  granted_permission=CASE WHEN p_action='approve' THEN p_permission ELSE NULL END,decided_by=actor,updated_at=clock_timestamp() WHERE id=r.id RETURNING * INTO r;
 UPDATE public.redirect_access_mail SET state='cancelled',updated_at=clock_timestamp() WHERE request_id=r.id AND event='requested' AND state IN('queued','leased');
 IF p_action IN('approve','deny') THEN PERFORM public.redirect_access_notify(r.id,r.status);END IF;
 RETURN to_jsonb(r);
END $$;
CREATE FUNCTION public.redirect_access_requests_page(p_principal uuid,p_view text DEFAULT 'mine',p_limit integer DEFAULT 50,p_after uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE member uuid;rows jsonb;total bigint;next_id text;
BEGIN
 PERFORM public.redirect_management_scope(p_principal,'workspace:read');
 IF p_view IS NULL OR p_view NOT IN('mine','review') OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid request page' USING ERRCODE='22023';END IF;
 IF p_principal IS NOT NULL THEN SELECT id INTO member FROM public.redirect_workspace_members WHERE id=p_principal AND kind='user' AND active;IF member IS NULL THEN RAISE EXCEPTION 'Account session required' USING ERRCODE='42501';END IF;END IF;
 WITH visible AS MATERIALIZED(
  SELECT r.*,CASE WHEN public.redirect_folder_rank(member,r.folder_id)>=1 THEN f.name ELSE 'Restricted folder' END AS folder_name,m.label AS member_label,m.role AS member_role,m.active AS member_active
  FROM public.redirect_access_requests r JOIN public.redirect_link_folders f ON f.id=r.folder_id JOIN public.redirect_workspace_members m ON m.id=r.member_id
  WHERE (p_view='mine' AND r.member_id=member) OR (p_view='review' AND r.status='pending' AND public.redirect_folder_rank(member,r.folder_id)>=3)
 ),page AS MATERIALIZED(SELECT * FROM visible WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit+1),shown AS(SELECT * FROM page ORDER BY id LIMIT p_limit)
 SELECT (SELECT count(*) FROM visible),coalesce(jsonb_agg(to_jsonb(shown) ORDER BY id),'[]'::jsonb),CASE WHEN (SELECT count(*) FROM page)>p_limit THEN max(id::text) ELSE NULL END INTO total,rows,next_id FROM shown;
 RETURN jsonb_build_object('data',rows,'count',total,'nextCursor',next_id);
END $$;
REVOKE ALL ON FUNCTION public.redirect_folder_owners(uuid),public.redirect_access_notify(uuid,text),public.redirect_access_request(text,uuid,uuid,uuid,text,text,uuid),public.redirect_access_requests_page(uuid,text,integer,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_folder_owners(uuid),public.redirect_access_notify(uuid,text),public.redirect_access_request(text,uuid,uuid,uuid,text,text,uuid),public.redirect_access_requests_page(uuid,text,integer,uuid) TO service_role;

CREATE FUNCTION public.claim_redirect_access_mail(p_from text,p_limit integer DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE job public.redirect_access_mail; request public.redirect_access_requests; valid boolean; result jsonb:='[]';
BEGIN
 PERFORM pg_advisory_xact_lock_shared(471983093);
 IF p_from IS NULL OR length(p_from) NOT BETWEEN 3 AND 320 OR p_from ~ E'[\r\n]' OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'Invalid mail claim' USING ERRCODE='22023';END IF;
 FOR job IN SELECT * FROM public.redirect_access_mail WHERE (state='queued' AND next_attempt_at<=clock_timestamp()) OR (state='leased' AND lease_until<=clock_timestamp()) ORDER BY next_attempt_at,id LIMIT p_limit FOR UPDATE SKIP LOCKED LOOP
  SELECT * INTO request FROM public.redirect_access_requests WHERE id=job.request_id;
  SELECT EXISTS(SELECT FROM public.redirect_access_recipient(job.recipient_user_id) u WHERE u.email=job.recipient_email) INTO valid;
  valid:=valid AND CASE WHEN job.event='requested' THEN request.status='pending' AND EXISTS(SELECT FROM public.redirect_folder_owners(request.folder_id) WHERE user_id=job.recipient_user_id)
   ELSE request.status=job.event AND EXISTS(SELECT FROM public.redirect_workspace_members WHERE id=request.member_id AND user_id=job.recipient_user_id AND active) END;
  IF NOT coalesce(valid,false) THEN UPDATE public.redirect_access_mail SET state='cancelled',lease_id=NULL,lease_until=NULL,updated_at=clock_timestamp() WHERE id=job.id;CONTINUE;END IF;
  IF job.attempts>=8 OR job.first_attempt_at<clock_timestamp()-interval '23 hours' THEN UPDATE public.redirect_access_mail SET state='failed',last_error='Delivery retry window elapsed',lease_id=NULL,lease_until=NULL,updated_at=clock_timestamp() WHERE id=job.id;CONTINUE;END IF;
  UPDATE public.redirect_access_mail SET state='leased',attempts=attempts+1,lease_id=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes',first_attempt_at=coalesce(first_attempt_at,clock_timestamp()),from_address=coalesce(from_address,p_from),updated_at=clock_timestamp() WHERE id=job.id RETURNING * INTO job;
  result:=result||jsonb_build_array(jsonb_build_object('id',job.id,'leaseId',job.lease_id,'email',job.recipient_email,'from',job.from_address,'event',job.event));
 END LOOP;
 RETURN result;
END $$;
CREATE FUNCTION public.finish_redirect_access_mail(p_id uuid,p_lease uuid,p_provider_id text DEFAULT NULL,p_error text DEFAULT NULL,p_retry boolean DEFAULT true,p_retry_after integer DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE job public.redirect_access_mail;
BEGIN
 SELECT * INTO job FROM public.redirect_access_mail WHERE id=p_id AND state='leased' AND lease_id=p_lease FOR UPDATE;
 IF job.id IS NULL THEN RETURN false;END IF;
 IF p_provider_id IS NOT NULL AND length(p_provider_id) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Invalid provider receipt' USING ERRCODE='22023';END IF;
 UPDATE public.redirect_access_mail SET state=CASE WHEN p_provider_id IS NOT NULL THEN 'sent' WHEN p_retry AND attempts<8 AND first_attempt_at>clock_timestamp()-interval '23 hours' THEN 'queued' ELSE 'failed' END,
  next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(least(3600,30*(2^greatest(0,attempts-1))::integer),least(82800,greatest(0,coalesce(p_retry_after,0))))),
  provider_id=p_provider_id,last_error=CASE WHEN p_provider_id IS NULL THEN left(coalesce(p_error,'Email delivery unavailable'),200) ELSE NULL END,
  lease_id=NULL,lease_until=NULL,updated_at=clock_timestamp() WHERE id=p_id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.claim_redirect_access_mail(text,integer),public.finish_redirect_access_mail(uuid,uuid,text,text,boolean,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_redirect_access_mail(text,integer),public.finish_redirect_access_mail(uuid,uuid,text,text,boolean,integer) TO service_role;

-- The existing internal invoke secret and a project-local Vault supabase_url
-- activate dispatch. No call is made when either is missing. Tests omit cron.
DO $migration$
DECLARE command text;
BEGIN
 IF to_regprocedure('cron.schedule(text,text,text)') IS NULL THEN RETURN;END IF;
 command:=$cron$
 SELECT net.http_post(
  url:=rtrim(url.decrypted_secret,'/')||'/functions/v1/redirect-access-notifications',
  headers:=jsonb_build_object('Content-Type','application/json','x-internal-secret',secret.decrypted_secret),body:='{}'::jsonb,timeout_milliseconds:=60000)
 FROM vault.decrypted_secrets url CROSS JOIN vault.decrypted_secrets secret
 WHERE url.name='supabase_url' AND secret.name='internal_invoke_secret'
  AND url.decrypted_secret ~ '^https://[a-z0-9-]+\.supabase\.co$' AND length(secret.decrypted_secret)>0
 LIMIT 1;
 $cron$;
 EXECUTE 'SELECT cron.schedule($1,$2,$3)' USING 'redirect-access-notifications','*/5 * * * *',command;
END $migration$;

-- Editors may rename folders; owners retain membership/deletion controls.
CREATE OR REPLACE FUNCTION public.redirect_folder_capabilities(p_folder uuid,p_principal uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE rank integer; scopes text[];
BEGIN
 rank:=public.redirect_folder_rank(public.redirect_principal_member(p_principal),p_folder);
 SELECT t.scopes INTO scopes FROM public.redirect_api_tokens t WHERE id=p_principal;
 RETURN jsonb_build_object('canEdit',rank>=2 AND (scopes IS NULL OR 'links:write'=ANY(scopes)),'canRename',rank>=2 AND (scopes IS NULL OR 'workspace:write'=ANY(scopes)),'canManage',rank>=3 AND (scopes IS NULL OR 'workspace:write'=ANY(scopes)));
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
  IF p_action NOT IN('list','get') AND (p_kind<>'folders' OR member_role='viewer' OR (p_action<>'create' AND public.redirect_folder_rank(member,p_id)<CASE WHEN p_action='update' THEN 2 ELSE 3 END)) THEN RAISE EXCEPTION 'Folder owner access is required' USING ERRCODE='42501';END IF;
  IF p_action='delete' AND EXISTS(SELECT FROM public.redirect_link_metadata WHERE folder_id=p_id) THEN RAISE EXCEPTION 'Move links before deleting this folder' USING ERRCODE='22023';END IF;
 END IF;
 table_name:=CASE p_kind WHEN 'folders' THEN 'redirect_link_folders' WHEN 'tags' THEN 'redirect_link_tags' ELSE 'redirect_utm_templates' END;
 IF p_action='list' THEN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid resource page' USING ERRCODE='22023'; END IF;
  EXECUTE format('WITH records AS MATERIALIZED(SELECT * FROM public.%I WHERE $3 IS NULL OR $4<>''folders'' OR public.redirect_folder_rank($3,id)>=1), page AS(SELECT * FROM records WHERE $1 IS NULL OR id>$1 ORDER BY id LIMIT $2+1) SELECT (SELECT count(*) FROM records),coalesce(jsonb_agg(to_jsonb(page) ORDER BY id),''[]''::jsonb) FROM page',table_name)
   INTO count_value,rows USING p_after,p_limit,member,p_kind;
  SELECT coalesce(jsonb_agg(value ORDER BY ordinal),'[]'::jsonb) INTO result FROM jsonb_array_elements(rows) WITH ORDINALITY e(value,ordinal) WHERE ordinal<=p_limit;
  IF p_kind='folders' THEN SELECT coalesce(jsonb_agg(value||public.redirect_folder_capabilities((value->>'id')::uuid,p_token_id) ORDER BY ordinal),'[]'::jsonb) INTO result FROM jsonb_array_elements(result) WITH ORDINALITY e(value,ordinal);END IF;
  RETURN jsonb_build_object('data',result,'count',count_value,'nextCursor',CASE WHEN jsonb_array_length(rows)>p_limit THEN result->(p_limit-1)->>'id' ELSE NULL END);
 END IF;
 IF p_action='get' THEN
  EXECUTE format('SELECT to_jsonb(r) FROM public.%I r WHERE id=$1',table_name) INTO result USING p_id;
  IF result IS NULL OR (member IS NOT NULL AND p_kind='folders' AND public.redirect_folder_rank(member,p_id)<1) THEN RAISE EXCEPTION 'Resource not found' USING ERRCODE='P0002'; END IF;
  IF p_kind='folders' THEN result:=result||public.redirect_folder_capabilities(p_id,p_token_id);END IF;
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
 IF p_kind='folders' THEN result:=result||public.redirect_folder_capabilities((result->>'id')::uuid,p_token_id);END IF;
 RETURN result;
END $$;


