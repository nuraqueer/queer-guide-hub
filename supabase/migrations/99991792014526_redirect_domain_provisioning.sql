-- Durable provider intent. Ownership, TLS and public routing remain independent.
CREATE TABLE public.redirect_domain_jobs(
 domain_id uuid PRIMARY KEY REFERENCES public.redirect_domains(id) ON DELETE CASCADE,
 zone_id text NOT NULL CHECK(zone_id ~ '^[a-f0-9]{32}$'),cname_target text NOT NULL,
 desired boolean NOT NULL DEFAULT true,requested_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 operation uuid NOT NULL DEFAULT gen_random_uuid(),state text NOT NULL DEFAULT 'queued' CHECK(state IN('queued','leased','waiting','ready','review','failed','disconnected')),
 attempts integer NOT NULL DEFAULT 0,next_attempt_at timestamptz NOT NULL DEFAULT now(),lease uuid,lease_until timestamptz,
 create_nonce uuid,create_started_at timestamptz,adopt_id uuid,
 candidates jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(candidates)='array' AND jsonb_array_length(candidates)<=5),
 provider_status text,ssl_status text,validation jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(validation)='array' AND jsonb_array_length(validation)<=10),
 checked_at timestamptz,reconciled_at timestamptz,last_error text CHECK(length(last_error)<=200),updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.redirect_domain_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_domain_jobs FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_domain_jobs TO service_role;
CREATE INDEX redirect_domain_jobs_due ON public.redirect_domain_jobs(next_attempt_at) WHERE state IN('queued','leased','waiting','ready');
CREATE UNIQUE INDEX redirect_domains_provider_id ON public.redirect_domains(provider_id) WHERE provider_id IS NOT NULL;
CREATE TRIGGER redirect_domain_jobs_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_domain_jobs FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE FUNCTION public.redirect_domain_provider_json(p_id uuid) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('provider',jsonb_build_object('id',d.provider_id,'state',coalesce(j.state,'not_requested'),'desired',coalesce(j.desired,false),'cnameTarget',j.cname_target,
 'hostnameStatus',j.provider_status,'certificateStatus',j.ssl_status,'validationRecords',coalesce(j.validation,'[]'),'candidates',coalesce(j.candidates,'[]'),
 'checkedAt',j.checked_at,'nextAttemptAt',j.next_attempt_at,'error',j.last_error,
 'canConfirmAbsence',coalesce(j.state='review' AND d.provider_id IS NULL AND j.create_started_at<clock_timestamp()-interval '15 minutes' AND j.reconciled_at>clock_timestamp()-interval '5 minutes' AND j.candidates='[]'::jsonb,false),
 'certificateReady',coalesce(d.provider_id IS NOT NULL AND j.desired AND NOT d.disabled AND d.ownership_state='verified' AND d.verified_until>clock_timestamp() AND j.state NOT IN('failed','review','disconnected') AND j.provider_status='active' AND j.ssl_status='active' AND j.checked_at>clock_timestamp()-interval '15 minutes' AND EXISTS(SELECT FROM public.user_roles WHERE user_id=j.requested_by AND role='admin'),false)))
 FROM public.redirect_domains d LEFT JOIN public.redirect_domain_jobs j ON j.domain_id=d.id WHERE d.id=p_id;
$$;
CREATE OR REPLACE FUNCTION public.redirect_domain_json(p_id uuid) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',id,'hostname',hostname,'version',version,'disabled',disabled,'ownershipState',ownership_state,
 'ownershipVerified',ownership_state='verified' AND verified_until>clock_timestamp(),'verifiedAt',verified_at,'verifiedUntil',verified_until,
 'lastCheckedAt',last_checked_at,'lastCheck',last_check,'nextCheckAt',next_check_at,
 'rootUrl',root_url,'notFoundUrl',not_found_url,'expiredUrl',expired_url,'providerConnected',provider_id IS NOT NULL,
 'verification',jsonb_build_object('type','TXT','name','_qg-redirect.'||hostname,'value','qg-redirect='||verification_token))||public.redirect_domain_provider_json(id)
 FROM public.redirect_domains WHERE id=p_id;
$$;
CREATE FUNCTION public.redirect_domain_provider_action(p_actor uuid,p_id uuid,p_version uuid,p_action text,p_zone text,p_target text,p_candidate uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE d public.redirect_domains;j public.redirect_domain_jobs;fresh boolean;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO d FROM public.redirect_domains WHERE id=p_id FOR UPDATE;
 IF d.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF p_version IS DISTINCT FROM d.version THEN RAISE EXCEPTION 'Domain changed; refresh before continuing' USING ERRCODE='23505';END IF;
 IF p_action IS NULL OR p_action NOT IN('connect','refresh','disconnect','adopt','confirm_absence') OR p_zone IS NULL OR p_zone !~ '^[a-f0-9]{32}$' OR p_target IS NULL OR NOT public.redirect_domain_public_host(p_target) OR p_target=d.hostname THEN RAISE EXCEPTION 'Invalid provider setup' USING ERRCODE='22023';END IF;
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE domain_id=d.id FOR UPDATE;
 IF j.domain_id IS NOT NULL AND (j.zone_id<>p_zone OR j.cname_target<>p_target) AND NOT(p_action='connect' AND j.state='disconnected' AND NOT j.desired AND d.provider_id IS NULL AND j.create_started_at IS NULL) THEN RAISE EXCEPTION 'Restore the bound provider configuration before managing this domain' USING ERRCODE='22023';END IF;
 fresh:=NOT d.disabled AND d.ownership_state='verified' AND d.verified_until>clock_timestamp();
 IF p_action='connect' THEN
  IF NOT coalesce(fresh,false) THEN RAISE EXCEPTION 'Verify ownership and enable this domain before connecting' USING ERRCODE='22023';END IF;
  IF j.state='leased' AND NOT j.desired THEN RAISE EXCEPTION 'Wait for provider cleanup before connecting again' USING ERRCODE='22023';END IF;
  IF j.create_started_at IS NOT NULL AND d.provider_id IS NULL THEN RAISE EXCEPTION 'Reconcile the previous creation before connecting again' USING ERRCODE='22023';END IF;
  INSERT INTO public.redirect_domain_jobs(domain_id,zone_id,cname_target,requested_by) VALUES(d.id,p_zone,p_target,p_actor)
  ON CONFLICT(domain_id) DO UPDATE SET zone_id=excluded.zone_id,cname_target=excluded.cname_target,desired=true,requested_by=p_actor,operation=gen_random_uuid(),state=CASE WHEN redirect_domain_jobs.state='leased' THEN 'leased' ELSE 'queued' END,attempts=0,next_attempt_at=clock_timestamp(),last_error=NULL,adopt_id=NULL;
 ELSE
  IF j.domain_id IS NULL THEN RAISE EXCEPTION 'No provider connection requested' USING ERRCODE='22023';END IF;
  IF p_action='adopt' THEN
   IF p_candidate IS NULL OR NOT EXISTS(SELECT FROM jsonb_array_elements(j.candidates) c WHERE c->>'id'=p_candidate::text) THEN RAISE EXCEPTION 'Refresh and review a matching provider candidate first' USING ERRCODE='22023';END IF;
   IF j.desired AND NOT coalesce(fresh,false) THEN RAISE EXCEPTION 'Fresh ownership proof is required to connect a provider candidate' USING ERRCODE='22023';END IF;
  ELSIF p_candidate IS NOT NULL THEN RAISE EXCEPTION 'Unexpected provider candidate' USING ERRCODE='22023';END IF;
  IF p_action='confirm_absence' THEN
   IF j.state<>'review' OR d.provider_id IS NOT NULL OR j.create_started_at IS NULL OR j.create_started_at>clock_timestamp()-interval '15 minutes' OR j.reconciled_at IS NULL OR j.reconciled_at<clock_timestamp()-interval '5 minutes' OR j.candidates<>'[]'::jsonb THEN RAISE EXCEPTION 'Refresh provider candidates and review the uncertain creation before confirming absence' USING ERRCODE='22023';END IF;
   UPDATE public.redirect_domain_jobs SET desired=false,state='disconnected',create_nonce=NULL,create_started_at=NULL,lease=NULL,lease_until=NULL,operation=gen_random_uuid(),adopt_id=NULL,last_error=NULL,updated_at=clock_timestamp() WHERE domain_id=d.id;
  ELSE
   UPDATE public.redirect_domain_jobs SET desired=CASE WHEN p_action='disconnect' THEN false ELSE desired END,requested_by=p_actor,operation=gen_random_uuid(),adopt_id=CASE WHEN p_action='adopt' THEN p_candidate ELSE NULL END,
    state=CASE WHEN state='leased' THEN 'leased' WHEN p_action='disconnect' AND d.provider_id IS NULL AND create_started_at IS NULL THEN 'disconnected' ELSE 'queued' END,
    attempts=0,next_attempt_at=clock_timestamp(),last_error=NULL,updated_at=clock_timestamp() WHERE domain_id=d.id;
  END IF;
 END IF;
 UPDATE public.redirect_domains SET version=gen_random_uuid(),verification_attempt=NULL,updated_at=clock_timestamp() WHERE id=d.id;
 RETURN public.redirect_domain_json(d.id);
END $$;
CREATE FUNCTION public.claim_redirect_domain_jobs(p_limit integer DEFAULT 3) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE j public.redirect_domain_jobs;d public.redirect_domains;result jsonb:='[]';kind text;
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'Invalid provider batch' USING ERRCODE='22023';END IF;
 FOR j IN SELECT * FROM public.redirect_domain_jobs WHERE (state IN('queued','waiting','ready') AND next_attempt_at<=clock_timestamp()) OR (state='leased' AND lease_until<=clock_timestamp()) ORDER BY next_attempt_at,domain_id LIMIT p_limit FOR UPDATE SKIP LOCKED LOOP
  SELECT * INTO d FROM public.redirect_domains WHERE id=j.domain_id FOR UPDATE;
  IF j.attempts>=12 THEN UPDATE public.redirect_domain_jobs SET state='failed',last_error='Provider retry limit reached',lease=NULL,lease_until=NULL WHERE domain_id=j.domain_id;CONTINUE;END IF;
  IF NOT j.desired AND d.provider_id IS NULL AND j.create_started_at IS NULL AND j.adopt_id IS NULL THEN UPDATE public.redirect_domain_jobs SET state='disconnected',lease=NULL,lease_until=NULL WHERE domain_id=j.domain_id;CONTINUE;END IF;
  kind:=CASE WHEN j.adopt_id IS NOT NULL THEN 'adopt' WHEN d.provider_id IS NOT NULL AND NOT j.desired THEN 'delete' WHEN d.provider_id IS NOT NULL THEN 'refresh' WHEN j.create_started_at IS NOT NULL THEN 'reconcile' ELSE 'preflight' END;
  IF kind='preflight' AND (d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() OR NOT EXISTS(SELECT FROM public.user_roles WHERE user_id=j.requested_by AND role='admin')) THEN
   UPDATE public.redirect_domain_jobs SET state='failed',last_error='Current owner permission and fresh ownership proof are required',lease=NULL,lease_until=NULL WHERE domain_id=j.domain_id;CONTINUE;
  END IF;
  UPDATE public.redirect_domain_jobs SET state='leased',attempts=attempts+1,lease=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes',updated_at=clock_timestamp() WHERE domain_id=j.domain_id RETURNING * INTO j;
  result:=result||jsonb_build_array(jsonb_build_object('id',j.domain_id,'operation',j.operation,'lease',j.lease,'kind',kind,'zoneId',j.zone_id,'cnameTarget',j.cname_target,'hostname',d.hostname,'providerId',d.provider_id,'adoptId',j.adopt_id,'desired',j.desired));
 END LOOP;
 RETURN result;
END $$;
CREATE FUNCTION public.begin_redirect_domain_create(p_id uuid,p_lease uuid,p_operation uuid) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE j public.redirect_domain_jobs;d public.redirect_domains;
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE domain_id=p_id FOR UPDATE;SELECT * INTO d FROM public.redirect_domains WHERE id=p_id FOR UPDATE;
 IF j.state<>'leased' OR p_lease IS DISTINCT FROM j.lease OR j.lease_until<=clock_timestamp() OR p_operation IS DISTINCT FROM j.operation OR NOT j.desired OR j.create_started_at IS NOT NULL OR d.provider_id IS NOT NULL OR d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() THEN RETURN NULL;END IF;
 PERFORM 1 FROM public.user_roles WHERE user_id=j.requested_by AND role='admin' FOR SHARE;IF NOT FOUND THEN RETURN NULL;END IF;
 UPDATE public.redirect_domain_jobs SET create_nonce=gen_random_uuid(),create_started_at=clock_timestamp(),updated_at=clock_timestamp() WHERE domain_id=p_id RETURNING create_nonce INTO j.create_nonce;
 RETURN j.create_nonce;
END $$;
CREATE FUNCTION public.record_redirect_domain_provider(p_id uuid,p_nonce uuid,p_provider uuid,p_mode text DEFAULT 'created') RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE j public.redirect_domain_jobs;d public.redirect_domains;
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE domain_id=p_id FOR UPDATE;SELECT * INTO d FROM public.redirect_domains WHERE id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR p_provider IS NULL OR p_nonce IS NULL THEN RETURN false;END IF;
 IF p_mode='created' THEN IF p_nonce IS DISTINCT FROM j.create_nonce THEN RETURN false;END IF;
 ELSIF p_mode='adopted' THEN
  IF p_nonce IS DISTINCT FROM j.lease OR j.lease_until<=clock_timestamp() OR p_provider IS DISTINCT FROM j.adopt_id THEN RETURN false;END IF;
  PERFORM 1 FROM public.user_roles WHERE user_id=j.requested_by AND role='admin' FOR SHARE;IF NOT FOUND THEN RETURN false;END IF;
  IF j.desired AND (d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp()) THEN RETURN false;END IF;
 ELSE RETURN false;END IF;
 IF d.provider_id IS NOT NULL AND d.provider_id<>p_provider::text THEN
  UPDATE public.redirect_domain_jobs SET state='review',last_error='Conflicting provider receipt requires review',candidates=jsonb_build_array(jsonb_build_object('id',p_provider,'hostname',d.hostname)) WHERE domain_id=p_id;RETURN false;
 END IF;
 UPDATE public.redirect_domains SET provider_id=p_provider::text,updated_at=clock_timestamp() WHERE id=p_id;
 UPDATE public.redirect_domain_jobs SET adopt_id=NULL,candidates='[]',state=CASE WHEN state='leased' AND lease_until>clock_timestamp() THEN state ELSE 'queued' END,next_attempt_at=clock_timestamp(),updated_at=clock_timestamp() WHERE domain_id=p_id;
 RETURN true;
END $$;
CREATE FUNCTION public.finish_redirect_domain_job(p_id uuid,p_lease uuid,p_operation uuid,p_result jsonb) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE j public.redirect_domain_jobs;d public.redirect_domains;kind text;delay integer;retry boolean;
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE domain_id=p_id FOR UPDATE;SELECT * INTO d FROM public.redirect_domains WHERE id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR p_result IS NULL OR jsonb_typeof(p_result)<>'object' THEN RETURN false;END IF;
 kind:=p_result->>'kind';
 -- A confirmed delete/404 describes an external fact even if a new action won
 -- the operation race. Never clear a newer/different provider binding.
 IF kind='deleted' AND d.provider_id=p_result->>'id' THEN
  UPDATE public.redirect_domains SET provider_id=NULL,updated_at=clock_timestamp() WHERE id=p_id;
  UPDATE public.redirect_domain_jobs SET create_nonce=NULL,create_started_at=NULL,provider_status=NULL,ssl_status=NULL,checked_at=NULL,validation='[]' WHERE domain_id=p_id;
  j.create_nonce:=NULL;j.create_started_at:=NULL;d.provider_id:=NULL;
 END IF;
 IF j.state<>'leased' OR p_lease IS DISTINCT FROM j.lease THEN RETURN false;END IF;
 IF j.lease_until<=clock_timestamp() OR p_operation IS DISTINCT FROM j.operation THEN
  UPDATE public.redirect_domain_jobs SET state=CASE WHEN NOT desired AND d.provider_id IS NULL AND create_started_at IS NULL THEN 'disconnected' ELSE 'queued' END,lease=NULL,lease_until=NULL,next_attempt_at=clock_timestamp() WHERE domain_id=p_id;RETURN false;
 END IF;
 IF kind='status' THEN
  IF d.provider_id IS NULL OR d.provider_id IS DISTINCT FROM p_result->>'id' OR p_result->>'hostname' IS DISTINCT FROM d.hostname OR coalesce(p_result->>'hostnameStatus','') !~ '^[a-z_]{1,64}$' OR coalesce(p_result->>'sslStatus','') !~ '^[a-z_]{1,64}$' OR jsonb_typeof(p_result->'validation') IS DISTINCT FROM 'array' OR jsonb_array_length(p_result->'validation')>10 THEN RAISE EXCEPTION 'Invalid provider result' USING ERRCODE='22023';END IF;
  UPDATE public.redirect_domain_jobs SET state=CASE WHEN NOT desired THEN 'queued' WHEN p_result->>'hostnameStatus'='active' AND p_result->>'sslStatus'='active' THEN 'ready' ELSE 'waiting' END,
   provider_status=p_result->>'hostnameStatus',ssl_status=p_result->>'sslStatus',validation=p_result->'validation',checked_at=clock_timestamp(),attempts=0,next_attempt_at=clock_timestamp()+CASE WHEN NOT desired THEN interval '0 seconds' ELSE interval '5 minutes' END,last_error=NULL WHERE domain_id=p_id;
 ELSIF kind='candidates' THEN
  IF jsonb_typeof(p_result->'candidates') IS DISTINCT FROM 'array' OR jsonb_array_length(p_result->'candidates')>5 THEN RAISE EXCEPTION 'Invalid provider candidates' USING ERRCODE='22023';END IF;
  UPDATE public.redirect_domain_jobs SET state='review',candidates=p_result->'candidates',reconciled_at=clock_timestamp(),attempts=0,last_error='Review the existing or uncertain provider hostname before continuing' WHERE domain_id=p_id;
 ELSIF kind IN('deleted','cancelled') THEN
  UPDATE public.redirect_domain_jobs SET state=CASE WHEN NOT desired AND d.provider_id IS NULL AND create_started_at IS NULL THEN 'disconnected' ELSE 'queued' END,next_attempt_at=clock_timestamp(),attempts=0,last_error=NULL WHERE domain_id=p_id;
 ELSIF kind='error' THEN
  retry:=coalesce((p_result->>'retry')::boolean,false);delay:=greatest(10,least(3600,coalesce((p_result->>'retryAfter')::integer,30*power(2,least(j.attempts,6))::integer)));
  IF coalesce((p_result->>'definiteRejection')::boolean,false) AND d.provider_id IS NULL THEN UPDATE public.redirect_domain_jobs SET create_nonce=NULL,create_started_at=NULL WHERE domain_id=p_id;j.create_started_at:=NULL;END IF;
  UPDATE public.redirect_domain_jobs SET state=CASE WHEN d.provider_id IS NULL AND j.create_started_at IS NOT NULL THEN 'review' WHEN retry AND attempts<12 THEN 'waiting' ELSE 'failed' END,
   last_error=left(coalesce(p_result->>'error','Provider request failed'),200),next_attempt_at=clock_timestamp()+make_interval(secs=>delay) WHERE domain_id=p_id;
 ELSE RAISE EXCEPTION 'Invalid provider completion' USING ERRCODE='22023';END IF;
 UPDATE public.redirect_domain_jobs SET lease=NULL,lease_until=NULL,updated_at=clock_timestamp() WHERE domain_id=p_id;
 RETURN true;
END $$;
CREATE FUNCTION public.guard_redirect_domain_provider_delete() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
 IF EXISTS(SELECT FROM public.redirect_domain_jobs WHERE domain_id=OLD.id AND (state<>'disconnected' OR desired OR create_started_at IS NOT NULL)) THEN RAISE EXCEPTION 'Disconnect or reconcile provider setup before removing this registration' USING ERRCODE='22023';END IF;
 RETURN OLD;
END $$;
CREATE TRIGGER redirect_domain_provider_delete BEFORE DELETE ON public.redirect_domains FOR EACH ROW EXECUTE FUNCTION public.guard_redirect_domain_provider_delete();
REVOKE ALL ON FUNCTION public.redirect_domain_provider_json(uuid),public.redirect_domain_provider_action(uuid,uuid,uuid,text,text,text,uuid),public.claim_redirect_domain_jobs(integer),public.begin_redirect_domain_create(uuid,uuid,uuid),public.record_redirect_domain_provider(uuid,uuid,uuid,text),public.finish_redirect_domain_job(uuid,uuid,uuid,jsonb),public.guard_redirect_domain_provider_delete() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_domain_provider_json(uuid),public.redirect_domain_provider_action(uuid,uuid,uuid,text,text,text,uuid),public.claim_redirect_domain_jobs(integer),public.begin_redirect_domain_create(uuid,uuid,uuid),public.record_redirect_domain_provider(uuid,uuid,uuid,text),public.finish_redirect_domain_job(uuid,uuid,uuid,jsonb),public.guard_redirect_domain_provider_delete() TO service_role;

-- Uses the established internal invocation mechanism; no HTTP request occurs
-- without both project-local Vault settings. Dedicated provider config is also
-- required by the worker before it claims any work.
DO $migration$
DECLARE command text;
BEGIN
 IF to_regprocedure('cron.schedule(text,text,text)') IS NULL THEN RETURN;END IF;
 command:=$cron$
 SELECT net.http_post(
  url:=rtrim(url.decrypted_secret,'/')||'/functions/v1/redirect-domain-provisioner',
  headers:=jsonb_build_object('Content-Type','application/json','x-internal-secret',secret.decrypted_secret),body:='{}'::jsonb,timeout_milliseconds:=60000)
 FROM vault.decrypted_secrets url CROSS JOIN vault.decrypted_secrets secret
 WHERE url.name='supabase_url' AND secret.name='internal_invoke_secret'
  AND url.decrypted_secret ~ '^https://[a-z0-9-]+\.supabase\.co$' AND length(secret.decrypted_secret)>0 LIMIT 1;
 $cron$;
 EXECUTE 'SELECT cron.schedule($1,$2,$3)' USING 'redirect-domain-provisioner','* * * * *',command;
END $migration$;
