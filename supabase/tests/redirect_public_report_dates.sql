BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE actor uuid:=gen_random_uuid();one uuid;other uuid;click uuid;r jsonb;s jsonb;checked jsonb;result jsonb;bad jsonb;
BEGIN
 INSERT INTO auth.users(id) VALUES(actor);INSERT INTO public.user_roles VALUES(actor,'admin');
 INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','dated-report','https://example.com/private') RETURNING id INTO one;
 INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','other-dated-report','https://example.com/other') RETURNING id INTO other;
 click:=public.record_redirect_visit(one,'/go/dated-report',NULL,NULL,'fixture','CH',NULL,302,NULL,NULL,'{}');
 UPDATE public.redirect_events SET ts='2026-01-05T00:00:00Z' WHERE click_id=click;
 click:=public.record_redirect_visit(one,'/go/dated-report',NULL,NULL,'fixture','CH',NULL,302,NULL,NULL,'{}');
 UPDATE public.redirect_events SET ts='2026-01-15T00:00:00Z' WHERE click_id=click;
 click:=public.record_redirect_visit(one,'/go/dated-report',NULL,NULL,'fixture','CH',NULL,302,NULL,NULL,'{}');
 UPDATE public.redirect_events SET ts='2026-01-16T00:00:00Z' WHERE click_id=click;
 click:=public.record_redirect_visit(one,'/go/dated-report',NULL,NULL,'fixture','US',NULL,302,NULL,NULL,'{}');
 UPDATE public.redirect_events SET ts='2026-01-15T00:00:00Z' WHERE click_id=click;
 click:=public.record_redirect_visit(other,'/go/other-dated-report',NULL,NULL,'fixture','CH',NULL,302,NULL,NULL,'{}');
 UPDATE public.redirect_events SET ts='2026-01-15T00:00:00Z' WHERE click_id=click;
 r:=public.redirect_saved_report_resource('create',actor,NULL,p_values=>jsonb_build_object('name','January','filters',jsonb_build_object('linkIds',jsonb_build_array(one),'country','CH','start','2026-01-01T00:00:00Z','end','2026-02-01T00:00:00Z')));
 s:=public.redirect_report_share_resource('create',actor,NULL,(r->>'id')::uuid,p_values=>jsonb_build_object('title','January clicks','reportVersion',r->>'version'));
 checked:=public.redirect_public_report_check((s->>'id')::uuid,repeat('a',64));
 result:=public.redirect_public_report_read((s->>'id')::uuid,(checked->>'version')::uuid,false);
 IF (result#>>'{report,totals,clicks}')::int<>3 OR (result#>>'{dateRange,earliest}')::timestamptz<>'2026-01-01T00:00:00Z'::timestamptz THEN RAISE EXCEPTION 'Default dates or private scope changed';END IF;
 result:=public.redirect_public_report_read((s->>'id')::uuid,(checked->>'version')::uuid,false,'{"start":"2026-01-15T00:00:00Z","end":"2026-01-16T00:00:00Z"}');
 IF (result#>>'{report,totals,clicks}')::int<>1 OR (result#>>'{dateRange,start}')::timestamptz<>'2026-01-15T00:00:00Z'::timestamptz THEN RAISE EXCEPTION 'Date narrowing lost scope or half-open boundaries';END IF;
 result:=public.redirect_public_report_read((s->>'id')::uuid,(checked->>'version')::uuid,false,'{"start":"2026-01-17T00:00:00Z"}');
 IF (result#>>'{report,totals,clicks}')::int<>0 THEN RAISE EXCEPTION 'Empty time range leaked events';END IF;
 FOREACH bad IN ARRAY ARRAY['{"start":"2025-12-31T00:00:00Z"}'::jsonb,'{"end":"2026-02-02T00:00:00Z"}','{"start":"2026-01-20T00:00:00Z","end":"2026-01-20T00:00:00Z"}','{"country":"US"}','{"linkIds":[]}','{"start":null}','{"start":"not a date"}','null','[]'] LOOP
  BEGIN PERFORM public.redirect_public_report_read((s->>'id')::uuid,(checked->>'version')::uuid,false,bad);RAISE EXCEPTION 'Invalid/widened dates accepted: %',bad;EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 END LOOP;
 -- Public reads cannot edit the frozen filters or reset them to a wider period.
 result:=public.redirect_public_report_read((s->>'id')::uuid,(checked->>'version')::uuid,false,'{}');
 IF (result#>>'{report,totals,clicks}')::int<>3 THEN RAISE EXCEPTION 'Public read mutated saved selection';END IF;
 DELETE FROM public.user_roles WHERE user_id=actor;
 BEGIN PERFORM public.redirect_public_report_read((s->>'id')::uuid,(checked->>'version')::uuid,false,'{"start":"2026-01-15T00:00:00Z"}');RAISE EXCEPTION 'Date read bypassed live access';EXCEPTION WHEN no_data_found THEN NULL;END;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF has_function_privilege(current_user,'public.redirect_public_report_read(uuid,uuid,boolean,jsonb)','execute') THEN RAISE EXCEPTION 'Date RPC exposed through Data API';END IF;
END $$;
ROLLBACK;
