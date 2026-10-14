ALTER TABLE public.redirect_events ADD COLUMN visitor jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(visitor)='object');
CREATE INDEX redirect_events_received_idx ON public.redirect_events(ts,click_id);
CREATE INDEX redirect_conversions_received_idx ON public.redirect_link_conversions(created_at,id);

CREATE FUNCTION public.record_redirect_visit(p_redirect_id uuid,p_path text,p_query text,p_referer text,p_user_agent text,p_country text,p_ip_hash text,p_status integer,p_variant_id text,p_destination text,p_metadata jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE visit_id uuid:=gen_random_uuid();updated uuid;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
 IF jsonb_typeof(p_metadata)<>'object' OR length(p_metadata::text)>4096 THEN RAISE EXCEPTION 'Invalid visitor metadata' USING ERRCODE='22023'; END IF;
 UPDATE public.redirects SET click_count=click_count+1 WHERE id=p_redirect_id AND is_enabled
 AND (start_at IS NULL OR start_at<=now()) AND (end_at IS NULL OR end_at>now()) AND (click_limit IS NULL OR click_count<click_limit)
 RETURNING id INTO updated;
 IF updated IS NULL THEN RETURN NULL; END IF;
 INSERT INTO public.redirect_events(redirect_id,path,query,referer,user_agent,country,ip_hash,status,variant_id,destination_url,click_id,visitor)
 VALUES(p_redirect_id,p_path,p_query,p_referer,left(p_user_agent,256),CASE WHEN p_country~'^[A-Za-z]{2}$' THEN upper(p_country) ELSE NULL END,p_ip_hash,p_status,p_variant_id,p_destination,visit_id,p_metadata);
 RETURN visit_id;
END $$;
REVOKE ALL ON FUNCTION public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_redirect_visit(uuid,text,text,text,text,text,text,integer,text,text,jsonb) TO service_role;

CREATE VIEW public.redirect_analytics_events WITH (security_invoker=true) AS
 SELECT 'click:'||e.click_id AS id,e.redirect_id,'click'::text AS kind,e.ts AS occurred_at,e.ts AS received_at,e.click_id,
   e.path AS source,'Visit'::text AS event_name,NULL::text AS customer_key,NULL::text AS amount,NULL::text AS currency,
   e.country,coalesce(e.visitor->>'city','Unknown') AS city,coalesce(e.visitor->>'region','Unknown') AS region,
   coalesce(e.visitor->>'continent','Unknown') AS continent,coalesce(e.visitor->>'domain','queer.guide') AS domain,
   coalesce(e.visitor->>'device','Unknown') AS device,coalesce(e.visitor->>'browser','Unknown') AS browser,
   coalesce(e.visitor->>'os','Unknown') AS os,coalesce((e.visitor->>'is_bot')::boolean,false) AS is_bot,
   coalesce((e.visitor->>'is_qr')::boolean,false) AS is_qr,e.variant_id,
   CASE WHEN e.referer~'^https?://' THEN regexp_replace(regexp_replace(lower(substring(e.referer FROM '^https?://([^/?#]+)')), '^.*@',''), ':([0-9]+)$','') ELSE 'Direct / unknown' END AS referrer
 FROM public.redirect_events e
 UNION ALL
 SELECT 'conversion:'||c.id,e.redirect_id,c.kind,c.occurred_at,c.created_at,e.click_id,
   e.path,c.event_name,c.customer_key,c.amount::text,c.currency,e.country,coalesce(e.visitor->>'city','Unknown'),coalesce(e.visitor->>'region','Unknown'),
   coalesce(e.visitor->>'continent','Unknown'),coalesce(e.visitor->>'domain','queer.guide'),coalesce(e.visitor->>'device','Unknown'),
   coalesce(e.visitor->>'browser','Unknown'),coalesce(e.visitor->>'os','Unknown'),coalesce((e.visitor->>'is_bot')::boolean,false),
   coalesce((e.visitor->>'is_qr')::boolean,false),e.variant_id,
   CASE WHEN e.referer~'^https?://' THEN regexp_replace(regexp_replace(lower(substring(e.referer FROM '^https?://([^/?#]+)')), '^.*@',''), ':([0-9]+)$','') ELSE 'Direct / unknown' END
 FROM public.redirect_link_conversions c JOIN public.redirect_events e ON e.click_id=c.click_id;
REVOKE ALL ON public.redirect_analytics_events FROM PUBLIC,anon;
GRANT SELECT ON public.redirect_analytics_events TO authenticated,service_role;

CREATE FUNCTION public.redirect_analytics_filtered(p_filters jsonb,p_allowed_ids uuid[] DEFAULT NULL,p_snapshot timestamptz DEFAULT NULL)
RETURNS SETOF public.redirect_analytics_events LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public AS $$
DECLARE links uuid[];start_at timestamptz;end_at timestamptz;folder uuid;tag uuid;
BEGIN
 IF jsonb_typeof(p_filters)<>'object' OR EXISTS(SELECT FROM jsonb_object_keys(p_filters) AS keys(key) WHERE key<>ALL(ARRAY['linkIds','folderId','tagId','start','end','event','country','city','device','browser','os','domain','referrer','variant','excludeBots','qr','interval'])) THEN
  RAISE EXCEPTION 'Invalid analytics filters' USING ERRCODE='22023';
 END IF;
 IF p_filters ? 'linkIds' THEN SELECT array_agg(value::uuid) INTO links FROM jsonb_array_elements_text(p_filters->'linkIds'); IF links IS NULL THEN links:='{}'; END IF; END IF;
 start_at:=nullif(p_filters->>'start','')::timestamptz;end_at:=nullif(p_filters->>'end','')::timestamptz;
 folder:=nullif(p_filters->>'folderId','')::uuid;tag:=nullif(p_filters->>'tagId','')::uuid;
 IF start_at IS NOT NULL AND end_at IS NOT NULL AND start_at>=end_at THEN RAISE EXCEPTION 'Start must precede end' USING ERRCODE='22023'; END IF;
 IF p_filters->>'event' IS NOT NULL AND p_filters->>'event'<>ALL(ARRAY['all','click','lead','sale']) THEN RAISE EXCEPTION 'Invalid event type' USING ERRCODE='22023'; END IF;
 RETURN QUERY SELECT a.* FROM public.redirect_analytics_events a
 WHERE (links IS NULL OR a.redirect_id=ANY(links)) AND (p_allowed_ids IS NULL OR a.redirect_id=ANY(p_allowed_ids))
 AND (start_at IS NULL OR a.occurred_at>=start_at) AND (end_at IS NULL OR a.occurred_at<end_at)
 AND (p_snapshot IS NULL OR a.received_at<=p_snapshot)
 AND (coalesce(p_filters->>'event','all')='all' OR a.kind=p_filters->>'event')
 AND (NOT coalesce((p_filters->>'excludeBots')::boolean,true) OR NOT a.is_bot)
 AND (p_filters->>'qr' IS NULL OR a.is_qr=(p_filters->>'qr')::boolean)
 AND (p_filters->>'country' IS NULL OR coalesce(a.country,'Unknown')=CASE WHEN upper(p_filters->>'country')='UNKNOWN' THEN 'Unknown' ELSE upper(p_filters->>'country') END)
 AND (p_filters->>'city' IS NULL OR a.city=p_filters->>'city')
 AND (p_filters->>'device' IS NULL OR a.device=p_filters->>'device')
 AND (p_filters->>'browser' IS NULL OR a.browser=p_filters->>'browser')
 AND (p_filters->>'os' IS NULL OR a.os=p_filters->>'os')
 AND (p_filters->>'domain' IS NULL OR a.domain=p_filters->>'domain')
 AND (p_filters->>'referrer' IS NULL OR a.referrer=p_filters->>'referrer')
 AND (p_filters->>'variant' IS NULL OR a.variant_id=p_filters->>'variant')
 AND (folder IS NULL OR EXISTS(SELECT FROM public.redirect_link_metadata m WHERE m.redirect_key='redirects:'||a.redirect_id AND m.folder_id=folder))
 AND (tag IS NULL OR EXISTS(SELECT FROM public.redirect_link_tag_assignments t WHERE t.redirect_key='redirects:'||a.redirect_id AND t.tag_id=tag));
END $$;
REVOKE ALL ON FUNCTION public.redirect_analytics_filtered(jsonb,uuid[],timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.redirect_analytics_filtered(jsonb,uuid[],timestamptz) TO authenticated,service_role;

CREATE FUNCTION public.redirect_analytics_report(p_filters jsonb,p_allowed_ids uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public AS $$
DECLARE result jsonb;grain text:=coalesce(p_filters->>'interval','day');snapshot timestamptz:=statement_timestamp();begin_at timestamptz;finish_at timestamptz;step interval;
BEGIN
 IF grain<>ALL(ARRAY['hour','day','week','month']) THEN RAISE EXCEPTION 'Invalid interval' USING ERRCODE='22023'; END IF;
 SELECT coalesce(nullif(p_filters->>'start','')::timestamptz,min(occurred_at),snapshot),coalesce(nullif(p_filters->>'end','')::timestamptz,snapshot) INTO begin_at,finish_at FROM public.redirect_analytics_filtered(p_filters,p_allowed_ids,snapshot);
 step:=('1 '||grain)::interval;
 IF extract(epoch FROM finish_at-begin_at)>(CASE grain WHEN 'hour' THEN 7200000 WHEN 'day' THEN 172800000 WHEN 'week' THEN 1209600000 ELSE 5184000000 END) THEN RAISE EXCEPTION 'Choose a larger interval for this date range' USING ERRCODE='22023'; END IF;
 WITH events AS MATERIALIZED (SELECT * FROM public.redirect_analytics_filtered(p_filters,p_allowed_ids,snapshot)),
 totals AS (SELECT count(*) FILTER(WHERE kind='click') AS clicks,count(*) FILTER(WHERE kind='lead') AS leads,count(*) FILTER(WHERE kind='sale') AS sales,count(DISTINCT customer_key) AS customers FROM events),
 revenue AS (SELECT currency,sum(amount::numeric)::text AS amount FROM events WHERE kind='sale' GROUP BY currency),
 buckets AS (SELECT date_trunc(grain,occurred_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS at,
 count(*) FILTER(WHERE kind='click') AS clicks,count(*) FILTER(WHERE kind='lead') AS leads,count(*) FILTER(WHERE kind='sale') AS sales FROM events GROUP BY 1),
 series AS (
  SELECT g.at,coalesce(b.clicks,0) AS clicks,coalesce(b.leads,0) AS leads,coalesce(b.sales,0) AS sales
  FROM generate_series(date_trunc(grain,begin_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',date_trunc(grain,(finish_at-interval '1 microsecond') AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',step) g(at)
  LEFT JOIN buckets b ON b.at=g.at
 ), dimensions AS (
  SELECT dimension,label,count(*) AS count FROM events CROSS JOIN LATERAL (VALUES
   ('country',coalesce(country,'Unknown')),('city',city),('region',region),('continent',continent),('domain',domain),('device',device),('browser',browser),('os',os),('referrer',referrer),('event',kind),('qr',CASE WHEN is_qr THEN 'QR' ELSE 'Link' END)
  ) d(dimension,label) GROUP BY dimension,label
 ), ranked AS (SELECT *,row_number() OVER(PARTITION BY dimension ORDER BY count DESC,label) AS n FROM dimensions),
 grouped AS (SELECT dimension,jsonb_agg(jsonb_build_object('label',label,'count',count) ORDER BY count DESC,label) AS data FROM ranked WHERE n<=100 GROUP BY dimension)
 SELECT jsonb_build_object('snapshot',snapshot,'totals',to_jsonb(totals),'revenue',coalesce((SELECT jsonb_agg(to_jsonb(revenue) ORDER BY currency) FROM revenue),'[]'),
 'series',coalesce((SELECT jsonb_agg(to_jsonb(series) ORDER BY at) FROM series),'[]'),
 'breakdowns',coalesce((SELECT jsonb_object_agg(dimension,data) FROM grouped),'{}'),'interval',grain) INTO result FROM totals;
 IF jsonb_array_length(result->'series')>2000 THEN RAISE EXCEPTION 'Choose a larger interval for this date range' USING ERRCODE='22023'; END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.redirect_analytics_report(jsonb,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.redirect_analytics_report(jsonb,uuid[]) TO authenticated,service_role;

CREATE FUNCTION public.redirect_analytics_page(p_filters jsonb,p_snapshot timestamptz DEFAULT NULL,p_before_at timestamptz DEFAULT NULL,p_before_id text DEFAULT NULL,p_limit integer DEFAULT 50,p_allowed_ids uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
 WITH events AS (SELECT * FROM public.redirect_analytics_filtered(p_filters,p_allowed_ids,coalesce(p_snapshot,statement_timestamp()))),
 page AS (SELECT * FROM events WHERE p_before_at IS NULL OR (received_at,id)<(p_before_at,p_before_id) ORDER BY received_at DESC,id DESC LIMIT greatest(1,least(p_limit,100))+1),
 shown AS (SELECT * FROM page ORDER BY received_at DESC,id DESC LIMIT greatest(1,least(p_limit,100)))
 SELECT jsonb_build_object('snapshot',coalesce(p_snapshot,statement_timestamp()),'data',coalesce((SELECT jsonb_agg(to_jsonb(shown) ORDER BY received_at DESC,id DESC) FROM shown),'[]'),
 'nextCursor',CASE WHEN (SELECT count(*) FROM page)>greatest(1,least(p_limit,100)) THEN (SELECT jsonb_build_object('at',received_at,'id',id) FROM shown ORDER BY received_at,id LIMIT 1) ELSE NULL END);
$$;
REVOKE ALL ON FUNCTION public.redirect_analytics_page(jsonb,timestamptz,timestamptz,text,integer,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.redirect_analytics_page(jsonb,timestamptz,timestamptz,text,integer,uuid[]) TO authenticated,service_role;
