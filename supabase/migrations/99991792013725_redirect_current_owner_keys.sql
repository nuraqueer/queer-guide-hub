-- Serialize current owner-role changes with scoped reads/writes before row locks.
CREATE TRIGGER redirect_owner_role_acl_lock BEFORE INSERT OR UPDATE OR DELETE
 ON public.user_roles FOR EACH STATEMENT EXECUTE FUNCTION public.redirect_acl_change_lock();

CREATE OR REPLACE FUNCTION public.redirect_management_scope(p_token_id uuid,p_scope text)
RETURNS uuid[] LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE t public.redirect_api_tokens; member public.redirect_workspace_members; member_key uuid; ids uuid[]; required_rank integer;
BEGIN
 IF current_user <> 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 IF p_scope IS NULL OR p_scope NOT IN('links:read','links:write','events:read','workspace:read','workspace:write','conversions:write') THEN RAISE EXCEPTION 'Invalid permission scope' USING ERRCODE='22023';END IF;
 IF p_scope LIKE '%:write' THEN PERFORM pg_advisory_xact_lock(471983093);ELSE PERFORM pg_advisory_xact_lock_shared(471983093);END IF;
 IF p_token_id IS NULL THEN RETURN NULL;END IF;
 SELECT * INTO t FROM public.redirect_api_tokens WHERE id=p_token_id FOR SHARE;
 IF t.id IS NOT NULL THEN
  IF t.revoked_at IS NOT NULL OR t.expires_at<=clock_timestamp() OR NOT(p_scope=ANY(t.scopes)) THEN RAISE EXCEPTION 'Credential expired, revoked or missing scope' USING ERRCODE='42501';END IF;
  IF p_scope LIKE 'workspace:%' AND t.redirect_ids IS NOT NULL THEN RAISE EXCEPTION 'Workspace permissions require an unrestricted credential' USING ERRCODE='42501';END IF;
  IF t.member_id IS NULL THEN
   PERFORM 1 FROM public.user_roles WHERE user_id=t.created_by AND role='admin' FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Credential owner access is no longer active' USING ERRCODE='42501';END IF;
   RETURN t.redirect_ids;
  END IF;
  member_key:=t.member_id;
 ELSE
  IF p_scope<>ALL(ARRAY['links:read','links:write','events:read','workspace:read','workspace:write']) THEN RAISE EXCEPTION 'Session scope is not allowed' USING ERRCODE='42501';END IF;
  member_key:=p_token_id;
 END IF;
 SELECT * INTO member FROM public.redirect_workspace_members WHERE id=member_key AND active AND (t.id IS NOT NULL OR kind='user') FOR SHARE;
 IF member.id IS NULL THEN RAISE EXCEPTION 'Redirects workspace membership is inactive or missing' USING ERRCODE='42501';END IF;
 required_rank:=CASE WHEN p_scope LIKE '%:write' THEN 2 ELSE 1 END;
 SELECT coalesce(array_agg(r.id),ARRAY[]::uuid[]) INTO ids
 FROM public.redirects r LEFT JOIN public.redirect_link_metadata m ON m.redirect_key='redirects:'||r.id::text
 LEFT JOIN public.redirect_link_folders f ON f.id=m.folder_id
 LEFT JOIN public.redirect_folder_members a ON a.folder_id=f.id AND a.member_id=member.id
 WHERE (r.type='SHORT' OR m.folder_id IS NOT NULL) AND (t.redirect_ids IS NULL OR r.id=ANY(t.redirect_ids))
 AND least(CASE WHEN member.role='viewer' THEN 1 ELSE 3 END,
  CASE WHEN m.folder_id IS NULL THEN 2 ELSE CASE coalesce(a.permission,f.default_permission) WHEN 'owner' THEN 3 WHEN 'edit' THEN 2 WHEN 'view' THEN 1 ELSE 0 END END)>=required_rank;
 RETURN ids;
END $$;

CREATE OR REPLACE FUNCTION public.authenticate_redirect_api_token(p_hash text,p_scope text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE t public.redirect_api_tokens;
BEGIN
 IF current_user <> 'service_role' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';END IF;
 IF p_scope LIKE '%:write' THEN PERFORM pg_advisory_xact_lock(471983093);
 ELSE PERFORM pg_advisory_xact_lock_shared(471983093);END IF;
 SELECT * INTO t FROM public.redirect_api_tokens WHERE token_hash=p_hash
 AND revoked_at IS NULL AND expires_at>clock_timestamp() AND p_scope=ANY(scopes) FOR UPDATE;
 IF t.id IS NULL THEN RETURN NULL;END IF;
 PERFORM public.redirect_management_scope(t.id,p_scope);
 UPDATE public.redirect_api_tokens SET last_used_at=now() WHERE id=t.id;
 RETURN jsonb_build_object('id',t.id,'redirect_ids',t.redirect_ids,'scopes',t.scopes);
END $$;
REVOKE ALL ON FUNCTION public.redirect_management_scope(uuid,text),public.authenticate_redirect_api_token(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redirect_management_scope(uuid,text),public.authenticate_redirect_api_token(text,text) TO service_role;
