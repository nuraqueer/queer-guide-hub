CREATE TABLE public.redirect_link_policies (
  redirect_id uuid PRIMARY KEY REFERENCES public.redirects(id) ON DELETE CASCADE,
  policy jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(policy)='object'),
  password_hash jsonb,
  has_password boolean GENERATED ALWAYS AS (password_hash IS NOT NULL) STORED,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.redirect_link_policies ENABLE ROW LEVEL SECURITY;
CREATE POLICY redirect_link_policies_admin_read ON public.redirect_link_policies FOR SELECT TO authenticated
  USING ((SELECT public.has_role_jwt('admin'::public.app_role)));
REVOKE ALL ON public.redirect_link_policies FROM anon, authenticated;
GRANT SELECT ON public.redirect_link_policies TO authenticated;
GRANT ALL ON public.redirect_link_policies TO service_role;

-- Public resolution goes through the password-aware server. A direct Data API
-- read or the old resolver RPC must not disclose a protected destination.
DROP POLICY IF EXISTS redirects_public_read ON public.redirects;
REVOKE EXECUTE ON FUNCTION public.resolve_short_redirect(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_short_redirect(text) TO service_role;

CREATE FUNCTION public.set_redirect_link_policy(p_redirect_id uuid,p_policy jsonb,p_password_hash jsonb,p_change_password boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE saved public.redirect_link_policies;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  IF NOT EXISTS (SELECT FROM public.redirects WHERE id=p_redirect_id AND type='SHORT') THEN
    RAISE EXCEPTION 'Managed short link not found' USING ERRCODE='P0002';
  END IF;
  INSERT INTO public.redirect_link_policies(redirect_id,policy,password_hash)
  VALUES (p_redirect_id,p_policy - 'expires_at',CASE WHEN p_change_password THEN p_password_hash ELSE NULL END)
  ON CONFLICT (redirect_id) DO UPDATE SET policy=excluded.policy,
    password_hash=CASE WHEN p_change_password THEN excluded.password_hash ELSE redirect_link_policies.password_hash END,
    updated_at=now() RETURNING * INTO saved;
  UPDATE public.redirects SET end_at=nullif(p_policy->>'expires_at','')::timestamptz, updated_at=now() WHERE id=p_redirect_id;
  RETURN jsonb_build_object('policy', saved.policy || jsonb_strip_nulls(jsonb_build_object('expires_at',nullif(p_policy->>'expires_at',''))),'has_password',saved.has_password);
END $$;
REVOKE ALL ON FUNCTION public.set_redirect_link_policy(uuid,jsonb,jsonb,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_redirect_link_policy(uuid,jsonb,jsonb,boolean) TO service_role;

ALTER TABLE public.redirect_events ADD COLUMN IF NOT EXISTS variant_id text;
ALTER TABLE public.redirect_events ADD COLUMN IF NOT EXISTS destination_url text;
ALTER TABLE public.redirect_events ADD COLUMN IF NOT EXISTS click_id uuid DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX IF NOT EXISTS redirect_events_click_id_idx ON public.redirect_events(click_id);
CREATE INDEX IF NOT EXISTS redirect_events_variant_idx ON public.redirect_events(redirect_id,variant_id,ts);

CREATE FUNCTION public.record_redirect_visit(p_redirect_id uuid,p_path text,p_query text,p_referer text,p_user_agent text,p_country text,p_ip_hash text,p_status integer,p_variant_id text,p_destination text)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE visit_id uuid := gen_random_uuid(); updated uuid;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  UPDATE public.redirects SET click_count=click_count+1 WHERE id=p_redirect_id AND is_enabled
    AND (start_at IS NULL OR start_at<=now()) AND (end_at IS NULL OR end_at>now())
    AND (click_limit IS NULL OR click_count<click_limit) RETURNING id INTO updated;
  IF updated IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.redirect_events(redirect_id,path,query,referer,user_agent,country,ip_hash,status,variant_id,destination_url,click_id)
  VALUES(p_redirect_id,p_path,p_query,p_referer,left(p_user_agent,256),p_country,p_ip_hash,p_status,p_variant_id,p_destination,visit_id);
  RETURN visit_id;
END $$;
REVOKE ALL ON FUNCTION public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.record_redirect_click(uuid,text,text,text,text,text,text,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_redirect_click(uuid,text,text,text,text,text,text,integer) TO service_role;

CREATE TABLE public.redirect_link_conversions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  click_id uuid NOT NULL REFERENCES public.redirect_events(click_id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('lead','sale')),
  amount numeric(18,6),
  currency text,
  customer_key text,
  provider_event_id text UNIQUE,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind='lead' AND amount IS NULL AND currency IS NULL) OR (kind='sale' AND amount IS NOT NULL AND amount>=0 AND currency IS NOT NULL AND currency ~ '^[A-Z]{3}$'))
);
CREATE INDEX redirect_link_conversions_click_idx ON public.redirect_link_conversions(click_id,created_at);
ALTER TABLE public.redirect_link_conversions ENABLE ROW LEVEL SECURITY;
CREATE POLICY redirect_link_conversions_admin_read ON public.redirect_link_conversions FOR SELECT TO authenticated
  USING ((SELECT public.has_role_jwt('admin'::public.app_role)));
REVOKE ALL ON public.redirect_link_conversions FROM anon, authenticated;
GRANT SELECT ON public.redirect_link_conversions TO authenticated;
GRANT ALL ON public.redirect_link_conversions TO service_role;

CREATE FUNCTION public.redirect_variant_performance(p_redirect_id uuid)
RETURNS TABLE(id text,clicks bigint,leads bigint,sales bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
  SELECT e.variant_id,count(DISTINCT e.click_id),
    count(DISTINCT c.id) FILTER (WHERE c.kind='lead'),
    count(DISTINCT c.id) FILTER (WHERE c.kind='sale')
  FROM public.redirect_events e LEFT JOIN public.redirect_link_conversions c ON c.click_id=e.click_id
  WHERE e.redirect_id=p_redirect_id AND e.variant_id IS NOT NULL GROUP BY e.variant_id;
$$;
REVOKE ALL ON FUNCTION public.redirect_variant_performance(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.redirect_variant_performance(uuid) TO authenticated, service_role;
