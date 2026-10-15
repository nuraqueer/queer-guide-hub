BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE u uuid:=gen_random_uuid(); m uuid; viewer uuid; machine uuid; f uuid; hidden uuid; link_id uuid; token_id uuid; result jsonb; own_folder uuid; click uuid;
BEGIN
 INSERT INTO auth.users(id) VALUES(u);
 INSERT INTO public.redirect_workspace_members(user_id,kind,label) VALUES(u,'user','Member') RETURNING id INTO m;
 INSERT INTO public.redirect_workspace_members(kind,label,role) VALUES('machine','Viewer','viewer') RETURNING id INTO viewer;
 INSERT INTO public.redirect_workspace_members(kind,label) VALUES('machine','Service') RETURNING id INTO machine;
 INSERT INTO public.redirect_link_folders(name,default_permission) VALUES('Visible','view') RETURNING id INTO f;
 INSERT INTO public.redirect_link_folders(name,default_permission) VALUES('Hidden','none') RETURNING id INTO hidden;
 result:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('slug','acl-fixture','target','/events','folderId',f))));
 link_id:=(result->0->'link'->>'id')::uuid;
 IF public.redirect_session_principal(u,'links:read')->>'id'<>m::text THEN RAISE EXCEPTION 'Session membership bridge failed';END IF;
 result:=public.redirect_management_list(p_token_id=>m);
 IF (result->>'count')::int<>1 OR (result->'data'->0->>'canEdit')::boolean THEN RAISE EXCEPTION 'View permission failed';END IF;
 BEGIN
  PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',link_id,'data',jsonb_build_object('comment','denied'))),m);
  RAISE EXCEPTION 'Viewer wrote link';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 result:=public.redirect_workspace_resource('folders','list',p_token_id=>m);
 IF (result->>'count')::int<>1 OR (result#>>'{data,0,canEdit}')::boolean OR (result#>>'{data,0,canManage}')::boolean THEN RAISE EXCEPTION 'Folder visibility or capabilities incorrect';END IF;
 BEGIN
  PERFORM public.redirect_workspace_resource('folders','get',hidden,p_token_id=>m);
  RAISE EXCEPTION 'Hidden detail disclosed';EXCEPTION WHEN no_data_found THEN NULL;
 END;
 INSERT INTO public.redirect_folder_members VALUES(f,m,'owner'),(f,viewer,'owner'),(f,machine,'edit');
 result:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',link_id,'data',jsonb_build_object('comment','allowed'))),m);
 IF result->0->'link'->>'comment'<>'allowed' THEN RAISE EXCEPTION 'Owner could not edit';END IF;
 BEGIN
  PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','update','id',link_id,'data',jsonb_build_object('folderId',hidden))),m);
  RAISE EXCEPTION 'Moved into inaccessible destination';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 BEGIN
  PERFORM public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('target','/events','folderId',hidden))),m);
  RAISE EXCEPTION 'Created in inaccessible destination';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 BEGIN
  PERFORM public.redirect_workspace_resource('folders','delete',f,p_token_id=>m);
  RAISE EXCEPTION 'Folder deletion exposed contents in unfiled';EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
 result:=public.redirect_workspace_resource('folders','create',p_values=>'{"name":"Member folder"}',p_token_id=>m);
 own_folder:=(result->>'id')::uuid;
 IF public.redirect_folder_rank(m,own_folder)<>3 THEN RAISE EXCEPTION 'Creator not owner';END IF;
 result:=public.redirect_folder_access(own_folder,jsonb_build_object('defaultPermission','none','overrides',jsonb_build_array(jsonb_build_object('memberId',machine,'permission','view'))),m);
 IF public.redirect_folder_rank(machine,own_folder)<>1 THEN RAISE EXCEPTION 'Override not applied';END IF;
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,member_id,created_by,expires_at) VALUES('Machine',repeat('a',64),'fixture',ARRAY['links:read','links:write','events:read','workspace:read','workspace:write','conversions:write'],machine,u,now()+interval '1 day') RETURNING id INTO token_id;
 IF (public.redirect_folder_capabilities(f,token_id)->>'canEdit')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'Editor token capability missing';END IF;
 UPDATE public.redirect_api_tokens SET scopes=ARRAY['workspace:read'] WHERE id=token_id;
 IF (public.redirect_folder_capabilities(f,token_id)->>'canEdit')::boolean OR (public.redirect_folder_capabilities(f,token_id)->>'canManage')::boolean THEN RAISE EXCEPTION 'Read-only token capability overclaimed';END IF;
 UPDATE public.redirect_api_tokens SET scopes=ARRAY['links:read','links:write','events:read','workspace:read','workspace:write','conversions:write'] WHERE id=token_id;
 IF NOT(link_id=ANY(public.redirect_management_scope(token_id,'links:write'))) THEN RAISE EXCEPTION 'Bound credential lacked editor access';END IF;
 result:=public.redirect_scoped_variant_performance(link_id,m);
 IF jsonb_typeof(result)<>'array' THEN RAISE EXCEPTION 'Variant response not an array';END IF;
 click:=public.record_redirect_visit(link_id,'/go/acl-fixture',NULL,NULL,'fixture','CH','fixture',302,NULL,'/events','{}');
 result:=public.redirect_scoped_analytics('report',p_token_id=>token_id);
 IF (result#>>'{totals,clicks}')::int<>1 THEN RAISE EXCEPTION 'Accessible analytics missing';END IF;
 UPDATE public.redirect_folder_members SET permission='none' WHERE folder_id=f AND member_id=machine;
 BEGIN
  PERFORM public.redirect_scoped_variant_performance(link_id,token_id);
  RAISE EXCEPTION 'Variant metrics disclosed after permission downgrade';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 BEGIN
  PERFORM public.redirect_policy_resource(link_id,'get',p_token_id=>token_id);
  RAISE EXCEPTION 'Policy disclosed after permission downgrade';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 result:=public.redirect_scoped_analytics('report',p_token_id=>token_id);
 IF (result#>>'{totals,clicks}')::int<>0 THEN RAISE EXCEPTION 'Analytics disclosed inaccessible link';END IF;
 IF cardinality(public.redirect_management_scope(token_id,'links:read'))<>0 THEN RAISE EXCEPTION 'Live downgrade ignored';END IF;
 BEGIN
  PERFORM public.record_redirect_conversion(jsonb_build_object('kind','lead','clickId',click,'customerExternalId','acl-customer','eventId','acl-lead','eventName','Sign up'),token_id);
  RAISE EXCEPTION 'Bound credential converted an inaccessible link';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 IF cardinality(public.redirect_management_scope(token_id,'conversions:write'))<>0 THEN RAISE EXCEPTION 'Conversion ACL bypass';END IF;
 UPDATE public.redirect_api_tokens SET member_id=viewer WHERE id=token_id;
 IF cardinality(public.redirect_management_scope(token_id,'links:write'))<>0 OR NOT(link_id=ANY(public.redirect_management_scope(token_id,'links:read'))) THEN RAISE EXCEPTION 'Workspace viewer cap failed';END IF;
 BEGIN
  PERFORM public.redirect_workspace_resource('folders','create',p_values=>'{"name":"Denied"}',p_token_id=>token_id);
  RAISE EXCEPTION 'Viewer created folder';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 UPDATE public.redirect_api_tokens SET member_id=m WHERE id=token_id;
 UPDATE public.redirect_workspace_members SET active=false WHERE id=m;
 BEGIN
  PERFORM public.redirect_management_list(p_token_id=>token_id);
  RAISE EXCEPTION 'Inactive member credential survived';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 BEGIN
  PERFORM public.redirect_session_principal(u,'events:read');
  RAISE EXCEPTION 'Inactive member session survived';EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 DELETE FROM auth.users WHERE id=u;
 IF EXISTS(SELECT FROM public.redirect_api_tokens WHERE id=token_id) THEN RAISE EXCEPTION 'Deleted member token upgraded to unrestricted';END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF has_function_privilege(current_user,'public.redirect_session_principal(uuid,text)','execute') OR has_function_privilege(current_user,'public.redirect_folder_access(uuid,jsonb,uuid)','execute') THEN RAISE EXCEPTION 'Private ACL RPC exposed';END IF;
 BEGIN PERFORM * FROM public.redirect_workspace_members;RAISE EXCEPTION 'Membership leaked through Data API';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END $$;
ROLLBACK;
