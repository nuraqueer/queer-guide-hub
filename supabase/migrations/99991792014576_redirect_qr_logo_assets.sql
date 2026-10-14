INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('redirect-brand-assets','redirect-brand-assets',true,1500000,ARRAY['image/png','image/jpeg']) ON CONFLICT(id) DO NOTHING;
DO $$ BEGIN
 IF EXISTS(SELECT FROM storage.buckets WHERE id='redirect-brand-assets' AND
  (public IS DISTINCT FROM true OR file_size_limit IS DISTINCT FROM 1500000 OR allowed_mime_types IS NULL OR NOT(allowed_mime_types @> ARRAY['image/png','image/jpeg'] AND allowed_mime_types <@ ARRAY['image/png','image/jpeg']))) THEN
  RAISE EXCEPTION 'Existing redirect-brand-assets bucket has incompatible settings';
 END IF;
END $$;
-- Only the validated server endpoint may upload to this public artwork bucket.
CREATE POLICY redirect_brand_asset_no_direct_insert ON storage.objects AS RESTRICTIVE FOR INSERT TO anon,authenticated WITH CHECK(bucket_id<>'redirect-brand-assets');
CREATE POLICY redirect_brand_asset_no_direct_update ON storage.objects AS RESTRICTIVE FOR UPDATE TO anon,authenticated USING(bucket_id<>'redirect-brand-assets') WITH CHECK(bucket_id<>'redirect-brand-assets');
CREATE POLICY redirect_brand_asset_no_direct_delete ON storage.objects AS RESTRICTIVE FOR DELETE TO anon,authenticated USING(bucket_id<>'redirect-brand-assets');
CREATE POLICY redirect_brand_asset_no_metadata_listing ON storage.objects AS RESTRICTIVE FOR SELECT TO anon,authenticated USING(bucket_id<>'redirect-brand-assets');


CREATE TABLE public.redirect_qr_assets(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),target_scope text NOT NULL,
 domain_id uuid REFERENCES public.redirect_domains(id) ON DELETE SET NULL,
 requested_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,expected_version uuid,
 mime text NOT NULL CHECK(mime IN('image/png','image/jpeg')),
 bytes integer NOT NULL CHECK(bytes BETWEEN 1 AND 1500000),width integer NOT NULL CHECK(width BETWEEN 1 AND 1024),height integer NOT NULL CHECK(height BETWEEN 1 AND 1024),
 sha256 text NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'),
 state text NOT NULL DEFAULT 'pending' CHECK(state IN('pending','active','deleting','deleted')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),expires_at timestamptz NOT NULL DEFAULT clock_timestamp()+interval '15 minutes',
 next_cleanup_at timestamptz NOT NULL DEFAULT clock_timestamp()+interval '15 minutes',
 lease uuid,lease_until timestamptz,attempts integer NOT NULL DEFAULT 0,
 last_deleted_at timestamptz,last_error text CHECK(length(last_error)<=200)
);
ALTER TABLE public.redirect_qr_assets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_qr_assets FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_qr_assets TO service_role;
CREATE INDEX redirect_qr_assets_cleanup_due ON public.redirect_qr_assets(next_cleanup_at);
CREATE INDEX redirect_qr_assets_upload_budget ON public.redirect_qr_assets(requested_by,created_at);
CREATE INDEX redirect_qr_assets_recent_uploads ON public.redirect_qr_assets(created_at);
CREATE INDEX redirect_qr_assets_pending_scope ON public.redirect_qr_assets(target_scope,expires_at) WHERE state='pending';
CREATE TRIGGER redirect_qr_assets_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_qr_assets FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
ALTER TABLE public.redirect_qr_styles ADD COLUMN logo_mode text NOT NULL DEFAULT 'inherit' CHECK(logo_mode IN('inherit','none','custom')),
 ADD COLUMN logo_asset_id uuid REFERENCES public.redirect_qr_assets(id) ON DELETE RESTRICT;
CREATE INDEX redirect_qr_styles_logo_reference ON public.redirect_qr_styles(logo_asset_id) WHERE logo_asset_id IS NOT NULL;
CREATE FUNCTION public.redirect_qr_asset_json(p_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',id,'key',id::text||CASE WHEN mime='image/png' THEN '.png' ELSE '.jpg' END,'mime',mime,'bytes',bytes,'width',width,'height',height,'sha256',sha256)
 FROM public.redirect_qr_assets WHERE id=p_id AND state='active';
$$;
CREATE FUNCTION public.redirect_qr_effective_logo(p_domain uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_qr_styles;source text:='domain';asset jsonb;
BEGIN
 IF p_domain IS NOT NULL THEN SELECT * INTO r FROM public.redirect_qr_styles WHERE domain_id=p_domain;END IF;
 IF r.scope IS NULL OR r.logo_mode='inherit' THEN SELECT * INTO r FROM public.redirect_qr_styles WHERE scope='workspace';source:='workspace';END IF;
 IF r.logo_mode='none' THEN RETURN jsonb_build_object('effectiveLogo',NULL,'logoSource','hidden');END IF;
 IF r.logo_mode='custom' THEN
  asset:=public.redirect_qr_asset_json(r.logo_asset_id);
  IF asset IS NULL THEN RAISE EXCEPTION 'Saved QR logo is unavailable; review owner logo settings' USING ERRCODE='22023';END IF;
  RETURN jsonb_build_object('effectiveLogo',asset,'logoSource',source);
 END IF;
 RETURN jsonb_build_object('effectiveLogo',NULL,'logoSource','default');
END $$;
CREATE FUNCTION public.redirect_qr_style_json(p_domain uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('version',(SELECT version FROM public.redirect_qr_styles WHERE scope=coalesce('domain:'||p_domain::text,'workspace')),
 'style',coalesce((SELECT style FROM public.redirect_qr_styles WHERE scope=coalesce('domain:'||p_domain::text,'workspace')),'{}'),
 'effectiveStyle',public.redirect_qr_effective_style(p_domain),'domainId',p_domain,
 'logoMode',coalesce((SELECT logo_mode FROM public.redirect_qr_styles WHERE scope=coalesce('domain:'||p_domain::text,'workspace')),'inherit'),
 'logoAsset',public.redirect_qr_asset_json((SELECT logo_asset_id FROM public.redirect_qr_styles WHERE scope=coalesce('domain:'||p_domain::text,'workspace'))))||public.redirect_qr_effective_logo(p_domain);
$$;
CREATE FUNCTION public.defer_redirect_qr_asset_cleanup() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
 IF OLD.logo_asset_id IS NOT NULL AND (TG_OP='DELETE' OR NEW.logo_asset_id IS DISTINCT FROM OLD.logo_asset_id) THEN
  UPDATE public.redirect_qr_assets SET next_cleanup_at=clock_timestamp()+interval '1 hour' WHERE id=OLD.logo_asset_id AND state='active';
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER defer_redirect_qr_asset_cleanup AFTER UPDATE OR DELETE ON public.redirect_qr_styles FOR EACH ROW EXECUTE FUNCTION public.defer_redirect_qr_asset_cleanup();
CREATE OR REPLACE FUNCTION public.redirect_qr_style_resource(p_actor uuid,p_domain uuid DEFAULT NULL,p_values jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE key text:=coalesce('domain:'||p_domain::text,'workspace');r public.redirect_qr_styles;next_style jsonb;candidate uuid;next_mode text;next_asset uuid;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF p_domain IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_domains WHERE id=p_domain) THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 SELECT * INTO r FROM public.redirect_qr_styles WHERE scope=key FOR UPDATE;
 IF p_values IS NOT NULL AND p_values<>'null'::jsonb THEN
  IF jsonb_typeof(p_values)<>'object' OR NOT(p_values?'version') OR NOT(p_values?'style' OR p_values?'logoMode' OR p_values?'clearLogo') OR p_values-ARRAY['version','style','logoMode','clearLogo']::text[]<>'{}' OR p_values?'style' AND jsonb_typeof(p_values->'style') NOT IN('object','null') OR p_values?'logoMode' AND coalesce(p_values->>'logoMode','') NOT IN('inherit','none','custom') OR p_values?'clearLogo' AND jsonb_typeof(p_values->'clearLogo')<>'boolean' THEN RAISE EXCEPTION 'Provide the current version and appearance overrides' USING ERRCODE='22023';END IF;
  IF r.version IS DISTINCT FROM (p_values->>'version')::uuid THEN RAISE EXCEPTION 'QR style changed; reload before saving' USING ERRCODE='23505';END IF;
  IF jsonb_typeof(p_values->'style')='object' AND (p_values->'style')-ARRAY['dots','border','center','foreground','background']::text[]<>'{}' THEN RAISE EXCEPTION 'Unknown QR appearance field' USING ERRCODE='22023';END IF;
  next_style:=CASE WHEN NOT(p_values?'style') THEN coalesce(r.style,'{}') WHEN p_values->'style'='null'::jsonb THEN '{}'::jsonb ELSE jsonb_strip_nulls(coalesce(r.style,'{}')||(p_values->'style')) END;
  next_asset:=CASE WHEN coalesce((p_values->>'clearLogo')::boolean,false) THEN NULL ELSE r.logo_asset_id END;
  next_mode:=coalesce(p_values->>'logoMode',CASE WHEN coalesce((p_values->>'clearLogo')::boolean,false) THEN 'inherit' ELSE r.logo_mode END,'inherit');
  IF next_mode='custom' AND (next_asset IS NULL OR NOT EXISTS(SELECT FROM public.redirect_qr_assets WHERE id=next_asset AND state='active' AND target_scope=key)) THEN RAISE EXCEPTION 'Upload a logo for this scope before choosing custom' USING ERRCODE='22023';END IF;
  INSERT INTO public.redirect_qr_styles(scope,domain_id,style,logo_mode,logo_asset_id) VALUES(key,p_domain,next_style,next_mode,next_asset)
  ON CONFLICT(scope) DO UPDATE SET style=excluded.style,logo_mode=excluded.logo_mode,logo_asset_id=excluded.logo_asset_id,version=gen_random_uuid(),updated_at=clock_timestamp() RETURNING * INTO r;
  IF NOT public.redirect_qr_style_valid(public.redirect_qr_effective_style()) THEN RAISE EXCEPTION 'Use supported shapes and dark-on-light colors with at least 4.5:1 contrast' USING ERRCODE='22023';END IF;
  FOR candidate IN SELECT domain_id FROM public.redirect_qr_styles WHERE domain_id IS NOT NULL LOOP
   IF NOT public.redirect_qr_style_valid(public.redirect_qr_effective_style(candidate)) THEN RAISE EXCEPTION 'An effective domain QR style is invalid; adjust its overrides or choose stronger contrast' USING ERRCODE='22023';END IF;
  END LOOP;
 END IF;
 RETURN public.redirect_qr_style_json(p_domain);
END $$;
CREATE OR REPLACE FUNCTION public.redirect_qr_styles_for_links(p_ids uuid[],p_token_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[];link public.redirects;link_id uuid;result jsonb:='[]';
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 allowed:=public.redirect_management_scope(p_token_id,'links:read');
 IF p_ids IS NULL OR cardinality(p_ids) NOT BETWEEN 1 AND 100 OR array_position(p_ids,NULL) IS NOT NULL OR cardinality(p_ids)<>(SELECT count(DISTINCT value) FROM unnest(p_ids) value) THEN RAISE EXCEPTION 'Choose 1–100 distinct link IDs' USING ERRCODE='22023';END IF;
 FOREACH link_id IN ARRAY p_ids LOOP
  SELECT * INTO link FROM public.redirects WHERE redirects.id=link_id AND type='SHORT' AND(allowed IS NULL OR redirects.id=ANY(allowed));
  IF link.id IS NULL THEN RAISE EXCEPTION 'Link not found' USING ERRCODE='P0002';END IF;
  result:=result||jsonb_build_array(jsonb_build_object('id',link.id,'style',public.redirect_qr_effective_style(link.domain_id),
   'source',CASE WHEN EXISTS(SELECT FROM public.redirect_qr_styles WHERE domain_id=link.domain_id AND style<>'{}') THEN 'domain' WHEN EXISTS(SELECT FROM public.redirect_qr_styles WHERE scope='workspace' AND style<>'{}') THEN 'workspace' ELSE 'default' END)||public.redirect_qr_effective_logo(link.domain_id));
 END LOOP;
 RETURN result;
END $$;

CREATE FUNCTION public.reserve_redirect_qr_logo(p_actor uuid,p_domain uuid,p_version uuid,p_mime text,p_bytes integer,p_width integer,p_height integer,p_sha256 text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE key text:=coalesce('domain:'||p_domain::text,'workspace');current_version uuid;asset public.redirect_qr_assets;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF p_domain IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_domains WHERE id=p_domain) THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 SELECT version INTO current_version FROM public.redirect_qr_styles WHERE scope=key FOR UPDATE;
 IF current_version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'QR style changed; reload before uploading' USING ERRCODE='23505';END IF;
 IF p_mime IS NULL OR p_mime NOT IN('image/png','image/jpeg') OR p_bytes IS NULL OR p_bytes NOT BETWEEN 1 AND 1500000 OR p_width IS NULL OR p_width NOT BETWEEN 1 AND 1024 OR p_height IS NULL OR p_height NOT BETWEEN 1 AND 1024 OR p_sha256 IS NULL OR p_sha256 !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid logo metadata' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.redirect_qr_assets WHERE requested_by=p_actor AND created_at>clock_timestamp()-interval '1 hour')>=60 OR (SELECT count(*) FROM public.redirect_qr_assets WHERE created_at>clock_timestamp()-interval '1 hour')>=600 OR (SELECT count(*) FROM public.redirect_qr_assets WHERE target_scope=key AND state='pending' AND expires_at>clock_timestamp())>=3 THEN RETURN jsonb_build_object('retryAfter',900);END IF;
 INSERT INTO public.redirect_qr_assets(target_scope,domain_id,requested_by,expected_version,mime,bytes,width,height,sha256) VALUES(key,p_domain,p_actor,p_version,p_mime,p_bytes,p_width,p_height,p_sha256) RETURNING * INTO asset;
 RETURN jsonb_build_object('id',asset.id,'key',asset.id::text||CASE WHEN asset.mime='image/png' THEN '.png' ELSE '.jpg' END);
END $$;
CREATE FUNCTION public.finish_redirect_qr_logo(p_actor uuid,p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE asset public.redirect_qr_assets;current_version uuid;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO asset FROM public.redirect_qr_assets WHERE id=p_id FOR UPDATE;
 IF asset.id IS NULL OR asset.requested_by IS DISTINCT FROM p_actor OR asset.state<>'pending' OR asset.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'Upload reservation expired; reload and upload again' USING ERRCODE='22023';END IF;
 IF asset.target_scope<>coalesce('domain:'||asset.domain_id::text,'workspace') THEN RAISE EXCEPTION 'Upload scope no longer exists' USING ERRCODE='P0002';END IF;
 SELECT version INTO current_version FROM public.redirect_qr_styles WHERE scope=asset.target_scope FOR UPDATE;
 IF current_version IS DISTINCT FROM asset.expected_version THEN RAISE EXCEPTION 'QR style changed; upload was not attached' USING ERRCODE='23505';END IF;
 UPDATE public.redirect_qr_assets SET state='active',next_cleanup_at=clock_timestamp()+interval '1 hour' WHERE id=asset.id;
 INSERT INTO public.redirect_qr_styles(scope,domain_id,logo_mode,logo_asset_id) VALUES(asset.target_scope,asset.domain_id,'custom',asset.id)
 ON CONFLICT(scope) DO UPDATE SET logo_mode='custom',logo_asset_id=excluded.logo_asset_id,version=gen_random_uuid(),updated_at=clock_timestamp();
 RETURN public.redirect_qr_style_json(asset.domain_id);
END $$;
CREATE FUNCTION public.claim_redirect_qr_asset_cleanup(p_limit integer DEFAULT 3) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE asset public.redirect_qr_assets;result jsonb:='[]';
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'Invalid cleanup batch' USING ERRCODE='22023';END IF;
 FOR asset IN SELECT * FROM public.redirect_qr_assets a WHERE next_cleanup_at<=clock_timestamp() AND NOT EXISTS(SELECT FROM public.redirect_qr_styles WHERE logo_asset_id=a.id)
 AND (state IN('active','deleted') OR state='pending' AND expires_at<=clock_timestamp() OR state='deleting' AND lease_until<=clock_timestamp()) ORDER BY next_cleanup_at,id LIMIT p_limit FOR UPDATE SKIP LOCKED LOOP
  UPDATE public.redirect_qr_assets SET state='deleting',lease=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes',attempts=least(attempts+1,1000000) WHERE id=asset.id RETURNING * INTO asset;
  result:=result||jsonb_build_array(jsonb_build_object('id',asset.id,'lease',asset.lease,'key',asset.id::text||CASE WHEN asset.mime='image/png' THEN '.png' ELSE '.jpg' END));
 END LOOP;
 RETURN result;
END $$;
CREATE FUNCTION public.finish_redirect_qr_asset_cleanup(p_id uuid,p_lease uuid,p_success boolean) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE asset public.redirect_qr_assets;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO asset FROM public.redirect_qr_assets WHERE id=p_id FOR UPDATE;
 IF asset.id IS NULL OR asset.state<>'deleting' OR p_lease IS DISTINCT FROM asset.lease OR asset.lease_until<=clock_timestamp() OR EXISTS(SELECT FROM public.redirect_qr_styles WHERE logo_asset_id=p_id) THEN RETURN false;END IF;
 UPDATE public.redirect_qr_assets SET state=CASE WHEN p_success IS TRUE THEN 'deleted' ELSE 'deleting' END,
  last_deleted_at=CASE WHEN p_success IS TRUE THEN clock_timestamp() ELSE last_deleted_at END,
  next_cleanup_at=clock_timestamp()+CASE WHEN p_success IS TRUE THEN CASE WHEN asset.last_deleted_at IS NULL THEN interval '1 day' ELSE interval '30 days' END ELSE make_interval(secs=>least(3600,30*power(2,least(asset.attempts,6))::integer)) END,
  lease=NULL,lease_until=CASE WHEN p_success IS TRUE THEN NULL ELSE clock_timestamp() END,
  attempts=CASE WHEN p_success IS TRUE THEN 0 ELSE attempts END,last_error=CASE WHEN p_success IS TRUE THEN NULL ELSE 'Storage cleanup failed; retry scheduled' END WHERE id=p_id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.redirect_qr_asset_json(uuid),public.redirect_qr_effective_logo(uuid),public.redirect_qr_style_json(uuid),public.defer_redirect_qr_asset_cleanup(),public.reserve_redirect_qr_logo(uuid,uuid,uuid,text,integer,integer,integer,text),public.finish_redirect_qr_logo(uuid,uuid),public.claim_redirect_qr_asset_cleanup(integer),public.finish_redirect_qr_asset_cleanup(uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_qr_asset_json(uuid),public.redirect_qr_effective_logo(uuid),public.redirect_qr_style_json(uuid),public.defer_redirect_qr_asset_cleanup(),public.reserve_redirect_qr_logo(uuid,uuid,uuid,text,integer,integer,integer,text),public.finish_redirect_qr_logo(uuid,uuid),public.claim_redirect_qr_asset_cleanup(integer),public.finish_redirect_qr_asset_cleanup(uuid,uuid,boolean) TO service_role;

DO $migration$
DECLARE command text;
BEGIN
 IF to_regprocedure('cron.schedule(text,text,text)') IS NULL THEN RETURN;END IF;
 command:=$cron$
 SELECT net.http_post(
  url:=rtrim(url.decrypted_secret,'/')||'/functions/v1/redirect-qr-assets-cleanup',
  headers:=jsonb_build_object('Content-Type','application/json','x-internal-secret',secret.decrypted_secret),body:='{}'::jsonb,timeout_milliseconds:=60000)
 FROM vault.decrypted_secrets url CROSS JOIN vault.decrypted_secrets secret
 WHERE url.name='supabase_url' AND secret.name='internal_invoke_secret'
  AND url.decrypted_secret ~ '^https://[a-z0-9-]+\.supabase\.co$' AND length(secret.decrypted_secret)>0 LIMIT 1;
 $cron$;
 EXECUTE 'SELECT cron.schedule($1,$2,$3)' USING 'redirect-qr-assets-cleanup','* * * * *',command;
END $migration$;
