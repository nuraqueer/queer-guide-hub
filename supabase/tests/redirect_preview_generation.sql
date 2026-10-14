BEGIN;
INSERT INTO auth.users(id) VALUES('00000000-0000-4000-8000-000000000001');
INSERT INTO public.user_roles VALUES('00000000-0000-4000-8000-000000000001','admin');
INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','generation-fixture','https://example.com');
SET LOCAL ROLE service_role;
DO $$ DECLARE link_id uuid; token_id uuid; result jsonb; BEGIN
 SELECT id INTO link_id FROM public.redirects WHERE slug='generation-fixture';
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,redirect_ids,created_by,expires_at) VALUES('generator',repeat('e',64),'fixture',ARRAY['links:write'],ARRAY[link_id],'00000000-0000-4000-8000-000000000001',now()+interval '1 day') RETURNING id INTO token_id;
 FOR i IN 1..5 LOOP
  result:=public.reserve_redirect_preview(link_id,token_id);
  IF result->>'target'<>'https://example.com' OR (result->>'retryAfter')::int<>0 THEN RAISE EXCEPTION 'Premature generation denial'; END IF;
 END LOOP;
 result:=public.reserve_redirect_preview(link_id,token_id);
 IF (result->>'retryAfter')::int<=0 THEN RAISE EXCEPTION 'Generation limit bypass'; END IF;
 UPDATE public.redirect_preview_requests SET window_started_at=now()-interval '2 hours';
 result:=public.reserve_redirect_preview(link_id,token_id);
 IF (result->>'retryAfter')::int<>0 THEN RAISE EXCEPTION 'Window did not reset'; END IF;
 UPDATE public.redirect_preview_requests SET attempts=10,window_started_at=now() WHERE bucket='actor:'||token_id::text;
 result:=public.reserve_redirect_preview(link_id,token_id);
 IF (result->>'retryAfter')::int<=0 THEN RAISE EXCEPTION 'Actor limit bypass'; END IF;
 UPDATE public.redirect_preview_requests SET window_started_at=now()-interval '2 hours';
 UPDATE public.redirect_preview_requests SET attempts=60,window_started_at=now() WHERE bucket='global';
 result:=public.reserve_redirect_preview(link_id,token_id);
 IF (result->>'retryAfter')::int<=0 THEN RAISE EXCEPTION 'Global limit bypass'; END IF;
 UPDATE public.redirect_api_tokens SET scopes=ARRAY['links:read'] WHERE id=token_id;
 BEGIN PERFORM public.reserve_redirect_preview(link_id,token_id); RAISE EXCEPTION 'Read credential generated preview'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 UPDATE public.redirect_api_tokens SET scopes=ARRAY['links:write'],redirect_ids=ARRAY[gen_random_uuid()] WHERE id=token_id;
 BEGIN PERFORM public.reserve_redirect_preview(link_id,token_id); RAISE EXCEPTION 'Scoped credential escaped link'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 UPDATE public.redirect_api_tokens SET redirect_ids=ARRAY[link_id] WHERE id=token_id;
 UPDATE public.redirect_api_tokens SET revoked_at=now() WHERE id=token_id;
 BEGIN PERFORM public.reserve_redirect_preview(link_id,token_id); RAISE EXCEPTION 'Revoked generation key accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF EXISTS(SELECT FROM public.redirect_link_policies WHERE redirect_id=link_id) THEN RAISE EXCEPTION 'Generation persisted presentation'; END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF has_function_privilege(current_user,'public.reserve_redirect_preview(uuid,uuid,uuid)','execute') THEN RAISE EXCEPTION 'Public generation reservation exposed'; END IF;
END $$;
ROLLBACK;
