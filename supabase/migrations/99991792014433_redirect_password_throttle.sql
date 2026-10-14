-- Service-only attempt reservations happen before expensive password verification.
CREATE TABLE public.redirect_password_attempts (
 redirect_id uuid NOT NULL REFERENCES public.redirects(id) ON DELETE CASCADE,
 client_hash text NOT NULL CHECK(client_hash = '*' OR client_hash ~ '^[0-9a-f]{64}$'),
 window_started_at timestamptz NOT NULL,
 attempts integer NOT NULL CHECK(attempts BETWEEN 1 AND 1001),
 PRIMARY KEY(redirect_id,client_hash)
);
CREATE INDEX redirect_password_attempts_age ON public.redirect_password_attempts(window_started_at);
ALTER TABLE public.redirect_password_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_password_attempts FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_password_attempts TO service_role;

CREATE FUNCTION public.reserve_redirect_password_attempt(p_redirect_id uuid,p_client_hash text)
RETURNS integer LANGUAGE plpgsql SECURITY INVOKER SET search_path = public,pg_temp AS $$
DECLARE v_now timestamptz := clock_timestamp(); v_key text; v_limit integer;
 v_count integer; v_started timestamptz; v_retry integer := 0;
BEGIN
 IF p_client_hash IS NULL OR p_client_hash !~ '^[0-9a-f]{64}$' THEN
  RAISE EXCEPTION 'Invalid client hash' USING ERRCODE='22023';
 END IF;
 -- Always reserve the shared link bucket first, then the client bucket.
 -- Count successes too: checking correctness must not bypass the CPU budget.
 FOREACH v_key IN ARRAY ARRAY['*',p_client_hash] LOOP
  v_limit := CASE WHEN v_key='*' THEN 1000 ELSE 10 END;
  INSERT INTO public.redirect_password_attempts AS a VALUES(p_redirect_id,v_key,v_now,1)
  ON CONFLICT(redirect_id,client_hash) DO UPDATE SET
   window_started_at=CASE WHEN a.window_started_at <= v_now-interval '15 minutes' THEN v_now ELSE a.window_started_at END,
   attempts=CASE WHEN a.window_started_at <= v_now-interval '15 minutes' THEN 1 ELSE least(a.attempts+1,v_limit+1) END
  RETURNING attempts,window_started_at INTO v_count,v_started;
  IF v_count>v_limit THEN
   v_retry := least(900,greatest(1,ceil(extract(epoch FROM v_started+interval '15 minutes'-clock_timestamp()))::integer));
   EXIT;
  END IF;
 END LOOP;
 -- Bounded lazy retention; SKIP LOCKED avoids cleanup deadlocks with other attempts.
 DELETE FROM public.redirect_password_attempts WHERE (redirect_id,client_hash) IN (
  SELECT redirect_id,client_hash FROM public.redirect_password_attempts
  WHERE window_started_at < v_now - interval '1 day'
  ORDER BY window_started_at LIMIT 100 FOR UPDATE SKIP LOCKED
 );
 RETURN v_retry;
END $$;
REVOKE ALL ON FUNCTION public.reserve_redirect_password_attempt(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_redirect_password_attempt(uuid,text) TO service_role;
