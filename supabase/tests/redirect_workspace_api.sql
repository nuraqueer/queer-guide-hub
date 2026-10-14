BEGIN;
INSERT INTO auth.users(id) VALUES('00000000-0000-4000-8000-000000000001');
INSERT INTO public.user_roles VALUES('00000000-0000-4000-8000-000000000001','admin');
SET LOCAL ROLE service_role;
DO $$
DECLARE folder jsonb; tag jsonb; template jsonb; token_id uuid; link_id uuid; result jsonb; page jsonb; next_id uuid;
BEGIN
 folder:=public.redirect_workspace_resource('folders','create',p_values=>'{"name":"SDK folder","description":"original"}');
 tag:=public.redirect_workspace_resource('tags','create',p_values=>'{"name":"SDK tag","color":"pink"}');
 template:=public.redirect_workspace_resource('templates','create',p_values=>'{"name":"SDK template","parameters":{"utm_campaign":"launch"}}');
 result:=public.redirect_workspace_resource('folders','update',(folder->>'id')::uuid,'{"description":"changed"}');
 IF result->>'name'<>'SDK folder' OR result->>'description'<>'changed' THEN RAISE EXCEPTION 'Patch erased omitted resource fields'; END IF;
 IF public.redirect_workspace_resource('folders','get',(folder->>'id')::uuid)->>'description'<>'changed' THEN RAISE EXCEPTION 'Resource detail failed'; END IF;
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,created_by,expires_at) VALUES('workspace',repeat('f',64),'fixture',ARRAY['workspace:read','workspace:write'],'00000000-0000-4000-8000-000000000001',now()+interval '1 day') RETURNING id INTO token_id;
 result:=public.redirect_workspace_resource('folders','list',p_limit=>1,p_token_id=>token_id);
 IF (result->>'count')::int<>1 OR jsonb_array_length(result->'data')<>1 THEN RAISE EXCEPTION 'Resource list failed'; END IF;
 INSERT INTO public.redirect_utm_templates(name) SELECT 'paged template '||seq FROM generate_series(1,103) AS fixtures(seq);
 page:=public.redirect_workspace_resource('templates','list',p_limit=>100);
 IF (page->>'count')::int<>104 OR jsonb_array_length(page->'data')<>100 OR page->>'nextCursor' IS NULL THEN RAISE EXCEPTION 'Resource count or first page capped'; END IF;
 next_id:=(page->>'nextCursor')::uuid;
 page:=public.redirect_workspace_resource('templates','list',p_limit=>100,p_after=>next_id);
 IF jsonb_array_length(page->'data')<>4 OR page->>'nextCursor' IS NOT NULL THEN RAISE EXCEPTION 'Resource second page lost rows'; END IF;
 IF EXISTS(SELECT FROM jsonb_array_elements(page->'data') e WHERE (e->>'id')::uuid<=next_id) THEN RAISE EXCEPTION 'Resource page duplicated records'; END IF;
 INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','workspace-api-fixture','/events') RETURNING id INTO link_id;
 INSERT INTO public.redirect_link_metadata(redirect_key,folder_id) VALUES('redirects:'||link_id::text,(folder->>'id')::uuid);
 INSERT INTO public.redirect_link_tag_assignments VALUES('redirects:'||link_id::text,(tag->>'id')::uuid);
 UPDATE public.redirect_api_tokens SET redirect_ids=ARRAY[link_id] WHERE id=token_id;
 BEGIN
  PERFORM public.redirect_workspace_resource('folders','delete',(folder->>'id')::uuid,p_token_id=>token_id);
  RAISE EXCEPTION 'Selected-link token changed workspace';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 UPDATE public.redirect_api_tokens SET redirect_ids=NULL,revoked_at=now() WHERE id=token_id;
 BEGIN
  PERFORM public.redirect_workspace_resource('folders','list',p_token_id=>token_id);
  RAISE EXCEPTION 'Revoked token read workspace';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 UPDATE public.redirect_api_tokens SET revoked_at=NULL,scopes=ARRAY['workspace:read'] WHERE id=token_id;
 BEGIN
  PERFORM public.redirect_workspace_resource('folders','delete',(folder->>'id')::uuid,p_token_id=>token_id);
  RAISE EXCEPTION 'Read-only token deleted workspace';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 PERFORM public.redirect_workspace_resource('folders','delete',(folder->>'id')::uuid);
 PERFORM public.redirect_workspace_resource('tags','delete',(tag->>'id')::uuid);
 IF EXISTS(SELECT FROM public.redirect_link_metadata WHERE folder_id=(folder->>'id')::uuid) OR EXISTS(SELECT FROM public.redirect_link_tag_assignments WHERE tag_id=(tag->>'id')::uuid) THEN RAISE EXCEPTION 'Delete left stale organization'; END IF;
 IF NOT EXISTS(SELECT FROM public.redirects WHERE id=link_id) THEN RAISE EXCEPTION 'Resource delete removed link'; END IF;
 BEGIN
  PERFORM public.redirect_workspace_resource('folders','get',(folder->>'id')::uuid);
  RAISE EXCEPTION 'Missing resource not rejected';
 EXCEPTION WHEN no_data_found THEN NULL;
 END;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF has_function_privilege(current_user,'public.redirect_workspace_resource(text,text,uuid,jsonb,integer,uuid,uuid)','execute') THEN RAISE EXCEPTION 'Workspace RPC exposed'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
