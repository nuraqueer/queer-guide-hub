BEGIN;
INSERT INTO public.redirects(type,slug,target,click_limit) VALUES('SHORT','policy-fixture','https://example.com/protected',1);
SET LOCAL ROLE service_role;
SET LOCAL request.jwt.claims='{"role":"service_role"}';
DO $$
DECLARE link_id uuid; visit_id uuid; result jsonb;
BEGIN
 SELECT id INTO link_id FROM public.redirects WHERE slug='policy-fixture';
 SELECT public.set_redirect_link_policy(link_id,'{"geo_targets":{"CH":"https://example.com/swiss"}}','{"algorithm":"fixture"}',true) INTO result;
 IF NOT (result->>'has_password')::boolean THEN RAISE EXCEPTION 'Protection not enabled'; END IF;
 IF result ? 'password_hash' THEN RAISE EXCEPTION 'Password hash disclosed by writer'; END IF;
 SELECT public.record_redirect_visit(link_id,'/go/policy-fixture',NULL,NULL,'fixture','CH','fixture',302,'a','https://example.com/a') INTO visit_id;
 IF visit_id IS NULL THEN RAISE EXCEPTION 'Valid visit was not recorded'; END IF;
 IF public.record_redirect_visit(link_id,'/go/policy-fixture',NULL,NULL,'fixture','CH','fixture',302,'a','https://example.com/a') IS NOT NULL THEN RAISE EXCEPTION 'Limit bypassed'; END IF;
 IF (SELECT click_count FROM public.redirects WHERE id=link_id)<>1 THEN RAISE EXCEPTION 'Count exceeds quota'; END IF;
 INSERT INTO public.redirect_link_conversions(click_id,kind,customer_key) VALUES(visit_id,'lead','fixture');
 INSERT INTO public.redirect_link_conversions(click_id,kind,amount,currency,customer_key) VALUES(visit_id,'sale',42.50,'CHF','fixture');
 IF NOT EXISTS(SELECT FROM public.redirect_variant_performance(link_id) WHERE id='a' AND clicks=1 AND leads=1 AND sales=1) THEN RAISE EXCEPTION 'Variant aggregation inflated or lost counts'; END IF;
 UPDATE public.redirects SET click_limit=NULL,end_at=now()-interval '1 second' WHERE id=link_id;
 IF public.record_redirect_visit(link_id,'/go/policy-fixture',NULL,NULL,'fixture','CH','fixture',302,NULL,'https://example.com') IS NOT NULL THEN RAISE EXCEPTION 'Expired visit counted'; END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims='{"role":"authenticated","user_role":"user"}';
DO $$
BEGIN
 IF EXISTS(SELECT FROM public.redirects WHERE slug='policy-fixture') THEN RAISE EXCEPTION 'Destination visible to ordinary member'; END IF;
 IF EXISTS(SELECT FROM public.redirect_link_policies) THEN RAISE EXCEPTION 'Protection settings exposed'; END IF;
 IF has_function_privilege(current_user,'public.resolve_short_redirect(text)','execute') THEN RAISE EXCEPTION 'Old resolver bypass remains'; END IF;
 IF has_function_privilege(current_user,'public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text)','execute') THEN RAISE EXCEPTION 'Visitor can forge visits'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
