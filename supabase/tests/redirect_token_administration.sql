BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE owner_id uuid:=gen_random_uuid(); ordinary uuid:=gen_random_uuid(); link_id uuid; member_id uuid; key_id uuid; result jsonb; values_json jsonb;
BEGIN
 INSERT INTO auth.users(id) VALUES(owner_id),(ordinary);
 INSERT INTO public.user_roles VALUES(owner_id,'admin');
 INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','token-admin-fixture','https://example.org/token') RETURNING id INTO link_id;
 INSERT INTO public.redirect_workspace_members(kind,label) VALUES('machine','Bound worker') RETURNING id INTO member_id;
 values_json:=jsonb_build_object('name','  Scoped credential  ','token_hash',repeat('8',64),'prefix','qg_redirect_88888888','expires_at',now()+interval '1 day','scopes',jsonb_build_array('links:read'),'redirect_ids',jsonb_build_array(link_id),'member_id',member_id);
 BEGIN PERFORM public.redirect_token_administration(ordinary,'list');RAISE EXCEPTION 'Ordinary actor read tokens';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 result:=public.redirect_token_administration(owner_id,'create',p_values=>values_json);key_id:=(result->>'id')::uuid;
 IF result->>'name'<>'Scoped credential' OR result->>'member_id'<>member_id::text OR result?'token_hash' OR result?'secret' OR result?'created_by' THEN RAISE EXCEPTION 'Credential metadata shape/privacy failed';END IF;
 IF NOT EXISTS(SELECT FROM public.redirect_api_tokens WHERE id=key_id AND created_by=owner_id) THEN RAISE EXCEPTION 'Credential actor not recorded';END IF;
 result:=public.redirect_token_administration(owner_id,'list');
 IF (result->>'count')::int<>1 OR result#>>'{data,0,id}'<>key_id::text OR result#>'{data,0}'?'token_hash' THEN RAISE EXCEPTION 'Credential page/privacy failed';END IF;
 BEGIN PERFORM public.redirect_token_administration(owner_id,'create',p_values=>values_json||jsonb_build_object('redirect_ids',jsonb_build_array(gen_random_uuid())));RAISE EXCEPTION 'Unknown link accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 BEGIN PERFORM public.redirect_token_administration(owner_id,'create',p_values=>values_json||'{"scopes":["workspace:read"]}');RAISE EXCEPTION 'Selected workspace credential accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 UPDATE public.redirect_workspace_members SET active=false WHERE id=member_id;
 BEGIN PERFORM public.redirect_token_administration(owner_id,'create',p_values=>values_json);RAISE EXCEPTION 'Inactive member bound';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 DELETE FROM public.user_roles WHERE user_id=owner_id;
 BEGIN PERFORM public.redirect_token_administration(owner_id,'list');RAISE EXCEPTION 'Lost owner read';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.redirect_token_administration(owner_id,'create',p_values=>values_json);RAISE EXCEPTION 'Lost owner created';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.redirect_token_administration(owner_id,'revoke',key_id);RAISE EXCEPTION 'Lost owner revoked';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 INSERT INTO public.user_roles VALUES(owner_id,'admin');
 IF NOT(public.redirect_token_administration(owner_id,'revoke',key_id)->>'revoked')::boolean THEN RAISE EXCEPTION 'Credential revoke failed';END IF;
 IF (public.redirect_token_administration(owner_id,'revoke',key_id)->>'revoked')::boolean THEN RAISE EXCEPTION 'Revoke not idempotent';END IF;
 IF public.authenticate_redirect_api_token(repeat('8',64),'links:read') IS NOT NULL THEN RAISE EXCEPTION 'Revoked credential authenticated';END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF has_function_privilege(current_user,'public.redirect_token_administration(uuid,text,uuid,jsonb,integer)','execute') OR has_function_privilege(current_user,'public.redirect_token_metadata(uuid)','execute') THEN RAISE EXCEPTION 'Private credential helpers exposed';END IF;
END $$;
ROLLBACK;
