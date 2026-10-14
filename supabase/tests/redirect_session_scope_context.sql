BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE owner_id uuid:=gen_random_uuid(); other_id uuid:=gen_random_uuid(); member_id uuid; link_id uuid; context jsonb;
BEGIN
 INSERT INTO auth.users(id) VALUES(owner_id),(other_id);
 INSERT INTO public.user_roles VALUES(owner_id,'admin');
 INSERT INTO public.redirect_workspace_members(user_id,kind,label) VALUES(other_id,'user','Scoped session') RETURNING id INTO member_id;
 INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','session-context','https://example.org/session') RETURNING id INTO link_id;
 context:=jsonb_build_object('x-qg-redirect-session-actor',owner_id);
 PERFORM set_config('request.headers',context::text,true);
 IF public.redirect_management_scope(NULL,'links:read') IS NOT NULL THEN RAISE EXCEPTION 'Current owner scope changed';END IF;
 DELETE FROM public.user_roles WHERE user_id=owner_id;
 BEGIN PERFORM public.redirect_management_list();RAISE EXCEPTION 'Stale owner session read';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',link_id,'data',jsonb_build_object('comment','denied'))));RAISE EXCEPTION 'Stale owner session wrote';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.headers',jsonb_build_object('x-qg-redirect-session-actor',other_id)::text,true);
 IF NOT(link_id=ANY(public.redirect_management_scope(member_id,'links:read'))) THEN RAISE EXCEPTION 'Matched member session rejected';END IF;
 BEGIN PERFORM public.redirect_management_scope(NULL,'links:read');RAISE EXCEPTION 'Member upgraded to owner';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.headers',context::text,true);
 BEGIN PERFORM public.redirect_management_scope(member_id,'links:read');RAISE EXCEPTION 'Member impersonation accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 PERFORM set_config('request.headers','{}',true);
 IF public.redirect_management_scope(NULL,'links:read') IS NOT NULL THEN RAISE EXCEPTION 'Trusted internal service changed';END IF;
END $$;
ROLLBACK;
