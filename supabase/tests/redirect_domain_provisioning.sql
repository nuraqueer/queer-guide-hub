BEGIN;
SET LOCAL ROLE service_role;
DO $$
<<fixture>>
DECLARE actor uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();d jsonb;r jsonb;claim jsonb;nonce uuid;provider uuid:=gen_random_uuid();other_provider uuid:=gen_random_uuid();zone text:=repeat('a',32);target text:='links.queer.guide';id uuid;version uuid;old_lease uuid;old_operation uuid;
BEGIN
 INSERT INTO auth.users(id) VALUES(actor),(outsider);INSERT INTO public.user_roles VALUES(actor,'admin');
 d:=public.redirect_domain_resource('create',actor,p_values=>'{"hostname":"provider.example.com"}');id:=(d->>'id')::uuid;
 BEGIN PERFORM public.redirect_domain_provider_action(outsider,id,(d->>'version')::uuid,'connect',zone,target);RAISE EXCEPTION 'Non-owner enqueued provider work';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'connect',zone,target);RAISE EXCEPTION 'Unverified domain connected';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 UPDATE public.redirect_domains SET ownership_state='verified',verified_at=now(),verified_until=now()+interval '1 day' WHERE public.redirect_domains.id=fixture.id;
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'connect',zone,target);
 claim:=public.claim_redirect_domain_jobs(1)->0;
 IF claim->>'kind'<>'preflight' THEN RAISE EXCEPTION 'First claim skipped provider preflight';END IF;
 nonce:=public.begin_redirect_domain_create(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid);
 IF nonce IS NULL OR public.begin_redirect_domain_create(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid) IS NOT NULL THEN RAISE EXCEPTION 'Provider creation intent not single-use';END IF;
 IF NOT public.record_redirect_domain_provider(id,nonce,provider) THEN RAISE EXCEPTION 'Provider creation receipt lost';END IF;
 IF NOT public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','status','id',provider,'hostname','provider.example.com','hostnameStatus','active','sslStatus','active','validation','[]'::jsonb)) THEN RAISE EXCEPTION 'Provider status not applied';END IF;
 r:=public.redirect_domain_json(id);
 IF NOT (r#>>'{provider,certificateReady}')::boolean THEN RAISE EXCEPTION 'Fresh active certificate not recognized';END IF;
 UPDATE public.redirect_domain_jobs SET checked_at=now()-interval '16 minutes',next_attempt_at=now()-interval '1 second' WHERE domain_id=id;
 IF (public.redirect_domain_json(id)#>>'{provider,certificateReady}')::boolean THEN RAISE EXCEPTION 'Stale certificate status still ready';END IF;
 claim:=public.claim_redirect_domain_jobs(1)->0;
 IF claim->>'kind'<>'refresh' THEN RAISE EXCEPTION 'Known provider object was recreated';END IF;
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'disconnect',zone,target);
 IF public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','status','id',provider,'hostname','provider.example.com','hostnameStatus','active','sslStatus','active','validation','[]'::jsonb)) THEN RAISE EXCEPTION 'Stale status overrode disconnect';END IF;
 claim:=public.claim_redirect_domain_jobs(1)->0;
 IF claim->>'kind'<>'delete' THEN RAISE EXCEPTION 'Provider cleanup not queued';END IF;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','deleted','id',provider));
 IF (public.redirect_domain_json(id)->>'providerConnected')::boolean THEN RAISE EXCEPTION 'Confirmed provider deletion did not clear binding';END IF;
 -- A cancellation racing a successful POST must retain the late receipt and delete it.
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'connect',zone,target);claim:=public.claim_redirect_domain_jobs(1)->0;
 nonce:=public.begin_redirect_domain_create(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid);
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'disconnect',zone,target);
 IF NOT public.record_redirect_domain_provider(id,nonce,other_provider) THEN RAISE EXCEPTION 'Late creation receipt orphaned';END IF;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','status','id',other_provider,'hostname','provider.example.com','hostnameStatus','active','sslStatus','active','validation','[]'::jsonb));
 r:=public.redirect_domain_json(id);IF (r#>>'{provider,certificateReady}')::boolean OR NOT(r->>'providerConnected')::boolean THEN RAISE EXCEPTION 'Late cancelled receipt activated or disappeared';END IF;
 claim:=public.claim_redirect_domain_jobs(1)->0;IF claim->>'kind'<>'delete' THEN RAISE EXCEPTION 'Cancelled creation not compensated';END IF;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','deleted','id',other_provider));
 -- A lost creation response never becomes a second automatic POST.
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'connect',zone,target);claim:=public.claim_redirect_domain_jobs(1)->0;
 nonce:=public.begin_redirect_domain_create(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid);
 UPDATE public.redirect_domain_jobs SET lease_until=now()-interval '1 second' WHERE domain_id=id;
 claim:=public.claim_redirect_domain_jobs(1)->0;
 IF claim->>'kind'<>'reconcile' OR public.begin_redirect_domain_create(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid) IS NOT NULL THEN RAISE EXCEPTION 'Ambiguous creation blindly retried';END IF;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','candidates','candidates',jsonb_build_array(jsonb_build_object('id',provider,'hostname','provider.example.com'))));
 BEGIN PERFORM public.redirect_domain_resource('delete',actor,id,jsonb_build_object('version',d->>'version'));
 -- Reconciliation can attach an exact candidate solely for cleanup after ownership loss.
 d:=public.redirect_domain_resource('create',actor,p_values=>'{"hostname":"cleanup.example.com"}');id:=(d->>'id')::uuid;
 UPDATE public.redirect_domains SET ownership_state='verified',verified_at=now(),verified_until=now()+interval '1 day' WHERE public.redirect_domains.id=fixture.id;
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'connect',zone,target);claim:=public.claim_redirect_domain_jobs(1)->0;
 nonce:=public.begin_redirect_domain_create(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid);
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','candidates','candidates',jsonb_build_array(jsonb_build_object('id',provider,'hostname','cleanup.example.com'))));
 d:=public.redirect_domain_resource('rotate',actor,id,jsonb_build_object('version',d->>'version'));
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'disconnect',zone,target);claim:=public.claim_redirect_domain_jobs(1)->0;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','candidates','candidates',jsonb_build_array(jsonb_build_object('id',provider,'hostname','cleanup.example.com'))));
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'adopt',zone,target,provider);claim:=public.claim_redirect_domain_jobs(1)->0;
 IF NOT public.record_redirect_domain_provider(id,(claim->>'lease')::uuid,provider,'adopted') THEN RAISE EXCEPTION 'Cleanup-only reconciliation required lost ownership proof';END IF;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','status','id',provider,'hostname','cleanup.example.com','hostnameStatus','active','sslStatus','active','validation','[]'::jsonb));
 IF (public.redirect_domain_json(id)#>>'{provider,certificateReady}')::boolean THEN RAISE EXCEPTION 'Cleanup-only adoption activated a lost domain';END IF;
 claim:=public.claim_redirect_domain_jobs(1)->0;
 IF claim->>'kind'<>'delete' THEN RAISE EXCEPTION 'Cleanup-only adoption did not delete';END IF;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','deleted','id',provider));
 PERFORM public.redirect_domain_resource('delete',actor,id,jsonb_build_object('version',d->>'version'));
RAISE EXCEPTION 'Uncertain provider intent orphaned by registry removal';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'adopt',zone,target,provider);claim:=public.claim_redirect_domain_jobs(1)->0;
 IF claim->>'kind'<>'adopt' OR NOT public.record_redirect_domain_provider(id,(claim->>'lease')::uuid,provider,'adopted') THEN RAISE EXCEPTION 'Reviewed provider candidate not adopted';END IF;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','status','id',provider,'hostname','provider.example.com','hostnameStatus','active','sslStatus','pending_validation','validation','[]'::jsonb));
 IF (public.redirect_domain_json(id)#>>'{provider,certificateReady}')::boolean THEN RAISE EXCEPTION 'Hostname activation mistaken for TLS readiness';END IF;
 BEGIN PERFORM public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'refresh',repeat('b',32),target);RAISE EXCEPTION 'Provider zone binding changed silently';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 -- Permission and ownership loss close readiness immediately, independent of job state.
 UPDATE public.redirect_domain_jobs SET provider_status='active',ssl_status='active',checked_at=now() WHERE domain_id=id;
 DELETE FROM public.user_roles WHERE user_id=actor;
 IF (public.redirect_domain_json(id)#>>'{provider,certificateReady}')::boolean THEN RAISE EXCEPTION 'Revoked requester kept readiness';END IF;
 INSERT INTO public.user_roles VALUES(actor,'admin');
 d:=public.redirect_domain_resource('rotate',actor,id,jsonb_build_object('version',d->>'version'));
 IF (public.redirect_domain_json(id)#>>'{provider,certificateReady}')::boolean THEN RAISE EXCEPTION 'Rotated ownership kept readiness';END IF;
 -- Only a fully disconnected binding can move to a new provider configuration.
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'disconnect',zone,target);claim:=public.claim_redirect_domain_jobs(1)->0;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,jsonb_build_object('kind','deleted','id',provider));
 UPDATE public.redirect_domains SET ownership_state='verified',verified_at=now(),verified_until=now()+interval '1 day' WHERE public.redirect_domains.id=fixture.id;
 zone:=repeat('b',32);target:='new.queer.guide';
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'connect',zone,target);claim:=public.claim_redirect_domain_jobs(1)->0;
 IF claim->>'zoneId'<>zone OR claim->>'cnameTarget'<>target THEN RAISE EXCEPTION 'Disconnected configuration did not rebind';END IF;
 nonce:=public.begin_redirect_domain_create(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid);
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,'{"kind":"error","error":"Uncertain fixture response","retry":true}');
 IF jsonb_array_length(public.claim_redirect_domain_jobs(1))<>0 THEN RAISE EXCEPTION 'Review state automatically retried a creation';END IF;
 BEGIN PERFORM public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'confirm_absence',zone,target);RAISE EXCEPTION 'Early/unreconciled absence accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'refresh',zone,target);claim:=public.claim_redirect_domain_jobs(1)->0;
 PERFORM public.finish_redirect_domain_job(id,(claim->>'lease')::uuid,(claim->>'operation')::uuid,'{"kind":"candidates","candidates":[]}');
 UPDATE public.redirect_domain_jobs SET create_started_at=now()-interval '16 minutes' WHERE domain_id=id;
 IF NOT (public.redirect_domain_json(id)#>>'{provider,canConfirmAbsence}')::boolean THEN RAISE EXCEPTION 'Reviewed empty provider lookup did not allow aged absence confirmation';END IF;
 d:=public.redirect_domain_provider_action(actor,id,(d->>'version')::uuid,'confirm_absence',zone,target);
 IF public.record_redirect_domain_provider(id,nonce,provider) OR (d#>>'{provider,desired}')::boolean THEN RAISE EXCEPTION 'Cleared uncertain intent accepted an old receipt or stayed connected';END IF;
 PERFORM public.redirect_domain_resource('delete',actor,id,jsonb_build_object('version',d->>'version'));

END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF has_function_privilege(current_user,'public.claim_redirect_domain_jobs(integer)','execute') OR has_function_privilege(current_user,'public.record_redirect_domain_provider(uuid,uuid,uuid,text)','execute') THEN RAISE EXCEPTION 'Provider job RPC exposed';END IF;
 BEGIN PERFORM * FROM public.redirect_domain_jobs;RAISE EXCEPTION 'Provider leases exposed';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END $$;
ROLLBACK;
