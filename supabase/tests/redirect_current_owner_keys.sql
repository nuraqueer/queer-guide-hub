BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE owner_id uuid:=gen_random_uuid(); key_id uuid; link_id uuid; outsider uuid:=gen_random_uuid(); result jsonb;
BEGIN
 INSERT INTO auth.users(id) VALUES(owner_id),(outsider);
 INSERT INTO public.user_roles VALUES(owner_id,'admin');
 INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','current-owner-fixture','https://example.com/private') RETURNING id INTO link_id;
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,redirect_ids,created_by,expires_at)
 VALUES('Current owner',repeat('9',64),'fixture',ARRAY['links:read','links:write'],ARRAY[link_id],owner_id,now()+interval '1 day') RETURNING id INTO key_id;
 IF public.authenticate_redirect_api_token(repeat('9',64),'links:read')->>'id' IS DISTINCT FROM key_id::text THEN RAISE EXCEPTION 'Current owner key rejected';END IF;
 IF public.redirect_management_scope(key_id,'links:read') IS DISTINCT FROM ARRAY[link_id] THEN RAISE EXCEPTION 'Selected IDs changed';END IF;
 DELETE FROM public.user_roles WHERE user_id=owner_id;
 IF public.authenticate_redirect_api_token(repeat('9',64),'links:read') IS NOT NULL THEN RAISE EXCEPTION 'Lost owner authenticated';END IF;
 BEGIN
  PERFORM public.redirect_management_list(p_token_id=>key_id);
  RAISE EXCEPTION 'Already authenticated key read after owner loss';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 BEGIN
  PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',link_id,'data',jsonb_build_object('comment','denied'))),key_id);
  RAISE EXCEPTION 'Lost owner wrote';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 INSERT INTO public.user_roles VALUES(owner_id,'admin');
 IF public.authenticate_redirect_api_token(repeat('9',64),'links:write')->>'id' IS DISTINCT FROM key_id::text THEN RAISE EXCEPTION 'Restored owner key rejected';END IF;
 UPDATE public.redirect_api_tokens SET created_by=outsider WHERE id=key_id;
 BEGIN
  PERFORM public.redirect_management_scope(key_id,'links:write');
  RAISE EXCEPTION 'Non-owner credential accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 IF EXISTS(SELECT FROM pg_policies WHERE schemaname='public' AND tablename='redirects' AND policyname='redirects_public_read') THEN RAISE EXCEPTION 'Legacy public destination policy survived ordered migrations';END IF;
 IF has_function_privilege('anon','public.resolve_short_redirect(text)','execute') OR has_function_privilege('authenticated','public.resolve_short_redirect(text)','execute') THEN RAISE EXCEPTION 'Raw public resolver exposed';END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims='{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000099","user_role":"user"}';
DO $$ BEGIN
 IF EXISTS(SELECT FROM public.redirects WHERE slug='current-owner-fixture') THEN RAISE EXCEPTION 'Ordinary account read destination';END IF;
 IF has_function_privilege(current_user,'public.redirect_management_scope(uuid,text)','execute') THEN RAISE EXCEPTION 'Scope helper exposed';END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
 BEGIN
  IF EXISTS(SELECT FROM public.redirects WHERE slug='current-owner-fixture') THEN RAISE EXCEPTION 'Anonymous destination exposed';END IF;
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END $$;
ROLLBACK;
