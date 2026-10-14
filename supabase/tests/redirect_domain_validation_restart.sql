BEGIN;
SET LOCAL ROLE service_role;
DO $$
<<fixture>>
DECLARE actor uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();id uuid;provider uuid:=gen_random_uuid();d jsonb;claim jsonb;version uuid;zone text:=repeat('a',32);target text:='links.queer.guide';
BEGIN
 INSERT INTO auth.users(id) VALUES(actor),(outsider);INSERT INTO public.user_roles VALUES(actor,'admin');
 d:=public.redirect_domain_resource('create',actor,p_values=>'{"hostname":"restart.example.com"}');id:=(d->>'id')::uuid;
 UPDATE public.redirect_domains SET ownership_state='verified',verified_until=now()+interval '1 day',provider_id=provider::text WHERE public.redirect_domains.id=fixture.id;
 INSERT INTO public.redirect_domain_jobs(domain_id,zone_id,cname_target,requested_by,state,provider_status,ssl_status,checked_at) VALUES(id,zone,target,actor,'ready','active','active',now());
 BEGIN PERFORM public.request_redirect_domain_validation_restart(outsider,id,(d->>'version')::uuid,zone,target);RAISE EXCEPTION 'Outsider restarted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.request_redirect_domain_validation_restart(actor,id,gen_random_uuid(),zone,target);RAISE EXCEPTION 'Stale version restarted';EXCEPTION WHEN unique_violation THEN NULL;END;
 BEGIN PERFORM public.request_redirect_domain_validation_restart(actor,id,(d->>'version')::uuid,repeat('b',32),target);RAISE EXCEPTION 'Other zone restarted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 d:=public.request_redirect_domain_validation_restart(actor,id,(d->>'version')::uuid,zone,target);
 IF NOT(d#>>'{provider,validationRestartPending}')::boolean OR (d#>>'{provider,certificateReady}')::boolean OR (d#>>'{provider,canRestartValidation}')::boolean THEN RAISE EXCEPTION 'Pending restart did not invalidate readiness or eligibility';END IF;
 BEGIN PERFORM public.request_redirect_domain_validation_restart(actor,id,(d->>'version')::uuid,zone,target);RAISE EXCEPTION 'Duplicate restart accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 claim:=public.claim_redirect_domain_jobs(1)->0;
 IF claim->>'kind'<>'refresh' THEN RAISE EXCEPTION 'Restart created another provider';END IF;
 IF public.begin_redirect_domain_validation_restart(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,NULL,zone,target) OR public.begin_redirect_domain_validation_restart(id,gen_random_uuid(),(claim->>'operation')::uuid,provider,zone,target) OR public.begin_redirect_domain_validation_restart(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,gen_random_uuid(),zone,target) THEN RAISE EXCEPTION 'Stale lease or mismatched binding authorized PATCH';END IF;
 UPDATE public.redirect_domains SET verified_until=now()-interval '1 second' WHERE public.redirect_domains.id=fixture.id;
 IF public.begin_redirect_domain_validation_restart(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,provider,zone,target) THEN RAISE EXCEPTION 'Expired proof authorized PATCH';END IF;
 UPDATE public.redirect_domains SET verified_until=now()+interval '1 day' WHERE public.redirect_domains.id=fixture.id;
 DELETE FROM public.user_roles WHERE user_id=actor;
 IF public.begin_redirect_domain_validation_restart(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,provider,zone,target) THEN RAISE EXCEPTION 'Revoked owner authorized PATCH';END IF;
 INSERT INTO public.user_roles VALUES(actor,'admin');
 IF NOT public.begin_redirect_domain_validation_restart(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,provider,zone,target) OR public.begin_redirect_domain_validation_restart(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,provider,zone,target) THEN RAISE EXCEPTION 'Restart reservation not single-use';END IF;
 IF (public.redirect_domain_json(id)#>>'{provider,validationRestartPending}')::boolean OR public.redirect_domain_json(id)#>>'{provider,validationRestartStartedAt}' IS NULL THEN RAISE EXCEPTION 'Restart attempt not recorded';END IF;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','status','id',provider,'hostname','restart.example.com','hostnameStatus','active','sslStatus','pending_validation','validation','[]'::jsonb));
 BEGIN PERFORM public.request_redirect_domain_validation_restart(actor,id,(d->>'version')::uuid,zone,target);RAISE EXCEPTION 'Cooldown ignored';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 UPDATE public.redirect_domain_jobs SET validation_restart_requested_at=now()-interval '6 minutes' WHERE domain_id=id;
 d:=public.request_redirect_domain_validation_restart(actor,id,(d->>'version')::uuid,zone,target);
 claim:=public.claim_redirect_domain_jobs(1)->0;
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'disconnect',zone,target);
 IF public.begin_redirect_domain_validation_restart(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,provider,zone,target) THEN RAISE EXCEPTION 'Disconnect did not cancel restart';END IF;
 IF has_function_privilege('authenticated','public.request_redirect_domain_validation_restart(uuid,uuid,uuid,text,text)','execute') OR has_function_privilege('anon','public.begin_redirect_domain_validation_restart(uuid,uuid,uuid,uuid,text,text)','execute') THEN RAISE EXCEPTION 'Restart RPC public';END IF;
END $$;
ROLLBACK;
