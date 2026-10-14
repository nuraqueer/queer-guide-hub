-- Custom image artwork is a separate publication asset, never a workspace preference.
ALTER TABLE public.redirect_qr_image_links DROP CONSTRAINT redirect_qr_image_links_logo_mode_check,
 ADD CONSTRAINT redirect_qr_image_links_logo_mode_check CHECK(logo_mode IN('inherit','none','custom')),
 ADD COLUMN publication_state text NOT NULL DEFAULT 'published' CHECK(publication_state IN('pending','published')),
 ADD COLUMN draft_expires_at timestamptz,
 ADD COLUMN logo_asset_id uuid REFERENCES public.redirect_qr_assets(id) ON DELETE RESTRICT,
 ADD CONSTRAINT redirect_qr_image_draft_shape CHECK((publication_state='pending')=(draft_expires_at IS NOT NULL) AND(publication_state<>'pending' OR logo_mode='custom' AND logo_asset_id IS NULL)),
 ADD CONSTRAINT redirect_qr_image_published_artwork CHECK(logo_asset_id IS NULL OR logo_mode='custom'),
 ADD CONSTRAINT redirect_qr_image_custom_asset CHECK(publication_state<>'published' OR logo_mode<>'custom' OR revoked_at IS NOT NULL OR logo_asset_id IS NOT NULL);
ALTER TABLE public.redirect_qr_assets ADD COLUMN qr_image_id uuid REFERENCES public.redirect_qr_image_links(id) ON DELETE SET NULL,
 ADD COLUMN requested_principal text;
CREATE INDEX redirect_qr_image_artwork_reference ON public.redirect_qr_image_links(logo_asset_id) WHERE logo_asset_id IS NOT NULL;
CREATE INDEX redirect_qr_image_draft_retention ON public.redirect_qr_image_links(draft_expires_at) WHERE publication_state='pending';
CREATE INDEX redirect_qr_asset_image_reference ON public.redirect_qr_assets(qr_image_id) WHERE qr_image_id IS NOT NULL;
CREATE INDEX redirect_qr_asset_principal_budget ON public.redirect_qr_assets(requested_principal,created_at) WHERE requested_principal IS NOT NULL;
CREATE FUNCTION public.release_redirect_qr_image_artwork() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
 IF OLD.logo_asset_id IS NOT NULL AND(TG_OP='DELETE' OR NEW.revoked_at IS NOT NULL OR NEW.logo_asset_id IS DISTINCT FROM OLD.logo_asset_id) THEN
  UPDATE public.redirect_qr_assets SET next_cleanup_at=clock_timestamp()+interval '1 hour' WHERE id=OLD.logo_asset_id AND state='active';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;
 IF NEW.revoked_at IS NOT NULL THEN NEW.logo_asset_id:=NULL;END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER release_redirect_qr_image_artwork BEFORE UPDATE OR DELETE ON public.redirect_qr_image_links FOR EACH ROW EXECUTE FUNCTION public.release_redirect_qr_image_artwork();

CREATE OR REPLACE FUNCTION public.redirect_qr_image_link_json(p_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',id,'label',label,'linkId',link_id,'version',version,'createdAt',created_at,'expiresAt',expires_at,'revokedAt',revoked_at,'style',style,'logoMode',logo_mode,'state',publication_state,'logoAsset',public.redirect_qr_asset_json(logo_asset_id))
 FROM public.redirect_qr_image_links WHERE id=p_id;
$$;
CREATE OR REPLACE FUNCTION public.redirect_qr_image_resource(p_action text,p_actor uuid DEFAULT NULL,p_principal uuid DEFAULT NULL,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT NULL,p_hash text DEFAULT NULL,p_limit integer DEFAULT 100,p_after uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE v_principal_key text;member_id uuid;key_id uuid;allowed uuid[];link public.redirects;r public.redirect_qr_image_links;effective jsonb;overrides jsonb;url text;expires timestamptz;rows jsonb;next_id uuid;owner boolean:=p_principal IS NULL;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 IF p_action NOT IN('create','list','revoke') OR p_action IS NULL THEN RAISE EXCEPTION 'Invalid QR image action' USING ERRCODE='22023';END IF;
 IF p_action='list' THEN PERFORM pg_advisory_xact_lock_shared(471983093);ELSE PERFORM pg_advisory_xact_lock(471983093);END IF;
 IF owner THEN
  PERFORM 1 FROM public.user_roles WHERE user_id=p_actor AND role='admin' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Workspace owner access required' USING ERRCODE='42501';END IF;
  v_principal_key:='owner:'||p_actor::text;
 ELSE
  allowed:=public.redirect_management_scope(p_principal,'links:read');
  SELECT id INTO key_id FROM public.redirect_api_tokens WHERE id=p_principal;
  IF key_id IS NULL THEN
   SELECT id INTO member_id FROM public.redirect_workspace_members WHERE id=p_principal AND kind='user' AND user_id=p_actor AND active;
   IF member_id IS NULL THEN RAISE EXCEPTION 'Account does not match membership' USING ERRCODE='42501';END IF;
  END IF;
  v_principal_key:=CASE WHEN key_id IS NOT NULL THEN 'key:' ELSE 'member:' END||p_principal::text;
 END IF;
 IF p_action='list' THEN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid image page' USING ERRCODE='22023';END IF;
  SELECT coalesce(jsonb_agg(public.redirect_qr_image_link_json(id) ORDER BY id),'[]') INTO rows
  FROM(SELECT id FROM public.redirect_qr_image_links q WHERE(owner OR q.principal_key=v_principal_key) AND(p_after IS NULL OR id>p_after) ORDER BY id LIMIT p_limit) page;
  IF jsonb_array_length(rows)=p_limit THEN
   next_id:=(rows->(p_limit-1)->>'id')::uuid;
   IF NOT EXISTS(SELECT FROM public.redirect_qr_image_links q WHERE(owner OR q.principal_key=v_principal_key) AND id>next_id) THEN next_id:=NULL;END IF;
  END IF;
  RETURN jsonb_build_object('data',rows,'nextCursor',next_id);
 END IF;
 IF p_action='revoke' THEN
  IF p_id IS NULL OR p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR p_values-ARRAY['version']::text[]<>'{}' OR NOT(p_values?'version') THEN RAISE EXCEPTION 'Provide the current image version' USING ERRCODE='22023';END IF;
  SELECT * INTO r FROM public.redirect_qr_image_links q WHERE id=p_id AND(owner OR q.principal_key=v_principal_key) FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'QR image link not found' USING ERRCODE='P0002';END IF;
  IF r.version IS DISTINCT FROM (p_values->>'version')::uuid THEN RAISE EXCEPTION 'QR image link changed; reload before revoking' USING ERRCODE='23505';END IF;
  IF r.revoked_at IS NULL THEN UPDATE public.redirect_qr_image_links SET revoked_at=clock_timestamp(),version=gen_random_uuid() WHERE id=r.id;END IF;
  RETURN public.redirect_qr_image_link_json(r.id);
 END IF;
 IF p_hash IS NULL OR p_hash !~ '^[a-f0-9]{64}$' OR p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR p_values-ARRAY['linkId','url','label','expiresAt','style','logoMode']::text[]<>'{}' OR ((p_values?'linkId')=(p_values?'url')) THEN RAISE EXCEPTION 'Choose a link or an explicit URL' USING ERRCODE='22023';END IF;
 IF p_values?'linkId' THEN
  SELECT * INTO link FROM public.redirects WHERE id=(p_values->>'linkId')::uuid AND type='SHORT' AND(allowed IS NULL OR id=ANY(allowed));
  IF link.id IS NULL THEN RAISE EXCEPTION 'Link not found' USING ERRCODE='P0002';END IF;
 ELSE
  IF NOT owner THEN RAISE EXCEPTION 'Explicit URL images require workspace owner access' USING ERRCODE='42501';END IF;
  url:=p_values->>'url';
  IF url IS NULL OR octet_length(url)>2048 OR url ~ '[[:space:][:cntrl:]]' OR url !~ '^https?://[^/@?#[:space:]]+([/?#]|$)' THEN RAISE EXCEPTION 'Provide an HTTP(S) URL without credentials up to 2048 bytes' USING ERRCODE='22023';END IF;
 END IF;
 IF p_values?'expiresAt' AND p_values->'expiresAt'<>'null'::jsonb THEN
  expires:=(p_values->>'expiresAt')::timestamptz;
  IF NOT isfinite(expires) OR expires<=clock_timestamp() OR expires>clock_timestamp()+interval '366 days' THEN RAISE EXCEPTION 'Choose expiry within one year or no expiry' USING ERRCODE='22023';END IF;
 END IF;
 IF p_values?'label' AND(jsonb_typeof(p_values->'label')<>'string' OR length(btrim(p_values->>'label')) NOT BETWEEN 1 AND 100) OR p_values?'logoMode' AND coalesce(p_values->>'logoMode','') NOT IN('inherit','none','custom') OR p_values?'style' AND jsonb_typeof(p_values->'style') NOT IN('object','null') THEN RAISE EXCEPTION 'Invalid image branding fields' USING ERRCODE='22023';END IF;
 IF coalesce(nullif(p_values->'style','null'::jsonb),'{}')-ARRAY['dots','border','center','foreground','background']::text[]<>'{}' THEN RAISE EXCEPTION 'Unknown image appearance field' USING ERRCODE='22023';END IF;
 overrides:=jsonb_strip_nulls(coalesce(nullif(p_values->'style','null'::jsonb),'{}'));
 effective:=public.redirect_qr_effective_style(link.domain_id)||overrides;
 IF NOT public.redirect_qr_style_valid(effective) THEN RAISE EXCEPTION 'Use supported shapes and dark-on-light colors with at least 4.5:1 contrast' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.redirect_qr_image_links q WHERE q.principal_key=v_principal_key AND revoked_at IS NULL AND(publication_state='published' OR draft_expires_at>clock_timestamp()) AND(expires_at IS NULL OR expires_at>clock_timestamp()))>=100 OR
 (SELECT count(*) FROM public.redirect_qr_image_creation_log q WHERE q.principal_key=v_principal_key AND created_at>clock_timestamp()-interval '1 hour')>=60 OR
 (SELECT count(*) FROM public.redirect_qr_image_creation_log WHERE created_at>clock_timestamp()-interval '1 hour')>=600 THEN
  RETURN jsonb_build_object('retryAfter',3600);
 END IF;
 INSERT INTO public.redirect_qr_image_links(token_hash,creator_user_id,creator_member_id,creator_key_id,principal_key,link_id,encoded_url,label,style,logo_mode,expires_at,publication_state,draft_expires_at)
 VALUES(p_hash,CASE WHEN owner THEN p_actor END,member_id,key_id,v_principal_key,link.id,url,coalesce(btrim(p_values->>'label'),'QR image'),overrides,coalesce(p_values->>'logoMode','inherit'),expires,CASE WHEN p_values->>'logoMode'='custom' THEN 'pending' ELSE 'published' END,CASE WHEN p_values->>'logoMode'='custom' THEN clock_timestamp()+interval '15 minutes' END)
 RETURNING * INTO r;
 RETURN public.redirect_qr_image_link_json(r.id);
END $$;
CREATE OR REPLACE FUNCTION public.redirect_public_qr_image(p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_qr_image_links;allowed uuid[];link public.redirects;url text;style jsonb;logo jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT * INTO r FROM public.redirect_qr_image_links WHERE token_hash=p_hash AND publication_state='published' AND revoked_at IS NULL AND(expires_at IS NULL OR expires_at>clock_timestamp()) FOR SHARE;
 IF r.id IS NULL THEN RETURN NULL;END IF;
 BEGIN
  IF r.creator_user_id IS NOT NULL THEN
   PERFORM 1 FROM public.user_roles WHERE user_id=r.creator_user_id AND role='admin' FOR SHARE;
   IF NOT FOUND THEN RETURN NULL;END IF;
  ELSE allowed:=public.redirect_management_scope(coalesce(r.creator_key_id,r.creator_member_id),'links:read');END IF;
 EXCEPTION WHEN insufficient_privilege THEN RETURN NULL;
 END;
 IF r.link_id IS NOT NULL THEN
  SELECT * INTO link FROM public.redirects WHERE id=r.link_id AND type='SHORT' AND(allowed IS NULL OR id=ANY(allowed));
  IF link.id IS NULL THEN RETURN NULL;END IF;
  url:=public.redirect_management_link(link.id)->>'shortUrl';
 ELSE url:=r.encoded_url;END IF;
 style:=public.redirect_qr_effective_style(link.domain_id)||r.style;
 IF NOT public.redirect_qr_style_valid(style) THEN RAISE EXCEPTION 'Saved QR branding is invalid; review its settings' USING ERRCODE='22023';END IF;
 logo:=CASE WHEN r.logo_mode='none' THEN jsonb_build_object('effectiveLogo',NULL,'logoSource','hidden') WHEN r.logo_mode='custom' THEN jsonb_build_object('effectiveLogo',public.redirect_qr_asset_json(r.logo_asset_id),'logoSource','custom') ELSE public.redirect_qr_effective_logo(link.domain_id) END;
 IF r.logo_mode='custom' AND(logo->'effectiveLogo'='null'::jsonb OR logo->'effectiveLogo' IS NULL) THEN RAISE EXCEPTION 'Custom QR artwork is unavailable' USING ERRCODE='22023';END IF;
 RETURN jsonb_build_object('url',url,'tracked',r.link_id IS NOT NULL,'style',style)||logo;
END $$;
CREATE OR REPLACE FUNCTION public.prune_redirect_qr_image_history(p_limit integer DEFAULT 1000) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE budget_before timestamptz:=clock_timestamp()-interval '2 days';draft_before timestamptz:=clock_timestamp()-interval '1 day';image_before timestamptz:=clock_timestamp()-interval '90 days';events integer;images integer;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'Invalid retention batch' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 DELETE FROM public.redirect_qr_image_creation_log q USING(SELECT id FROM public.redirect_qr_image_creation_log WHERE created_at<budget_before ORDER BY created_at,id LIMIT p_limit FOR UPDATE SKIP LOCKED) old WHERE q.id=old.id;
 GET DIAGNOSTICS events=ROW_COUNT;
 DELETE FROM public.redirect_qr_image_links q USING(SELECT id FROM public.redirect_qr_image_links WHERE least(revoked_at,expires_at)<image_before OR publication_state='pending' AND draft_expires_at<draft_before ORDER BY least(revoked_at,expires_at),id LIMIT p_limit FOR UPDATE SKIP LOCKED) old WHERE q.id=old.id;
 GET DIAGNOSTICS images=ROW_COUNT;
 RETURN jsonb_build_object('events',events,'images',images);
END $$;
CREATE OR REPLACE FUNCTION public.claim_redirect_qr_asset_cleanup(p_limit integer DEFAULT 3) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE asset public.redirect_qr_assets;result jsonb:='[]';
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'Invalid cleanup batch' USING ERRCODE='22023';END IF;
 FOR asset IN SELECT * FROM public.redirect_qr_assets a WHERE next_cleanup_at<=clock_timestamp() AND NOT EXISTS(SELECT FROM public.redirect_qr_styles WHERE logo_asset_id=a.id)
 AND NOT EXISTS(SELECT FROM public.redirect_qr_image_links WHERE logo_asset_id=a.id)
 AND (state IN('active','deleted') OR state='pending' AND expires_at<=clock_timestamp() OR state='deleting' AND lease_until<=clock_timestamp()) ORDER BY next_cleanup_at,id LIMIT p_limit FOR UPDATE SKIP LOCKED LOOP
  UPDATE public.redirect_qr_assets SET state='deleting',lease=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes',attempts=least(attempts+1,1000000) WHERE id=asset.id RETURNING * INTO asset;
  result:=result||jsonb_build_array(jsonb_build_object('id',asset.id,'lease',asset.lease,'key',asset.id::text||CASE WHEN asset.mime='image/png' THEN '.png' ELSE '.jpg' END));
 END LOOP;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.finish_redirect_qr_asset_cleanup(p_id uuid,p_lease uuid,p_success boolean) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE asset public.redirect_qr_assets;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 SELECT * INTO asset FROM public.redirect_qr_assets WHERE id=p_id FOR UPDATE;
 IF asset.id IS NULL OR asset.state<>'deleting' OR p_lease IS DISTINCT FROM asset.lease OR asset.lease_until<=clock_timestamp() OR EXISTS(SELECT FROM public.redirect_qr_styles WHERE logo_asset_id=p_id) OR EXISTS(SELECT FROM public.redirect_qr_image_links WHERE logo_asset_id=p_id) THEN RETURN false;END IF;
 UPDATE public.redirect_qr_assets SET state=CASE WHEN p_success IS TRUE THEN 'deleted' ELSE 'deleting' END,
  last_deleted_at=CASE WHEN p_success IS TRUE THEN clock_timestamp() ELSE last_deleted_at END,
  next_cleanup_at=clock_timestamp()+CASE WHEN p_success IS TRUE THEN CASE WHEN asset.last_deleted_at IS NULL THEN interval '1 day' ELSE interval '30 days' END ELSE make_interval(secs=>least(3600,30*power(2,least(asset.attempts,6))::integer)) END,
  lease=NULL,lease_until=CASE WHEN p_success IS TRUE THEN NULL ELSE clock_timestamp() END,
  attempts=CASE WHEN p_success IS TRUE THEN 0 ELSE attempts END,last_error=CASE WHEN p_success IS TRUE THEN NULL ELSE 'Storage cleanup failed; retry scheduled' END WHERE id=p_id;
 RETURN true;
END $$;
CREATE FUNCTION public.redirect_qr_image_draft(p_actor uuid,p_principal uuid,p_image uuid) RETURNS public.redirect_qr_image_links
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_qr_image_links;allowed uuid[];key text;is_key boolean;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 IF p_principal IS NULL THEN
  PERFORM 1 FROM public.user_roles WHERE user_id=p_actor AND role='admin' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Workspace owner access required' USING ERRCODE='42501';END IF;
  key:='owner:'||p_actor::text;
 ELSE
  allowed:=public.redirect_management_scope(p_principal,'links:read');
  is_key:=EXISTS(SELECT FROM public.redirect_api_tokens WHERE id=p_principal);
  IF NOT is_key AND NOT EXISTS(SELECT FROM public.redirect_workspace_members WHERE id=p_principal AND kind='user' AND active AND user_id=p_actor) THEN RAISE EXCEPTION 'Account does not match membership' USING ERRCODE='42501';END IF;
  key:=CASE WHEN is_key THEN 'key:' ELSE 'member:' END||p_principal::text;
 END IF;
 SELECT * INTO r FROM public.redirect_qr_image_links WHERE id=p_image AND principal_key=key AND revoked_at IS NULL AND(expires_at IS NULL OR expires_at>clock_timestamp()) FOR UPDATE;
 IF r.id IS NULL OR r.publication_state<>'pending' OR r.draft_expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'QR image draft expired or is unavailable' USING ERRCODE='P0002';END IF;
 IF r.link_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirects WHERE id=r.link_id AND type='SHORT' AND(allowed IS NULL OR id=ANY(allowed))) THEN RAISE EXCEPTION 'Link is no longer accessible' USING ERRCODE='42501';END IF;
 RETURN r;
END $$;
CREATE FUNCTION public.reserve_redirect_qr_image_logo(p_actor uuid,p_principal uuid,p_image uuid,p_version uuid,p_mime text,p_bytes integer,p_width integer,p_height integer,p_sha256 text) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_qr_image_links;asset public.redirect_qr_assets;domain uuid;style jsonb;url text;
BEGIN
 r:=public.redirect_qr_image_draft(p_actor,p_principal,p_image);
 IF r.version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'QR image draft changed; upload was not reserved' USING ERRCODE='23505';END IF;
 IF p_mime IS NULL OR p_mime NOT IN('image/png','image/jpeg') OR p_bytes IS NULL OR p_bytes NOT BETWEEN 1 AND 1500000 OR p_width IS NULL OR p_width NOT BETWEEN 1 AND 1024 OR p_height IS NULL OR p_height NOT BETWEEN 1 AND 1024 OR p_sha256 IS NULL OR p_sha256 !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid logo metadata' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.redirect_qr_assets WHERE requested_principal=r.principal_key AND created_at>clock_timestamp()-interval '1 hour')>=60 OR
 (p_actor IS NOT NULL AND(SELECT count(*) FROM public.redirect_qr_assets WHERE requested_by=p_actor AND created_at>clock_timestamp()-interval '1 hour')>=60) OR
 (SELECT count(*) FROM public.redirect_qr_assets WHERE created_at>clock_timestamp()-interval '1 hour')>=600 OR
 (SELECT count(*) FROM public.redirect_qr_assets WHERE qr_image_id=r.id AND state='pending' AND expires_at>clock_timestamp())>=3 THEN RETURN jsonb_build_object('retryAfter',900);END IF;
 IF r.link_id IS NOT NULL THEN SELECT domain_id INTO domain FROM public.redirects WHERE id=r.link_id;url:=public.redirect_management_link(r.link_id)->>'shortUrl';ELSE url:=r.encoded_url;END IF;
 style:=public.redirect_qr_effective_style(domain)||r.style;
 IF NOT public.redirect_qr_style_valid(style) THEN RAISE EXCEPTION 'QR image branding is invalid' USING ERRCODE='22023';END IF;
 INSERT INTO public.redirect_qr_assets(target_scope,requested_by,requested_principal,qr_image_id,expected_version,mime,bytes,width,height,sha256,expires_at,next_cleanup_at)
 VALUES('image:'||r.id::text,p_actor,r.principal_key,r.id,r.version,p_mime,p_bytes,p_width,p_height,p_sha256,r.draft_expires_at,r.draft_expires_at) RETURNING * INTO asset;
 RETURN jsonb_build_object('id',asset.id,'key',asset.id::text||CASE WHEN asset.mime='image/png' THEN '.png' ELSE '.jpg' END,'profile',jsonb_build_object('url',url,'tracked',r.link_id IS NOT NULL,'style',style));
END $$;
CREATE FUNCTION public.finish_redirect_qr_image_logo(p_actor uuid,p_principal uuid,p_image uuid,p_asset uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_qr_image_links;asset public.redirect_qr_assets;
BEGIN
 r:=public.redirect_qr_image_draft(p_actor,p_principal,p_image);
 SELECT * INTO asset FROM public.redirect_qr_assets WHERE id=p_asset FOR UPDATE;
 IF asset.id IS NULL OR asset.state<>'pending' OR asset.qr_image_id IS DISTINCT FROM r.id OR asset.requested_principal IS DISTINCT FROM r.principal_key OR asset.target_scope<>'image:'||r.id::text OR asset.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'Artwork reservation expired or does not match this draft' USING ERRCODE='22023';END IF;
 IF r.version IS DISTINCT FROM asset.expected_version THEN RAISE EXCEPTION 'QR image draft changed; upload was not attached' USING ERRCODE='23505';END IF;
 UPDATE public.redirect_qr_assets SET state='active',next_cleanup_at=clock_timestamp()+interval '1 hour' WHERE id=asset.id;
 UPDATE public.redirect_qr_image_links SET logo_asset_id=asset.id,publication_state='published',draft_expires_at=NULL,version=gen_random_uuid() WHERE id=r.id;
 RETURN public.redirect_qr_image_link_json(r.id);
END $$;
REVOKE ALL ON FUNCTION public.release_redirect_qr_image_artwork(),public.redirect_qr_image_draft(uuid,uuid,uuid),public.reserve_redirect_qr_image_logo(uuid,uuid,uuid,uuid,text,integer,integer,integer,text),public.finish_redirect_qr_image_logo(uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.release_redirect_qr_image_artwork(),public.redirect_qr_image_draft(uuid,uuid,uuid),public.reserve_redirect_qr_image_logo(uuid,uuid,uuid,uuid,text,integer,integer,integer,text),public.finish_redirect_qr_image_logo(uuid,uuid,uuid,uuid) TO service_role;
