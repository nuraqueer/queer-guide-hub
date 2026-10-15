BEGIN;
INSERT INTO auth.users(id) VALUES('00000000-0000-4000-8000-000000000011');
INSERT INTO public.user_roles VALUES('00000000-0000-4000-8000-000000000011','admin');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims='{"role":"authenticated","user_role":"admin","sub":"00000000-0000-4000-8000-000000000011"}';
DO $$ BEGIN
 IF NOT public.redirect_current_owner() THEN RAISE EXCEPTION 'Current owner rejected';END IF;
 PERFORM public.create_redirect_campaign_link('rls-current-owner','https://example.org/private');
 PERFORM public.set_redirect_link_metadata('static:/fixture',NULL,ARRAY[]::uuid[],'Owner comment');
END $$;
RESET ROLE;
DELETE FROM public.user_roles WHERE user_id='00000000-0000-4000-8000-000000000011';
SET LOCAL ROLE authenticated;
-- Keep the cached admin claim: current database role must be authoritative.
DO $$ BEGIN
 IF public.redirect_current_owner() THEN RAISE EXCEPTION 'Cached admin accepted';END IF;
 IF EXISTS(SELECT FROM public.redirects) OR EXISTS(SELECT FROM public.redirect_link_metadata) THEN RAISE EXCEPTION 'Lost owner read private rows';END IF;
 BEGIN PERFORM public.create_redirect_campaign_link('rls-stale-owner','/events');RAISE EXCEPTION 'Lost owner created';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.set_redirect_link_metadata('static:/fixture',NULL,ARRAY[]::uuid[],'denied');RAISE EXCEPTION 'Lost owner changed automatic metadata';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN INSERT INTO public.redirect_link_folders(name) VALUES('Denied folder');RAISE EXCEPTION 'Lost owner direct write';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 IF EXISTS(SELECT FROM pg_policies WHERE schemaname='public' AND tablename IN('redirects','redirect_events','redirect_api_tokens','redirect_link_customers','redirect_link_conversions','redirect_link_folders','redirect_link_tags','redirect_utm_templates','redirect_link_metadata','redirect_link_tag_assignments','redirect_link_policies') AND (qual LIKE '%has_role_jwt(%' OR with_check LIKE '%has_role_jwt(%')) THEN RAISE EXCEPTION 'Private cached-role policy survived';END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$ BEGIN
 PERFORM set_config('request.headers','{"x-qg-redirect-session-actor":"00000000-0000-4000-8000-000000000011"}',true);
 BEGIN PERFORM public.set_redirect_link_policy((SELECT id FROM public.redirects WHERE slug='rls-current-owner'),'{}',NULL,false);RAISE EXCEPTION 'Lost legacy owner saved policy';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN IF has_function_privilege(current_user,'public.redirect_current_owner()','execute') THEN RAISE EXCEPTION 'Anonymous owner helper exposed';END IF;END $$;
RESET ROLE;
INSERT INTO public.user_roles VALUES('00000000-0000-4000-8000-000000000011','admin');
SET LOCAL TRANSACTION READ ONLY;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF NOT public.redirect_current_owner() OR NOT EXISTS(SELECT FROM public.redirects WHERE slug='rls-current-owner') THEN RAISE EXCEPTION 'Read-only owner Data API semantics broke';END IF;
END $$;
ROLLBACK;
