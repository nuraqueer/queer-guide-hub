-- Scope domain/manual records, DNS setup/mail and provider lifecycle to workspace.
-- Service workers retain explicit legacy selection; public verified hostnames are
-- legacy-only until tenant ownership/public resolution is complete. Fences stay.

CREATE OR REPLACE FUNCTION public.redirect_domain_actor(p_actor uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); 
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 PERFORM 1 FROM public.user_roles WHERE user_id=p_actor AND role='admin' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Workspace owner access required' USING ERRCODE='42501';END IF;
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_resource(p_action text, p_actor uuid, p_id uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT '{}'::jsonb, p_limit integer DEFAULT 50, p_after uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); r public.redirect_domains;result jsonb;field text;retry integer;filters jsonb;archive_mode text;search_term text;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF p_action='list' THEN
  filters:=coalesce(p_values,'{}'::jsonb);
  IF jsonb_typeof(filters)<>'object' OR filters-ARRAY['archive','q']::text[]<>'{}' OR filters?'archive' AND(jsonb_typeof(filters->'archive')<>'string' OR coalesce(filters->>'archive','') NOT IN('active','archived','all')) OR filters?'q' AND(jsonb_typeof(filters->'q')<>'string' OR length(filters->>'q')>253 OR filters->>'q' ~ '[[:cntrl:]]') THEN RAISE EXCEPTION 'Invalid domain filters' USING ERRCODE='22023';END IF;
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid domain page' USING ERRCODE='22023';END IF;
  archive_mode:=coalesce(filters->>'archive','active');search_term:=lower(btrim(coalesce(filters->>'q','')));
  WITH matching AS MATERIALIZED(SELECT id FROM public.redirect_domains WHERE workspace_id=selected_workspace AND(archive_mode='all' OR archived=(archive_mode='archived')) AND position(search_term in hostname)>0),
  page AS MATERIALIZED(SELECT id FROM matching WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit+1),shown AS(SELECT id FROM page ORDER BY id LIMIT p_limit)
  SELECT jsonb_build_object('data',coalesce(jsonb_agg(public.redirect_domain_json(id) ORDER BY id),'[]'),'count',(SELECT count(*) FROM matching),'nextCursor',CASE WHEN(SELECT count(*) FROM page)>p_limit THEN max(id::text) ELSE NULL END) INTO result FROM shown;RETURN result;
 END IF;
 IF p_action IS NULL OR p_action NOT IN('get','create','patch','delete','rotate','reserve') THEN RAISE EXCEPTION 'Invalid domain action' USING ERRCODE='22023';END IF;
 IF p_action<>'create' THEN SELECT * INTO r FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;IF r.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;END IF;
 IF p_action='get' THEN RETURN public.redirect_domain_json(r.id);END IF;
 IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' THEN RAISE EXCEPTION 'Invalid domain fields' USING ERRCODE='22023';END IF;
 IF p_action<>'create' AND (p_values->>'version')::uuid IS DISTINCT FROM r.version THEN RAISE EXCEPTION 'Domain changed; reload before continuing' USING ERRCODE='23505';END IF;
 IF p_action IN('delete','rotate','reserve') AND p_values-ARRAY['version']::text[]<>'{}' THEN RAISE EXCEPTION 'Provide only the current domain version' USING ERRCODE='22023';END IF;
 IF p_action='delete' THEN
  IF r.provider_id IS NOT NULL THEN RAISE EXCEPTION 'Disconnect the provider hostname before removing this domain' USING ERRCODE='22023';END IF;
  DELETE FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=r.id;RETURN jsonb_build_object('id',r.id,'deleted',true);
 END IF;
 IF p_action='rotate' THEN
  UPDATE public.redirect_domains SET verification_token=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),ownership_state='pending',verified_at=NULL,verified_until=NULL,verification_attempt=NULL,version=gen_random_uuid(),updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=r.id;
  RETURN public.redirect_domain_json(r.id);
 END IF;
 IF p_action='reserve' THEN
  IF r.disabled THEN RAISE EXCEPTION 'Enable this domain before checking ownership' USING ERRCODE='22023';END IF;
  IF r.next_check_at>clock_timestamp() THEN RETURN jsonb_build_object('retryAfter',greatest(1,ceil(extract(epoch FROM r.next_check_at-clock_timestamp()))::integer));END IF;
  retry:=public.redirect_report_budget('domain-check-global',100,3600);IF retry=0 THEN retry:=public.redirect_report_budget('domain-check:'||p_actor::text,30,3600);END IF;
  IF retry>0 THEN RETURN jsonb_build_object('retryAfter',retry);END IF;
  UPDATE public.redirect_domains SET verification_attempt=gen_random_uuid(),next_check_at=clock_timestamp()+interval '1 minute' WHERE workspace_id=selected_workspace AND id=r.id RETURNING * INTO r;
  RETURN jsonb_build_object('domain',public.redirect_domain_json(r.id),'attempt',r.verification_attempt);
 END IF;
 IF p_values-ARRAY['hostname','version','rootUrl','notFoundUrl','expiredUrl','disabled','archived']::text[]<>'{}' OR (p_action='patch' AND p_values?'hostname') OR(p_action='create' AND p_values?'archived') THEN RAISE EXCEPTION 'Invalid domain fields' USING ERRCODE='22023';END IF;
 IF p_action='create' THEN
  IF p_values?'version' THEN RAISE EXCEPTION 'Do not provide a creation version' USING ERRCODE='22023';END IF;
  INSERT INTO public.redirect_domains(workspace_id,hostname,created_by) VALUES(selected_workspace,p_values->>'hostname',p_actor) RETURNING * INTO r;
 END IF;
 FOREACH field IN ARRAY ARRAY['rootUrl','notFoundUrl','expiredUrl'] LOOP
  IF p_values?field AND (jsonb_typeof(p_values->field) NOT IN('string','null') OR NOT public.redirect_domain_destination(p_values->>field,r.hostname)) THEN RAISE EXCEPTION 'Choose a public HTTP(S) destination outside redirect domains' USING ERRCODE='22023';END IF;
 END LOOP;
 IF p_values?'archived' AND jsonb_typeof(p_values->'archived')<>'boolean' THEN RAISE EXCEPTION 'Invalid archive state' USING ERRCODE='22023';END IF;
 IF p_values?'disabled' AND jsonb_typeof(p_values->'disabled')<>'boolean' THEN RAISE EXCEPTION 'Invalid domain state' USING ERRCODE='22023';END IF;
 UPDATE public.redirect_domains SET root_url=CASE WHEN p_values?'rootUrl' THEN p_values->>'rootUrl' ELSE root_url END,
 not_found_url=CASE WHEN p_values?'notFoundUrl' THEN p_values->>'notFoundUrl' ELSE not_found_url END,
 expired_url=CASE WHEN p_values?'expiredUrl' THEN p_values->>'expiredUrl' ELSE expired_url END,
 archived=CASE WHEN p_values?'archived' THEN (p_values->>'archived')::boolean ELSE archived END,
 disabled=CASE WHEN p_values?'disabled' THEN (p_values->>'disabled')::boolean ELSE disabled END,
 verification_attempt=NULL,version=gen_random_uuid(),updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=r.id;
 RETURN public.redirect_domain_json(r.id);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_json(p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
 SELECT jsonb_build_object('id',id,'hostname',hostname,'version',version,'disabled',disabled,'archived',archived,'ownershipState',ownership_state,
 'ownershipVerified',ownership_state='verified' AND verified_until>clock_timestamp(),'verifiedAt',verified_at,'verifiedUntil',verified_until,
 'lastCheckedAt',last_checked_at,'lastCheck',last_check,'nextCheckAt',next_check_at,
 'rootUrl',root_url,'notFoundUrl',not_found_url,'expiredUrl',expired_url,'providerConnected',provider_id IS NOT NULL,
 'routingReady',public.redirect_public_domain(hostname,true) IS NOT NULL,'routingSeenAt',routing_seen_at,
 'verification',jsonb_build_object('type','TXT','name','_qg-redirect.'||hostname,'value','qg-redirect='||verification_token))||public.redirect_domain_provider_json(id)
 FROM public.redirect_domains WHERE workspace_id=public.redirect_request_workspace() AND id=p_id;
$function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_provider_json(p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
 SELECT jsonb_build_object('provider',jsonb_build_object('id',d.provider_id,'state',coalesce(j.state,'not_requested'),'desired',coalesce(j.desired,false),'cnameTarget',j.cname_target,
 'hostnameStatus',j.provider_status,'certificateStatus',j.ssl_status,'validationRecords',coalesce(j.validation,'[]'),'candidates',coalesce(j.candidates,'[]'),
 'validationRestartRequestedAt',j.validation_restart_requested_at,'validationRestartStartedAt',j.validation_restart_started_at,
 'validationRestartPending',coalesce(j.validation_restart_operation=j.operation,false),
 'canRestartValidation',coalesce(d.provider_id IS NOT NULL AND j.desired AND NOT d.disabled AND d.ownership_state='verified' AND d.verified_until>clock_timestamp() AND j.state NOT IN('review','disconnected') AND j.validation_restart_operation IS DISTINCT FROM j.operation AND (j.validation_restart_requested_at IS NULL OR j.validation_restart_requested_at<=clock_timestamp()-interval '5 minutes'),false),
 'checkedAt',j.checked_at,'nextAttemptAt',j.next_attempt_at,'error',j.last_error,
 'canConfirmAbsence',coalesce(j.state='review' AND d.provider_id IS NULL AND j.create_started_at<clock_timestamp()-interval '15 minutes' AND j.reconciled_at>clock_timestamp()-interval '5 minutes' AND j.candidates='[]'::jsonb,false),
 'certificateReady',coalesce(d.provider_id IS NOT NULL AND j.desired AND NOT d.disabled AND d.ownership_state='verified' AND d.verified_until>clock_timestamp() AND j.state NOT IN('failed','review','disconnected') AND j.provider_status='active' AND j.ssl_status='active' AND j.checked_at>clock_timestamp()-interval '15 minutes' AND EXISTS(SELECT FROM public.user_roles WHERE user_id=j.requested_by AND role='admin'),false)))
 FROM public.redirect_domains d LEFT JOIN public.redirect_domain_jobs j ON j.workspace_id=d.workspace_id AND j.domain_id=d.id WHERE d.workspace_id=public.redirect_request_workspace() AND d.id=p_id;
$function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_choices(p_token_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_after uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); allowed uuid[];wide boolean;primary_id uuid;result jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 allowed:=public.redirect_management_scope(p_token_id,'links:read');
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid domain page' USING ERRCODE='22023';END IF;
 wide:=allowed IS NULL OR public.redirect_can_create_in_folder(p_token_id,NULL);
 IF wide THEN SELECT domain_id INTO primary_id FROM public.redirect_domain_preferences WHERE workspace_id=selected_workspace AND singleton;END IF;
 WITH ready AS MATERIALIZED(
  SELECT d.id,d.hostname FROM public.redirect_domains d
  WHERE d.workspace_id=selected_workspace AND (wide OR EXISTS(SELECT FROM public.redirects r WHERE r.workspace_id=selected_workspace AND r.domain_id=d.id AND r.id=ANY(allowed)))
   AND NOT d.archived AND public.redirect_public_domain(d.hostname,true) IS NOT NULL
 ),page AS MATERIALIZED(SELECT * FROM ready WHERE p_after IS NULL OR id>p_after ORDER BY id LIMIT p_limit+1),
 shown AS MATERIALIZED(SELECT * FROM page ORDER BY id LIMIT p_limit)
 SELECT jsonb_build_object('data',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'hostname',hostname) ORDER BY id) FROM shown),'[]'::jsonb),
 'count',(SELECT count(*) FROM ready),'primaryDomainId',primary_id,'primaryUnavailable',primary_id IS NOT NULL AND NOT EXISTS(SELECT FROM ready WHERE id=primary_id),
 'nextCursor',CASE WHEN(SELECT count(*) FROM page)>p_limit THEN(SELECT max(id::text) FROM shown) ELSE NULL END) INTO result;
 RETURN result;
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_preference(p_actor uuid, p_values jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); pref public.redirect_domain_preferences;host text;
BEGIN
 IF p_values='null'::jsonb THEN p_values:=NULL;END IF;
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO pref FROM public.redirect_domain_preferences WHERE workspace_id=selected_workspace AND singleton FOR UPDATE;
 IF p_values IS NOT NULL THEN
  IF jsonb_typeof(p_values)<>'object' OR p_values-ARRAY['domainId','version']::text[]<>'{}' OR NOT(p_values?'domainId') OR (p_values->>'version')::uuid IS DISTINCT FROM pref.version THEN RAISE EXCEPTION 'Primary domain changed; refresh before saving' USING ERRCODE='23505';END IF;
  IF p_values->>'domainId' IS NOT NULL THEN
   SELECT hostname INTO host FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=(p_values->>'domainId')::uuid AND NOT archived;
   IF host IS NULL OR public.redirect_public_domain(host,true) IS NULL THEN RAISE EXCEPTION 'Choose an active domain with current ownership, TLS and routing proof' USING ERRCODE='22023';END IF;
  END IF;
  UPDATE public.redirect_domain_preferences SET domain_id=(p_values->>'domainId')::uuid WHERE workspace_id=selected_workspace AND singleton RETURNING * INTO pref;
 END IF;
 SELECT hostname INTO host FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=pref.domain_id;
 RETURN jsonb_build_object('domainId',pref.domain_id,'hostname',host,'version',pref.version,'ready',pref.domain_id IS NULL OR(public.redirect_public_domain(host,true) IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=pref.domain_id AND archived)));
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_check_result(p_actor uuid, p_id uuid, p_version uuid, p_attempt uuid, p_outcome text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); r public.redirect_domains;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO r FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF r.disabled OR r.next_check_at IS NULL OR r.next_check_at<=clock_timestamp() OR p_version IS DISTINCT FROM r.version OR p_attempt IS NULL OR p_attempt IS DISTINCT FROM r.verification_attempt THEN RAISE EXCEPTION 'Domain changed; check ownership again' USING ERRCODE='23505';END IF;
 IF p_outcome IS NULL OR p_outcome NOT IN('verified','missing','unavailable') THEN RAISE EXCEPTION 'Invalid DNS result' USING ERRCODE='22023';END IF;
 UPDATE public.redirect_domains SET ownership_state=CASE WHEN p_outcome='verified' THEN 'verified' WHEN p_outcome='missing' AND verified_at IS NOT NULL THEN 'lost' WHEN p_outcome='missing' THEN 'pending' ELSE ownership_state END,
 verified_at=CASE WHEN p_outcome='verified' THEN clock_timestamp() ELSE verified_at END,
 verified_until=CASE WHEN p_outcome='verified' THEN clock_timestamp()+interval '24 hours' WHEN p_outcome='missing' THEN NULL ELSE verified_until END,
 last_checked_at=clock_timestamp(),last_check=p_outcome,verification_attempt=NULL,version=gen_random_uuid(),updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=r.id;
 RETURN public.redirect_domain_json(r.id);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_provider_action(p_actor uuid, p_id uuid, p_version uuid, p_action text, p_zone text, p_target text, p_candidate uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); d public.redirect_domains;j public.redirect_domain_jobs;fresh boolean;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;
 IF d.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF p_version IS DISTINCT FROM d.version THEN RAISE EXCEPTION 'Domain changed; refresh before continuing' USING ERRCODE='23505';END IF;
 IF p_action IS NULL OR p_action NOT IN('connect','refresh','disconnect','adopt','confirm_absence') OR p_zone IS NULL OR p_zone !~ '^[a-f0-9]{32}$' OR p_target IS NULL OR NOT public.redirect_domain_public_host(p_target) OR p_target=d.hostname THEN RAISE EXCEPTION 'Invalid provider setup' USING ERRCODE='22023';END IF;
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE workspace_id=selected_workspace AND domain_id=d.id FOR UPDATE;
 IF j.domain_id IS NOT NULL AND (j.zone_id<>p_zone OR j.cname_target<>p_target) AND NOT(p_action='connect' AND j.state='disconnected' AND NOT j.desired AND d.provider_id IS NULL AND j.create_started_at IS NULL) THEN RAISE EXCEPTION 'Restore the bound provider configuration before managing this domain' USING ERRCODE='22023';END IF;
 fresh:=NOT d.disabled AND d.ownership_state='verified' AND d.verified_until>clock_timestamp();
 IF p_action='connect' THEN
  IF NOT coalesce(fresh,false) THEN RAISE EXCEPTION 'Verify ownership and enable this domain before connecting' USING ERRCODE='22023';END IF;
  IF j.state='leased' AND NOT j.desired THEN RAISE EXCEPTION 'Wait for provider cleanup before connecting again' USING ERRCODE='22023';END IF;
  IF j.create_started_at IS NOT NULL AND d.provider_id IS NULL THEN RAISE EXCEPTION 'Reconcile the previous creation before connecting again' USING ERRCODE='22023';END IF;
  INSERT INTO public.redirect_domain_jobs(workspace_id,domain_id,zone_id,cname_target,requested_by) VALUES(selected_workspace,d.id,p_zone,p_target,p_actor)
  ON CONFLICT(domain_id) DO UPDATE SET zone_id=excluded.zone_id,cname_target=excluded.cname_target,desired=true,requested_by=p_actor,operation=gen_random_uuid(),state=CASE WHEN redirect_domain_jobs.state='leased' THEN 'leased' ELSE 'queued' END,attempts=0,next_attempt_at=clock_timestamp(),last_error=NULL,adopt_id=NULL WHERE redirect_domain_jobs.workspace_id=selected_workspace;
  IF NOT FOUND THEN RAISE EXCEPTION 'Provider setup is unavailable in this workspace' USING ERRCODE='23505';END IF;
 ELSE
  IF j.domain_id IS NULL THEN RAISE EXCEPTION 'No provider connection requested' USING ERRCODE='22023';END IF;
  IF p_action='adopt' THEN
   IF p_candidate IS NULL OR NOT EXISTS(SELECT FROM jsonb_array_elements(j.candidates) c WHERE c->>'id'=p_candidate::text) THEN RAISE EXCEPTION 'Refresh and review a matching provider candidate first' USING ERRCODE='22023';END IF;
   IF j.desired AND NOT coalesce(fresh,false) THEN RAISE EXCEPTION 'Fresh ownership proof is required to connect a provider candidate' USING ERRCODE='22023';END IF;
  ELSIF p_candidate IS NOT NULL THEN RAISE EXCEPTION 'Unexpected provider candidate' USING ERRCODE='22023';END IF;
  IF p_action='confirm_absence' THEN
   IF j.state<>'review' OR d.provider_id IS NOT NULL OR j.create_started_at IS NULL OR j.create_started_at>clock_timestamp()-interval '15 minutes' OR j.reconciled_at IS NULL OR j.reconciled_at<clock_timestamp()-interval '5 minutes' OR j.candidates<>'[]'::jsonb THEN RAISE EXCEPTION 'Refresh provider candidates and review the uncertain creation before confirming absence' USING ERRCODE='22023';END IF;
   UPDATE public.redirect_domain_jobs SET desired=false,state='disconnected',create_nonce=NULL,create_started_at=NULL,lease=NULL,lease_until=NULL,operation=gen_random_uuid(),adopt_id=NULL,last_error=NULL,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND domain_id=d.id;
  ELSE
   UPDATE public.redirect_domain_jobs SET desired=CASE WHEN p_action='disconnect' THEN false ELSE desired END,requested_by=p_actor,operation=gen_random_uuid(),adopt_id=CASE WHEN p_action='adopt' THEN p_candidate ELSE NULL END,
    state=CASE WHEN state='leased' THEN 'leased' WHEN p_action='disconnect' AND d.provider_id IS NULL AND create_started_at IS NULL THEN 'disconnected' ELSE 'queued' END,
    attempts=0,next_attempt_at=clock_timestamp(),last_error=NULL,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND domain_id=d.id;
  END IF;
 END IF;
 UPDATE public.redirect_domains SET version=gen_random_uuid(),verification_attempt=NULL,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=d.id;
 RETURN public.redirect_domain_json(d.id);
END $function$;

CREATE OR REPLACE FUNCTION public.request_redirect_domain_validation_restart(p_actor uuid, p_id uuid, p_version uuid, p_zone text, p_target text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); d public.redirect_domains;j public.redirect_domain_jobs;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;
 IF d.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF p_version IS DISTINCT FROM d.version THEN RAISE EXCEPTION 'Domain changed; refresh before continuing' USING ERRCODE='23505';END IF;
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE workspace_id=selected_workspace AND domain_id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR d.provider_id IS NULL OR NOT j.desired OR d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() OR j.state IN('review','disconnected') THEN RAISE EXCEPTION 'An enabled verified domain with a known requested provider is required' USING ERRCODE='22023';END IF;
 IF j.validation_restart_operation=j.operation OR j.validation_restart_requested_at>clock_timestamp()-interval '5 minutes' THEN RAISE EXCEPTION 'Wait five minutes and refresh provider checks before requesting validation again' USING ERRCODE='22023';END IF;
 PERFORM public.redirect_domain_provider_action(p_actor,p_id,p_version,'refresh',p_zone,p_target);
 UPDATE public.redirect_domain_jobs SET validation_restart_operation=operation,validation_restart_requested_at=clock_timestamp(),validation_restart_started_at=NULL,checked_at=NULL WHERE workspace_id=selected_workspace AND domain_id=p_id;
 RETURN public.redirect_domain_json(p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_connect_current(p_actor uuid, p_operation uuid, p_configuration text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); o public.redirect_domain_connect_operations;d public.redirect_domains;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO o FROM public.redirect_domain_connect_operations WHERE workspace_id=selected_workspace AND id=p_operation AND actor_id=p_actor;
 IF o.id IS NULL THEN RAISE EXCEPTION 'DNS setup not found' USING ERRCODE='P0002';END IF;
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=o.domain_id;
 IF d.id IS NULL OR d.disabled OR d.archived OR d.version IS DISTINCT FROM o.domain_version OR o.expires_at<=clock_timestamp() OR p_configuration IS DISTINCT FROM o.configuration THEN RAISE EXCEPTION 'DNS setup expired or changed; restart setup' USING ERRCODE='23505';END IF;
 RETURN jsonb_build_object('id',o.id,'state',o.state,'expiresAt',o.expires_at,'domain',public.redirect_domain_json(d.id),'discovery',o.discovery,'outcome',o.outcome);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_connect_operation(p_action text, p_actor uuid, p_domain uuid, p_version uuid, p_configuration text, p_operation uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); d public.redirect_domains;o public.redirect_domain_connect_operations;retry integer;latest timestamptz;checked jsonb;result jsonb;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF p_action IS NULL OR p_action NOT IN('reserve','discovered','sign','issued','check','checked') OR p_configuration IS NULL OR p_configuration !~ '^[a-f0-9]{64}$' OR p_values IS NULL OR jsonb_typeof(p_values)<>'object' THEN RAISE EXCEPTION 'Invalid DNS setup operation' USING ERRCODE='22023';END IF;
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_domain FOR UPDATE;
 IF d.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF d.version IS DISTINCT FROM p_version OR d.disabled OR d.archived THEN RAISE EXCEPTION 'Domain changed; restart DNS setup' USING ERRCODE='23505';END IF;
 IF p_action='reserve' THEN
  IF p_operation IS NOT NULL OR p_values<>'{}' THEN RAISE EXCEPTION 'Invalid discovery fields' USING ERRCODE='22023';END IF;
  SELECT max(created_at) INTO latest FROM public.redirect_domain_connect_operations WHERE workspace_id=selected_workspace AND domain_id=d.id;
  IF latest>clock_timestamp()-interval '1 minute' THEN RETURN jsonb_build_object('retryAfter',greatest(1,ceil(extract(epoch FROM latest+interval '1 minute'-clock_timestamp()))::integer));END IF;
  retry:=public.redirect_report_budget('domain-connect-global',100,3600);IF retry=0 THEN retry:=public.redirect_report_budget('domain-connect:'||p_actor::text,30,3600);END IF;
  IF retry>0 THEN RETURN jsonb_build_object('retryAfter',retry);END IF;
  DELETE FROM public.redirect_domain_connect_operations WHERE workspace_id=selected_workspace AND expires_at<clock_timestamp()-interval '1 day';
  INSERT INTO public.redirect_domain_connect_operations(workspace_id,domain_id,actor_id,domain_version,configuration) VALUES(selected_workspace,d.id,p_actor,d.version,p_configuration) RETURNING * INTO o;
 ELSE
  SELECT * INTO o FROM public.redirect_domain_connect_operations WHERE workspace_id=selected_workspace AND id=p_operation AND domain_id=d.id AND actor_id=p_actor FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'DNS setup not found' USING ERRCODE='P0002';END IF;
  IF o.expires_at<=clock_timestamp() OR o.domain_version IS DISTINCT FROM d.version OR o.configuration<>p_configuration THEN RAISE EXCEPTION 'DNS setup expired or changed; restart setup' USING ERRCODE='23505';END IF;
  IF p_action='discovered' THEN
   IF o.state<>'discovering' THEN RAISE EXCEPTION 'DNS discovery already finished' USING ERRCODE='23505';END IF;
   IF p_values->>'status'='available' THEN
    IF p_values-ARRAY['status','provider','hostname','domain','host','apiBase','syncBase','templateVersion']::text[]<>'{}'
     OR NOT(p_values?&ARRAY['status','provider','hostname','domain','host','apiBase','syncBase','templateVersion'])
     OR p_values->>'provider' NOT IN('cloudflare','vercel') OR p_values->>'hostname' IS DISTINCT FROM d.hostname
     OR coalesce(p_values->>'domain','')='' OR coalesce(p_values->>'host','')='' OR p_values->>'host'||'.'||(p_values->>'domain') IS DISTINCT FROM d.hostname
     OR p_values->>'domain' !~ '^([a-z0-9-]+\.)+[a-z0-9-]+$' OR p_values->>'host' !~ '^[a-z0-9-]+(\.[a-z0-9-]+)*$'
     OR jsonb_typeof(p_values->'templateVersion') NOT IN('number','null') OR p_values->'templateVersion' NOT IN('null'::jsonb,'1'::jsonb)
     OR (p_values->>'provider'='cloudflare' AND(p_values->>'apiBase'<>'https://api.cloudflare.com/client/v4/dns/domainconnect' OR p_values->>'syncBase' !~ '^https://dash\.cloudflare\.com(/[A-Za-z0-9_-]+)*$'))
     OR (p_values->>'provider'='vercel' AND(p_values->>'apiBase' !~ '^https://([a-z0-9-]+\.)*vercel\.com(/[A-Za-z0-9_-]+)*$' OR p_values->>'syncBase' !~ '^https://vercel\.com(/[A-Za-z0-9_-]+)*$'))
    THEN RAISE EXCEPTION 'Invalid discovered provider' USING ERRCODE='22023';END IF;
    UPDATE public.redirect_domain_connect_operations SET state='review',discovery=p_values WHERE workspace_id=selected_workspace AND id=o.id RETURNING * INTO o;
   ELSE
    IF p_values-ARRAY['status','reason']::text[]<>'{}' OR coalesce(p_values->>'status','') NOT IN('unsupported','unavailable') OR coalesce(p_values->>'reason','') NOT IN('no_zone','apex_not_supported','dns_provider_not_supported','template_not_supported','provider_unavailable') THEN RAISE EXCEPTION 'Invalid discovery result' USING ERRCODE='22023';END IF;
    UPDATE public.redirect_domain_connect_operations SET state=p_values->>'status',discovery=p_values WHERE workspace_id=selected_workspace AND id=o.id RETURNING * INTO o;
   END IF;
  ELSIF p_action IN('sign','issued','check') THEN
   IF p_values<>'{}' THEN RAISE EXCEPTION 'Unexpected DNS setup fields' USING ERRCODE='22023';END IF;
   IF o.state<>(CASE p_action WHEN 'sign' THEN 'review' WHEN 'issued' THEN 'signing' ELSE 'approved' END) THEN RAISE EXCEPTION 'DNS setup changed; reload before continuing' USING ERRCODE='23505';END IF;
   IF p_action='check' THEN
    checked:=public.redirect_domain_resource('reserve',p_actor,d.id,jsonb_build_object('version',d.version));
    IF checked?'retryAfter' THEN RETURN checked;END IF;
    UPDATE public.redirect_domain_connect_operations SET state='checking',check_attempt=(checked->>'attempt')::uuid WHERE workspace_id=selected_workspace AND id=o.id RETURNING * INTO o;
   ELSE
    UPDATE public.redirect_domain_connect_operations SET state=CASE p_action WHEN 'sign' THEN 'signing' ELSE 'approved' END WHERE workspace_id=selected_workspace AND id=o.id RETURNING * INTO o;
   END IF;
  ELSE
   IF o.state<>'checking' THEN RAISE EXCEPTION 'DNS check not pending' USING ERRCODE='23505';END IF;
   IF p_values-ARRAY['outcome']::text[]<>'{}' OR coalesce(p_values->>'outcome','') NOT IN('verified','missing','unavailable') THEN RAISE EXCEPTION 'Invalid DNS check result' USING ERRCODE='22023';END IF;
   checked:=public.redirect_domain_check_result(p_actor,d.id,d.version,o.check_attempt,p_values->>'outcome');
   UPDATE public.redirect_domain_connect_operations SET state='complete',outcome=p_values->>'outcome',check_attempt=NULL,domain_version=(checked->>'version')::uuid WHERE workspace_id=selected_workspace AND id=o.id RETURNING * INTO o;
  END IF;
 END IF;
 result:=jsonb_build_object('id',o.id,'state',o.state,'expiresAt',o.expires_at,'discovery',o.discovery,'outcome',o.outcome,'domain',public.redirect_domain_json(d.id));
 RETURN result;
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_manual_record(p_actor uuid, p_id uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT NULL::jsonb, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); r public.redirects;creating boolean:=p_id IS NULL;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF NOT creating THEN SELECT * INTO r FROM public.redirects WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;IF r.id IS NULL THEN RAISE EXCEPTION 'Redirect not found' USING ERRCODE='P0002';END IF;END IF;
 IF p_values IS NULL OR p_values='null'::jsonb THEN IF creating THEN RAISE EXCEPTION 'Provide redirect fields' USING ERRCODE='22023';END IF;RETURN to_jsonb(r);END IF;
 IF jsonb_typeof(p_values)<>'object' OR p_values='{}' OR p_values-ARRAY['type','slug','source_path','match_kind','target','status_code','is_enabled','start_at','end_at','query_mode','query_override','utm_defaults','click_limit','notes','domain_id','is_domain_root']::text[]<>'{}' THEN RAISE EXCEPTION 'Invalid redirect fields' USING ERRCODE='22023';END IF;
 IF NOT creating AND (p_expected_updated_at IS NULL OR p_expected_updated_at IS DISTINCT FROM r.updated_at) THEN RAISE EXCEPTION 'Redirect changed; reload before saving' USING ERRCODE='23505';END IF;
 IF creating THEN
  IF p_expected_updated_at IS NOT NULL THEN RAISE EXCEPTION 'Unexpected record version' USING ERRCODE='22023';END IF;
  r:=jsonb_populate_record(NULL::public.redirects,'{"is_domain_root":false,"type":"SHORT","match_kind":"EXACT","status_code":301,"is_enabled":true,"query_mode":"PRESERVE"}'::jsonb);
 END IF;
 r:=jsonb_populate_record(r,p_values);
 IF r.type IS NULL OR r.target IS NULL OR length(r.target) NOT BETWEEN 1 AND 8192 OR r.status_code IS NULL OR r.status_code NOT IN(301,302,307,308) OR r.is_enabled IS NULL OR r.query_mode IS NULL OR r.click_limit<1 OR (creating OR p_values?'notes') AND length(r.notes)>10000 OR (creating OR p_values?'start_at' OR p_values?'end_at') AND r.start_at IS NOT NULL AND r.end_at IS NOT NULL AND r.end_at<=r.start_at THEN RAISE EXCEPTION 'Invalid redirect settings' USING ERRCODE='22023';END IF;
 IF r.type='SHORT' THEN
  IF coalesce(r.is_domain_root,false) AND r.slug IS NULL THEN r.slug:=left(replace(gen_random_uuid()::text,'-',''),12);END IF;
  IF r.slug IS NULL OR r.slug!~'^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$' THEN RAISE EXCEPTION 'A valid short-link slug is required' USING ERRCODE='22023';END IF;
  r.source_path:=NULL;r.match_kind:='EXACT';
 ELSE
  IF p_values->>'domain_id' IS NOT NULL OR r.source_path IS NULL OR r.source_path NOT LIKE '/%' OR r.source_path LIKE '//%' OR r.source_path LIKE '%..%' OR length(r.source_path)>8192 OR r.match_kind IS NULL OR r.match_kind::text NOT IN('EXACT','WILDCARD','REGEX') THEN RAISE EXCEPTION 'Invalid path settings' USING ERRCODE='22023';END IF;
  r.slug:=NULL;r.domain_id:=NULL;r.is_domain_root:=false;
 END IF;
 IF r.domain_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=r.domain_id) THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF creating THEN
  INSERT INTO public.redirects(workspace_id,type,slug,source_path,match_kind,target,status_code,is_enabled,start_at,end_at,preserve_query,query_mode,query_override,utm_defaults,click_limit,notes,domain_id,is_domain_root,created_by)
  VALUES(selected_workspace,r.type,r.slug,r.source_path,r.match_kind,r.target,r.status_code,r.is_enabled,r.start_at,r.end_at,r.query_mode<>'DROP',r.query_mode,r.query_override,r.utm_defaults,r.click_limit,r.notes,r.domain_id,r.is_domain_root,p_actor) RETURNING * INTO r;
 ELSE
  UPDATE public.redirects SET is_domain_root=r.is_domain_root,type=r.type,slug=r.slug,source_path=r.source_path,match_kind=r.match_kind,target=r.target,status_code=r.status_code,is_enabled=r.is_enabled,start_at=r.start_at,end_at=r.end_at,preserve_query=r.query_mode<>'DROP',query_mode=r.query_mode,query_override=r.query_override,utm_defaults=r.utm_defaults,click_limit=r.click_limit,notes=r.notes,domain_id=r.domain_id,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=p_id RETURNING * INTO r;
 END IF;
 IF creating OR p_values?'end_at' THEN
  UPDATE public.redirect_link_policies SET policy=CASE WHEN r.end_at IS NULL THEN policy-'expires_at' ELSE policy||jsonb_build_object('expires_at',r.end_at) END,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND redirect_id=r.id;
 END IF;
 RETURN to_jsonb(r);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_instruction_snapshot(p_domain uuid, p_target text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); d public.redirect_domains;j public.redirect_domain_jobs;records jsonb;record jsonb;result jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_domain;
 IF d.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF p_target IS NULL OR length(p_target)>239 OR p_target !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$' OR p_target ~ '(^|\.)(localhost|local|internal|home|test|invalid|example|onion)$' THEN RAISE EXCEPTION 'DNS target is not configured' USING ERRCODE='22023';END IF;
 records:=jsonb_build_array(jsonb_build_object('type','CNAME','name',d.hostname,'value',p_target||'.'),jsonb_build_object('type','TXT','name','_qg-redirect.'||d.hostname,'value','qg-redirect='||d.verification_token));
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE workspace_id=selected_workspace AND domain_id=d.id;
 IF d.provider_id IS NOT NULL AND j.desired AND j.cname_target=p_target AND j.state NOT IN('failed','review','disconnected') AND EXISTS(SELECT FROM public.user_roles WHERE user_id=j.requested_by AND role='admin') THEN
  IF jsonb_typeof(j.validation)<>'array' OR jsonb_array_length(j.validation)>10 THEN RAISE EXCEPTION 'Refresh provider records before forwarding instructions' USING ERRCODE='22023';END IF;
  FOR record IN SELECT DISTINCT value FROM jsonb_array_elements(j.validation) ORDER BY value LOOP
   IF jsonb_typeof(record)<>'object' OR record-ARRAY['type','name','value']::text[]<>'{}' OR NOT(record?&ARRAY['type','name','value']) OR record->>'type'<>'TXT'
    OR jsonb_typeof(record->'name')<>'string' OR jsonb_typeof(record->'value')<>'string' OR length(record->>'name') NOT BETWEEN 1 AND 253 OR length(record->>'value') NOT BETWEEN 1 AND 1024
    OR record->>'name' !~ '^[a-z0-9_.-]+$' OR (record->>'name'<>d.hostname AND right(record->>'name',length(d.hostname)+1)<>'.'||d.hostname) OR record->>'value' ~ '[[:cntrl:]]'
   THEN RAISE EXCEPTION 'Refresh provider records before forwarding instructions' USING ERRCODE='22023';END IF;
   IF NOT records @> jsonb_build_array(record) THEN records:=records||jsonb_build_array(record);END IF;
  END LOOP;
 END IF;
 result:=jsonb_build_object('hostname',d.hostname,'version',d.version,'records',records);
 RETURN result||jsonb_build_object('snapshot',encode(sha256(convert_to(result::text,'UTF8')),'hex'));
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_instruction_current(p_id uuid, p_target text)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); m public.redirect_domain_instruction_mail;d public.redirect_domains;s jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 SELECT * INTO m FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND id=p_id;
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=m.domain_id;
 IF m.id IS NULL OR d.id IS NULL OR d.disabled OR d.archived OR d.version IS DISTINCT FROM m.domain_version OR p_target IS DISTINCT FROM m.cname_target OR NOT EXISTS(SELECT FROM public.user_roles WHERE user_id=m.actor_id AND role='admin') THEN RETURN false;END IF;
 BEGIN s:=public.redirect_domain_instruction_snapshot(d.id,p_target);EXCEPTION WHEN invalid_parameter_value OR no_data_found THEN RETURN false;END;
 RETURN s->>'snapshot'=m.snapshot;
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_instruction_mail_latest(p_actor uuid, p_domain uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); latest uuid;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM public.redirect_domain_actor(p_actor);
 IF NOT EXISTS(SELECT FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_domain) THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 SELECT id INTO latest FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND domain_id=p_domain AND actor_id=p_actor ORDER BY created_at DESC,id DESC LIMIT 1;
 RETURN public.redirect_domain_instruction_mail_json(latest);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_instruction_mail_action(p_action text, p_actor uuid, p_domain uuid, p_values jsonb DEFAULT '{}'::jsonb, p_job uuid DEFAULT NULL::uuid, p_target text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); d public.redirect_domains;m public.redirect_domain_instruction_mail;s jsonb;latest uuid;retry integer;recent timestamptz;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM public.redirect_domain_actor(p_actor);
 IF p_action IS NULL OR p_action NOT IN('draft','queue','get','cancel','lookup') OR p_values IS NULL OR jsonb_typeof(p_values)<>'object' THEN RAISE EXCEPTION 'Invalid instruction email action' USING ERRCODE='22023';END IF;
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_domain FOR UPDATE;
 IF d.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF p_action='lookup' THEN
  IF p_job IS NOT NULL OR p_values-ARRAY['requestId']::text[]<>'{}' OR jsonb_typeof(p_values->'requestId') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'Choose an instruction email request' USING ERRCODE='22023';END IF;
  SELECT id INTO latest FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND domain_id=d.id AND actor_id=p_actor AND request_id=(p_values->>'requestId')::uuid;
  RETURN public.redirect_domain_instruction_mail_json(latest);
 END IF;
 IF p_action IN('get','cancel') THEN
  IF p_values<>'{}' OR p_job IS NULL THEN RAISE EXCEPTION 'Choose an instruction email' USING ERRCODE='22023';END IF;
  SELECT * INTO m FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND id=p_job AND domain_id=d.id AND actor_id=p_actor FOR UPDATE;
  IF m.id IS NULL THEN RAISE EXCEPTION 'Instruction email not found' USING ERRCODE='P0002';END IF;
  IF p_action='cancel' AND m.state<>'cancelled' THEN
   IF m.state NOT IN('queued','leased') OR m.ambiguous OR m.send_started_at IS NOT NULL THEN RAISE EXCEPTION 'This email may already have been sent and cannot be recalled' USING ERRCODE='23505';END IF;
   UPDATE public.redirect_domain_instruction_mail SET state='cancelled',lease_id=NULL,lease_until=NULL,last_error='Cancelled before sending',updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=m.id;
  END IF;
  RETURN public.redirect_domain_instruction_mail_json(m.id);
 END IF;
 IF p_job IS NOT NULL OR d.disabled OR d.archived THEN RAISE EXCEPTION 'Enable and restore the domain before forwarding instructions' USING ERRCODE='22023';END IF;
 s:=public.redirect_domain_instruction_snapshot(d.id,p_target);
 IF p_action='draft' THEN
  IF p_values<>'{}' THEN RAISE EXCEPTION 'Unexpected instruction draft fields' USING ERRCODE='22023';END IF;
  SELECT id INTO latest FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND domain_id=d.id AND actor_id=p_actor ORDER BY created_at DESC,id DESC LIMIT 1;
  RETURN s||jsonb_build_object('latestMail',public.redirect_domain_instruction_mail_json(latest));
 END IF;
 IF p_values-ARRAY['version','snapshot','email','requestId']::text[]<>'{}' OR NOT(p_values?&ARRAY['version','snapshot','email','requestId'])
  OR jsonb_typeof(p_values->'version')<>'string' OR jsonb_typeof(p_values->'requestId')<>'string' OR jsonb_typeof(p_values->'snapshot')<>'string' OR jsonb_typeof(p_values->'email')<>'string'
  OR p_values->>'snapshot' !~ '^[a-f0-9]{64}$' OR length(p_values->>'email') NOT BETWEEN 3 AND 254 OR p_values->>'email' !~ '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z][a-z0-9-]{0,61}[a-z0-9]$' OR p_values->>'email' ~ '[[:cntrl:]]' OR length(split_part(p_values->>'email','@',1))>64 OR split_part(p_values->>'email','@',1) ~ '(^\.|\.$|\.\.)' OR split_part(p_values->>'email','@',2) !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'
 THEN RAISE EXCEPTION 'Provide a recipient, current draft and request ID' USING ERRCODE='22023';END IF;
 IF (p_values->>'version')::uuid IS DISTINCT FROM d.version OR p_values->>'snapshot'<>s->>'snapshot' THEN RAISE EXCEPTION 'DNS records changed; reload the instructions before sending' USING ERRCODE='23505';END IF;
 SELECT * INTO m FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND actor_id=p_actor AND request_id=(p_values->>'requestId')::uuid FOR UPDATE;
 IF m.id IS NOT NULL THEN
  IF m.domain_id<>d.id OR m.recipient_email<>p_values->>'email' OR m.snapshot<>s->>'snapshot' THEN RAISE EXCEPTION 'Request ID already belongs to different instructions' USING ERRCODE='23505';END IF;
  RETURN public.redirect_domain_instruction_mail_json(m.id);
 END IF;
 SELECT max(created_at) INTO recent FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND domain_id=d.id;
 IF recent>clock_timestamp()-interval '1 minute' THEN RETURN jsonb_build_object('retryAfter',greatest(1,ceil(extract(epoch FROM recent+interval '1 minute'-clock_timestamp()))::integer));END IF;
 retry:=public.redirect_report_budget('domain-mail:'||p_actor::text,10,3600);IF retry=0 THEN retry:=public.redirect_report_budget('domain-mail-global',100,3600);END IF;
 IF retry>0 THEN RETURN jsonb_build_object('retryAfter',retry);END IF;
 INSERT INTO public.redirect_domain_instruction_mail(workspace_id,domain_id,actor_id,request_id,domain_version,snapshot,hostname,cname_target,records,recipient_email)
 VALUES(selected_workspace,d.id,p_actor,(p_values->>'requestId')::uuid,d.version,s->>'snapshot',d.hostname,p_target,s->'records',p_values->>'email') RETURNING * INTO m;
 RETURN public.redirect_domain_instruction_mail_json(m.id);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_instruction_mail_json(p_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
 SELECT jsonb_build_object('id',id,'requestId',request_id,'domainId',domain_id,'domainVersion',domain_version,'email',recipient_email,'state',state,'createdAt',created_at,'updatedAt',updated_at,'nextAttemptAt',CASE WHEN state='queued' THEN next_attempt_at END,'sentAt',sent_at,'error',last_error,
 'canCancel',state IN('queued','leased') AND NOT ambiguous AND send_started_at IS NULL)
 FROM public.redirect_domain_instruction_mail WHERE workspace_id=public.redirect_request_workspace() AND id=p_id;
$function$;

CREATE OR REPLACE FUNCTION public.prepare_redirect_domain_instruction_mail(p_id uuid, p_lease uuid, p_target text, p_fingerprint text, p_payload jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); m public.redirect_domain_instruction_mail;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO m FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND id=p_id AND state='leased' AND lease_id=p_lease FOR UPDATE;
 IF m.id IS NULL OR m.lease_until<=clock_timestamp() OR m.created_at<=clock_timestamp()-interval '23 hours' OR m.transport_fingerprint IS DISTINCT FROM p_fingerprint THEN RETURN NULL;END IF;
 IF NOT public.redirect_domain_instruction_current(m.id,p_target) THEN
  UPDATE public.redirect_domain_instruction_mail SET state=CASE WHEN ambiguous OR send_started_at IS NOT NULL THEN 'uncertain' ELSE 'cancelled' END,last_error='DNS setup or owner changed before sending',lease_id=NULL,lease_until=NULL,send_started_at=NULL,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=m.id;RETURN NULL;
 END IF;
 IF m.send_started_at IS NOT NULL THEN RETURN NULL;END IF;
 IF m.message_payload IS NULL THEN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR p_payload-ARRAY['from','to','subject','text','html']::text[]<>'{}' OR NOT(p_payload?&ARRAY['from','to','subject','text','html']) OR p_payload->>'from' IS DISTINCT FROM m.from_address OR p_payload->'to' IS DISTINCT FROM jsonb_build_array(m.recipient_email)
   OR jsonb_typeof(p_payload->'subject')<>'string' OR length(p_payload->>'subject') NOT BETWEEN 1 AND 200 OR p_payload->>'subject' ~ '[[:cntrl:]]'
   OR jsonb_typeof(p_payload->'text')<>'string' OR length(p_payload->>'text') NOT BETWEEN 1 AND 40000 OR jsonb_typeof(p_payload->'html')<>'string' OR length(p_payload->>'html') NOT BETWEEN 1 AND 200000
  THEN RAISE EXCEPTION 'Invalid instruction email payload' USING ERRCODE='22023';END IF;
 ELSIF p_payload IS NOT NULL AND p_payload<>m.message_payload THEN RAISE EXCEPTION 'Instruction email payload is immutable' USING ERRCODE='23505';END IF;
 UPDATE public.redirect_domain_instruction_mail SET message_payload=coalesce(message_payload,p_payload),send_started_at=clock_timestamp(),updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=m.id RETURNING * INTO m;
 RETURN m.message_payload;
END $function$;

CREATE OR REPLACE FUNCTION public.claim_redirect_domain_instruction_mail(p_from text, p_target text, p_fingerprint text, p_limit integer DEFAULT 3, p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); m public.redirect_domain_instruction_mail;result jsonb:='[]';had_unknown boolean;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 IF p_from IS NULL OR length(p_from) NOT BETWEEN 3 AND 320 OR p_from ~ '[[:cntrl:]]' OR p_fingerprint IS NULL OR p_fingerprint !~ '^[a-f0-9]{64}$' OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'Invalid instruction mail claim' USING ERRCODE='22023';END IF;
 FOR m IN SELECT * FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND (p_id IS NULL OR id=p_id) AND ((state='queued' AND next_attempt_at<=clock_timestamp()) OR(state='leased' AND lease_until<=clock_timestamp())) ORDER BY next_attempt_at,id LIMIT p_limit FOR UPDATE SKIP LOCKED LOOP
  had_unknown:=m.ambiguous OR m.send_started_at IS NOT NULL;
  IF NOT public.redirect_domain_instruction_current(m.id,p_target) THEN
   UPDATE public.redirect_domain_instruction_mail SET state=CASE WHEN had_unknown THEN 'uncertain' ELSE 'cancelled' END,ambiguous=had_unknown,last_error=CASE WHEN had_unknown THEN 'Setup changed after a possible send; delivery is uncertain' ELSE 'DNS setup or owner changed before sending' END,lease_id=NULL,lease_until=NULL,send_started_at=NULL,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=m.id;CONTINUE;
  END IF;
  IF m.attempts>=8 OR m.created_at<=clock_timestamp()-interval '23 hours' OR had_unknown AND m.transport_fingerprint IS DISTINCT FROM p_fingerprint THEN
   UPDATE public.redirect_domain_instruction_mail SET state=CASE WHEN had_unknown THEN 'uncertain' ELSE 'failed' END,ambiguous=had_unknown,last_error=CASE WHEN had_unknown THEN 'Delivery is uncertain; automatic retry stopped' ELSE 'Email retry limit or window elapsed' END,lease_id=NULL,lease_until=NULL,send_started_at=NULL,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=m.id;CONTINUE;
  END IF;
  UPDATE public.redirect_domain_instruction_mail SET state='leased',attempts=attempts+1,lease_id=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes',send_started_at=NULL,ambiguous=had_unknown,transport_fingerprint=p_fingerprint,from_address=coalesce(from_address,p_from),updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=m.id RETURNING * INTO m;
  result:=result||jsonb_build_array(jsonb_build_object('id',m.id,'leaseId',m.lease_id,'email',m.recipient_email,'from',m.from_address,'hostname',m.hostname,'records',m.records,'payload',m.message_payload));
 END LOOP;
 RETURN result;
END $function$;

CREATE OR REPLACE FUNCTION public.finish_redirect_domain_instruction_mail(p_id uuid, p_lease uuid, p_outcome text, p_provider_id text DEFAULT NULL::text, p_retry_after integer DEFAULT NULL::integer, p_retry boolean DEFAULT true)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); m public.redirect_domain_instruction_mail;unknown boolean;next_state text;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 SELECT * INTO m FROM public.redirect_domain_instruction_mail WHERE workspace_id=selected_workspace AND id=p_id AND state='leased' AND lease_id=p_lease AND send_started_at IS NOT NULL FOR UPDATE;
 IF m.id IS NULL THEN RETURN false;END IF;
 IF p_outcome IS NULL OR p_outcome NOT IN('sent','retry','rejected','unknown') OR p_retry IS NULL OR (p_outcome='sent' AND(p_provider_id IS NULL OR p_provider_id !~ '^[A-Za-z0-9_-]{1,200}$')) OR(p_outcome<>'sent' AND p_provider_id IS NOT NULL) THEN RAISE EXCEPTION 'Invalid instruction mail outcome' USING ERRCODE='22023';END IF;
 unknown:=m.ambiguous OR p_outcome='unknown';
 next_state:=CASE WHEN p_outcome='sent' THEN 'sent' WHEN p_outcome IN('retry','unknown') AND p_retry AND m.attempts<8 AND m.created_at>clock_timestamp()-interval '23 hours' THEN 'queued' WHEN unknown THEN 'uncertain' ELSE 'failed' END;
 UPDATE public.redirect_domain_instruction_mail SET state=next_state,ambiguous=CASE WHEN p_outcome='sent' THEN false ELSE unknown END,provider_id=p_provider_id,sent_at=CASE WHEN p_outcome='sent' THEN clock_timestamp() END,
  next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(least(3600,30*(2^greatest(0,attempts-1))::integer),least(82800,greatest(0,coalesce(p_retry_after,0))))),
  last_error=CASE WHEN p_outcome='sent' THEN NULL WHEN next_state='uncertain' THEN 'Delivery is uncertain; automatic retry stopped' WHEN p_outcome='unknown' THEN 'Email outcome unknown; retrying the same request' WHEN p_outcome='retry' THEN 'Email provider asked us to retry' ELSE 'Email provider rejected the request' END,
  lease_id=NULL,lease_until=NULL,send_started_at=NULL,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=m.id;
 RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.begin_redirect_domain_create(p_id uuid, p_lease uuid, p_operation uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); j public.redirect_domain_jobs;d public.redirect_domains;
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE workspace_id=selected_workspace AND domain_id=p_id FOR UPDATE;SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;
 IF j.state<>'leased' OR p_lease IS DISTINCT FROM j.lease OR j.lease_until<=clock_timestamp() OR p_operation IS DISTINCT FROM j.operation OR NOT j.desired OR j.create_started_at IS NOT NULL OR d.provider_id IS NOT NULL OR d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() THEN RETURN NULL;END IF;
 PERFORM 1 FROM public.user_roles WHERE user_id=j.requested_by AND role='admin' FOR SHARE;IF NOT FOUND THEN RETURN NULL;END IF;
 UPDATE public.redirect_domain_jobs SET create_nonce=gen_random_uuid(),create_started_at=clock_timestamp(),updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND domain_id=p_id RETURNING create_nonce INTO j.create_nonce;
 RETURN j.create_nonce;
END $function$;

CREATE OR REPLACE FUNCTION public.begin_redirect_domain_validation_restart(p_id uuid, p_lease uuid, p_operation uuid, p_provider uuid, p_zone text, p_target text)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); d public.redirect_domains;j public.redirect_domain_jobs;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE workspace_id=selected_workspace AND domain_id=p_id FOR UPDATE;
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR j.state<>'leased' OR p_lease IS DISTINCT FROM j.lease OR j.lease_until<=clock_timestamp() OR p_operation IS DISTINCT FROM j.operation OR j.validation_restart_operation IS DISTINCT FROM j.operation OR p_provider IS NULL OR d.provider_id IS NULL OR p_provider::text IS DISTINCT FROM d.provider_id OR p_zone IS DISTINCT FROM j.zone_id OR p_target IS DISTINCT FROM j.cname_target OR NOT j.desired OR d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() THEN RETURN false;END IF;
 PERFORM 1 FROM public.user_roles WHERE user_id=j.requested_by AND role='admin' FOR SHARE;
 IF NOT FOUND THEN RETURN false;END IF;
 UPDATE public.redirect_domain_jobs SET validation_restart_operation=NULL,validation_restart_started_at=clock_timestamp(),updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND domain_id=p_id;
 RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.record_redirect_domain_provider(p_id uuid, p_nonce uuid, p_provider uuid, p_mode text DEFAULT 'created'::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); j public.redirect_domain_jobs;d public.redirect_domains;
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE workspace_id=selected_workspace AND domain_id=p_id FOR UPDATE;SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR p_provider IS NULL OR p_nonce IS NULL THEN RETURN false;END IF;
 IF p_mode='created' THEN IF p_nonce IS DISTINCT FROM j.create_nonce THEN RETURN false;END IF;
 ELSIF p_mode='adopted' THEN
  IF p_nonce IS DISTINCT FROM j.lease OR j.lease_until<=clock_timestamp() OR p_provider IS DISTINCT FROM j.adopt_id THEN RETURN false;END IF;
  PERFORM 1 FROM public.user_roles WHERE user_id=j.requested_by AND role='admin' FOR SHARE;IF NOT FOUND THEN RETURN false;END IF;
  IF j.desired AND (d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp()) THEN RETURN false;END IF;
 ELSE RETURN false;END IF;
 IF d.provider_id IS NOT NULL AND d.provider_id<>p_provider::text THEN
  UPDATE public.redirect_domain_jobs SET state='review',last_error='Conflicting provider receipt requires review',candidates=jsonb_build_array(jsonb_build_object('id',p_provider,'hostname',d.hostname)) WHERE workspace_id=selected_workspace AND domain_id=p_id;RETURN false;
 END IF;
 UPDATE public.redirect_domains SET provider_id=p_provider::text,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=p_id;
 UPDATE public.redirect_domain_jobs SET adopt_id=NULL,candidates='[]',state=CASE WHEN state='leased' AND lease_until>clock_timestamp() THEN state ELSE 'queued' END,next_attempt_at=clock_timestamp(),updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND domain_id=p_id;
 RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.finish_redirect_domain_job(p_id uuid, p_lease uuid, p_operation uuid, p_result jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); j public.redirect_domain_jobs;d public.redirect_domains;kind text;delay integer;retry boolean;
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE workspace_id=selected_workspace AND domain_id=p_id FOR UPDATE;SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR p_result IS NULL OR jsonb_typeof(p_result)<>'object' THEN RETURN false;END IF;
 kind:=p_result->>'kind';
 -- A confirmed delete/404 describes an external fact even if a new action won
 -- the operation race. Never clear a newer/different provider binding.
 IF kind='deleted' AND d.provider_id=p_result->>'id' THEN
  UPDATE public.redirect_domains SET provider_id=NULL,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND id=p_id;
  UPDATE public.redirect_domain_jobs SET create_nonce=NULL,create_started_at=NULL,provider_status=NULL,ssl_status=NULL,checked_at=NULL,validation='[]' WHERE workspace_id=selected_workspace AND domain_id=p_id;
  j.create_nonce:=NULL;j.create_started_at:=NULL;d.provider_id:=NULL;
 END IF;
 IF j.state<>'leased' OR p_lease IS DISTINCT FROM j.lease THEN RETURN false;END IF;
 IF j.lease_until<=clock_timestamp() OR p_operation IS DISTINCT FROM j.operation THEN
  UPDATE public.redirect_domain_jobs SET state=CASE WHEN NOT desired AND d.provider_id IS NULL AND create_started_at IS NULL THEN 'disconnected' ELSE 'queued' END,lease=NULL,lease_until=NULL,next_attempt_at=clock_timestamp() WHERE workspace_id=selected_workspace AND domain_id=p_id;RETURN false;
 END IF;
 IF kind='status' THEN
  IF d.provider_id IS NULL OR d.provider_id IS DISTINCT FROM p_result->>'id' OR p_result->>'hostname' IS DISTINCT FROM d.hostname OR coalesce(p_result->>'hostnameStatus','') !~ '^[a-z_]{1,64}$' OR coalesce(p_result->>'sslStatus','') !~ '^[a-z_]{1,64}$' OR jsonb_typeof(p_result->'validation') IS DISTINCT FROM 'array' OR jsonb_array_length(p_result->'validation')>10 THEN RAISE EXCEPTION 'Invalid provider result' USING ERRCODE='22023';END IF;
  UPDATE public.redirect_domain_jobs SET state=CASE WHEN NOT desired THEN 'queued' WHEN p_result->>'hostnameStatus'='active' AND p_result->>'sslStatus'='active' THEN 'ready' ELSE 'waiting' END,
   provider_status=p_result->>'hostnameStatus',ssl_status=p_result->>'sslStatus',validation=p_result->'validation',checked_at=clock_timestamp(),attempts=0,next_attempt_at=clock_timestamp()+CASE WHEN NOT desired THEN interval '0 seconds' ELSE interval '5 minutes' END,last_error=NULL WHERE workspace_id=selected_workspace AND domain_id=p_id;
 ELSIF kind='candidates' THEN
  IF jsonb_typeof(p_result->'candidates') IS DISTINCT FROM 'array' OR jsonb_array_length(p_result->'candidates')>5 THEN RAISE EXCEPTION 'Invalid provider candidates' USING ERRCODE='22023';END IF;
  UPDATE public.redirect_domain_jobs SET state='review',candidates=p_result->'candidates',reconciled_at=clock_timestamp(),attempts=0,last_error='Review the existing or uncertain provider hostname before continuing' WHERE workspace_id=selected_workspace AND domain_id=p_id;
 ELSIF kind IN('deleted','cancelled') THEN
  UPDATE public.redirect_domain_jobs SET state=CASE WHEN NOT desired AND d.provider_id IS NULL AND create_started_at IS NULL THEN 'disconnected' ELSE 'queued' END,next_attempt_at=clock_timestamp(),attempts=0,last_error=NULL WHERE workspace_id=selected_workspace AND domain_id=p_id;
 ELSIF kind='error' THEN
  retry:=coalesce((p_result->>'retry')::boolean,false);delay:=greatest(10,least(3600,coalesce((p_result->>'retryAfter')::integer,30*power(2,least(j.attempts,6))::integer)));
  IF coalesce((p_result->>'definiteRejection')::boolean,false) AND d.provider_id IS NULL THEN UPDATE public.redirect_domain_jobs SET create_nonce=NULL,create_started_at=NULL WHERE workspace_id=selected_workspace AND domain_id=p_id;j.create_started_at:=NULL;END IF;
  UPDATE public.redirect_domain_jobs SET state=CASE WHEN d.provider_id IS NULL AND j.create_started_at IS NOT NULL THEN 'review' WHEN retry AND attempts<12 THEN 'waiting' ELSE 'failed' END,
   last_error=left(coalesce(p_result->>'error','Provider request failed'),200),next_attempt_at=clock_timestamp()+make_interval(secs=>delay) WHERE workspace_id=selected_workspace AND domain_id=p_id;
 ELSE RAISE EXCEPTION 'Invalid provider completion' USING ERRCODE='22023';END IF;
 UPDATE public.redirect_domain_jobs SET lease=NULL,lease_until=NULL,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND domain_id=p_id;
 RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.reserve_redirect_domain_renewal(p_id uuid, p_lease uuid, p_operation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); d public.redirect_domains;j public.redirect_domain_jobs;reserved jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE workspace_id=selected_workspace AND domain_id=p_id FOR UPDATE;
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR d.id IS NULL OR j.state<>'leased' OR j.lease IS DISTINCT FROM p_lease OR j.operation IS DISTINCT FROM p_operation OR j.lease_until<=clock_timestamp() OR NOT j.desired OR d.provider_id IS NULL OR d.disabled OR d.verified_at IS NULL OR d.verified_until>clock_timestamp()+interval '6 hours' THEN RETURN NULL;END IF;
 IF NOT EXISTS(SELECT FROM public.user_roles WHERE user_id=j.requested_by AND role='admin') THEN RETURN NULL;END IF;
 reserved:=public.redirect_domain_resource('reserve',j.requested_by,d.id,jsonb_build_object('version',d.version));
 IF reserved?'retryAfter' THEN RETURN NULL;END IF;
 RETURN jsonb_build_object('actor',j.requested_by,'version',d.version,'attempt',reserved->'attempt','verification',reserved#>'{domain,verification}');
END $function$;

CREATE OR REPLACE FUNCTION public.claim_redirect_domain_jobs(p_limit integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(); j public.redirect_domain_jobs;d public.redirect_domains;result jsonb:='[]';kind text;
BEGIN
 PERFORM pg_advisory_xact_lock(471983093);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'Invalid provider batch' USING ERRCODE='22023';END IF;
 FOR j IN SELECT * FROM public.redirect_domain_jobs WHERE workspace_id=selected_workspace AND ((state IN('queued','waiting','ready') AND next_attempt_at<=clock_timestamp()) OR (state='leased' AND lease_until<=clock_timestamp())) ORDER BY next_attempt_at,domain_id LIMIT p_limit FOR UPDATE SKIP LOCKED LOOP
  SELECT * INTO d FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=j.domain_id FOR UPDATE;
  IF j.attempts>=12 THEN UPDATE public.redirect_domain_jobs SET state='failed',last_error='Provider retry limit reached',lease=NULL,lease_until=NULL WHERE workspace_id=selected_workspace AND domain_id=j.domain_id;CONTINUE;END IF;
  IF NOT j.desired AND d.provider_id IS NULL AND j.create_started_at IS NULL AND j.adopt_id IS NULL THEN UPDATE public.redirect_domain_jobs SET state='disconnected',lease=NULL,lease_until=NULL WHERE workspace_id=selected_workspace AND domain_id=j.domain_id;CONTINUE;END IF;
  kind:=CASE WHEN j.adopt_id IS NOT NULL THEN 'adopt' WHEN d.provider_id IS NOT NULL AND NOT j.desired THEN 'delete' WHEN d.provider_id IS NOT NULL THEN 'refresh' WHEN j.create_started_at IS NOT NULL THEN 'reconcile' ELSE 'preflight' END;
  IF kind='preflight' AND (d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() OR NOT EXISTS(SELECT FROM public.user_roles WHERE user_id=j.requested_by AND role='admin')) THEN
   UPDATE public.redirect_domain_jobs SET state='failed',last_error='Current owner permission and fresh ownership proof are required',lease=NULL,lease_until=NULL WHERE workspace_id=selected_workspace AND domain_id=j.domain_id;CONTINUE;
  END IF;
  UPDATE public.redirect_domain_jobs SET state='leased',attempts=attempts+1,lease=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes',updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND domain_id=j.domain_id RETURNING * INTO j;
  result:=result||jsonb_build_array(jsonb_build_object('id',j.domain_id,'operation',j.operation,'lease',j.lease,'kind',kind,'zoneId',j.zone_id,'cnameTarget',j.cname_target,'hostname',d.hostname,'providerId',d.provider_id,'adoptId',j.adopt_id,'desired',j.desired));
 END LOOP;
 RETURN result;
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_public_domain(p_hostname text, p_require_route boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE d public.redirect_domains;j public.redirect_domain_jobs;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT * INTO d FROM public.redirect_domains WHERE workspace_id='58aa4340-8f21-4b7f-9a10-90be2da89c01'::uuid AND hostname=p_hostname FOR SHARE;
 IF d.id IS NULL OR d.disabled OR d.provider_id IS NULL OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() THEN RETURN NULL;END IF;
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE workspace_id=d.workspace_id AND domain_id=d.id FOR SHARE;
 IF j.domain_id IS NULL OR NOT j.desired OR j.state IN('failed','review','disconnected') OR j.provider_status IS DISTINCT FROM 'active' OR j.ssl_status IS DISTINCT FROM 'active' OR j.checked_at IS NULL OR j.checked_at<=clock_timestamp()-interval '15 minutes' THEN RETURN NULL;END IF;
 PERFORM 1 FROM public.user_roles WHERE user_id=j.requested_by AND role='admin' FOR SHARE;
 IF NOT FOUND THEN RETURN NULL;END IF;
 IF p_require_route AND (d.routing_protocol IS DISTINCT FROM 1 OR d.routing_provider_id IS DISTINCT FROM d.provider_id OR d.routing_seen_at IS NULL OR d.routing_seen_at<=clock_timestamp()-interval '24 hours') THEN RETURN NULL;END IF;
 RETURN jsonb_build_object('id',d.id,'hostname',d.hostname,'rootUrl',d.root_url,'notFoundUrl',d.not_found_url,'expiredUrl',d.expired_url,'needsRouteRefresh',d.routing_protocol IS DISTINCT FROM 1 OR d.routing_provider_id IS DISTINCT FROM d.provider_id OR d.routing_seen_at IS NULL OR d.routing_seen_at<clock_timestamp()-interval '6 hours');
END $function$;

CREATE OR REPLACE FUNCTION public.record_redirect_domain_route(p_hostname text)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE context jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 -- Acquire exclusive ACL lock first: the registry update also takes this lock.
 PERFORM pg_advisory_xact_lock(471983093);
 context:=public.redirect_public_domain(p_hostname);
 IF context IS NULL THEN RETURN false;END IF;
 UPDATE public.redirect_domains SET routing_seen_at=clock_timestamp(),routing_provider_id=provider_id,routing_protocol=1 WHERE workspace_id='58aa4340-8f21-4b7f-9a10-90be2da89c01'::uuid AND id=(context->>'id')::uuid;
 RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_link_domain_binding()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE host text;
BEGIN
 IF TG_OP='UPDATE' AND NEW.domain_id IS NOT DISTINCT FROM OLD.domain_id THEN
  NEW.domain_hostname:=OLD.domain_hostname;RETURN NEW;
 END IF;
 IF NEW.domain_id IS NULL THEN NEW.domain_hostname:=NULL;RETURN NEW;END IF;
 SELECT hostname INTO host FROM public.redirect_domains WHERE workspace_id=NEW.workspace_id AND id=NEW.domain_id;
 IF host IS NULL OR public.redirect_public_domain(host,true) IS NULL THEN RAISE EXCEPTION 'Choose a domain with current ownership, TLS and routing proof' USING ERRCODE='22023';END IF;
 NEW.domain_hostname:=host;RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_root_binding_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
 IF NEW.is_domain_root AND (TG_OP='INSERT' OR NOT OLD.is_domain_root) THEN
  IF NEW.domain_id IS NULL OR public.redirect_public_domain((SELECT hostname FROM public.redirect_domains WHERE workspace_id=NEW.workspace_id AND id=NEW.domain_id),true) IS NULL THEN RAISE EXCEPTION 'Choose a ready custom domain for its root link' USING ERRCODE='22023';END IF;
 END IF;
 RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_domain_archive_primary()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
 IF NEW.archived AND NOT OLD.archived THEN UPDATE public.redirect_domain_preferences SET domain_id=NULL WHERE workspace_id=NEW.workspace_id AND singleton AND domain_id=NEW.id;END IF;
 RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.guard_redirect_domain_provider_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
 IF EXISTS(SELECT FROM public.redirect_domain_jobs WHERE workspace_id=OLD.workspace_id AND domain_id=OLD.id AND (state<>'disconnected' OR desired OR create_started_at IS NOT NULL)) THEN RAISE EXCEPTION 'Disconnect or reconcile provider setup before removing this registration' USING ERRCODE='22023';END IF;
 RETURN OLD;
END $function$;
