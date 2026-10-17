-- Fence remaining legacy organization writers and the old service policy setter.
-- Authenticated direct RPCs retain fixed legacy identity; activation stays disabled.

CREATE OR REPLACE FUNCTION public.set_redirect_link_policy(p_redirect_id uuid, p_policy jsonb, p_password_hash jsonb, p_change_password boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:=public.redirect_request_workspace();saved public.redirect_link_policies;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  PERFORM public.redirect_management_scope(NULL,'links:write');
  IF NOT EXISTS (SELECT FROM public.redirects WHERE workspace_id=selected_workspace AND id=p_redirect_id AND type='SHORT') THEN
    RAISE EXCEPTION 'Managed short link not found' USING ERRCODE='P0002';
  END IF;
  INSERT INTO public.redirect_link_policies(workspace_id,redirect_id,policy,password_hash)
  VALUES (selected_workspace,p_redirect_id,p_policy - 'expires_at',CASE WHEN p_change_password THEN p_password_hash ELSE NULL END)
  ON CONFLICT (redirect_id) DO UPDATE SET policy=excluded.policy,
    password_hash=CASE WHEN p_change_password THEN excluded.password_hash ELSE redirect_link_policies.password_hash END,
    updated_at=now() WHERE redirect_link_policies.workspace_id=selected_workspace RETURNING * INTO saved;
  IF NOT FOUND THEN RAISE EXCEPTION 'Policy is unavailable in this workspace' USING ERRCODE='23505';END IF;
  UPDATE public.redirects SET end_at=nullif(p_policy->>'expires_at','')::timestamptz, updated_at=now() WHERE workspace_id=selected_workspace AND id=p_redirect_id;
  RETURN jsonb_build_object('policy', saved.policy || jsonb_strip_nulls(jsonb_build_object('expires_at',nullif(p_policy->>'expires_at',''))),'has_password',saved.has_password);
END $function$;

CREATE OR REPLACE FUNCTION public.redirect_cloaking_https_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE rule jsonb; destination text; candidate text;
BEGIN
 IF TG_TABLE_NAME='redirects' THEN
  destination:=NEW.target;SELECT policy INTO rule FROM public.redirect_link_policies WHERE workspace_id=NEW.workspace_id AND redirect_id=NEW.id;
 ELSE
  rule:=NEW.policy;SELECT target INTO destination FROM public.redirects WHERE workspace_id=NEW.workspace_id AND id=NEW.redirect_id;
 END IF;
 IF coalesce((rule->>'cloaked')::boolean,false) THEN
  IF NOT(destination LIKE 'https://%' OR destination LIKE '/%' AND destination NOT LIKE '//%') THEN RAISE EXCEPTION 'Framed destinations require HTTPS' USING ERRCODE='22023'; END IF;
  FOR candidate IN
   SELECT value FROM jsonb_each_text(coalesce(rule->'device_targets','{}'))
   UNION ALL SELECT value FROM jsonb_each_text(coalesce(rule->'geo_targets','{}'))
   UNION ALL SELECT value->>'url' FROM jsonb_array_elements(coalesce(rule->'experiment'->'variants','[]'))
  LOOP
   IF NOT(candidate LIKE 'https://%' OR candidate LIKE '/%' AND candidate NOT LIKE '//%') THEN RAISE EXCEPTION 'Framed targeting rules require HTTPS' USING ERRCODE='22023'; END IF;
  END LOOP;
 END IF;
 RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.set_redirect_link_metadata(p_redirect_key text, p_folder_id uuid, p_tag_ids uuid[], p_comment text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:='58aa4340-8f21-4b7f-9a10-90be2da89c01'::uuid;
BEGIN
  PERFORM pg_advisory_xact_lock(471983093);
  IF NOT public.redirect_current_owner() THEN RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'; END IF;

  IF p_redirect_key LIKE 'redirects:%' AND NOT EXISTS(SELECT FROM public.redirects WHERE workspace_id=selected_workspace AND id::text=substring(p_redirect_key from 11)) THEN
    RAISE EXCEPTION 'Redirect no longer exists' USING ERRCODE='P0002';
  END IF;
  IF p_folder_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_link_folders WHERE workspace_id=selected_workspace AND id=p_folder_id) THEN
    RAISE EXCEPTION 'Unknown folder' USING ERRCODE='23503';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_tag_ids) t WHERE NOT EXISTS (SELECT FROM public.redirect_link_tags WHERE workspace_id=selected_workspace AND id = t)) THEN
    RAISE EXCEPTION 'Unknown tag' USING ERRCODE = '23503';
  END IF;
  INSERT INTO public.redirect_link_metadata(workspace_id,redirect_key, folder_id, comment)
  VALUES (selected_workspace,p_redirect_key, p_folder_id, coalesce(p_comment,''))
  ON CONFLICT (redirect_key) DO UPDATE SET folder_id=excluded.folder_id, comment=excluded.comment, updated_at=now() WHERE redirect_link_metadata.workspace_id=selected_workspace;
  IF NOT FOUND THEN RAISE EXCEPTION 'Metadata is unavailable in this workspace' USING ERRCODE='23505';END IF;
  DELETE FROM public.redirect_link_tag_assignments WHERE workspace_id=selected_workspace AND redirect_key=p_redirect_key;
  INSERT INTO public.redirect_link_tag_assignments(workspace_id,redirect_key,tag_id)
  SELECT selected_workspace,p_redirect_key, t FROM (SELECT DISTINCT unnest(coalesce(p_tag_ids,ARRAY[]::uuid[])) AS t) tags;
END $function$;

CREATE OR REPLACE FUNCTION public.create_redirect_campaign_link(p_slug text, p_target text, p_folder_id uuid DEFAULT NULL::uuid, p_tag_ids uuid[] DEFAULT ARRAY[]::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:='58aa4340-8f21-4b7f-9a10-90be2da89c01'::uuid;saved public.redirects;
BEGIN
  PERFORM pg_advisory_xact_lock(471983093);
  IF NOT public.redirect_current_owner() THEN RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'; END IF;
  IF lower(btrim(p_slug)) !~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$' OR length(p_target) NOT BETWEEN 1 AND 8192 THEN
    RAISE EXCEPTION 'Invalid short link';
  END IF;
  INSERT INTO public.redirects(workspace_id,type,slug,target,match_kind,status_code,is_enabled,query_mode,preserve_query,created_by)
  VALUES (selected_workspace,'SHORT',lower(btrim(p_slug)),p_target,'EXACT',302,true,'PRESERVE',true,auth.uid()) RETURNING * INTO saved;
  PERFORM public.set_redirect_link_metadata('redirects:' || saved.id::text, p_folder_id, p_tag_ids, '');
  RETURN to_jsonb(saved);
END $function$;

CREATE OR REPLACE FUNCTION public.bulk_redirect_organization(p_keys text[], p_action text, p_value uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE selected_workspace uuid:='58aa4340-8f21-4b7f-9a10-90be2da89c01'::uuid;key text; changed integer:=0;
BEGIN
  PERFORM pg_advisory_xact_lock(471983093);
 IF NOT public.redirect_current_owner() THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='42501'; END IF;
 IF p_keys IS NULL OR cardinality(p_keys) NOT BETWEEN 1 AND 100 OR EXISTS(SELECT FROM unnest(p_keys) k WHERE k IS NULL OR length(k) NOT BETWEEN 1 AND 4096) THEN RAISE EXCEPTION 'Select 1–100 redirects' USING ERRCODE='22023'; END IF;
 IF p_action IS NULL OR p_action NOT IN('archive','restore','folder','add-tag','remove-tag') THEN RAISE EXCEPTION 'Invalid bulk action' USING ERRCODE='22023'; END IF;
 IF p_action='folder' AND p_value IS NOT NULL AND NOT EXISTS(SELECT FROM public.redirect_link_folders WHERE workspace_id=selected_workspace AND id=p_value) THEN RAISE EXCEPTION 'Folder not found' USING ERRCODE='23503'; END IF;
 IF p_action IN('add-tag','remove-tag') AND (p_value IS NULL OR NOT EXISTS(SELECT FROM public.redirect_link_tags WHERE workspace_id=selected_workspace AND id=p_value)) THEN RAISE EXCEPTION 'Tag not found' USING ERRCODE='23503'; END IF;
 PERFORM pg_advisory_xact_lock(471983092);
 FOR key IN SELECT DISTINCT k FROM unnest(p_keys) k ORDER BY k LOOP
  IF key LIKE 'redirects:%' THEN
   PERFORM 1 FROM public.redirects WHERE workspace_id=selected_workspace AND id::text=substring(key from 11) FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Redirect no longer exists' USING ERRCODE='P0002'; END IF;
  END IF;
  IF EXISTS(SELECT FROM public.redirect_link_metadata WHERE redirect_key=key AND workspace_id<>selected_workspace) THEN RAISE EXCEPTION 'Metadata is unavailable in this workspace' USING ERRCODE='23505';END IF;
  INSERT INTO public.redirect_link_metadata(workspace_id,redirect_key) VALUES(selected_workspace,key) ON CONFLICT(redirect_key) DO UPDATE SET redirect_key=excluded.redirect_key WHERE redirect_link_metadata.workspace_id=selected_workspace;
  IF NOT FOUND THEN RAISE EXCEPTION 'Metadata is unavailable in this workspace' USING ERRCODE='23505';END IF;
  IF p_action IN('archive','restore') THEN UPDATE public.redirect_link_metadata SET is_archived=p_action='archive',updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND redirect_key=key;
  ELSIF p_action='folder' THEN UPDATE public.redirect_link_metadata SET folder_id=p_value,updated_at=clock_timestamp() WHERE workspace_id=selected_workspace AND redirect_key=key;
  ELSIF p_action='add-tag' THEN INSERT INTO public.redirect_link_tag_assignments(workspace_id,redirect_key,tag_id) VALUES(selected_workspace,key,p_value) ON CONFLICT DO NOTHING;
  ELSE DELETE FROM public.redirect_link_tag_assignments WHERE workspace_id=selected_workspace AND redirect_key=key AND tag_id=p_value;
  END IF;
  changed:=changed+1;
 END LOOP;
 RETURN changed;
END $function$;
