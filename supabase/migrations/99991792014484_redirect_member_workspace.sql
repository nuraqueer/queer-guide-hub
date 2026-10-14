-- Capabilities describe both folder access and a credential's explicit scopes.
CREATE FUNCTION public.redirect_folder_capabilities(p_folder uuid,p_principal uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE rank integer; scopes text[];
BEGIN
 rank:=public.redirect_folder_rank(public.redirect_principal_member(p_principal),p_folder);
 SELECT t.scopes INTO scopes FROM public.redirect_api_tokens t WHERE id=p_principal;
 RETURN jsonb_build_object('canEdit',rank>=2 AND (scopes IS NULL OR 'links:write'=ANY(scopes)),'canManage',rank>=3 AND (scopes IS NULL OR 'workspace:write'=ANY(scopes)));
END $$;
REVOKE ALL ON FUNCTION public.redirect_folder_capabilities(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_folder_capabilities(uuid,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.redirect_workspace_resource(p_kind text,p_action text,p_id uuid DEFAULT NULL,p_values jsonb DEFAULT '{}',p_limit integer DEFAULT 50,p_after uuid DEFAULT NULL,p_token_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE table_name text; scope_ids uuid[]; rows jsonb; count_value bigint; result jsonb; changed uuid; member uuid; member_role text;
BEGIN
 IF p_kind NOT IN('folders','tags','templates') OR p_action NOT IN('list','get','create','update','delete') OR p_kind IS NULL OR p_action IS NULL THEN RAISE EXCEPTION 'Invalid workspace operation' USING ERRCODE='22023'; END IF;
 scope_ids:=public.redirect_management_scope(p_token_id,CASE WHEN p_action IN('list','get') THEN 'workspace:read' ELSE 'workspace:write' END);
 member:=public.redirect_principal_member(p_token_id);
 IF member IS NOT NULL THEN
  SELECT role INTO member_role FROM public.redirect_workspace_members WHERE id=member;
  IF p_action NOT IN('list','get') AND (p_kind<>'folders' OR member_role='viewer' OR (p_action<>'create' AND public.redirect_folder_rank(member,p_id)<3)) THEN RAISE EXCEPTION 'Folder owner access is required' USING ERRCODE='42501';END IF;
  IF p_action='delete' AND EXISTS(SELECT FROM public.redirect_link_metadata WHERE folder_id=p_id) THEN RAISE EXCEPTION 'Move links before deleting this folder' USING ERRCODE='22023';END IF;
 END IF;
 table_name:=CASE p_kind WHEN 'folders' THEN 'redirect_link_folders' WHEN 'tags' THEN 'redirect_link_tags' ELSE 'redirect_utm_templates' END;
 IF p_action='list' THEN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid resource page' USING ERRCODE='22023'; END IF;
  EXECUTE format('WITH records AS MATERIALIZED(SELECT * FROM public.%I WHERE $3 IS NULL OR $4<>''folders'' OR public.redirect_folder_rank($3,id)>=1), page AS(SELECT * FROM records WHERE $1 IS NULL OR id>$1 ORDER BY id LIMIT $2+1) SELECT (SELECT count(*) FROM records),coalesce(jsonb_agg(to_jsonb(page) ORDER BY id),''[]''::jsonb) FROM page',table_name)
   INTO count_value,rows USING p_after,p_limit,member,p_kind;
  SELECT coalesce(jsonb_agg(value ORDER BY ordinal),'[]'::jsonb) INTO result FROM jsonb_array_elements(rows) WITH ORDINALITY e(value,ordinal) WHERE ordinal<=p_limit;
  IF p_kind='folders' THEN SELECT coalesce(jsonb_agg(value||public.redirect_folder_capabilities((value->>'id')::uuid,p_token_id) ORDER BY ordinal),'[]'::jsonb) INTO result FROM jsonb_array_elements(result) WITH ORDINALITY e(value,ordinal);END IF;
  RETURN jsonb_build_object('data',result,'count',count_value,'nextCursor',CASE WHEN jsonb_array_length(rows)>p_limit THEN result->(p_limit-1)->>'id' ELSE NULL END);
 END IF;
 IF p_action='get' THEN
  EXECUTE format('SELECT to_jsonb(r) FROM public.%I r WHERE id=$1',table_name) INTO result USING p_id;
  IF result IS NULL OR (member IS NOT NULL AND p_kind='folders' AND public.redirect_folder_rank(member,p_id)<1) THEN RAISE EXCEPTION 'Resource not found' USING ERRCODE='P0002'; END IF;
  IF p_kind='folders' THEN result:=result||public.redirect_folder_capabilities(p_id,p_token_id);END IF;
  RETURN result;
 END IF;
 IF p_action IN('update','delete') THEN
  EXECUTE format('SELECT id FROM public.%I WHERE id=$1 FOR UPDATE',table_name) INTO changed USING p_id;
  IF changed IS NULL THEN RAISE EXCEPTION 'Resource not found' USING ERRCODE='P0002'; END IF;
 END IF;
 IF p_action='delete' THEN
  EXECUTE format('DELETE FROM public.%I WHERE id=$1',table_name) USING p_id;
  RETURN jsonb_build_object('id',p_id,'deleted',true);
 END IF;
 IF p_action='create' THEN
  IF p_kind='folders' THEN INSERT INTO public.redirect_link_folders(name,description) VALUES(p_values->>'name',coalesce(p_values->>'description','')) RETURNING to_jsonb(redirect_link_folders.*) INTO result;
  ELSIF p_kind='tags' THEN INSERT INTO public.redirect_link_tags(name,color) VALUES(p_values->>'name',coalesce(p_values->>'color','gray')) RETURNING to_jsonb(redirect_link_tags.*) INTO result;
  ELSE INSERT INTO public.redirect_utm_templates(name,parameters) VALUES(p_values->>'name',coalesce(p_values->'parameters','{}')) RETURNING to_jsonb(redirect_utm_templates.*) INTO result;
  END IF;
 ELSE
  IF p_kind='folders' THEN UPDATE public.redirect_link_folders SET name=CASE WHEN p_values?'name' THEN p_values->>'name' ELSE name END,description=CASE WHEN p_values?'description' THEN p_values->>'description' ELSE description END WHERE id=p_id RETURNING to_jsonb(redirect_link_folders.*) INTO result;
  ELSIF p_kind='tags' THEN UPDATE public.redirect_link_tags SET name=CASE WHEN p_values?'name' THEN p_values->>'name' ELSE name END,color=CASE WHEN p_values?'color' THEN p_values->>'color' ELSE color END WHERE id=p_id RETURNING to_jsonb(redirect_link_tags.*) INTO result;
  ELSE UPDATE public.redirect_utm_templates SET name=CASE WHEN p_values?'name' THEN p_values->>'name' ELSE name END,parameters=CASE WHEN p_values?'parameters' THEN p_values->'parameters' ELSE parameters END WHERE id=p_id RETURNING to_jsonb(redirect_utm_templates.*) INTO result;
  END IF;
 END IF;
 IF p_action='create' AND p_kind='folders' AND member IS NOT NULL THEN INSERT INTO public.redirect_folder_members(folder_id,member_id,permission) VALUES((result->>'id')::uuid,member,'owner');END IF;
 IF p_kind='folders' THEN result:=result||public.redirect_folder_capabilities((result->>'id')::uuid,p_token_id);END IF;
 RETURN result;
END $$;


CREATE FUNCTION public.redirect_scoped_variant_performance(p_redirect_id uuid,p_token_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE allowed uuid[]; result jsonb;
BEGIN
 allowed:=public.redirect_management_scope(p_token_id,'links:read');
 IF allowed IS NOT NULL AND NOT(p_redirect_id=ANY(allowed)) THEN RAISE EXCEPTION 'Link is outside credential scope' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT FROM public.redirects WHERE id=p_redirect_id AND type='SHORT') THEN RAISE EXCEPTION 'Link not found' USING ERRCODE='P0002';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) INTO result FROM public.redirect_variant_performance(p_redirect_id) p;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.redirect_scoped_variant_performance(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_scoped_variant_performance(uuid,uuid) TO service_role;
