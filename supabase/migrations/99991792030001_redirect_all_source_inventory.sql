-- Live routing records are projected, never copied into another inventory table.
CREATE VIEW public.redirect_inventory_database WITH(security_invoker=true) AS
SELECT 'redirects:'||r.id::text AS key,'redirects:'||r.id::text AS row_id,
 jsonb_build_object('id','redirects:'||r.id::text,'manualId',r.id,'isShortLink',r.type='SHORT','matchKind',r.match_kind,'source',CASE WHEN r.type='PATH' THEN coalesce(CASE WHEN r.domain_id IS NOT NULL THEN 'https://'||r.domain_hostname END,'')||r.source_path WHEN r.domain_id IS NOT NULL THEN 'https://'||r.domain_hostname||'/'||CASE WHEN r.is_domain_root THEN '' ELSE r.slug END ELSE '/go/'||r.slug END,'target',r.target,'origin','redirects','kind','Manual','statusCode',r.status_code,'state',CASE WHEN NOT r.is_enabled THEN 'Disabled' WHEN r.start_at>clock_timestamp() THEN 'Scheduled' WHEN r.end_at<=clock_timestamp() THEN 'Expired' WHEN r.click_limit IS NOT NULL AND r.click_count>=r.click_limit THEN 'Limit reached' ELSE 'Enabled' END,'updatedAt',r.updated_at,'clicks',r.click_count,'campaign',coalesce(r.utm_defaults,'{}'),'domainId',r.domain_id,'domainHostname',r.domain_hostname) AS data
 FROM public.redirects r
UNION ALL
SELECT 'venue_slug_redirects:'||a.old_slug AS key, 'venue_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','venue_slug_redirects:'||a.old_slug,'source','/venues/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/venues/'||e.slug END,'origin','venue_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.venue_slug_redirects a LEFT JOIN public.venues e ON e.id=a.venue_id
UNION ALL
SELECT 'city_slug_redirects:'||a.old_slug AS key, 'city_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','city_slug_redirects:'||a.old_slug,'source','/city/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/city/'||e.slug END,'origin','city_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.city_slug_redirects a LEFT JOIN public.cities e ON e.id=a.city_id
UNION ALL
SELECT 'country_slug_redirects:'||a.old_slug AS key, 'country_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','country_slug_redirects:'||a.old_slug,'source','/country/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/country/'||e.slug END,'origin','country_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.country_slug_redirects a LEFT JOIN public.countries e ON e.id=a.country_id
UNION ALL
SELECT 'event_slug_redirects:'||a.old_slug AS key, 'event_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','event_slug_redirects:'||a.old_slug,'source','/events/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/events/'||e.slug END,'origin','event_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.event_slug_redirects a LEFT JOIN public.events e ON e.id=a.event_id
UNION ALL
SELECT 'guide_slug_redirects:'||a.old_slug AS key, 'guide_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','guide_slug_redirects:'||a.old_slug,'source','/guides/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/guides/'||e.slug END,'origin','guide_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.guide_slug_redirects a LEFT JOIN public.guides e ON e.id=a.guide_id
UNION ALL
SELECT 'hotel_slug_redirects:'||a.old_slug AS key, 'hotel_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','hotel_slug_redirects:'||a.old_slug,'source','/hotels/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/hotels/'||e.slug END,'origin','hotel_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.hotel_slug_redirects a LEFT JOIN public.hotels e ON e.id=a.hotel_id
UNION ALL
SELECT 'marketplace_slug_redirects:'||a.old_slug AS key, 'marketplace_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','marketplace_slug_redirects:'||a.old_slug,'source','/marketplace/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/marketplace/'||e.slug END,'origin','marketplace_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.marketplace_slug_redirects a LEFT JOIN public.marketplace_listings e ON e.id=a.listing_id
UNION ALL
SELECT 'marketplace_brand_slug_redirects:'||a.old_slug AS key, 'marketplace_brand_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','marketplace_brand_slug_redirects:'||a.old_slug,'source','/marketplace/brands/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/marketplace/brands/'||e.slug END,'origin','marketplace_brand_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.marketplace_brand_slug_redirects a LEFT JOIN public.marketplace_brands e ON e.id=a.brand_id
UNION ALL
SELECT 'milestone_slug_redirects:'||a.old_slug AS key, 'milestone_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','milestone_slug_redirects:'||a.old_slug,'source','/history/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/history/'||e.slug END,'origin','milestone_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.milestone_slug_redirects a LEFT JOIN public.milestones e ON e.id=a.milestone_id
UNION ALL
SELECT 'news_slug_redirects:'||a.old_slug AS key, 'news_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','news_slug_redirects:'||a.old_slug,'source','/news/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/news/'||e.slug END,'origin','news_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.news_slug_redirects a LEFT JOIN public.news_articles e ON e.id=a.article_id
UNION ALL
SELECT 'org_slug_redirects:'||a.old_slug AS key, 'org_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','org_slug_redirects:'||a.old_slug,'source','/organizations/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/organizations/'||e.slug END,'origin','org_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.org_slug_redirects a LEFT JOIN public.organizations e ON e.id=a.organization_id
UNION ALL
SELECT 'personality_slug_redirects:'||a.old_slug AS key, 'personality_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','personality_slug_redirects:'||a.old_slug,'source','/personalities/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/personalities/'||e.slug END,'origin','personality_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.personality_slug_redirects a LEFT JOIN public.personalities e ON e.id=a.personality_id
UNION ALL
SELECT 'tag_slug_redirects:'||a.old_slug AS key, 'tag_slug_redirects:'||a.id::text AS row_id,
 jsonb_build_object('id','tag_slug_redirects:'||a.old_slug,'source','/tags/'||a.old_slug,'target',CASE WHEN coalesce(e.slug,a.new_slug) IS NOT NULL THEN '/tags/'||coalesce(e.slug,a.new_slug) END,'origin','tag_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN coalesce(e.slug,a.new_slug) IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.tag_slug_redirects a LEFT JOIN public.unified_tags e ON e.id=a.tag_id
UNION ALL
SELECT 'village_slug_redirects:'||a.old_slug AS key, 'village_slug_redirects:'||a.old_slug AS row_id,
 jsonb_build_object('id','village_slug_redirects:'||a.old_slug,'source','/villages/'||a.old_slug,'target',CASE WHEN e.slug IS NOT NULL THEN '/villages/'||e.slug END,'origin','village_slug_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN e.slug IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',a.created_at) AS data
 FROM public.village_slug_redirects a LEFT JOIN public.queer_villages e ON e.id=a.village_id
UNION ALL
SELECT 'venue_redirects:'||id::text,'venue_redirects:'||id::text,jsonb_build_object('id','venue_redirects:'||id::text,'source','/venues/'||slug_from,'target',CASE WHEN slug_to IS NOT NULL THEN '/venues/'||slug_to END,'origin','venue_redirects','kind','Automatic','statusCode',301,'state',CASE WHEN slug_to IS NULL THEN 'Missing target' ELSE 'Enabled' END,'updatedAt',created_at) FROM public.venue_redirects
UNION ALL
SELECT 'username_redirects:'||old_username,'username_redirects:'||old_username,jsonb_build_object('id','username_redirects:'||old_username,'source','@'||old_username,'target',CASE WHEN user_id IS NOT NULL THEN '/user/'||user_id::text END,'origin','username_redirects','kind','Automatic','statusCode',NULL,'state',CASE WHEN expires_at<=clock_timestamp() THEN 'Expired' ELSE 'Recorded' END,'updatedAt',created_at) FROM public.username_redirects;
REVOKE ALL ON public.redirect_inventory_database FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.redirect_inventory_database TO service_role;

CREATE FUNCTION public.redirect_inventory_rank(p_principal uuid,p_key text) RETURNS integer
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE selected uuid[]; folder uuid; member uuid;
BEGIN
 IF p_principal IS NOT NULL THEN
  SELECT redirect_ids INTO selected FROM public.redirect_api_tokens WHERE id=p_principal;
  IF selected IS NOT NULL AND NOT EXISTS(SELECT FROM unnest(selected) s WHERE p_key='redirects:'||s::text) THEN RETURN 0;END IF;
 END IF;
 member:=public.redirect_principal_member(p_principal);
 IF member IS NULL THEN RETURN 3;END IF;
 SELECT folder_id INTO folder FROM public.redirect_link_metadata WHERE redirect_key=p_key;
 RETURN public.redirect_folder_rank(member,folder);
END $$;
REVOKE ALL ON FUNCTION public.redirect_inventory_rank(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_inventory_rank(uuid,text) TO service_role;

CREATE FUNCTION public.redirect_inventory_records(p_manifest jsonb) RETURNS TABLE(key text,row_id text,data jsonb)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT key,row_id,data FROM public.redirect_inventory_database
 UNION ALL SELECT value->>'id',value->>'id',value FROM jsonb_array_elements(p_manifest);
$$;
REVOKE ALL ON FUNCTION public.redirect_inventory_records(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_inventory_records(jsonb) TO service_role;

ALTER TABLE public.redirect_link_metadata ADD COLUMN metadata_revision uuid NOT NULL DEFAULT gen_random_uuid();
CREATE FUNCTION public.redirect_metadata_revision_stamp() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN NEW.metadata_revision:=gen_random_uuid();RETURN NEW;END $$;
REVOKE ALL ON FUNCTION public.redirect_metadata_revision_stamp() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER redirect_metadata_revision_stamp BEFORE INSERT OR UPDATE ON public.redirect_link_metadata FOR EACH ROW EXECUTE FUNCTION public.redirect_metadata_revision_stamp();

CREATE FUNCTION public.redirect_inventory_page(p_manifest jsonb,p_filters jsonb DEFAULT '{}',p_limit integer DEFAULT 50,p_after text DEFAULT NULL,p_principal uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM public.redirect_management_scope(p_principal,'links:read');
 IF p_manifest IS NULL OR jsonb_typeof(p_manifest)<>'array' OR jsonb_array_length(p_manifest)>2000 OR p_filters IS NULL OR jsonb_typeof(p_filters)<>'object' OR p_limit IS NULL OR p_limit NOT BETWEEN 0 AND 100 OR length(p_after)>4096 THEN RAISE EXCEPTION 'Invalid inventory page' USING ERRCODE='22023';END IF;
 WITH visible AS MATERIALIZED(
  SELECT r.*,m.folder_id,m.comment,m.is_archived,m.metadata_revision AS metadata_version FROM public.redirect_inventory_records(p_manifest) r LEFT JOIN public.redirect_link_metadata m ON m.redirect_key=r.key
  WHERE public.redirect_inventory_rank(p_principal,r.key)>=1
   AND (NOT(p_filters?'excludeManaged') OR NOT coalesce((p_filters->>'excludeManaged')::boolean,false) OR NOT coalesce((r.data->>'isShortLink')::boolean,false))
   AND (NOT(p_filters?'search') OR strpos(lower(coalesce(r.data->>'source','')||' '||coalesce(r.data->>'target','')),lower(p_filters->>'search'))>0)
   AND (NOT(p_filters?'folderId') OR m.folder_id=(p_filters->>'folderId')::uuid)
   AND (NOT(p_filters?'tagId') OR EXISTS(SELECT FROM public.redirect_link_tag_assignments t WHERE t.redirect_key=r.key AND t.tag_id=(p_filters->>'tagId')::uuid))
   AND (NOT(p_filters?'origin') OR r.data->>'origin'=p_filters->>'origin')
   AND (NOT(p_filters?'kind') OR r.data->>'kind'=p_filters->>'kind')
   AND (NOT(p_filters?'isArchived') OR coalesce(m.is_archived,false)=(p_filters->>'isArchived')::boolean)
   AND (NOT(p_filters?'domainId') OR (p_filters->'domainId'='null' AND r.data->>'domainId' IS NULL) OR r.data->>'domainId'=p_filters->>'domainId')
 ), page AS MATERIALIZED(SELECT * FROM visible WHERE p_after IS NULL OR row_id COLLATE "C">p_after COLLATE "C" ORDER BY row_id COLLATE "C" LIMIT p_limit+1), shown AS MATERIALIZED(SELECT * FROM page ORDER BY row_id COLLATE "C" LIMIT p_limit)
 SELECT jsonb_build_object('count',(SELECT count(*) FROM visible),'data',coalesce((SELECT jsonb_agg(data||jsonb_build_object('rowId',row_id,'folderId',folder_id,'comment',coalesce(comment,''),'isArchived',coalesce(is_archived,false),'metadataVersion',metadata_version,'canEditMetadata',public.redirect_inventory_rank(p_principal,key)>=2,'tagIds',coalesce((SELECT jsonb_agg(tag_id ORDER BY tag_id) FROM public.redirect_link_tag_assignments t WHERE t.redirect_key=shown.key),'[]')) ORDER BY row_id COLLATE "C") FROM shown),'[]'),'nextCursor',CASE WHEN p_limit>0 AND (SELECT count(*) FROM page)>p_limit THEN (SELECT row_id FROM shown ORDER BY row_id COLLATE "C" DESC LIMIT 1) END) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.redirect_inventory_page(jsonb,jsonb,integer,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_inventory_page(jsonb,jsonb,integer,text,uuid) TO service_role;

CREATE FUNCTION public.redirect_inventory_metadata(p_manifest jsonb,p_key text,p_values jsonb DEFAULT NULL,p_expected uuid DEFAULT NULL,p_principal uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE saved public.redirect_link_metadata; folder uuid; member uuid; tags uuid[];
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM public.redirect_management_scope(p_principal,CASE WHEN p_values IS NULL THEN 'links:read' ELSE 'links:write' END);
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 1 AND 4096 OR NOT EXISTS(SELECT FROM public.redirect_inventory_records(p_manifest) WHERE key=p_key) OR public.redirect_inventory_rank(p_principal,p_key)<(CASE WHEN p_values IS NULL THEN 1 ELSE 2 END) THEN RAISE EXCEPTION 'Inventory record unavailable' USING ERRCODE='P0002';END IF;
 IF p_values IS NULL THEN SELECT * INTO saved FROM public.redirect_link_metadata WHERE redirect_key=p_key;
 ELSE
  IF jsonb_typeof(p_values)<>'object' OR p_values='{}' OR EXISTS(SELECT FROM jsonb_object_keys(p_values) k WHERE k NOT IN('folderId','tagIds','comment','isArchived')) THEN RAISE EXCEPTION 'Invalid inventory metadata fields' USING ERRCODE='22023';END IF;
  SELECT * INTO saved FROM public.redirect_link_metadata WHERE redirect_key=p_key FOR UPDATE;
  IF saved.metadata_revision IS DISTINCT FROM p_expected THEN RAISE EXCEPTION 'Inventory metadata changed; reload before saving' USING ERRCODE='23505';END IF;
  member:=public.redirect_principal_member(p_principal);
  folder:=saved.folder_id;
  IF p_values?'folderId' THEN
   IF p_values->'folderId'<>'null' AND jsonb_typeof(p_values->'folderId')<>'string' THEN RAISE EXCEPTION 'Invalid folder ID' USING ERRCODE='22023';END IF;
   folder:=(p_values->>'folderId')::uuid;
   IF public.redirect_folder_rank(member,folder)<2 THEN RAISE EXCEPTION 'Destination folder edit access required' USING ERRCODE='42501';END IF;
  END IF;
  IF p_values?'comment' AND (jsonb_typeof(p_values->'comment')<>'string' OR length(p_values->>'comment')>10000) OR p_values?'isArchived' AND jsonb_typeof(p_values->'isArchived')<>'boolean' THEN RAISE EXCEPTION 'Invalid comment or archive flag' USING ERRCODE='22023';END IF;
  IF p_values?'tagIds' THEN
   IF jsonb_typeof(p_values->'tagIds')<>'array' OR jsonb_array_length(p_values->'tagIds')>100 OR EXISTS(SELECT FROM jsonb_array_elements(p_values->'tagIds') e WHERE jsonb_typeof(e)<>'string') THEN RAISE EXCEPTION 'Invalid tags' USING ERRCODE='22023';END IF;
   SELECT coalesce(array_agg(DISTINCT value::uuid),ARRAY[]::uuid[]) INTO tags FROM jsonb_array_elements_text(p_values->'tagIds');
   IF EXISTS(SELECT FROM unnest(tags) t WHERE NOT EXISTS(SELECT FROM public.redirect_link_tags WHERE id=t)) THEN RAISE EXCEPTION 'Tag not found' USING ERRCODE='23503';END IF;
  END IF;
  INSERT INTO public.redirect_link_metadata AS m(redirect_key,folder_id,comment,is_archived) VALUES(p_key,folder,coalesce(p_values->>'comment',saved.comment,''),coalesce((p_values->>'isArchived')::boolean,saved.is_archived,false))
  ON CONFLICT(redirect_key) DO UPDATE SET folder_id=excluded.folder_id,comment=excluded.comment,is_archived=excluded.is_archived,updated_at=clock_timestamp()
  WHERE m.metadata_revision IS NOT DISTINCT FROM p_expected RETURNING * INTO saved;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory metadata changed; reload before saving' USING ERRCODE='23505';END IF;
  IF tags IS NOT NULL THEN
   DELETE FROM public.redirect_link_tag_assignments WHERE redirect_key=p_key;
   INSERT INTO public.redirect_link_tag_assignments(redirect_key,tag_id) SELECT p_key,value FROM unnest(tags) value;
  END IF;
 END IF;
 RETURN jsonb_build_object('id',p_key,'folderId',saved.folder_id,'comment',coalesce(saved.comment,''),'isArchived',coalesce(saved.is_archived,false),'metadataVersion',saved.metadata_revision,'canEditMetadata',public.redirect_inventory_rank(p_principal,p_key)>=2,'tagIds',coalesce((SELECT jsonb_agg(tag_id ORDER BY tag_id) FROM public.redirect_link_tag_assignments WHERE redirect_key=p_key),'[]'));
END $$;
REVOKE ALL ON FUNCTION public.redirect_inventory_metadata(jsonb,text,jsonb,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_inventory_metadata(jsonb,text,jsonb,uuid,uuid) TO service_role;

CREATE FUNCTION public.redirect_inventory_organize(p_manifest jsonb,p_operations jsonb,p_principal uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE op jsonb; output jsonb:='[]'; changed jsonb;
BEGIN
 IF current_user<>'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 PERFORM public.redirect_management_scope(p_principal,'links:write');
 IF p_operations IS NULL OR jsonb_typeof(p_operations)<>'array' OR jsonb_array_length(p_operations) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Select 1–100 inventory records' USING ERRCODE='22023';END IF;
 IF (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(p_operations))<>jsonb_array_length(p_operations) THEN RAISE EXCEPTION 'Duplicate inventory record operations' USING ERRCODE='22023';END IF;
 FOR op IN SELECT value FROM jsonb_array_elements(p_operations) ORDER BY value->>'id' LOOP
  IF jsonb_typeof(op)<>'object' OR NOT(op?'version') OR EXISTS(SELECT FROM jsonb_object_keys(op) k WHERE k NOT IN('id','version','values')) OR jsonb_typeof(op->'id')<>'string' OR op->'values' IS NULL THEN RAISE EXCEPTION 'Invalid inventory operation' USING ERRCODE='22023';END IF;
  changed:=public.redirect_inventory_metadata(p_manifest,op->>'id',op->'values',(op->>'version')::uuid,p_principal);
  output:=output||jsonb_build_array(changed);
 END LOOP;
 RETURN jsonb_build_object('data',output);
END $$;
REVOKE ALL ON FUNCTION public.redirect_inventory_organize(jsonb,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_inventory_organize(jsonb,jsonb,uuid) TO service_role;
