BEGIN;
INSERT INTO auth.users(id) VALUES('00000000-0000-4000-8000-000000000001');
INSERT INTO public.user_roles VALUES('00000000-0000-4000-8000-000000000001','admin');
INSERT INTO public.redirects(type,slug,target,end_at) VALUES('SHORT','presentation-fixture','/events','2030-01-01');
SET LOCAL ROLE service_role;
DO $$
DECLARE link_id uuid; token_id uuid; result jsonb;
BEGIN
 SELECT id INTO link_id FROM public.redirects WHERE slug='presentation-fixture';
 PERFORM public.set_redirect_link_policy(link_id,'{"expires_at":"2030-01-01T00:00:00Z","track_conversions":true}','{"algorithm":"fixture"}',true);
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,redirect_ids,created_by,expires_at) VALUES('presentation',repeat('a',64),'fixture',ARRAY['links:read','links:write'],ARRAY[link_id],'00000000-0000-4000-8000-000000000001',now()+interval '1 day') RETURNING id INTO token_id;
 result:=public.redirect_presentation(link_id,'patch','{"preview":{"title":"Community","description":"Join us","video":"https://example.com/preview.mp4"},"cloaked":true}',token_id);
 IF result->'preview'->>'title'<>'Community' OR NOT(result->>'cloaked')::boolean THEN RAISE EXCEPTION 'Presentation patch lost fields'; END IF;
 IF NOT EXISTS(SELECT FROM public.redirect_link_policies WHERE redirect_id=link_id AND has_password AND (policy->>'track_conversions')::boolean) THEN RAISE EXCEPTION 'Presentation overwrote password or targeting'; END IF;
 IF NOT EXISTS(SELECT FROM public.redirects WHERE id=link_id AND end_at IS NOT NULL) THEN RAISE EXCEPTION 'Presentation cleared expiry'; END IF;
 BEGIN
  UPDATE public.redirects SET target='http://example.com/plain' WHERE id=link_id;
  RAISE EXCEPTION 'HTTP target accepted while framing enabled';
 EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
 result:=public.redirect_presentation(link_id,'get',p_token_id=>token_id);
 IF result?'password_hash' OR result?'target' THEN RAISE EXCEPTION 'Unexpected protected data in presentation'; END IF;
 result:=public.redirect_presentation(link_id,'patch','{"preview":null,"cloaked":false}',token_id);
 IF result->'preview'<>'null'::jsonb OR (result->>'cloaked')::boolean THEN RAISE EXCEPTION 'Presentation removal failed'; END IF;
 UPDATE public.redirect_api_tokens SET scopes=ARRAY['links:read'] WHERE id=token_id;
 BEGIN
  PERFORM public.redirect_presentation(link_id,'check',p_token_id=>token_id);
  RAISE EXCEPTION 'Read scope allowed image upload';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 UPDATE public.redirect_api_tokens SET scopes=ARRAY['links:write'],redirect_ids=ARRAY[gen_random_uuid()] WHERE id=token_id;
 BEGIN
  PERFORM public.redirect_presentation(link_id,'patch','{"cloaked":true}',token_id);
  RAISE EXCEPTION 'Presentation escaped link scope';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF has_function_privilege(current_user,'public.redirect_presentation(uuid,text,jsonb,uuid)','execute') THEN RAISE EXCEPTION 'Presentation RPC exposed'; END IF;
 BEGIN
  INSERT INTO storage.objects(bucket_id,name) VALUES('redirect-previews','direct.svg');
  RAISE EXCEPTION 'Direct image upload allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END $$;
RESET ROLE;
ROLLBACK;
