-- Redirects-specific current-owner check; never change the app-wide JWT helper.
CREATE FUNCTION public.redirect_current_owner() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM pg_catalog.pg_advisory_xact_lock_shared(471983093);
 IF auth.uid() IS NULL THEN RETURN false;END IF;
 -- PostgREST table GETs are read-only. The shared ACL lock serializes role
 -- mutation statements; row-locking reads would break these GET requests.
 PERFORM 1 FROM public.user_roles WHERE user_id=auth.uid() AND role='admin';
 RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.redirect_current_owner() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_current_owner() TO authenticated,service_role;

-- Preserve policy commands, roles and every non-admin predicate.
DO $$
DECLARE r record; replacement text; ddl text;
BEGIN
 FOR r IN SELECT * FROM pg_policies WHERE schemaname='public'
 AND tablename IN('redirects','redirect_events','redirect_api_tokens','redirect_link_customers','redirect_link_conversions','redirect_link_folders','redirect_link_tags','redirect_utm_templates','redirect_link_metadata','redirect_link_tag_assignments','redirect_link_policies')
 AND (qual LIKE '%has_role_jwt%' OR with_check LIKE '%has_role_jwt%') LOOP
  ddl:=format('ALTER POLICY %I ON public.%I',r.policyname,r.tablename);
  IF r.qual IS NOT NULL THEN
   replacement:=regexp_replace(r.qual,$pattern$(public[.])?has_role_jwt\('admin'::(public[.])?app_role\)$pattern$,'public.redirect_current_owner()','g');
   ddl:=ddl||' USING ('||replacement||')';
  END IF;
  IF r.with_check IS NOT NULL THEN
   replacement:=regexp_replace(r.with_check,$pattern$(public[.])?has_role_jwt\('admin'::(public[.])?app_role\)$pattern$,'public.redirect_current_owner()','g');
   ddl:=ddl||' WITH CHECK ('||replacement||')';
  END IF;
  EXECUTE ddl;
 END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.set_redirect_link_metadata(p_redirect_key text, p_folder_id uuid, p_tag_ids uuid[], p_comment text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(471983093);
  IF NOT public.redirect_current_owner() THEN RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_tag_ids) t WHERE NOT EXISTS (SELECT FROM public.redirect_link_tags WHERE id = t)) THEN
    RAISE EXCEPTION 'Unknown tag' USING ERRCODE = '23503';
  END IF;
  INSERT INTO public.redirect_link_metadata(redirect_key, folder_id, comment)
  VALUES (p_redirect_key, p_folder_id, coalesce(p_comment,''))
  ON CONFLICT (redirect_key) DO UPDATE SET folder_id=excluded.folder_id, comment=excluded.comment, updated_at=now();
  DELETE FROM public.redirect_link_tag_assignments WHERE redirect_key=p_redirect_key;
  INSERT INTO public.redirect_link_tag_assignments(redirect_key,tag_id)
  SELECT p_redirect_key, t FROM (SELECT DISTINCT unnest(coalesce(p_tag_ids,ARRAY[]::uuid[])) AS t) tags;
END $$;

CREATE OR REPLACE FUNCTION public.create_redirect_campaign_link(p_slug text, p_target text, p_folder_id uuid DEFAULT NULL, p_tag_ids uuid[] DEFAULT ARRAY[]::uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE saved public.redirects;
BEGIN
  PERFORM pg_advisory_xact_lock(471983093);
  IF NOT public.redirect_current_owner() THEN RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'; END IF;
  IF lower(btrim(p_slug)) !~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$' OR length(p_target) NOT BETWEEN 1 AND 8192 THEN
    RAISE EXCEPTION 'Invalid short link';
  END IF;
  INSERT INTO public.redirects(type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by)
  VALUES ('SHORT',lower(btrim(p_slug)),p_target,'EXACT',302,true,'PRESERVE',true,auth.uid()) RETURNING * INTO saved;
  PERFORM public.set_redirect_link_metadata('redirects:' || saved.id::text, p_folder_id, p_tag_ids, '');
  RETURN to_jsonb(saved);
END $$;

CREATE OR REPLACE FUNCTION public.bulk_redirect_organization(p_keys text[],p_action text,p_value uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE key text; changed integer:=0;
BEGIN
  PERFORM pg_advisory_xact_lock(471983093);
 IF NOT public.redirect_current_owner() THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='42501'; END IF;
 IF p_keys IS NULL OR cardinality(p_keys) NOT BETWEEN 1 AND 100 OR EXISTS(SELECT FROM unnest(p_keys) k WHERE k IS NULL OR length(k) NOT BETWEEN 1 AND 4096) THEN RAISE EXCEPTION 'Select 1–100 redirects' USING ERRCODE='22023'; END IF;
 IF p_action IS NULL OR p_action NOT IN('archive','restore','folder','add-tag','remove-tag') THEN RAISE EXCEPTION 'Invalid bulk action' USING ERRCODE='22023'; END IF;
 IF p_action='folder' AND p_value IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_link_folders WHERE id=p_value) THEN RAISE EXCEPTION 'Folder not found' USING ERRCODE='23503'; END IF;
 IF p_action IN('add-tag','remove-tag') AND (p_value IS NULL OR NOT EXISTS(SELECT FROM public.redirect_link_tags WHERE id=p_value)) THEN RAISE EXCEPTION 'Tag not found' USING ERRCODE='23503'; END IF;
 PERFORM pg_advisory_xact_lock(471983092);
 FOR key IN SELECT DISTINCT k FROM unnest(p_keys) k ORDER BY k LOOP
  IF key LIKE 'redirects:%' THEN
   PERFORM 1 FROM public.redirects WHERE id::text=substring(key from 11) FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Redirect no longer exists' USING ERRCODE='P0002'; END IF;
  END IF;
  INSERT INTO public.redirect_link_metadata(redirect_key) VALUES(key) ON CONFLICT DO NOTHING;
  IF p_action IN('archive','restore') THEN UPDATE public.redirect_link_metadata SET is_archived=p_action='archive',updated_at=clock_timestamp() WHERE redirect_key=key;
  ELSIF p_action='folder' THEN UPDATE public.redirect_link_metadata SET folder_id=p_value,updated_at=clock_timestamp() WHERE redirect_key=key;
  ELSIF p_action='add-tag' THEN INSERT INTO public.redirect_link_tag_assignments(redirect_key,tag_id) VALUES(key,p_value) ON CONFLICT DO NOTHING;
  ELSE DELETE FROM public.redirect_link_tag_assignments WHERE redirect_key=key AND tag_id=p_value;
  END IF;
  changed:=changed+1;
 END LOOP;
 RETURN changed;
END $$;

CREATE OR REPLACE FUNCTION public.set_redirect_link_policy(p_redirect_id uuid,p_policy jsonb,p_password_hash jsonb,p_change_password boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE saved public.redirect_link_policies;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  PERFORM public.redirect_management_scope(NULL,'links:write');
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

