BEGIN;
INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','conversion-a','https://example.com/a'),('SHORT','conversion-b','https://example.com/b');
SET LOCAL ROLE service_role;
SET LOCAL request.jwt.claims='{"role":"service_role"}';
DO $$
DECLARE a uuid;b uuid;ca uuid;cb uuid;t uuid;result jsonb;page jsonb;cursor jsonb;
BEGIN
 SELECT id INTO a FROM public.redirects WHERE slug='conversion-a'; SELECT id INTO b FROM public.redirects WHERE slug='conversion-b';
 ca:=public.record_redirect_visit(a,'/go/conversion-a',NULL,NULL,'fixture','CH','fixture',302,'a','https://example.com/a');
 cb:=public.record_redirect_visit(b,'/go/conversion-b',NULL,NULL,'fixture','CH','fixture',302,'b','https://example.com/b');
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,redirect_ids,created_by,expires_at)
 VALUES('fixture',repeat('a',64),'fixture',ARRAY['conversions:write'],ARRAY[a],'00000000-0000-4000-8000-000000000001',now()+interval '1 day') RETURNING id INTO t;
 IF public.authenticate_redirect_api_token(repeat('a',64),'events:read') IS NOT NULL THEN RAISE EXCEPTION 'Scope bypass'; END IF;
 IF public.authenticate_redirect_api_token(repeat('b',64),'conversions:write') IS NOT NULL THEN RAISE EXCEPTION 'Unknown key accepted'; END IF;
 IF public.authenticate_redirect_api_token(repeat('a',64),'conversions:write')->>'id' IS DISTINCT FROM t::text THEN RAISE EXCEPTION 'Credential rejected'; END IF;
 result:=public.record_redirect_conversion(jsonb_build_object('kind','lead','clickId',ca,'customerExternalId','customer-a','eventId','signup:a','eventName','Sign up'),t);
 IF (result->>'duplicate')::boolean THEN RAISE EXCEPTION 'First event marked duplicate'; END IF;
 result:=public.record_redirect_conversion(jsonb_build_object('kind','lead','clickId',ca,'customerExternalId','customer-a','eventId','signup:a','eventName','Sign up'),t);
 IF NOT (result->>'duplicate')::boolean THEN RAISE EXCEPTION 'Retry counted twice'; END IF;
 BEGIN
  PERFORM public.record_redirect_conversion(jsonb_build_object('kind','lead','clickId',ca,'customerExternalId','different-customer','eventId','signup:a','eventName','Sign up'),t);
  RAISE EXCEPTION 'Conflicting idempotency accepted';
 EXCEPTION WHEN unique_violation THEN NULL; END;
 result:=public.record_redirect_conversion('{"kind":"sale","customerExternalId":"customer-a","eventId":"billing:a","eventName":"Purchase","amount":49.9,"currency":"CHF"}',t);
 IF result->>'clickId' IS DISTINCT FROM ca::text THEN RAISE EXCEPTION 'Customer sale lost lead attribution'; END IF;
 IF NOT EXISTS(SELECT FROM public.redirect_conversion_report WHERE amount='49.900000' AND currency='CHF') THEN RAISE EXCEPTION 'Revenue report lost decimal text'; END IF;
 IF (SELECT count(*) FROM public.redirect_link_conversions WHERE customer_key='customer-a')<>2 THEN RAISE EXCEPTION 'Wrong conversion count'; END IF;
 BEGIN
  PERFORM public.record_redirect_conversion(jsonb_build_object('kind','sale','clickId',cb,'customerExternalId','customer-b','eventId','billing:outside','eventName','Purchase','amount',20,'currency','CHF'),t);
  RAISE EXCEPTION 'Link scope bypass';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF EXISTS(SELECT FROM public.redirect_link_customers WHERE customer_key='customer-b') THEN RAISE EXCEPTION 'Denied write left an orphan customer'; END IF;
 PERFORM public.record_redirect_conversion(jsonb_build_object('kind','sale','clickId',cb,'customerExternalId','customer-a','eventId','billing:other-link','eventName','Purchase','amount',10,'currency','EUR'));
 IF (SELECT click_id FROM public.redirect_link_customers WHERE customer_key='customer-a')<>ca THEN RAISE EXCEPTION 'Customer anchor overwritten'; END IF;
 page:=public.redirect_customer_journey('customer-a',NULL,NULL,2);
 IF jsonb_array_length(page->'data')<>2 OR page->'nextCursor'='null'::jsonb THEN RAISE EXCEPTION 'Journey pagination missing'; END IF;
 cursor:=page->'nextCursor';
 page:=public.redirect_customer_journey('customer-a',(cursor->>'at')::timestamptz,cursor->>'id',100);
 IF jsonb_array_length(page->'data')<>3 OR page->'nextCursor'<>'null'::jsonb THEN RAISE EXCEPTION 'Journey skips or duplicates events'; END IF;
 UPDATE public.redirects SET slug='conversion-a-renamed' WHERE id=a;
 IF NOT EXISTS(SELECT FROM jsonb_array_elements(public.redirect_customer_journey('customer-a')->'data') item WHERE item->>'kind'='click' AND item->>'source'='/go/conversion-a') THEN RAISE EXCEPTION 'Historical source changed on slug edit'; END IF;
 PERFORM public.record_redirect_conversion(jsonb_build_object('kind','sale','clickId',ca,'customerExternalId','large-amount','eventId','billing:exact','eventName','Purchase','amount','999999999999.999999','currency','CHF'),t);
 IF NOT EXISTS(SELECT FROM public.redirect_conversion_report WHERE customer_key='large-amount' AND amount='999999999999.999999') THEN RAISE EXCEPTION 'Exact large decimal lost'; END IF;
 UPDATE public.redirect_api_tokens SET revoked_at=now() WHERE id=t;
 IF public.authenticate_redirect_api_token(repeat('a',64),'conversions:write') IS NOT NULL THEN RAISE EXCEPTION 'Revoked key authenticated'; END IF;
 BEGIN
  PERFORM public.record_redirect_conversion('{"kind":"sale","customerExternalId":"customer-a","eventId":"billing:revoked","eventName":"Purchase","amount":1,"currency":"CHF"}',t);
  RAISE EXCEPTION 'In-flight revoked credential wrote';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 UPDATE public.redirect_api_tokens SET revoked_at=NULL,expires_at=now()-interval '1 second',created_at=now()-interval '1 day' WHERE id=t;
 IF public.authenticate_redirect_api_token(repeat('a',64),'conversions:write') IS NOT NULL THEN RAISE EXCEPTION 'Expired credential authenticated'; END IF;
 BEGIN
  PERFORM public.record_redirect_conversion(jsonb_build_object('kind','lead','clickId',ca,'customerExternalId','native-old','eventId','native:old','eventName','Sign up'),NULL,now()-interval '1 day');
  RAISE EXCEPTION 'Existing account attributed to later click';
 EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 PERFORM public.record_redirect_conversion(jsonb_build_object('kind','lead','clickId',ca,'customerExternalId','native-new','eventId','native:new','eventName','Sign up'),NULL,now());
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims='{"role":"authenticated","user_role":"admin"}';
DO $$ BEGIN
 IF NOT EXISTS(SELECT id,name FROM public.redirect_api_tokens) THEN RAISE EXCEPTION 'Admin metadata unavailable'; END IF;
 BEGIN PERFORM token_hash FROM public.redirect_api_tokens; RAISE EXCEPTION 'Token hash disclosed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SET LOCAL request.jwt.claims='{"role":"authenticated","user_role":"user"}';
DO $$ BEGIN
 IF EXISTS(SELECT id FROM public.redirect_api_tokens) OR EXISTS(SELECT FROM public.redirect_link_customers) OR EXISTS(SELECT FROM public.redirect_link_conversions) THEN RAISE EXCEPTION 'Private tracking data disclosed'; END IF;
 IF EXISTS(SELECT FROM public.redirect_conversion_report) THEN RAISE EXCEPTION 'Revenue view bypasses RLS'; END IF;
 IF jsonb_array_length(public.redirect_customer_journey('customer-a')->'data')<>0 THEN RAISE EXCEPTION 'Customer journey bypasses RLS'; END IF;
 IF has_function_privilege(current_user,'public.record_redirect_conversion(jsonb,uuid,timestamptz)','execute') THEN RAISE EXCEPTION 'Member can forge a conversion'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
