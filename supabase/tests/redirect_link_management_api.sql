BEGIN;
INSERT INTO auth.users(id) VALUES('00000000-0000-4000-8000-000000000001');
INSERT INTO public.user_roles VALUES('00000000-0000-4000-8000-000000000001','admin');
INSERT INTO public.redirect_link_folders(id,name) VALUES('00000000-0000-4000-8000-000000000020','API folder');
INSERT INTO public.redirect_link_tags(id,name) VALUES('00000000-0000-4000-8000-000000000021','API tag');
SET LOCAL ROLE service_role;
DO $$
DECLARE result jsonb; link_id uuid; second_id uuid; token_id uuid; n integer; before_count integer; page jsonb; cursor_id uuid; click_id_value uuid; donation_id uuid;
BEGIN
 result:=public.redirect_management_mutate('[{"operation":"create","data":{"slug":"api-fixture","target":"https://example.com/a?x=1#details","folderId":"00000000-0000-4000-8000-000000000020","tagIds":["00000000-0000-4000-8000-000000000021"],"comment":"API comment","utmDefaults":{"utm_campaign":"launch"}}}]');
 link_id:=(result->0->'link'->>'id')::uuid;
 IF NOT (result->0->>'created')::boolean OR result->0->'link'->>'comment'<>'API comment' OR result->0->'link'->>'shortUrl'<>'https://queer.guide/go/api-fixture' THEN RAISE EXCEPTION 'Creation projection failed'; END IF;
 result:=public.redirect_management_mutate('[{"operation":"create","data":{"target":"/events"}}]');
 second_id:=(result->0->'link'->>'id')::uuid;
 IF result->0->'link'->>'slug' !~ '^[0-9a-f]{12}$' THEN RAISE EXCEPTION 'Random slug missing'; END IF;
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,redirect_ids,created_by,expires_at)
 VALUES('API limited',repeat('e',64),'fixture',ARRAY['links:read','links:write'],ARRAY[link_id],'00000000-0000-4000-8000-000000000001',now()+interval '1 day') RETURNING id INTO token_id;
 result:=public.redirect_management_list('{}',50,NULL,token_id);
 IF (result->>'count')::integer<>1 OR jsonb_array_length(result->'data')<>1 THEN RAISE EXCEPTION 'Selected-link read escaped scope'; END IF;
 IF result->'data'->0 ? 'password_hash' OR result->'data'->0 ? 'ip_hash' THEN RAISE EXCEPTION 'Secret projection exposed'; END IF;
 result:=public.redirect_management_list('{"folderId":"00000000-0000-4000-8000-000000000020","tagId":"00000000-0000-4000-8000-000000000021"}',0,NULL,token_id);
 IF (result->>'count')::integer<>1 OR jsonb_array_length(result->'data')<>0 THEN RAISE EXCEPTION 'Count or organization filters failed'; END IF;
 result:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',link_id,'data','{"target":"https://example.com/new","expiresAt":"2030-01-01T00:00:00Z"}'::jsonb)),token_id);
 IF result->0->'link'->>'comment'<>'API comment' OR jsonb_array_length(result->0->'link'->'tagIds')<>1 THEN RAISE EXCEPTION 'Partial update erased organization'; END IF;
 PERFORM public.set_redirect_link_policy(link_id,'{"expires_at":"2030-01-01T00:00:00Z"}',NULL,false);
 result:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',link_id,'data','{"expiresAt":null,"folderId":null,"tagIds":[],"comment":""}'::jsonb)),token_id);
 IF EXISTS(SELECT FROM public.redirect_link_policies WHERE redirect_id=link_id AND policy?'expires_at') THEN RAISE EXCEPTION 'Cleared expiration remained active'; END IF;
 IF result->0->'link'->'folderId'<>'null'::jsonb OR jsonb_array_length(result->0->'link'->'tagIds')<>0 THEN RAISE EXCEPTION 'Explicit organization clear failed'; END IF;
 BEGIN
  PERFORM public.redirect_management_mutate(jsonb_build_array(
   jsonb_build_object('operation','update','id',link_id,'data','{"comment":"should roll back"}'::jsonb),
   jsonb_build_object('operation','update','id',second_id,'data','{"comment":"outside scope"}'::jsonb)),token_id);
  RAISE EXCEPTION 'Scoped bulk escaped';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 IF public.redirect_management_link(link_id)->>'comment'<>'' THEN RAISE EXCEPTION 'Denied bulk left partial writes'; END IF;
 BEGIN
  PERFORM public.redirect_management_mutate('[{"operation":"create","data":{"slug":"denied-create","target":"/events"}}]',token_id);
  RAISE EXCEPTION 'Limited credential created link';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 result:=public.redirect_management_mutate('[{"operation":"upsert","data":{"slug":"api-fixture","target":"/updated"}}]',token_id);
 IF (result->0->>'created')::boolean OR (result->0->'link'->>'id')::uuid<>link_id THEN RAISE EXCEPTION 'Upsert changed identity'; END IF;
 BEGIN
  PERFORM public.redirect_management_mutate('[{"operation":"create","data":{"slug":"rollback-create","target":"/events"}},{"operation":"create","data":{"slug":"invalid-tag","target":"/events","tagIds":["00000000-0000-4000-8000-000000000099"]}}]');
  RAISE EXCEPTION 'Invalid tag accepted';
 EXCEPTION WHEN foreign_key_violation THEN NULL;
 END;
 IF EXISTS(SELECT FROM public.redirects WHERE slug IN('rollback-create','invalid-tag')) THEN RAISE EXCEPTION 'Failed batch left links behind'; END IF;
 UPDATE public.redirect_api_tokens SET revoked_at=now() WHERE id=token_id;
 BEGIN
  PERFORM public.redirect_management_list('{}',50,NULL,token_id);
  RAISE EXCEPTION 'Revoked read accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 UPDATE public.redirect_api_tokens SET revoked_at=NULL,scopes=ARRAY['events:read'] WHERE id=token_id;
 BEGIN
  PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','delete','id',link_id)),token_id);
  RAISE EXCEPTION 'Analytics scope deleted link';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 INSERT INTO public.redirects(type,slug,target) SELECT 'SHORT','page-fixture-'||fixtures.seq,'/events' FROM generate_series(1,1101) AS fixtures(seq);
 result:=public.redirect_management_list('{"search":"page-fixture-"}',100);
 IF (result->>'count')::integer<>1101 OR jsonb_array_length(result->'data')<>100 OR result->>'nextCursor' IS NULL THEN RAISE EXCEPTION 'Count or first page capped'; END IF;
 cursor_id:=(result->>'nextCursor')::uuid; n:=100;
 LOOP
  page:=public.redirect_management_list('{"search":"page-fixture-"}',100,cursor_id);
  IF EXISTS(SELECT FROM jsonb_array_elements(page->'data') e WHERE (e->>'id')::uuid<=cursor_id) THEN RAISE EXCEPTION 'Page duplicates'; END IF;
  n:=n+jsonb_array_length(page->'data'); cursor_id:=(page->>'nextCursor')::uuid;
  EXIT WHEN cursor_id IS NULL;
 END LOOP;
 IF n<>1101 THEN RAISE EXCEPTION 'Pagination lost links'; END IF;
 click_id_value:=public.record_redirect_visit(link_id,'/go/api-fixture',NULL,NULL,NULL,NULL,NULL,302,NULL,'/events');
 INSERT INTO public.donations(redirect_click_id) VALUES(click_id_value) RETURNING id INTO donation_id;
 result:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','delete','id',link_id)));
 IF NOT (result->0->>'deleted')::boolean OR EXISTS(SELECT FROM public.redirects WHERE id=link_id) OR EXISTS(SELECT FROM public.redirect_link_metadata WHERE redirect_key='redirects:'||link_id::text) OR EXISTS(SELECT FROM public.redirect_events WHERE redirect_id=link_id) THEN RAISE EXCEPTION 'Delete did not clean managed resources'; END IF;
 IF NOT EXISTS(SELECT FROM public.donations WHERE id=donation_id AND redirect_click_id IS NULL) THEN RAISE EXCEPTION 'Deletion damaged donation ledger'; END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF has_function_privilege(current_user,'public.redirect_management_mutate(jsonb,uuid,uuid)','execute') OR has_function_privilege(current_user,'public.redirect_management_list(jsonb,integer,uuid,uuid)','execute') THEN RAISE EXCEPTION 'Management RPC exposed'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
