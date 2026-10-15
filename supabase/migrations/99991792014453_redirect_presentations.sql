INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('redirect-previews','redirect-previews',true,1500000,ARRAY['image/png','image/jpeg']) ON CONFLICT(id) DO NOTHING;
DO $$ BEGIN
 IF EXISTS(SELECT FROM storage.buckets WHERE id='redirect-previews' AND
  (public IS DISTINCT FROM true OR file_size_limit IS DISTINCT FROM 1500000 OR allowed_mime_types IS NULL OR NOT(allowed_mime_types @> ARRAY['image/png','image/jpeg'] AND allowed_mime_types <@ ARRAY['image/png','image/jpeg']))) THEN
  RAISE EXCEPTION 'Existing redirect-previews bucket has incompatible settings';
 END IF;
END $$;
-- Only the validated server endpoint may upload to this public artwork bucket.
CREATE POLICY redirect_preview_no_direct_insert ON storage.objects AS RESTRICTIVE FOR INSERT TO anon,authenticated WITH CHECK(bucket_id<>'redirect-previews');
CREATE POLICY redirect_preview_no_direct_update ON storage.objects AS RESTRICTIVE FOR UPDATE TO anon,authenticated USING(bucket_id<>'redirect-previews') WITH CHECK(bucket_id<>'redirect-previews');
CREATE POLICY redirect_preview_no_direct_delete ON storage.objects AS RESTRICTIVE FOR DELETE TO anon,authenticated USING(bucket_id<>'redirect-previews');
CREATE POLICY redirect_preview_no_metadata_listing ON storage.objects AS RESTRICTIVE FOR SELECT TO anon,authenticated USING(bucket_id<>'redirect-previews');

CREATE FUNCTION public.redirect_presentation(p_redirect_id uuid,p_action text,p_values jsonb DEFAULT '{}',p_token_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[]; existing public.redirect_link_policies; merged jsonb;
BEGIN
 IF p_action NOT IN('get','check','patch') OR p_action IS NULL THEN RAISE EXCEPTION 'Invalid presentation action' USING ERRCODE='22023'; END IF;
 allowed:=public.redirect_management_scope(p_token_id,CASE WHEN p_action='get' THEN 'links:read' ELSE 'links:write' END);
 IF allowed IS NOT NULL AND NOT(p_redirect_id=ANY(allowed)) THEN RAISE EXCEPTION 'Link is outside credential scope' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.redirects WHERE id=p_redirect_id AND type='SHORT' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Managed link not found' USING ERRCODE='P0002'; END IF;
 SELECT * INTO existing FROM public.redirect_link_policies WHERE redirect_id=p_redirect_id;
 IF p_action='check' THEN RETURN '{}'::jsonb; END IF;
 IF p_action<>'get' THEN
  IF p_values IS NULL OR jsonb_typeof(p_values)<>'object' OR p_values-ARRAY['preview','cloaked']::text[]<>'{}' THEN RAISE EXCEPTION 'Invalid presentation values' USING ERRCODE='22023'; END IF;
  merged:=coalesce(existing.policy,'{}');
   IF p_values?'preview' THEN merged:=CASE WHEN p_values->'preview'='null'::jsonb THEN merged-'preview' ELSE merged||jsonb_build_object('preview',p_values->'preview') END; END IF;
   IF p_values?'cloaked' THEN merged:=merged||jsonb_build_object('cloaked',p_values->'cloaked'); END IF;
  INSERT INTO public.redirect_link_policies(redirect_id,policy) VALUES(p_redirect_id,merged)
  ON CONFLICT(redirect_id) DO UPDATE SET policy=excluded.policy,updated_at=clock_timestamp();
 END IF;
 RETURN jsonb_build_object('preview',CASE WHEN p_action='get' THEN existing.policy->'preview' ELSE merged->'preview' END,'cloaked',coalesce(CASE WHEN p_action='get' THEN existing.policy->'cloaked' ELSE merged->'cloaked' END,'false'));
END $$;
REVOKE ALL ON FUNCTION public.redirect_presentation(uuid,text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_presentation(uuid,text,jsonb,uuid) TO service_role;

CREATE FUNCTION public.redirect_cloaking_https_guard() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE rule jsonb; destination text; candidate text;
BEGIN
 IF TG_TABLE_NAME='redirects' THEN
  destination:=NEW.target;SELECT policy INTO rule FROM public.redirect_link_policies WHERE redirect_id=NEW.id;
 ELSE
  rule:=NEW.policy;SELECT target INTO destination FROM public.redirects WHERE id=NEW.redirect_id;
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
END $$;
REVOKE ALL ON FUNCTION public.redirect_cloaking_https_guard() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_cloaking_https_guard() TO service_role;
CREATE TRIGGER redirect_policy_cloaking_https BEFORE INSERT OR UPDATE OF policy ON public.redirect_link_policies FOR EACH ROW EXECUTE FUNCTION public.redirect_cloaking_https_guard();
CREATE TRIGGER redirect_target_cloaking_https BEFORE UPDATE OF target ON public.redirects FOR EACH ROW EXECUTE FUNCTION public.redirect_cloaking_https_guard();
