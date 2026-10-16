-- External customer/event identifiers are private to their owning workspace.
-- Existing composite relationships remain; no tenant activation or data moves.
ALTER TABLE public.redirect_link_customers DROP CONSTRAINT redirect_link_customers_pkey, ADD CONSTRAINT redirect_link_customers_pkey PRIMARY KEY(workspace_id,customer_key);
ALTER TABLE public.redirect_customer_profiles DROP CONSTRAINT redirect_customer_profiles_pkey, ADD CONSTRAINT redirect_customer_profiles_pkey PRIMARY KEY(workspace_id,customer_key);
ALTER TABLE public.redirect_link_conversions DROP CONSTRAINT redirect_link_conversions_provider_event_id_key, ADD CONSTRAINT redirect_link_conversions_provider_event_id_key UNIQUE(workspace_id,provider_event_id);

CREATE OR REPLACE FUNCTION public.redirect_customer_profile(p_action text, p_customer text, p_actor uuid, p_principal uuid, p_values jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); profile public.redirect_customer_profiles;editable boolean;expected uuid;
BEGIN
 IF p_action IS NULL OR p_action NOT IN('get','patch','clear') THEN RAISE EXCEPTION 'Invalid customer action' USING ERRCODE='22023';END IF;
 editable:=public.redirect_customer_access(p_customer,p_actor,p_principal,p_action<>'get');
 IF p_action='get' THEN SELECT * INTO profile FROM public.redirect_customer_profiles WHERE workspace_id=selected_workspace AND customer_key=p_customer;
 ELSE
  IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR NOT(p_values?'version') OR p_values-ARRAY['version','name','email','avatarUrl']::text[]<>'{}' OR
    (p_values->'version'<>'null'::jsonb AND(jsonb_typeof(p_values->'version')<>'string' OR(p_values->>'version')!~*'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$')) THEN RAISE EXCEPTION 'Provide current profile fields and version' USING ERRCODE='22023';END IF;
  IF p_action='clear' AND p_values-ARRAY['version']::text[]<>'{}' THEN RAISE EXCEPTION 'Clear accepts only version' USING ERRCODE='22023';END IF;
  IF p_action='patch' AND p_values-ARRAY['version']::text[]='{}' THEN RAISE EXCEPTION 'Provide profile changes' USING ERRCODE='22023';END IF;
  IF EXISTS(SELECT FROM jsonb_each(p_values-ARRAY['version']::text[]) WHERE value<>'null'::jsonb AND jsonb_typeof(value)<>'string') THEN RAISE EXCEPTION 'Profile fields must be strings or null' USING ERRCODE='22023';END IF;
  expected:=(p_values->>'version')::uuid;
  SELECT * INTO profile FROM public.redirect_customer_profiles WHERE workspace_id=selected_workspace AND customer_key=p_customer FOR UPDATE;
  IF profile.version IS DISTINCT FROM expected THEN RAISE EXCEPTION 'Customer profile changed; reload before saving' USING ERRCODE='23505';END IF;
  IF profile.customer_key IS NULL THEN
   -- A removed original visit erases identity; explicit re-enrichment may anchor to a remaining recorded conversion.
   INSERT INTO public.redirect_link_customers(workspace_id,customer_key,click_id) SELECT selected_workspace,p_customer,click_id FROM public.redirect_link_conversions WHERE workspace_id=selected_workspace AND customer_key=p_customer ORDER BY occurred_at,id LIMIT 1 ON CONFLICT(workspace_id,customer_key) DO NOTHING;
   IF NOT EXISTS(SELECT FROM public.redirect_link_customers WHERE workspace_id=selected_workspace AND customer_key=p_customer) THEN RAISE EXCEPTION 'Customer identity is unavailable in this workspace' USING ERRCODE='23505';END IF;
   INSERT INTO public.redirect_customer_profiles(workspace_id,customer_key) VALUES(selected_workspace,p_customer);
  END IF;
  UPDATE public.redirect_customer_profiles SET
   name=CASE WHEN p_action='clear' THEN NULL WHEN p_values?'name' THEN nullif(btrim(p_values->>'name'),'') ELSE name END,
   email=CASE WHEN p_action='clear' THEN NULL WHEN p_values?'email' THEN nullif(btrim(p_values->>'email'),'') ELSE email END,
   avatar_url=CASE WHEN p_action='clear' THEN NULL WHEN p_values?'avatarUrl' THEN nullif(btrim(p_values->>'avatarUrl'),'') ELSE avatar_url END,
   version=gen_random_uuid(),updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND customer_key=p_customer RETURNING * INTO profile;
 END IF;
 RETURN jsonb_build_object('customerExternalId',p_customer,'name',profile.name,'email',profile.email,'avatarUrl',profile.avatar_url,'version',profile.version,'updatedAt',profile.updated_at,'canEdit',editable);
END $function$;

CREATE OR REPLACE FUNCTION public.record_redirect_conversion(p_event jsonb, p_token_id uuid DEFAULT NULL::uuid, p_registered_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace();
 visit public.redirect_events; token public.redirect_api_tokens; saved public.redirect_link_conversions;
 event_click uuid := nullif(p_event->>'clickId','')::uuid;
 customer text := nullif(p_event->>'customerExternalId','');
 event_kind text := p_event->>'kind'; event_key text := p_event->>'eventId';
 event_amount numeric := nullif(p_event->>'amount','')::numeric;
 event_currency text := nullif(p_event->>'currency','');
 event_time timestamptz := coalesce(nullif(p_event->>'occurredAt','')::timestamptz,now());
 inserted uuid;
BEGIN
 IF current_user <> 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
 -- Native signups have separate verified-account/timing checks. Manual account
 -- conversions must recheck current owner state at the write boundary.
 IF p_token_id IS NULL AND p_registered_at IS NULL THEN PERFORM public.redirect_management_scope(NULL,'conversions:write');END IF;
 IF event_kind IS NULL OR event_kind NOT IN ('lead','sale') OR customer IS NULL OR length(customer)>256
 OR event_key IS NULL OR length(event_key) NOT BETWEEN 1 AND 256
 OR coalesce(length(p_event->>'eventName'),0) NOT BETWEEN 1 AND 120
 OR jsonb_typeof(coalesce(p_event->'metadata','{}')) <> 'object'
 OR length(coalesce(p_event->'metadata','{}')::text)>8192
 OR event_time>now()+interval '5 minutes'
 OR (event_kind='lead' AND (event_amount IS NOT NULL OR event_currency IS NOT NULL))
 OR (event_kind='sale' AND (event_amount IS NULL OR event_amount<0 OR event_amount>=1e12 OR event_amount<>round(event_amount,6) OR event_amount::text IN ('NaN','Infinity','-Infinity') OR event_currency IS NULL OR event_currency !~ '^[A-Z]{3}$'))
 THEN RAISE EXCEPTION 'Invalid conversion event' USING ERRCODE='22023'; END IF;
 IF event_click IS NULL THEN SELECT click_id INTO event_click FROM public.redirect_link_customers WHERE workspace_id=selected_workspace AND customer_key=customer; END IF;
 SELECT * INTO visit FROM public.redirect_events WHERE workspace_id=selected_workspace AND click_id=event_click;
 IF visit.id IS NULL THEN RAISE EXCEPTION 'Attributed click not found' USING ERRCODE='P0002'; END IF;
 IF event_time<visit.ts THEN RAISE EXCEPTION 'Conversion precedes click' USING ERRCODE='22023'; END IF;
 IF p_registered_at IS NOT NULL AND (event_kind<>'lead' OR visit.ts>p_registered_at OR visit.ts<p_registered_at-interval '30 days') THEN
  RAISE EXCEPTION 'Signup is not attributable to this click' USING ERRCODE='22023';
 END IF;
 IF p_token_id IS NOT NULL AND NOT(visit.redirect_id=ANY(coalesce(public.redirect_management_scope(p_token_id,'conversions:write'),ARRAY[visit.redirect_id]))) THEN
  RAISE EXCEPTION 'Credential cannot attribute this link' USING ERRCODE='42501';
 END IF;
 INSERT INTO public.redirect_link_conversions(workspace_id,click_id,kind,amount,currency,customer_key,provider_event_id,metadata,event_name,occurred_at)
 VALUES(selected_workspace,event_click,event_kind,event_amount,event_currency,customer,event_key,coalesce(p_event->'metadata','{}'),p_event->>'eventName',event_time)
 ON CONFLICT(workspace_id,provider_event_id) DO NOTHING RETURNING id INTO inserted;
 SELECT * INTO saved FROM public.redirect_link_conversions WHERE workspace_id=selected_workspace AND provider_event_id=event_key;
 IF saved.id IS NULL THEN RAISE EXCEPTION 'Event ID is unavailable in this workspace' USING ERRCODE='23505';END IF;
 IF inserted IS NULL AND (saved.click_id IS DISTINCT FROM event_click OR saved.kind IS DISTINCT FROM event_kind
  OR saved.amount IS DISTINCT FROM event_amount OR saved.currency IS DISTINCT FROM event_currency
  OR saved.customer_key IS DISTINCT FROM customer OR saved.event_name IS DISTINCT FROM (p_event->>'eventName')
  OR saved.metadata IS DISTINCT FROM coalesce(p_event->'metadata','{}')
  OR (p_event ? 'occurredAt' AND saved.occurred_at IS DISTINCT FROM event_time)) THEN
  RAISE EXCEPTION 'Event ID was already used with different data' USING ERRCODE='23505';
 END IF;
 INSERT INTO public.redirect_link_customers(workspace_id,customer_key,click_id) VALUES(selected_workspace,customer,event_click) ON CONFLICT(workspace_id,customer_key) DO NOTHING;
 IF NOT EXISTS(SELECT FROM public.redirect_link_customers WHERE workspace_id=selected_workspace AND customer_key=customer) THEN RAISE EXCEPTION 'Customer identity is unavailable in this workspace' USING ERRCODE='23505';END IF;
 RETURN jsonb_build_object('id',saved.id,'clickId',saved.click_id,'kind',saved.kind,'duplicate',inserted IS NULL);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_customer_access(p_customer text, p_actor uuid, p_principal uuid, p_write boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor); allowed uuid[];ids uuid[];editable boolean;
BEGIN
 IF p_write THEN PERFORM pg_advisory_xact_lock(471983093);ELSE PERFORM pg_advisory_xact_lock_shared(471983093);END IF;
 IF p_customer IS NULL OR length(p_customer) NOT BETWEEN 1 AND 256 OR btrim(p_customer)='' OR p_customer ~ '[[:cntrl:]]' THEN RAISE EXCEPTION 'Provide a customer ID' USING ERRCODE='22023';END IF;
 IF p_principal IS NULL THEN
  PERFORM public.redirect_management_scope(NULL,'events:read');
  IF NOT EXISTS(SELECT FROM public.user_roles WHERE user_id=p_actor AND role='admin') THEN RAISE EXCEPTION 'Workspace access required' USING ERRCODE='42501';END IF;
 ELSIF NOT EXISTS(SELECT FROM public.redirect_api_tokens WHERE workspace_id=selected_workspace AND id=p_principal) AND NOT EXISTS(SELECT FROM public.redirect_workspace_members WHERE workspace_id=selected_workspace AND id=p_principal AND user_id=p_actor AND active AND kind='user') THEN
  RAISE EXCEPTION 'Account does not match membership' USING ERRCODE='42501';
 END IF;
 allowed:=public.redirect_management_scope(p_principal,'events:read');
 PERFORM pg_advisory_xact_lock(hashtextextended('redirect-customer:'||CASE WHEN selected_workspace='58aa4340-8f21-4b7f-9a10-90be2da89c01'::uuid THEN '' ELSE selected_workspace::text||':' END||p_customer,0));
 SELECT array_agg(DISTINCT redirect_id) INTO ids FROM (
  SELECT e.redirect_id FROM public.redirect_events e JOIN public.redirect_link_conversions c ON c.workspace_id=e.workspace_id AND c.click_id=e.click_id WHERE e.workspace_id=selected_workspace AND c.customer_key=p_customer
  UNION SELECT e.redirect_id FROM public.redirect_events e JOIN public.redirect_link_customers c ON c.workspace_id=e.workspace_id AND c.click_id=e.click_id WHERE e.workspace_id=selected_workspace AND c.customer_key=p_customer
 ) links;
 IF ids IS NULL OR(allowed IS NOT NULL AND NOT(ids&&allowed)) THEN RAISE EXCEPTION 'Customer not found' USING ERRCODE='P0002';END IF;
 SELECT coalesce(bool_and((allowed IS NULL OR id=ANY(allowed)) AND public.redirect_can_write_link(p_principal,id)),false) INTO editable FROM unnest(ids) AS id;
 IF p_write THEN
  allowed:=public.redirect_management_scope(p_principal,'links:write');
  IF NOT editable OR(allowed IS NOT NULL AND NOT(ids<@allowed)) THEN RAISE EXCEPTION 'Edit access to every customer link is required' USING ERRCODE='42501';END IF;
 END IF;
 RETURN editable;
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_customer_identity_lock()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE keys text[]; v_customer text;
BEGIN
 IF TG_OP<>'INSERT' THEN keys:=ARRAY['redirect-customer:'||CASE WHEN OLD.workspace_id='58aa4340-8f21-4b7f-9a10-90be2da89c01'::uuid THEN '' ELSE OLD.workspace_id::text||':' END||OLD.customer_key];END IF;
 IF TG_OP<>'DELETE' THEN keys:=coalesce(keys,ARRAY[]::text[])||('redirect-customer:'||CASE WHEN NEW.workspace_id='58aa4340-8f21-4b7f-9a10-90be2da89c01'::uuid THEN '' ELSE NEW.workspace_id::text||':' END||NEW.customer_key);END IF;
 FOR v_customer IN SELECT DISTINCT entry FROM unnest(keys) AS entry WHERE entry IS NOT NULL ORDER BY entry LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended(v_customer,0));
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $function$;
