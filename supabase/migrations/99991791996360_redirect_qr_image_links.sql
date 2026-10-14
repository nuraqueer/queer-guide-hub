-- Revocable opaque image capabilities. Only explicit authorized creation publishes a profile.
CREATE TABLE public.redirect_qr_image_links(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),token_hash text NOT NULL UNIQUE CHECK(token_hash ~ '^[a-f0-9]{64}$'),
 creator_user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
 creator_member_id uuid REFERENCES public.redirect_workspace_members(id) ON DELETE CASCADE,
 creator_key_id uuid REFERENCES public.redirect_api_tokens(id) ON DELETE CASCADE,
 principal_key text NOT NULL,
 link_id uuid REFERENCES public.redirects(id) ON DELETE CASCADE,encoded_url text,
 label text NOT NULL DEFAULT 'QR image' CHECK(length(btrim(label)) BETWEEN 1 AND 100),
 style jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(style)='object' AND length(style::text)<=512),
 logo_mode text NOT NULL DEFAULT 'inherit' CHECK(logo_mode IN('inherit','none')),
 version uuid NOT NULL DEFAULT gen_random_uuid(),created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 expires_at timestamptz,revoked_at timestamptz,
 CHECK(num_nonnulls(creator_user_id,creator_member_id,creator_key_id)=1),
 CHECK(principal_key=coalesce('owner:'||creator_user_id::text,'member:'||creator_member_id::text,'key:'||creator_key_id::text)),
 CHECK(num_nonnulls(link_id,encoded_url)=1),CHECK(expires_at IS NULL OR expires_at>created_at)
);
ALTER TABLE public.redirect_qr_image_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_qr_image_links FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_qr_image_links TO service_role;
CREATE INDEX redirect_qr_image_principal_budget ON public.redirect_qr_image_links(principal_key,created_at);
CREATE INDEX redirect_qr_image_global_budget ON public.redirect_qr_image_links(created_at);
CREATE INDEX redirect_qr_image_active_principal ON public.redirect_qr_image_links(principal_key) WHERE revoked_at IS NULL;
CREATE INDEX redirect_qr_image_user_reference ON public.redirect_qr_image_links(creator_user_id) WHERE creator_user_id IS NOT NULL;
CREATE INDEX redirect_qr_image_member_reference ON public.redirect_qr_image_links(creator_member_id) WHERE creator_member_id IS NOT NULL;
CREATE INDEX redirect_qr_image_key_reference ON public.redirect_qr_image_links(creator_key_id) WHERE creator_key_id IS NOT NULL;
CREATE INDEX redirect_qr_image_link_reference ON public.redirect_qr_image_links(link_id);
CREATE TRIGGER redirect_qr_image_links_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_qr_image_links FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
-- Budget events deliberately survive redirect/user/key cascades.
CREATE TABLE public.redirect_qr_image_creation_log(id uuid PRIMARY KEY,principal_key text NOT NULL,created_at timestamptz NOT NULL);
ALTER TABLE public.redirect_qr_image_creation_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_qr_image_creation_log FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_qr_image_creation_log TO service_role;
CREATE INDEX redirect_qr_image_creation_principal ON public.redirect_qr_image_creation_log(principal_key,created_at);
CREATE INDEX redirect_qr_image_creation_time ON public.redirect_qr_image_creation_log(created_at);
CREATE INDEX redirect_qr_image_retention ON public.redirect_qr_image_links(least(revoked_at,expires_at)) WHERE least(revoked_at,expires_at) IS NOT NULL;
CREATE FUNCTION public.log_redirect_qr_image_creation() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN INSERT INTO public.redirect_qr_image_creation_log(id,principal_key,created_at) VALUES(NEW.id,NEW.principal_key,NEW.created_at);RETURN NULL;END $$;
CREATE TRIGGER log_redirect_qr_image_creation AFTER INSERT ON public.redirect_qr_image_links FOR EACH ROW EXECUTE FUNCTION public.log_redirect_qr_image_creation();
CREATE FUNCTION public.prune_redirect_qr_image_history(p_limit integer DEFAULT 1000) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE budget_before timestamptz:=clock_timestamp()-interval '2 days';image_before timestamptz:=clock_timestamp()-interval '90 days';events integer;images integer;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'Invalid retention batch' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 DELETE FROM public.redirect_qr_image_creation_log q USING(SELECT id FROM public.redirect_qr_image_creation_log WHERE created_at<budget_before ORDER BY created_at,id LIMIT p_limit FOR UPDATE SKIP LOCKED) old WHERE q.id=old.id;
 GET DIAGNOSTICS events=ROW_COUNT;
 DELETE FROM public.redirect_qr_image_links q USING(SELECT id FROM public.redirect_qr_image_links WHERE least(revoked_at,expires_at)<image_before ORDER BY least(revoked_at,expires_at),id LIMIT p_limit FOR UPDATE SKIP LOCKED) old WHERE q.id=old.id;
 GET DIAGNOSTICS images=ROW_COUNT;
 RETURN jsonb_build_object('events',events,'images',images);
END $$;
CREATE FUNCTION public.redirect_qr_image_link_json(p_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('id',id,'label',label,'linkId',link_id,'version',version,'createdAt',created_at,'expiresAt',expires_at,'revokedAt',revoked_at,'style',style,'logoMode',logo_mode)
 FROM public.redirect_qr_image_links WHERE id=p_id;
$$;
CREATE FUNCTION public.redirect_qr_image_resource(p_action text,p_actor uuid DEFAULT NULL,p_principal uuid DEFAULT NULL,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT NULL,p_hash text DEFAULT NULL,p_limit integer DEFAULT 100,p_after uuid DEFAULT NULL)
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
 IF p_values?'label' AND(jsonb_typeof(p_values->'label')<>'string' OR length(btrim(p_values->>'label')) NOT BETWEEN 1 AND 100) OR p_values?'logoMode' AND coalesce(p_values->>'logoMode','') NOT IN('inherit','none') OR p_values?'style' AND jsonb_typeof(p_values->'style') NOT IN('object','null') THEN RAISE EXCEPTION 'Invalid image branding fields' USING ERRCODE='22023';END IF;
 IF coalesce(nullif(p_values->'style','null'::jsonb),'{}')-ARRAY['dots','border','center','foreground','background']::text[]<>'{}' THEN RAISE EXCEPTION 'Unknown image appearance field' USING ERRCODE='22023';END IF;
 overrides:=jsonb_strip_nulls(coalesce(nullif(p_values->'style','null'::jsonb),'{}'));
 effective:=public.redirect_qr_effective_style(link.domain_id)||overrides;
 IF NOT public.redirect_qr_style_valid(effective) THEN RAISE EXCEPTION 'Use supported shapes and dark-on-light colors with at least 4.5:1 contrast' USING ERRCODE='22023';END IF;
 IF (SELECT count(*) FROM public.redirect_qr_image_links q WHERE q.principal_key=v_principal_key AND revoked_at IS NULL AND(expires_at IS NULL OR expires_at>clock_timestamp()))>=100 OR
 (SELECT count(*) FROM public.redirect_qr_image_creation_log q WHERE q.principal_key=v_principal_key AND created_at>clock_timestamp()-interval '1 hour')>=60 OR
 (SELECT count(*) FROM public.redirect_qr_image_creation_log WHERE created_at>clock_timestamp()-interval '1 hour')>=600 THEN
  RETURN jsonb_build_object('retryAfter',3600);
 END IF;
 INSERT INTO public.redirect_qr_image_links(token_hash,creator_user_id,creator_member_id,creator_key_id,principal_key,link_id,encoded_url,label,style,logo_mode,expires_at)
 VALUES(p_hash,CASE WHEN owner THEN p_actor END,member_id,key_id,v_principal_key,link.id,url,coalesce(btrim(p_values->>'label'),'QR image'),overrides,coalesce(p_values->>'logoMode','inherit'),expires)
 RETURNING * INTO r;
 RETURN public.redirect_qr_image_link_json(r.id);
END $$;
CREATE FUNCTION public.redirect_public_qr_image(p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE r public.redirect_qr_image_links;allowed uuid[];link public.redirects;url text;style jsonb;logo jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock_shared(471983093);
 SELECT * INTO r FROM public.redirect_qr_image_links WHERE token_hash=p_hash AND revoked_at IS NULL AND(expires_at IS NULL OR expires_at>clock_timestamp()) FOR SHARE;
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
 logo:=CASE WHEN r.logo_mode='none' THEN jsonb_build_object('effectiveLogo',NULL,'logoSource','hidden') ELSE public.redirect_qr_effective_logo(link.domain_id) END;
 RETURN jsonb_build_object('url',url,'tracked',r.link_id IS NOT NULL,'style',style)||logo;
END $$;
REVOKE ALL ON FUNCTION public.redirect_qr_image_link_json(uuid),public.redirect_qr_image_resource(text,uuid,uuid,uuid,jsonb,text,integer,uuid),public.redirect_public_qr_image(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_qr_image_link_json(uuid),public.redirect_qr_image_resource(text,uuid,uuid,uuid,jsonb,text,integer,uuid),public.redirect_public_qr_image(text) TO service_role;

REVOKE ALL ON FUNCTION public.log_redirect_qr_image_creation(),public.prune_redirect_qr_image_history(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.log_redirect_qr_image_creation(),public.prune_redirect_qr_image_history(integer) TO service_role;
