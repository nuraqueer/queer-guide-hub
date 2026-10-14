BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"role":"authenticated","user_role":"admin"}';
DO $$ DECLARE folder uuid; tag_a uuid; tag_b uuid; saved jsonb; key text; count_before integer; BEGIN
 INSERT INTO public.redirect_link_folders(name) VALUES('bulk-fixture') RETURNING id INTO folder;
 INSERT INTO public.redirect_link_tags(name) VALUES('bulk-a') RETURNING id INTO tag_a;
 INSERT INTO public.redirect_link_tags(name) VALUES('bulk-b') RETURNING id INTO tag_b;
 saved:=public.create_redirect_campaign_link('bulk-fixture-link','/events',NULL,ARRAY[tag_a]);
 key:='redirects:'||(saved->>'id');
 PERFORM public.set_redirect_link_metadata(key,NULL,ARRAY[tag_a],'Keep this comment');
 IF public.bulk_redirect_organization(ARRAY[key,key,'static:fixture'],'archive')<>2 THEN RAISE EXCEPTION 'Bulk keys not deduplicated'; END IF;
 IF NOT EXISTS(SELECT FROM public.redirect_link_metadata WHERE redirect_key=key AND is_archived) OR NOT EXISTS(SELECT FROM public.redirects WHERE id=(saved->>'id')::uuid AND is_enabled) THEN RAISE EXCEPTION 'Archive changed routing or failed'; END IF;
 PERFORM public.bulk_redirect_organization(ARRAY[key],'folder',folder);
 PERFORM public.bulk_redirect_organization(ARRAY[key],'add-tag',tag_b);
 IF (SELECT count(*) FROM public.redirect_link_tag_assignments WHERE redirect_key=key)<>2 THEN RAISE EXCEPTION 'Adding tag erased previous tags'; END IF;
 PERFORM public.bulk_redirect_organization(ARRAY[key],'remove-tag',tag_b);
 IF NOT EXISTS(SELECT FROM public.redirect_link_metadata WHERE redirect_key=key AND comment='Keep this comment' AND folder_id=folder AND is_archived) THEN RAISE EXCEPTION 'Bulk assignment erased other metadata'; END IF;
 BEGIN
  PERFORM public.bulk_redirect_organization(ARRAY['new-key','redirects:'||gen_random_uuid()::text],'archive');
  RAISE EXCEPTION 'Missing managed redirect accepted';
 EXCEPTION WHEN no_data_found THEN NULL; END;
 IF EXISTS(SELECT FROM public.redirect_link_metadata WHERE redirect_key='new-key') THEN RAISE EXCEPTION 'Failed batch partially persisted'; END IF;
 BEGIN PERFORM public.bulk_redirect_organization(ARRAY[key],'add-tag',gen_random_uuid()); RAISE EXCEPTION 'Unknown tag accepted'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 PERFORM public.bulk_redirect_organization(ARRAY[key],'restore');
 IF EXISTS(SELECT FROM public.redirect_link_metadata WHERE redirect_key=key AND is_archived) THEN RAISE EXCEPTION 'Restore failed'; END IF;
END $$;
SET LOCAL request.jwt.claims = '{"role":"authenticated","user_role":"user"}';
DO $$ BEGIN
 BEGIN PERFORM public.bulk_redirect_organization(ARRAY['static:fixture'],'archive'); RAISE EXCEPTION 'Member modified archive'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$ DECLARE link_id uuid; token uuid; result jsonb; BEGIN
 INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','api-archive-fixture','/events') RETURNING id INTO link_id;
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,redirect_ids,created_by,expires_at) VALUES('archive',repeat('f',64),'fixture',ARRAY['links:read','links:write'],ARRAY[link_id],gen_random_uuid(),now()+interval '1 day') RETURNING id INTO token;
 result:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',link_id,'data',jsonb_build_object('isArchived',true))),token);
 IF NOT(result->0->'link'->>'isArchived')::boolean THEN RAISE EXCEPTION 'Archive API response missing'; END IF;
 result:=public.redirect_management_list('{"isArchived":false}',p_token_id=>token);
 IF (result->>'count')::integer<>0 THEN RAISE EXCEPTION 'Active filter ignored archive'; END IF;
 result:=public.redirect_management_list('{"isArchived":true}',p_token_id=>token);
 IF (result->>'count')::integer<>1 THEN RAISE EXCEPTION 'Archived filter lost row'; END IF;
 IF NOT EXISTS(SELECT FROM public.redirects WHERE id=link_id AND is_enabled) THEN RAISE EXCEPTION 'API archive disabled routing'; END IF;
END $$;
ROLLBACK;
