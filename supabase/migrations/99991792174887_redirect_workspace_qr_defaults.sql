-- Each workspace owns its default primary domain and workspace QR appearance.
-- Public QR tokens retain their legacy activation guard; no new tenant is enabled.
ALTER TABLE public.redirect_domain_preferences DROP CONSTRAINT redirect_domain_preferences_pkey, ADD CONSTRAINT redirect_domain_preferences_pkey PRIMARY KEY(workspace_id,singleton);
ALTER TABLE public.redirect_qr_styles DROP CONSTRAINT redirect_qr_styles_pkey, ADD CONSTRAINT redirect_qr_styles_pkey PRIMARY KEY(workspace_id,scope);

CREATE OR REPLACE FUNCTION redirect_internal.qr_style_for_workspace(p_workspace uuid,p_domain uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
 SELECT '{"dots":"square","border":"square","center":"square","foreground":"#111111","background":"#ffffff"}'::jsonb
 ||coalesce((SELECT style FROM public.redirect_qr_styles WHERE workspace_id=p_workspace AND scope='workspace'),'{}')
 ||coalesce((SELECT style FROM public.redirect_qr_styles WHERE workspace_id=p_workspace AND domain_id=p_domain),'{}');
$function$;

CREATE OR REPLACE FUNCTION redirect_internal.qr_logo_for_workspace(p_workspace uuid,p_domain uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=p_workspace;r public.redirect_qr_styles;source text:='domain';asset jsonb;
BEGIN
 IF p_domain IS NOT NULL THEN SELECT * INTO r FROM public.redirect_qr_styles WHERE workspace_id=selected_workspace AND domain_id=p_domain;END IF;
 IF r.scope IS NULL OR r.logo_mode='inherit' THEN SELECT * INTO r FROM public.redirect_qr_styles WHERE workspace_id=selected_workspace AND scope='workspace';source:='workspace';END IF;
 IF r.logo_mode='none' THEN RETURN jsonb_build_object('effectiveLogo',NULL,'logoSource','hidden');END IF;
 IF r.logo_mode='custom' THEN
  asset:=redirect_internal.qr_asset_for_workspace(p_workspace,r.logo_asset_id);
  IF asset IS NULL THEN RAISE EXCEPTION 'Saved QR logo is unavailable; review owner logo settings' USING ERRCODE='22023';END IF;
  RETURN jsonb_build_object('effectiveLogo',asset,'logoSource',source);
 END IF;
 RETURN jsonb_build_object('effectiveLogo',NULL,'logoSource','default');
END $function$;

REVOKE ALL ON FUNCTION redirect_internal.qr_style_for_workspace(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION redirect_internal.qr_style_for_workspace(uuid,uuid) TO service_role;

REVOKE ALL ON FUNCTION redirect_internal.qr_logo_for_workspace(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION redirect_internal.qr_logo_for_workspace(uuid,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.redirect_qr_effective_style(p_domain uuid DEFAULT NULL::uuid) RETURNS jsonb LANGUAGE sql VOLATILE SET search_path=public,pg_temp AS $$
 SELECT redirect_internal.qr_style_for_workspace(public.redirect_request_workspace(),p_domain);
$$;

CREATE OR REPLACE FUNCTION public.redirect_qr_effective_logo(p_domain uuid DEFAULT NULL::uuid) RETURNS jsonb LANGUAGE sql VOLATILE SET search_path=public,pg_temp AS $$
 SELECT redirect_internal.qr_logo_for_workspace(public.redirect_request_workspace(),p_domain);
$$;

CREATE OR REPLACE FUNCTION public.redirect_qr_style_resource(p_actor uuid, p_domain uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor);key text:=coalesce('domain:'||p_domain::text,'workspace');r public.redirect_qr_styles;next_style jsonb;candidate uuid;next_mode text;next_asset uuid;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF p_domain IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_domain) THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 SELECT * INTO r FROM public.redirect_qr_styles WHERE workspace_id=selected_workspace AND scope=key FOR UPDATE;
 IF p_values IS NOT NULL AND p_values<>'null'::jsonb THEN
  IF jsonb_typeof(p_values)<>'object' OR NOT(p_values?'version') OR NOT(p_values?'style' OR p_values?'logoMode' OR p_values?'clearLogo') OR p_values-ARRAY['version','style','logoMode','clearLogo']::text[]<>'{}' OR p_values?'style' AND jsonb_typeof(p_values->'style') NOT IN('object','null') OR p_values?'logoMode' AND coalesce(p_values->>'logoMode','') NOT IN('inherit','none','custom') OR p_values?'clearLogo' AND jsonb_typeof(p_values->'clearLogo')<>'boolean' THEN RAISE EXCEPTION 'Provide the current version and appearance overrides' USING ERRCODE='22023';END IF;
  IF r.version IS DISTINCT FROM (p_values->>'version')::uuid THEN RAISE EXCEPTION 'QR style changed; reload before saving' USING ERRCODE='23505';END IF;
  IF jsonb_typeof(p_values->'style')='object' AND (p_values->'style')-ARRAY['dots','border','center','foreground','background']::text[]<>'{}' THEN RAISE EXCEPTION 'Unknown QR appearance field' USING ERRCODE='22023';END IF;
  next_style:=CASE WHEN NOT(p_values?'style') THEN coalesce(r.style,'{}') WHEN p_values->'style'='null'::jsonb THEN '{}'::jsonb ELSE jsonb_strip_nulls(coalesce(r.style,'{}')||(p_values->'style')) END;
  next_asset:=CASE WHEN coalesce((p_values->>'clearLogo')::boolean,false) THEN NULL ELSE r.logo_asset_id END;
  next_mode:=coalesce(p_values->>'logoMode',CASE WHEN coalesce((p_values->>'clearLogo')::boolean,false) THEN 'inherit' ELSE r.logo_mode END,'inherit');
  IF next_mode='custom' AND (next_asset IS NULL OR NOT EXISTS(SELECT FROM public.redirect_qr_assets WHERE workspace_id=selected_workspace AND id=next_asset AND state='active' AND target_scope=key)) THEN RAISE EXCEPTION 'Upload a logo for this scope before choosing custom' USING ERRCODE='22023';END IF;
  INSERT INTO public.redirect_qr_styles(workspace_id,scope,domain_id,style,logo_mode,logo_asset_id) VALUES(selected_workspace,key,p_domain,next_style,next_mode,next_asset)
  ON CONFLICT(workspace_id,scope) DO UPDATE SET style=excluded.style,logo_mode=excluded.logo_mode,logo_asset_id=excluded.logo_asset_id,version=gen_random_uuid(),updated_at=clock_timestamp() WHERE redirect_qr_styles.workspace_id=selected_workspace RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR style is unavailable in this workspace' USING ERRCODE='23505';END IF;
  IF NOT public.redirect_qr_style_valid(public.redirect_qr_effective_style()) THEN RAISE EXCEPTION 'Use supported shapes and dark-on-light colors with at least 4.5:1 contrast' USING ERRCODE='22023';END IF;
  FOR candidate IN SELECT domain_id FROM public.redirect_qr_styles WHERE workspace_id=selected_workspace AND domain_id IS NOT NULL LOOP
   IF NOT public.redirect_qr_style_valid(public.redirect_qr_effective_style(candidate)) THEN RAISE EXCEPTION 'An effective domain QR style is invalid; adjust its overrides or choose stronger contrast' USING ERRCODE='22023';END IF;
  END LOOP;
 END IF;
 RETURN public.redirect_qr_style_json(p_domain);
END $function$;

CREATE OR REPLACE FUNCTION public.reserve_redirect_qr_logo(p_actor uuid, p_domain uuid, p_version uuid, p_mime text, p_bytes integer, p_width integer, p_height integer, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor);key text:=coalesce('domain:'||p_domain::text,'workspace');current_version uuid;asset public.redirect_qr_assets;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 IF p_domain IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=p_domain) THEN RAISE EXCEPTION 'Domain not found' USING ERRCODE='P0002';END IF;
 SELECT version INTO current_version FROM public.redirect_qr_styles WHERE workspace_id=selected_workspace AND scope=key FOR UPDATE;
 IF current_version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'QR style changed; reload before uploading' USING ERRCODE='23505';END IF;
 IF p_mime IS NULL OR p_mime NOT IN('image/png','image/jpeg') OR p_bytes IS NULL OR p_bytes NOT BETWEEN 1 AND 1500000 OR p_width IS NULL OR p_width NOT BETWEEN 1 AND 1024 OR p_height IS NULL OR p_height NOT BETWEEN 1 AND 1024 OR p_sha256 IS NULL OR p_sha256 !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid logo metadata' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.redirect_qr_assets WHERE requested_by=p_actor AND created_at>clock_timestamp()-interval '1 hour')>=60 OR (SELECT count(*) FROM public.redirect_qr_assets WHERE created_at>clock_timestamp()-interval '1 hour')>=600 OR (SELECT count(*) FROM public.redirect_qr_assets WHERE workspace_id=selected_workspace AND target_scope=key AND state='pending' AND expires_at>clock_timestamp())>=3 THEN RETURN jsonb_build_object('retryAfter',900);END IF;
 INSERT INTO public.redirect_qr_assets(workspace_id,target_scope,domain_id,requested_by,expected_version,mime,bytes,width,height,sha256) VALUES(selected_workspace,key,p_domain,p_actor,p_version,p_mime,p_bytes,p_width,p_height,p_sha256) RETURNING * INTO asset;
 RETURN jsonb_build_object('id',asset.id,'key',asset.id::text||CASE WHEN asset.mime='image/png' THEN '.png' ELSE '.jpg' END);
END $function$;

CREATE OR REPLACE FUNCTION public.finish_redirect_qr_logo(p_actor uuid, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace(p_actor);asset public.redirect_qr_assets;current_version uuid;
BEGIN
 PERFORM public.redirect_domain_actor(p_actor);
 SELECT * INTO asset FROM public.redirect_qr_assets WHERE workspace_id=selected_workspace AND id=p_id FOR UPDATE;
 IF asset.id IS NULL OR asset.requested_by IS DISTINCT FROM p_actor OR asset.state<>'pending' OR asset.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'Upload reservation expired; reload and upload again' USING ERRCODE='22023';END IF;
 IF asset.target_scope<>coalesce('domain:'||asset.domain_id::text,'workspace') THEN RAISE EXCEPTION 'Upload scope no longer exists' USING ERRCODE='P0002';END IF;
 SELECT version INTO current_version FROM public.redirect_qr_styles WHERE workspace_id=selected_workspace AND scope=asset.target_scope FOR UPDATE;
 IF current_version IS DISTINCT FROM asset.expected_version THEN RAISE EXCEPTION 'QR style changed; upload was not attached' USING ERRCODE='23505';END IF;
 UPDATE public.redirect_qr_assets SET state='active',next_cleanup_at=clock_timestamp()+interval '1 hour' WHERE workspace_id=selected_workspace AND id=asset.id;
 INSERT INTO public.redirect_qr_styles(workspace_id,scope,domain_id,logo_mode,logo_asset_id) VALUES(selected_workspace,asset.target_scope,asset.domain_id,'custom',asset.id)
 ON CONFLICT(workspace_id,scope) DO UPDATE SET logo_mode='custom',logo_asset_id=excluded.logo_asset_id,version=gen_random_uuid(),updated_at=clock_timestamp() WHERE redirect_qr_styles.workspace_id=selected_workspace;
 IF NOT FOUND THEN RAISE EXCEPTION 'QR style is unavailable in this workspace' USING ERRCODE='23505';END IF;
 RETURN public.redirect_qr_style_json(asset.domain_id);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_public_qr_image(p_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r public.redirect_qr_image_links;allowed uuid[];link public.redirects;url text;style jsonb;logo jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT * INTO r FROM public.redirect_qr_image_links WHERE workspace_id='58aa4340-8f21-4b7f-9a10-90be2da89c01'::uuid AND token_hash=p_hash AND publication_state='published' AND revoked_at IS NULL AND(expires_at IS NULL OR expires_at>clock_timestamp()) FOR SHARE;
 IF r.id IS NULL THEN RETURN NULL;END IF;
 BEGIN
  IF r.creator_user_id IS NOT NULL THEN
   PERFORM 1 FROM public.user_roles WHERE user_id=r.creator_user_id AND role='admin' FOR SHARE;
   IF NOT FOUND THEN RETURN NULL;END IF;
  ELSE allowed:=public.redirect_management_scope(coalesce(r.creator_key_id,r.creator_member_id),'links:read');END IF;
 EXCEPTION WHEN insufficient_privilege THEN RETURN NULL;
 END;
 IF r.link_id IS NOT NULL THEN
  SELECT * INTO link FROM public.redirects WHERE workspace_id=r.workspace_id AND id=r.link_id AND type='SHORT' AND(allowed IS NULL OR id=ANY(allowed));
  IF link.id IS NULL THEN RETURN NULL;END IF;
  url:=CASE WHEN link.domain_id IS NULL THEN 'https://queer.guide/go/'||link.slug ELSE 'https://'||link.domain_hostname||'/'||CASE WHEN link.is_domain_root THEN '' ELSE link.slug END END;
 ELSE url:=r.encoded_url;END IF;
 IF r.purpose='install' THEN url:=url||'?qg_handoff=install'||CASE WHEN r.entry_query<>'' THEN '&'||r.entry_query ELSE '' END;END IF;
 style:=redirect_internal.qr_style_for_workspace(r.workspace_id,link.domain_id)||r.style;
 IF NOT public.redirect_qr_style_valid(style) THEN RAISE EXCEPTION 'Saved QR branding is invalid; review its settings' USING ERRCODE='22023';END IF;
 logo:=CASE WHEN r.logo_mode='none' THEN jsonb_build_object('effectiveLogo',NULL,'logoSource','hidden') WHEN r.logo_mode='custom' THEN jsonb_build_object('effectiveLogo',redirect_internal.qr_asset_for_workspace(r.workspace_id,r.logo_asset_id),'logoSource','custom') ELSE redirect_internal.qr_logo_for_workspace(r.workspace_id,link.domain_id) END;
 IF r.logo_mode='custom' AND(logo->'effectiveLogo'='null'::jsonb OR logo->'effectiveLogo' IS NULL) THEN RAISE EXCEPTION 'Custom QR artwork is unavailable' USING ERRCODE='22023';END IF;
 RETURN jsonb_build_object('url',url,'tracked',r.link_id IS NOT NULL,'style',style)||logo;
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
  IF pref.singleton IS NULL THEN
   INSERT INTO public.redirect_domain_preferences(workspace_id,singleton,domain_id) VALUES(selected_workspace,true,(p_values->>'domainId')::uuid) RETURNING * INTO pref;
  ELSE
   UPDATE public.redirect_domain_preferences SET domain_id=(p_values->>'domainId')::uuid WHERE workspace_id=selected_workspace AND singleton RETURNING * INTO pref;
  END IF;
 END IF;
 SELECT hostname INTO host FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=pref.domain_id;
 RETURN jsonb_build_object('domainId',pref.domain_id,'hostname',host,'version',pref.version,'ready',pref.domain_id IS NULL OR(public.redirect_public_domain(host,true) IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_domains WHERE workspace_id=selected_workspace AND id=pref.domain_id AND archived)));
END $function$;
