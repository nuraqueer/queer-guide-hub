-- Explicit validation restart intent; status refreshes never imply a provider PATCH.
ALTER TABLE public.redirect_domain_jobs ADD COLUMN validation_restart_operation uuid,
 ADD COLUMN validation_restart_requested_at timestamptz,
 ADD COLUMN validation_restart_started_at timestamptz;
CREATE OR REPLACE FUNCTION public.redirect_domain_provider_json(p_id uuid) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('provider',jsonb_build_object('id',d.provider_id,'state',coalesce(j.state,'not_requested'),'desired',coalesce(j.desired,false),'cnameTarget',j.cname_target,
 'hostnameStatus',j.provider_status,'certificateStatus',j.ssl_status,'validationRecords',coalesce(j.validation,'[]'),'candidates',coalesce(j.candidates,'[]'),
 'validationRestartRequestedAt',j.validation_restart_requested_at,'validationRestartStartedAt',j.validation_restart_started_at,
 'validationRestartPending',coalesce(j.validation_restart_operation=j.operation,false),
 'canRestartValidation',coalesce(d.provider_id IS NOT NULL AND j.desired AND NOT d.disabled AND d.ownership_state='verified' AND d.verified_until>clock_timestamp() AND j.state NOT IN('review','disconnected') AND j.validation_restart_operation IS DISTINCT FROM j.operation AND (j.validation_restart_requested_at IS NULL OR j.validation_restart_requested_at<=clock_timestamp()-interval '5 minutes'),false),
 'checkedAt',j.checked_at,'nextAttemptAt',j.next_attempt_at,'error',j.last_error,
 'canConfirmAbsence',coalesce(j.state='review' AND d.provider_id IS NULL AND j.create_started_at<clock_timestamp()-interval '15 minutes' AND j.reconciled_at>clock_timestamp()-interval '5 minutes' AND j.candidates='[]'::jsonb,false),
 'certificateReady',coalesce(d.provider_id IS NOT NULL AND j.desired AND NOT d.disabled AND d.ownership_state='verified' AND d.verified_until>clock_timestamp() AND j.state NOT IN('failed','review','disconnected') AND j.provider_status='active' AND j.ssl_status='active' AND j.checked_at>clock_timestamp()-interval '15 minutes' AND EXISTS(SELECT FROM public.user_roles WHERE user_id=j.requested_by AND role='admin'),false)))
 FROM public.redirect_domains d LEFT JOIN public.redirect_domain_jobs j ON j.domain_id=d.id WHERE d.id=p_id;
$$;

CREATE FUNCTION public.request_redirect_domain_validation_restart(p_actor uuid,p_id uuid,p_version uuid,p_zone text,p_target text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE d public.redirect_domains;j public.redirect_domain_jobs;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO d FROM public.redirect_domains WHERE id=p_id FOR UPDATE;
 IF d.id IS NULL THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 IF p_version IS DISTINCT FROM d.version THEN RAISE EXCEPTION 'Domain changed; refresh before continuing' USING ERRCODE='23505';END IF;
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE domain_id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR d.provider_id IS NULL OR NOT j.desired OR d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() OR j.state IN('review','disconnected') THEN RAISE EXCEPTION 'An enabled verified domain with a known requested provider is required' USING ERRCODE='22023';END IF;
 IF j.validation_restart_operation=j.operation OR j.validation_restart_requested_at>clock_timestamp()-interval '5 minutes' THEN RAISE EXCEPTION 'Wait five minutes and refresh provider checks before requesting validation again' USING ERRCODE='22023';END IF;
 PERFORM public.redirect_domain_provider_action(p_actor,p_id,p_version,'refresh',p_zone,p_target);
 UPDATE public.redirect_domain_jobs SET validation_restart_operation=operation,validation_restart_requested_at=clock_timestamp(),validation_restart_started_at=NULL,checked_at=NULL WHERE domain_id=p_id;
 RETURN public.redirect_domain_json(p_id);
END $$;
CREATE FUNCTION public.begin_redirect_domain_validation_restart(p_id uuid,p_lease uuid,p_operation uuid,p_provider uuid,p_zone text,p_target text)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE d public.redirect_domains;j public.redirect_domain_jobs;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO j FROM public.redirect_domain_jobs WHERE domain_id=p_id FOR UPDATE;
 SELECT * INTO d FROM public.redirect_domains WHERE id=p_id FOR UPDATE;
 IF j.domain_id IS NULL OR j.state<>'leased' OR p_lease IS DISTINCT FROM j.lease OR j.lease_until<=clock_timestamp() OR p_operation IS DISTINCT FROM j.operation OR j.validation_restart_operation IS DISTINCT FROM j.operation OR p_provider IS NULL OR d.provider_id IS NULL OR p_provider::text IS DISTINCT FROM d.provider_id OR p_zone IS DISTINCT FROM j.zone_id OR p_target IS DISTINCT FROM j.cname_target OR NOT j.desired OR d.disabled OR d.ownership_state<>'verified' OR d.verified_until IS NULL OR d.verified_until<=clock_timestamp() THEN RETURN false;END IF;
 PERFORM 1 FROM public.user_roles WHERE user_id=j.requested_by AND role='admin' FOR SHARE;
 IF NOT FOUND THEN RETURN false;END IF;
 UPDATE public.redirect_domain_jobs SET validation_restart_operation=NULL,validation_restart_started_at=clock_timestamp(),updated_at=clock_timestamp() WHERE domain_id=p_id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.request_redirect_domain_validation_restart(uuid,uuid,uuid,text,text),public.begin_redirect_domain_validation_restart(uuid,uuid,uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.request_redirect_domain_validation_restart(uuid,uuid,uuid,text,text),public.begin_redirect_domain_validation_restart(uuid,uuid,uuid,uuid,text,text) TO service_role;
