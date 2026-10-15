BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE actor uuid:=gen_random_uuid();a uuid;b uuid;root uuid;other uuid;d jsonb;r jsonb;click uuid;
BEGIN
 INSERT INTO auth.users(id) VALUES(actor);INSERT INTO public.user_roles VALUES(actor,'admin');
 d:=public.redirect_domain_resource('create',actor,p_values=>'{"hostname":"root-a.example.com"}');a:=(d->>'id')::uuid;
 d:=public.redirect_domain_resource('create',actor,p_values=>'{"hostname":"root-b.example.com"}');b:=(d->>'id')::uuid;
 UPDATE public.redirect_domains SET ownership_state='verified',verified_at=now(),verified_until=now()+interval '1 day',provider_id=gen_random_uuid()::text WHERE id IN(a,b);
 INSERT INTO public.redirect_domain_jobs(domain_id,zone_id,cname_target,requested_by,state,provider_status,ssl_status,checked_at)
 SELECT id,repeat('a',32),'links.queer.guide',actor,'ready','active','active',now() FROM public.redirect_domains WHERE id IN(a,b);
 PERFORM public.record_redirect_domain_route('root-a.example.com');PERFORM public.record_redirect_domain_route('root-b.example.com');
 r:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('domainId',a,'isDomainRoot',true,'target','https://example.org/home','comment','Homepage'))),NULL,actor);root:=(r#>>'{0,link,id}')::uuid;
 IF r#>>'{0,link,shortUrl}'<>'https://root-a.example.com/' OR NOT(r#>>'{0,link,isDomainRoot}')::boolean OR r#>>'{0,link,comment}'<>'Homepage' THEN RAISE EXCEPTION 'Root URL/metadata missing';END IF;
 BEGIN PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('slug','second-root','domainId',a,'isDomainRoot',true,'target','https://example.org/other'))),NULL,actor);RAISE EXCEPTION 'Duplicate root allowed';EXCEPTION WHEN unique_violation THEN NULL;END;
 BEGIN PERFORM public.redirect_management_mutate('[{"operation":"create","data":{"isDomainRoot":true,"target":"https://example.org"}}]',NULL,actor);RAISE EXCEPTION 'Builtin root allowed';EXCEPTION WHEN invalid_parameter_value OR check_violation THEN NULL;END;
 r:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','upsert','data',jsonb_build_object('domainId',a,'isDomainRoot',true,'target','https://example.org/changed'))),NULL,actor);
 IF (r#>>'{0,link,id}')::uuid<>root OR (r#>>'{0,created}')::boolean THEN RAISE EXCEPTION 'Root upsert created duplicate';END IF;
 r:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('domainId',b,'isDomainRoot',true,'target','https://example.org/b'))),NULL,actor);other:=(r#>>'{0,link,id}')::uuid;
 IF other=root THEN RAISE EXCEPTION 'Different domains share root identity';END IF;
 click:=public.record_redirect_visit(root,'/internal-slug',NULL,NULL,'Fixture','CH',NULL,302,NULL,'https://example.org','{"domain":"root-a.example.com"}');IF click IS NOT NULL THEN RAISE EXCEPTION 'Slug request counted against root';END IF;
 click:=public.record_redirect_visit(root,'/',NULL,NULL,'Fixture','CH',NULL,302,NULL,'https://example.org','{"domain":"root-a.example.com"}');IF click IS NULL THEN RAISE EXCEPTION 'Root visit not counted';END IF;
 UPDATE public.redirects SET slug='same-storage' WHERE id=root;
 PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('domainId',a,'slug','same-storage','target','https://example.org/normal'))),NULL,actor);
 BEGIN UPDATE public.redirects SET is_domain_root=false WHERE id=root;RAISE EXCEPTION 'Conflicting normal conversion allowed';EXCEPTION WHEN unique_violation THEN NULL;END;
 DELETE FROM public.redirects WHERE domain_id=a AND NOT is_domain_root AND slug='same-storage';
 UPDATE public.redirects SET is_domain_root=false WHERE id=root;
 click:=public.record_redirect_visit(root,'/',NULL,NULL,'Fixture','CH',NULL,302,NULL,'https://example.org','{"domain":"root-a.example.com"}');IF click IS NOT NULL THEN RAISE EXCEPTION 'In-flight root counted after conversion';END IF;
 UPDATE public.redirect_domains SET disabled=true WHERE id=a;
 BEGIN UPDATE public.redirects SET is_domain_root=true WHERE id=root;RAISE EXCEPTION 'Unavailable root conversion allowed';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 -- Omitted root flag preserves an existing root even while repairing an unavailable domain.
 UPDATE public.redirect_domains SET disabled=true WHERE id=b;
 r:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',other,'data','{"notes":"repair"}'::jsonb)),NULL,actor);
 IF NOT(r#>>'{0,link,isDomainRoot}')::boolean THEN RAISE EXCEPTION 'Omitted flag cleared root';END IF;
 d:=public.redirect_manual_record(actor,other,NULL);
 r:=public.redirect_manual_record(actor,other,'{"type":"PATH","source_path":"/previous-home","domain_id":null,"is_domain_root":false}',(d->>'updated_at')::timestamptz);
 IF (r->>'is_domain_root')::boolean OR r->>'domain_id' IS NOT NULL THEN RAISE EXCEPTION 'PATH conversion retained root';END IF;
 UPDATE public.redirect_domains SET disabled=false WHERE id=a;
 d:=public.redirect_manual_record(actor,NULL,jsonb_build_object('type','SHORT','is_domain_root',true,'domain_id',a,'target','https://example.org/manual'));
 IF NOT(d->>'is_domain_root')::boolean OR d->>'slug' IS NULL THEN RAISE EXCEPTION 'Manual root could not allocate internal identity';END IF;
END $$;
ROLLBACK;
