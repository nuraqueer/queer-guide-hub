-- Atomic spend reservations; failed provider calls consume a reservation too.
CREATE TABLE public.redirect_preview_requests (
 bucket text PRIMARY KEY,
 window_started_at timestamptz NOT NULL,
 attempts integer NOT NULL CHECK(attempts BETWEEN 1 AND 61)
);
ALTER TABLE public.redirect_preview_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_preview_requests FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_preview_requests TO service_role;
CREATE FUNCTION public.reserve_redirect_preview(p_redirect_id uuid,p_token_id uuid DEFAULT NULL,p_actor_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[]; destination text; key text; cap integer; used integer; started timestamptz; now_at timestamptz:=clock_timestamp();
BEGIN
 allowed:=public.redirect_management_scope(p_token_id,'links:write');
 IF allowed IS NOT NULL AND NOT(p_redirect_id=ANY(allowed)) THEN RAISE EXCEPTION 'Link is outside credential scope' USING ERRCODE='42501'; END IF;
 IF p_token_id IS NULL AND p_actor_id IS NULL THEN RAISE EXCEPTION 'Actor is required' USING ERRCODE='22023'; END IF;
 SELECT target INTO destination FROM public.redirects WHERE id=p_redirect_id AND type='SHORT' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Managed link not found' USING ERRCODE='P0002'; END IF;
 FOREACH key IN ARRAY ARRAY['global','actor:'||coalesce(p_token_id,p_actor_id)::text,'link:'||p_redirect_id::text] LOOP
  cap:=CASE WHEN key='global' THEN 60 WHEN key LIKE 'actor:%' THEN 10 ELSE 5 END;
  INSERT INTO public.redirect_preview_requests AS r VALUES(key,now_at,1)
  ON CONFLICT(bucket) DO UPDATE SET
   window_started_at=CASE WHEN r.window_started_at<=now_at-interval '1 hour' THEN now_at ELSE r.window_started_at END,
   attempts=CASE WHEN r.window_started_at<=now_at-interval '1 hour' THEN 1 ELSE least(r.attempts+1,cap+1) END
  RETURNING attempts,window_started_at INTO used,started;
  IF used>cap THEN RETURN jsonb_build_object('retryAfter',greatest(1,ceil(extract(epoch FROM started+interval '1 hour'-clock_timestamp()))::integer)); END IF;
 END LOOP;
 DELETE FROM public.redirect_preview_requests WHERE bucket IN(SELECT bucket FROM public.redirect_preview_requests WHERE window_started_at<now_at-interval '1 day' LIMIT 100 FOR UPDATE SKIP LOCKED);
 RETURN jsonb_build_object('target',destination,'retryAfter',0);
END $$;
REVOKE ALL ON FUNCTION public.reserve_redirect_preview(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_redirect_preview(uuid,uuid,uuid) TO service_role;
