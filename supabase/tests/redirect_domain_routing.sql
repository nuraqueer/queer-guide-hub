BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE actor uuid:=gen_random_uuid();a uuid;b uuid;first_link uuid;builtin uuid;d jsonb;result jsonb;click uuid;old_provider text;test_host text;
BEGIN
 INSERT INTO auth.users(id) VALUES(actor);INSERT INTO public.user_roles VALUES(actor,'admin');
 d:=public.redirect_domain_resource('create',actor,p_values=>'{"hostname":"route-a.example.com"}');a:=(d->>'id')::uuid;
 d:=public.redirect_domain_resource('create',actor,p_values=>'{"hostname":"route-b.example.com"}');b:=(d->>'id')::uuid;
 FOREACH test_host IN ARRAY ARRAY['route-a.example.com','route-b.example.com'] LOOP
  UPDATE public.redirect_domains SET ownership_state='verified',verified_at=now(),verified_until=now()+interval '1 day',provider_id=gen_random_uuid()::text WHERE redirect_domains.hostname=test_host;
 END LOOP;
 INSERT INTO public.redirect_domain_jobs(domain_id,zone_id,cname_target,requested_by,state,provider_status,ssl_status,checked_at)
 SELECT id,repeat('a',32),'links.queer.guide',actor,'ready','active','active',now() FROM public.redirect_domains WHERE id IN(a,b);
 IF public.redirect_public_domain('route-a.example.com') IS NULL OR public.redirect_public_domain('route-a.example.com',true) IS NOT NULL THEN RAISE EXCEPTION 'TLS and routing proof were conflated';END IF;
 BEGIN PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('slug','namespace-link','target','https://example.com','domainId',a))),NULL,actor);RAISE EXCEPTION 'Unproven route accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 IF NOT public.record_redirect_domain_route('route-a.example.com') OR NOT public.record_redirect_domain_route('route-b.example.com') THEN RAISE EXCEPTION 'Healthy route proof rejected';END IF;
 result:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('slug','namespace-link','target','https://example.com','domainId',a))),NULL,actor);
 first_link:=(result#>>'{0,link,id}')::uuid;
 IF result#>>'{0,link,shortUrl}'<>'https://route-a.example.com/namespace-link' OR result#>>'{0,link,domainHostname}'<>'route-a.example.com' THEN RAISE EXCEPTION 'Canonical branded URL missing';END IF;
 PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('slug','namespace-link','target','https://example.com','domainId',b))),NULL,actor);
 result:=public.redirect_management_mutate('[{"operation":"upsert","data":{"slug":"namespace-link","target":"https://example.com/default"}}]',NULL,actor);builtin:=(result#>>'{0,link,id}')::uuid;
 IF builtin=first_link OR result#>>'{0,link,shortUrl}'<>'https://queer.guide/go/namespace-link' THEN RAISE EXCEPTION 'Default namespace upsert changed branded link';END IF;
 result:=public.redirect_management_list(jsonb_build_object('domainId',a));IF (result->>'count')::integer<>1 THEN RAISE EXCEPTION 'Domain filter leaked other namespace';END IF;
 result:=public.redirect_management_list('{"domainId":null,"search":"namespace-link"}');IF (result->>'count')::integer<>1 THEN RAISE EXCEPTION 'Default domain filter incorrect';END IF;
 BEGIN PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('slug','namespace-link','target','https://example.com','domainId',a))),NULL,actor);RAISE EXCEPTION 'Duplicate within namespace allowed';EXCEPTION WHEN unique_violation THEN NULL;END;
 UPDATE public.redirects SET domain_hostname='spoof.example.com' WHERE id=first_link;
 IF (SELECT domain_hostname FROM public.redirects WHERE id=first_link)<>'route-a.example.com' THEN RAISE EXCEPTION 'Denormalized hostname spoofed';END IF;
 click:=public.record_redirect_visit(first_link,'/namespace-link',NULL,NULL,'Fixture','CH',NULL,302,NULL,'https://example.com','{"domain":"route-b.example.com"}');IF click IS NOT NULL THEN RAISE EXCEPTION 'Wrong-host visit recorded';END IF;
 click:=public.record_redirect_visit(first_link,'/namespace-link',NULL,NULL,'Fixture','CH',NULL,302,NULL,'https://example.com');IF click IS NOT NULL THEN RAISE EXCEPTION 'Legacy service overload bypassed branded checks';END IF;
 PERFORM public.record_redirect_click(first_link,'/namespace-link');
 IF (SELECT click_count FROM public.redirects WHERE id=first_link)<>0 THEN RAISE EXCEPTION 'Old click entry point bypassed branded checks';END IF;
 click:=public.record_redirect_visit(builtin,'/namespace-link',NULL,NULL,'Fixture','CH',NULL,302,NULL,'https://example.com','{"domain":"route-a.example.com"}');IF click IS NOT NULL THEN RAISE EXCEPTION 'In-flight branded request recorded against default binding';END IF;
 click:=public.record_redirect_visit(first_link,'/namespace-link',NULL,NULL,'Fixture','CH',NULL,302,NULL,'https://example.com','{"domain":"route-a.example.com"}');IF click IS NULL THEN RAISE EXCEPTION 'Current branded visit rejected';END IF;
 UPDATE public.redirect_domains SET disabled=true WHERE id=a;
 IF public.redirect_public_domain('route-a.example.com') IS NOT NULL OR public.record_redirect_domain_route('route-a.example.com') THEN RAISE EXCEPTION 'Disabled domain active';END IF;
 click:=public.record_redirect_visit(first_link,'/namespace-link',NULL,NULL,'Fixture','CH',NULL,302,NULL,'https://example.com','{"domain":"route-a.example.com"}');IF click IS NOT NULL THEN RAISE EXCEPTION 'Disabled domain consumed quota';END IF;
 -- Existing links can be repaired while their domain is down; omitted binding persists.
 result:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',first_link,'data',jsonb_build_object('target','https://example.com/repaired'))),NULL,actor);
 IF (result#>>'{0,link,domainId}')::uuid<>a THEN RAISE EXCEPTION 'Repair lost domain binding';END IF;
 BEGIN PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',builtin,'data',jsonb_build_object('domainId',a))),NULL,actor);RAISE EXCEPTION 'Move to unavailable domain accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 UPDATE public.redirect_domains SET disabled=false,provider_id=gen_random_uuid()::text WHERE id=a;
 IF public.redirect_public_domain('route-a.example.com',true) IS NOT NULL THEN RAISE EXCEPTION 'Old provider route proof reused';END IF;
 PERFORM public.record_redirect_domain_route('route-a.example.com');
 UPDATE public.redirect_domains SET routing_seen_at=now()-interval '25 hours' WHERE id=a;
 IF public.redirect_public_domain('route-a.example.com',true) IS NOT NULL THEN RAISE EXCEPTION 'Expired route proof accepted';END IF;
 UPDATE public.redirect_domain_jobs SET checked_at=now()-interval '16 minutes' WHERE domain_id=a;
 IF public.redirect_public_domain('route-a.example.com') IS NOT NULL THEN RAISE EXCEPTION 'Stale TLS accepted';END IF;
 UPDATE public.redirect_domain_jobs SET checked_at=now() WHERE domain_id=a;
 DELETE FROM public.user_roles WHERE user_id=actor;
 IF public.redirect_public_domain('route-a.example.com') IS NOT NULL THEN RAISE EXCEPTION 'Revoked provider requester kept domain active';END IF;
 IF has_function_privilege('authenticated','public.redirect_public_domain(text,boolean)','EXECUTE') OR has_function_privilege('anon','public.record_redirect_domain_route(text)','EXECUTE') THEN RAISE EXCEPTION 'Public domain resolver privilege leaked';END IF;
END $$;
ROLLBACK;
