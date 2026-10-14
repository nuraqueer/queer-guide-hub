-- Independent public password-page decoration with scoped, immutable asset publication.
CREATE TABLE public.redirect_password_branding(
 link_id uuid PRIMARY KEY REFERENCES public.redirects(id) ON DELETE CASCADE,
 brand_name text CHECK(brand_name IS NULL OR(length(brand_name) BETWEEN 1 AND 80 AND btrim(brand_name)<>'' AND brand_name!~'[[:cntrl:]]')),
 logo_asset_id uuid REFERENCES public.redirect_qr_assets(id) ON DELETE RESTRICT,
 version uuid NOT NULL DEFAULT gen_random_uuid(),updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.redirect_password_branding ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redirect_password_branding FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.redirect_password_branding TO service_role;
CREATE INDEX redirect_password_branding_asset_reference ON public.redirect_password_branding(logo_asset_id) WHERE logo_asset_id IS NOT NULL;
CREATE TRIGGER redirect_password_branding_acl_lock BEFORE INSERT OR UPDATE OR DELETE ON public.redirect_password_branding FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
-- Lock before the parent row, so FK logo-release cascades preserve ACL lock order.
CREATE TRIGGER redirect_password_parent_delete_lock BEFORE DELETE ON public.redirects FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
CREATE TRIGGER redirect_password_parent_type_lock BEFORE UPDATE OF type ON public.redirects FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();
ALTER TABLE public.redirect_qr_assets ADD COLUMN password_link_id uuid REFERENCES public.redirects(id) ON DELETE SET NULL;
CREATE INDEX redirect_asset_password_link ON public.redirect_qr_assets(password_link_id) WHERE password_link_id IS NOT NULL;

CREATE FUNCTION public.redirect_password_branding_actor(p_actor uuid,p_principal uuid,p_link uuid,p_write boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[];t public.redirect_api_tokens;member public.redirect_workspace_members;actor uuid;principal_key text;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 IF p_write IS NULL THEN RAISE EXCEPTION 'Invalid access mode' USING ERRCODE='22023';END IF;
 IF p_write THEN PERFORM pg_advisory_xact_lock(471983093);ELSE PERFORM pg_advisory_xact_lock_shared(471983093);END IF;
 IF p_principal IS NULL THEN
  PERFORM 1 FROM public.user_roles WHERE user_id=p_actor AND role='admin' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Workspace owner access required' USING ERRCODE='42501';END IF;
  actor:=p_actor;principal_key:='owner:'||actor::text;
 ELSE
  SELECT * INTO t FROM public.redirect_api_tokens WHERE id=p_principal FOR SHARE;
  IF t.id IS NOT NULL THEN
   actor:=t.created_by;principal_key:='key:'||t.id::text;
   IF t.member_id IS NULL THEN
    PERFORM 1 FROM public.user_roles WHERE user_id=actor AND role='admin' FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Key owner access changed' USING ERRCODE='42501';END IF;
   END IF;
  ELSE
   SELECT * INTO member FROM public.redirect_workspace_members WHERE id=p_principal AND kind='user' AND active AND user_id=p_actor FOR SHARE;
   IF member.id IS NULL THEN RAISE EXCEPTION 'Account does not match membership' USING ERRCODE='42501';END IF;
   actor:=p_actor;principal_key:='member:'||member.id::text;
  END IF;
 END IF;
 allowed:=public.redirect_management_scope(p_principal,CASE WHEN p_write THEN 'links:write' ELSE 'links:read' END);
 PERFORM 1 FROM public.redirects WHERE id=p_link AND type='SHORT' AND(allowed IS NULL OR id=ANY(allowed)) FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Managed link not found or access changed' USING ERRCODE='P0002';END IF;
 IF p_write AND NOT public.redirect_can_write_link(p_principal,p_link) THEN RAISE EXCEPTION 'Link edit access required' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('actor',actor,'principalKey',principal_key);
END $$;
CREATE FUNCTION public.redirect_password_branding_public(p_link uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('brandName',b.brand_name,'logoAsset',CASE WHEN a.state='active' AND a.password_link_id=b.link_id AND a.target_scope='password:'||b.link_id::text THEN public.redirect_qr_asset_json(a.id) ELSE NULL END)
 FROM public.redirect_password_branding b LEFT JOIN public.redirect_qr_assets a ON a.id=b.logo_asset_id WHERE b.link_id=p_link;
$$;
CREATE FUNCTION public.redirect_password_branding_json(p_link uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('linkId',p_link,'version',(SELECT version FROM public.redirect_password_branding WHERE link_id=p_link),'updatedAt',(SELECT updated_at FROM public.redirect_password_branding WHERE link_id=p_link))||coalesce(public.redirect_password_branding_public(p_link),jsonb_build_object('brandName',NULL,'logoAsset',NULL));
$$;
CREATE FUNCTION public.release_redirect_password_logo() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
 IF OLD.logo_asset_id IS NOT NULL AND(TG_OP='DELETE' OR NEW.logo_asset_id IS DISTINCT FROM OLD.logo_asset_id) THEN
  UPDATE public.redirect_qr_assets SET next_cleanup_at=clock_timestamp()+interval '1 hour' WHERE id=OLD.logo_asset_id AND state='active';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
CREATE TRIGGER release_redirect_password_logo AFTER UPDATE OR DELETE ON public.redirect_password_branding FOR EACH ROW EXECUTE FUNCTION public.release_redirect_password_logo();

CREATE FUNCTION public.redirect_password_branding_resource(p_action text,p_actor uuid,p_principal uuid,p_link uuid,p_values jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE identity jsonb;current_version uuid;b public.redirect_password_branding;brand text;asset uuid;
BEGIN
 IF p_action IS NULL OR p_action NOT IN('get','patch') THEN RAISE EXCEPTION 'Invalid branding action' USING ERRCODE='22023';END IF;
 identity:=public.redirect_password_branding_actor(p_actor,p_principal,p_link,p_action='patch');
 IF p_action='get' THEN RETURN public.redirect_password_branding_json(p_link)||jsonb_build_object('canEdit',public.redirect_can_write_link(p_principal,p_link));END IF;
 SELECT * INTO b FROM public.redirect_password_branding WHERE link_id=p_link FOR UPDATE;current_version:=b.version;
 IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR NOT(p_values?'version') OR p_values-ARRAY['version','brandName','clearLogo']::text[]<>'{}' OR p_values-ARRAY['version']::text[]='{}' THEN RAISE EXCEPTION 'Provide the current version and branding changes' USING ERRCODE='22023';END IF;
 IF current_version IS DISTINCT FROM(p_values->>'version')::uuid THEN RAISE EXCEPTION 'Password branding changed; reload before saving' USING ERRCODE='23505';END IF;
 IF(p_values?'brandName' AND jsonb_typeof(p_values->'brandName') NOT IN('string','null')) OR(p_values?'clearLogo' AND jsonb_typeof(p_values->'clearLogo')<>'boolean') THEN RAISE EXCEPTION 'Invalid branding fields' USING ERRCODE='22023';END IF;
 brand:=CASE WHEN p_values?'brandName' THEN nullif(btrim(p_values->>'brandName'),'') ELSE b.brand_name END;
 asset:=CASE WHEN coalesce((p_values->>'clearLogo')::boolean,false) THEN NULL ELSE b.logo_asset_id END;
 INSERT INTO public.redirect_password_branding(link_id,brand_name,logo_asset_id) VALUES(p_link,brand,asset)
 ON CONFLICT(link_id) DO UPDATE SET brand_name=excluded.brand_name,logo_asset_id=excluded.logo_asset_id,version=gen_random_uuid(),updated_at=clock_timestamp();
 RETURN public.redirect_password_branding_json(p_link)||jsonb_build_object('canEdit',true);
END $$;
CREATE FUNCTION public.reserve_redirect_password_logo(p_actor uuid,p_principal uuid,p_link uuid,p_version uuid,p_mime text,p_bytes integer,p_width integer,p_height integer,p_sha256 text) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE identity jsonb;current_version uuid;asset public.redirect_qr_assets;scope text:='password:'||p_link::text;
BEGIN
 identity:=public.redirect_password_branding_actor(p_actor,p_principal,p_link,true);
 SELECT version INTO current_version FROM public.redirect_password_branding WHERE link_id=p_link FOR UPDATE;
 IF current_version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'Password branding changed; reload before uploading' USING ERRCODE='23505';END IF;
 IF p_mime IS NULL OR p_mime NOT IN('image/png','image/jpeg') OR p_bytes IS NULL OR p_bytes NOT BETWEEN 1 AND 1500000 OR p_width IS NULL OR p_width NOT BETWEEN 1 AND 1024 OR p_height IS NULL OR p_height NOT BETWEEN 1 AND 1024 OR p_sha256 IS NULL OR p_sha256!~'^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid logo metadata' USING ERRCODE='22023';END IF;
 IF(SELECT count(*) FROM public.redirect_qr_assets WHERE requested_by=(identity->>'actor')::uuid AND created_at>clock_timestamp()-interval '1 hour')>=60 OR(SELECT count(*) FROM public.redirect_qr_assets WHERE created_at>clock_timestamp()-interval '1 hour')>=600 OR(SELECT count(*) FROM public.redirect_qr_assets WHERE target_scope=scope AND state='pending' AND expires_at>clock_timestamp())>=3 THEN RETURN jsonb_build_object('retryAfter',900);END IF;
 INSERT INTO public.redirect_qr_assets(target_scope,password_link_id,requested_by,requested_principal,expected_version,mime,bytes,width,height,sha256)
 VALUES(scope,p_link,(identity->>'actor')::uuid,identity->>'principalKey',p_version,p_mime,p_bytes,p_width,p_height,p_sha256) RETURNING * INTO asset;
 RETURN jsonb_build_object('id',asset.id,'key',asset.id::text||CASE WHEN asset.mime='image/png' THEN '.png' ELSE '.jpg' END);
END $$;
CREATE FUNCTION public.finish_redirect_password_logo(p_actor uuid,p_principal uuid,p_link uuid,p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE identity jsonb;current_version uuid;asset public.redirect_qr_assets;
BEGIN
 identity:=public.redirect_password_branding_actor(p_actor,p_principal,p_link,true);
 SELECT version INTO current_version FROM public.redirect_password_branding WHERE link_id=p_link FOR UPDATE;
 SELECT * INTO asset FROM public.redirect_qr_assets WHERE id=p_id FOR UPDATE;
 IF asset.id IS NULL OR asset.state<>'pending' OR asset.password_link_id IS DISTINCT FROM p_link OR asset.target_scope<>'password:'||p_link::text OR asset.requested_principal IS DISTINCT FROM identity->>'principalKey' OR asset.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'Logo reservation expired or does not match this link' USING ERRCODE='22023';END IF;
 IF current_version IS DISTINCT FROM asset.expected_version THEN RAISE EXCEPTION 'Password branding changed during upload; reload settings' USING ERRCODE='23505';END IF;
 UPDATE public.redirect_qr_assets SET state='active',next_cleanup_at=clock_timestamp()+interval '1 hour' WHERE id=asset.id;
 INSERT INTO public.redirect_password_branding(link_id,logo_asset_id) VALUES(p_link,asset.id)
 ON CONFLICT(link_id) DO UPDATE SET logo_asset_id=excluded.logo_asset_id,version=gen_random_uuid(),updated_at=clock_timestamp();
 RETURN public.redirect_password_branding_json(p_link)||jsonb_build_object('canEdit',true);
END $$;
REVOKE ALL ON FUNCTION public.redirect_password_branding_actor(uuid,uuid,uuid,boolean),public.redirect_password_branding_public(uuid),public.redirect_password_branding_json(uuid),public.release_redirect_password_logo(),public.redirect_password_branding_resource(text,uuid,uuid,uuid,jsonb),public.reserve_redirect_password_logo(uuid,uuid,uuid,uuid,text,integer,integer,integer,text),public.finish_redirect_password_logo(uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_password_branding_actor(uuid,uuid,uuid,boolean),public.redirect_password_branding_public(uuid),public.redirect_password_branding_json(uuid),public.release_redirect_password_logo(),public.redirect_password_branding_resource(text,uuid,uuid,uuid,jsonb),public.reserve_redirect_password_logo(uuid,uuid,uuid,uuid,text,integer,integer,integer,text),public.finish_redirect_password_logo(uuid,uuid,uuid,uuid) TO service_role;

-- Every cleanup claim/receipt includes the independent password-page reference.
CREATE OR REPLACE FUNCTION public.claim_redirect_qr_asset_cleanup(p_limit integer DEFAULT 3) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE asset public.redirect_qr_assets;result jsonb:='[]';
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(471983093);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'Invalid cleanup batch' USING ERRCODE='22023';END IF;
 FOR asset IN SELECT * FROM public.redirect_qr_assets a WHERE next_cleanup_at<=clock_timestamp() AND NOT EXISTS(SELECT FROM public.redirect_qr_styles WHERE logo_asset_id=a.id)
 AND NOT EXISTS(SELECT FROM public.redirect_qr_image_links WHERE logo_asset_id=a.id)
 AND NOT EXISTS(SELECT FROM public.redirect_password_branding WHERE logo_asset_id=a.id)
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
 IF asset.id IS NULL OR asset.state<>'deleting' OR p_lease IS DISTINCT FROM asset.lease OR asset.lease_until<=clock_timestamp() OR EXISTS(SELECT FROM public.redirect_qr_styles WHERE logo_asset_id=p_id) OR EXISTS(SELECT FROM public.redirect_qr_image_links WHERE logo_asset_id=p_id) OR EXISTS(SELECT FROM public.redirect_password_branding WHERE logo_asset_id=p_id) THEN RETURN false;END IF;
 UPDATE public.redirect_qr_assets SET state=CASE WHEN p_success IS TRUE THEN 'deleted' ELSE 'deleting' END,
  last_deleted_at=CASE WHEN p_success IS TRUE THEN clock_timestamp() ELSE last_deleted_at END,
  next_cleanup_at=clock_timestamp()+CASE WHEN p_success IS TRUE THEN CASE WHEN asset.last_deleted_at IS NULL THEN interval '1 day' ELSE interval '30 days' END ELSE make_interval(secs=>least(3600,30*power(2,least(asset.attempts,6))::integer)) END,
  lease=NULL,lease_until=CASE WHEN p_success IS TRUE THEN NULL ELSE clock_timestamp() END,
  attempts=CASE WHEN p_success IS TRUE THEN 0 ELSE attempts END,last_error=CASE WHEN p_success IS TRUE THEN NULL ELSE 'Storage cleanup failed; retry scheduled' END WHERE id=p_id;
 RETURN true;
END $$;

-- Published branding changes are link lifecycle changes without exposing artwork.
CREATE OR REPLACE FUNCTION redirect_internal.capture_webhook_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r public.redirects;type text;source text;data jsonb;key text;link uuid;event public.redirect_events;url text;
BEGIN
 IF TG_TABLE_SCHEMA<>'public' THEN RAISE EXCEPTION 'Invalid webhook source';END IF;
 IF TG_TABLE_NAME='redirect_events' THEN
  type:='link.clicked';link:=NEW.redirect_id;source:='click:'||NEW.click_id;
  data:=jsonb_build_object('linkId',link,'clickId',NEW.click_id,'occurredAt',NEW.ts,'country',NEW.country,'device',NEW.visitor->>'device','qr',coalesce(NEW.visitor->'is_qr'='true'::jsonb,false),'variantId',NEW.variant_id);
 ELSIF TG_TABLE_NAME='redirect_link_conversions' THEN
  SELECT * INTO event FROM public.redirect_events WHERE click_id=NEW.click_id;link:=event.redirect_id;
  type:=CASE NEW.kind WHEN 'lead' THEN 'lead.created' ELSE 'sale.created' END;source:='conversion:'||NEW.id;
  data:=jsonb_build_object('linkId',link,'clickId',NEW.click_id,'occurredAt',NEW.occurred_at,'eventName',NEW.event_name,'customerExternalId',NEW.customer_key,'amount',NEW.amount::text,'currency',NEW.currency);
 ELSIF TG_TABLE_NAME='redirects' THEN
  IF TG_OP='DELETE' THEN r:=OLD;type:='link.deleted';
  ELSIF TG_OP='INSERT' THEN r:=NEW;type:='link.created';
  ELSIF OLD.type='SHORT' AND NEW.type<>'SHORT' THEN r:=OLD;type:='link.deleted';
  ELSIF OLD.type<>'SHORT' AND NEW.type='SHORT' THEN r:=NEW;type:='link.created';
  ELSE
   IF (to_jsonb(NEW)-ARRAY['click_count','updated_at']::text[]) IS NOT DISTINCT FROM(to_jsonb(OLD)-ARRAY['click_count','updated_at']::text[]) THEN RETURN NEW;END IF;
   r:=NEW;type:='link.updated';
  END IF;
  IF r.type<>'SHORT' THEN IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;END IF;
  link:=r.id;
 ELSE
  IF TG_TABLE_NAME='redirect_password_branding' THEN link:=CASE WHEN TG_OP='DELETE' THEN OLD.link_id ELSE NEW.link_id END;
  ELSIF TG_TABLE_NAME='redirect_link_policies' THEN link:=CASE WHEN TG_OP='DELETE' THEN OLD.redirect_id ELSE NEW.redirect_id END;
  ELSIF TG_TABLE_NAME IN('redirect_link_metadata','redirect_link_tag_assignments') THEN
   key:=CASE WHEN TG_OP='DELETE' THEN OLD.redirect_key ELSE NEW.redirect_key END;
   IF key!~*'^redirects:[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' THEN IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;END IF;
   link:=substring(key FROM 11)::uuid;
  ELSE RAISE EXCEPTION 'Invalid webhook table';END IF;
  SELECT * INTO r FROM public.redirects WHERE id=link;
  IF r.id IS NULL OR r.type<>'SHORT' THEN IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;END IF;
  IF TG_OP='UPDATE' AND(to_jsonb(NEW)-'updated_at') IS NOT DISTINCT FROM(to_jsonb(OLD)-'updated_at') THEN RETURN NEW;END IF;
  type:='link.updated';
 END IF;
 IF type IN('link.created','link.updated','link.deleted') THEN
  url:=CASE WHEN r.domain_id IS NULL THEN 'https://queer.guide/go/'||r.slug ELSE 'https://'||r.domain_hostname||'/'||CASE WHEN r.is_domain_root THEN '' ELSE r.slug END END;
  source:=type||':'||link||':'||txid_current();
  data:=jsonb_build_object('linkId',link,'shortUrl',url,'isDomainRoot',r.is_domain_root,'enabled',r.is_enabled,'archived',coalesce((SELECT m.is_archived FROM public.redirect_link_metadata m WHERE m.redirect_key='redirects:'||link),false));
 END IF;
 PERFORM public.redirect_webhook_enqueue(type,link,source,data);
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
CREATE TRIGGER redirect_webhook_password_branding AFTER INSERT OR UPDATE OR DELETE ON public.redirect_password_branding FOR EACH ROW EXECUTE FUNCTION redirect_internal.capture_webhook_event();
