-- Scoped server credentials never disclose token hashes through the Data API.
CREATE TABLE public.redirect_api_tokens (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL CHECK(length(name) BETWEEN 1 AND 100),
 token_hash text UNIQUE NOT NULL CHECK(token_hash ~ '^[a-f0-9]{64}$'), prefix text NOT NULL,
 scopes text[] NOT NULL CHECK(cardinality(scopes)>0 AND scopes <@ ARRAY['conversions:write','events:read']::text[]),
 redirect_ids uuid[], created_by uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL, revoked_at timestamptz, last_used_at timestamptz,
 CHECK(expires_at>created_at), CHECK(redirect_ids IS NULL OR cardinality(redirect_ids)>0)
);
ALTER TABLE public.redirect_api_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY redirect_api_tokens_admin_read ON public.redirect_api_tokens FOR SELECT TO authenticated
 USING((SELECT public.has_role_jwt('admin'::public.app_role)));
REVOKE ALL ON public.redirect_api_tokens FROM anon,authenticated;
GRANT SELECT(id,name,prefix,scopes,redirect_ids,created_by,created_at,expires_at,revoked_at,last_used_at) ON public.redirect_api_tokens TO authenticated;
GRANT ALL ON public.redirect_api_tokens TO service_role;

CREATE TABLE public.redirect_link_customers (
 customer_key text PRIMARY KEY CHECK(length(customer_key) BETWEEN 1 AND 256),
 click_id uuid NOT NULL REFERENCES public.redirect_events(click_id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.redirect_link_customers ENABLE ROW LEVEL SECURITY;
CREATE POLICY redirect_link_customers_admin_read ON public.redirect_link_customers FOR SELECT TO authenticated
 USING((SELECT public.has_role_jwt('admin'::public.app_role)));
REVOKE ALL ON public.redirect_link_customers FROM anon,authenticated;
GRANT SELECT ON public.redirect_link_customers TO authenticated;
GRANT ALL ON public.redirect_link_customers TO service_role;
ALTER TABLE public.redirect_link_conversions ADD COLUMN event_name text NOT NULL DEFAULT 'Conversion';
ALTER TABLE public.redirect_link_conversions ADD COLUMN occurred_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.redirect_link_conversions ADD CONSTRAINT redirect_conversion_finite_amount CHECK(amount IS NULL OR (amount::text NOT IN ('NaN','Infinity','-Infinity') AND amount<1e12));
CREATE INDEX redirect_conversions_customer_idx ON public.redirect_link_conversions(customer_key,occurred_at,id);

CREATE FUNCTION public.authenticate_redirect_api_token(p_hash text,p_scope text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE t public.redirect_api_tokens;
BEGIN
 IF current_user <> 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
 UPDATE public.redirect_api_tokens SET last_used_at=now()
 WHERE token_hash=p_hash AND revoked_at IS NULL AND expires_at>now() AND p_scope=ANY(scopes) RETURNING * INTO t;
 IF t.id IS NULL THEN RETURN NULL; END IF;
 RETURN jsonb_build_object('id',t.id,'redirect_ids',t.redirect_ids,'scopes',t.scopes);
END $$;
REVOKE ALL ON FUNCTION public.authenticate_redirect_api_token(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.authenticate_redirect_api_token(text,text) TO service_role;

CREATE FUNCTION public.record_redirect_conversion(p_event jsonb,p_token_id uuid DEFAULT NULL,p_registered_at timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE
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
 IF event_kind IS NULL OR event_kind NOT IN ('lead','sale') OR customer IS NULL OR length(customer)>256
 OR event_key IS NULL OR length(event_key) NOT BETWEEN 1 AND 256
 OR coalesce(length(p_event->>'eventName'),0) NOT BETWEEN 1 AND 120
 OR jsonb_typeof(coalesce(p_event->'metadata','{}')) <> 'object'
 OR length(coalesce(p_event->'metadata','{}')::text)>8192
 OR event_time>now()+interval '5 minutes'
 OR (event_kind='lead' AND (event_amount IS NOT NULL OR event_currency IS NOT NULL))
 OR (event_kind='sale' AND (event_amount IS NULL OR event_amount<0 OR event_amount>=1e12 OR event_amount<>round(event_amount,6) OR event_amount::text IN ('NaN','Infinity','-Infinity') OR event_currency IS NULL OR event_currency !~ '^[A-Z]{3}$'))
 THEN RAISE EXCEPTION 'Invalid conversion event' USING ERRCODE='22023'; END IF;
 IF event_click IS NULL THEN SELECT click_id INTO event_click FROM public.redirect_link_customers WHERE customer_key=customer; END IF;
 SELECT * INTO visit FROM public.redirect_events WHERE click_id=event_click;
 IF visit.id IS NULL THEN RAISE EXCEPTION 'Attributed click not found' USING ERRCODE='P0002'; END IF;
 IF event_time<visit.ts THEN RAISE EXCEPTION 'Conversion precedes click' USING ERRCODE='22023'; END IF;
 IF p_registered_at IS NOT NULL AND (event_kind<>'lead' OR visit.ts>p_registered_at OR visit.ts<p_registered_at-interval '30 days') THEN
  RAISE EXCEPTION 'Signup is not attributable to this click' USING ERRCODE='22023';
 END IF;
 IF p_token_id IS NOT NULL THEN
  SELECT * INTO token FROM public.redirect_api_tokens WHERE id=p_token_id FOR SHARE;
  IF token.id IS NULL OR token.revoked_at IS NOT NULL OR token.expires_at<=now() OR NOT ('conversions:write'=ANY(token.scopes))
   OR (token.redirect_ids IS NOT NULL AND NOT (visit.redirect_id=ANY(token.redirect_ids))) THEN
   RAISE EXCEPTION 'Credential cannot attribute this link' USING ERRCODE='42501';
  END IF;
 END IF;
 INSERT INTO public.redirect_link_conversions(click_id,kind,amount,currency,customer_key,provider_event_id,metadata,event_name,occurred_at)
 VALUES(event_click,event_kind,event_amount,event_currency,customer,event_key,coalesce(p_event->'metadata','{}'),p_event->>'eventName',event_time)
 ON CONFLICT(provider_event_id) DO NOTHING RETURNING id INTO inserted;
 SELECT * INTO saved FROM public.redirect_link_conversions WHERE provider_event_id=event_key;
 IF inserted IS NULL AND (saved.click_id IS DISTINCT FROM event_click OR saved.kind IS DISTINCT FROM event_kind
  OR saved.amount IS DISTINCT FROM event_amount OR saved.currency IS DISTINCT FROM event_currency
  OR saved.customer_key IS DISTINCT FROM customer OR saved.event_name IS DISTINCT FROM (p_event->>'eventName')
  OR saved.metadata IS DISTINCT FROM coalesce(p_event->'metadata','{}')
  OR (p_event ? 'occurredAt' AND saved.occurred_at IS DISTINCT FROM event_time)) THEN
  RAISE EXCEPTION 'Event ID was already used with different data' USING ERRCODE='23505';
 END IF;
 INSERT INTO public.redirect_link_customers(customer_key,click_id) VALUES(customer,event_click) ON CONFLICT(customer_key) DO NOTHING;
 RETURN jsonb_build_object('id',saved.id,'clickId',saved.click_id,'kind',saved.kind,'duplicate',inserted IS NULL);
END $$;
REVOKE ALL ON FUNCTION public.record_redirect_conversion(jsonb,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_redirect_conversion(jsonb,uuid,timestamptz) TO service_role;

CREATE FUNCTION public.redirect_customer_journey(p_customer_key text,p_after_at timestamptz DEFAULT NULL,p_after_id text DEFAULT NULL,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
 WITH visits AS (
  SELECT DISTINCT e.click_id FROM public.redirect_events e JOIN public.redirect_link_conversions c ON c.click_id=e.click_id WHERE c.customer_key=p_customer_key
  UNION SELECT click_id FROM public.redirect_link_customers WHERE customer_key=p_customer_key
 ), journey AS (
  SELECT 'click:'||e.click_id AS id,'click' AS kind,e.ts AS occurred_at,coalesce(e.path,'/go/'||r.slug,r.source_path) AS source,'Visit' AS event_name,NULL::text AS amount,NULL::text AS currency,e.click_id
  FROM visits v JOIN public.redirect_events e ON e.click_id=v.click_id JOIN public.redirects r ON r.id=e.redirect_id
  UNION ALL
  SELECT 'conversion:'||c.id,c.kind,c.occurred_at,coalesce(e.path,'/go/'||r.slug,r.source_path),c.event_name,c.amount::text,c.currency,c.click_id
  FROM public.redirect_link_conversions c JOIN public.redirect_events e ON e.click_id=c.click_id JOIN public.redirects r ON r.id=e.redirect_id
  WHERE c.customer_key=p_customer_key
 ), page AS (
  SELECT * FROM journey WHERE p_after_at IS NULL OR (occurred_at,id)>(p_after_at,p_after_id)
  ORDER BY occurred_at,id LIMIT greatest(1,least(p_limit,100))+1
 ), shown AS (
  SELECT * FROM page ORDER BY occurred_at,id LIMIT greatest(1,least(p_limit,100))
 )
 SELECT jsonb_build_object('data',coalesce((SELECT jsonb_agg(to_jsonb(shown) ORDER BY occurred_at,id) FROM shown),'[]'::jsonb),
  'nextCursor',CASE WHEN (SELECT count(*) FROM page)>greatest(1,least(p_limit,100)) THEN
   (SELECT jsonb_build_object('at',occurred_at,'id',id) FROM shown ORDER BY occurred_at DESC,id DESC LIMIT 1) ELSE NULL END);
$$;
REVOKE ALL ON FUNCTION public.redirect_customer_journey(text,timestamptz,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.redirect_customer_journey(text,timestamptz,text,integer) TO authenticated,service_role;

-- Preserve the donation ledger if a campaign/event is later removed.
ALTER TABLE public.donations ADD COLUMN redirect_click_id uuid REFERENCES public.redirect_events(click_id) ON DELETE SET NULL;

-- JSON numeric decoding otherwise loses micro-units on large amounts. Keep
-- exact decimal strings in reports; inherit both underlying tables' RLS.
CREATE VIEW public.redirect_conversion_report WITH (security_invoker=true) AS
 SELECT c.id,c.click_id,c.kind,c.event_name,c.occurred_at,c.customer_key,c.amount::text AS amount,c.currency,
   e.redirect_id,e.ts AS click_ts,c.created_at AS received_at
 FROM public.redirect_link_conversions c JOIN public.redirect_events e ON e.click_id=c.click_id;
REVOKE ALL ON public.redirect_conversion_report FROM PUBLIC,anon;
GRANT SELECT ON public.redirect_conversion_report TO authenticated,service_role;
