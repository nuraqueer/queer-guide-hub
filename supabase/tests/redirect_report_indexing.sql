BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE actor uuid:=gen_random_uuid();one uuid;r jsonb;plain jsonb;indexed jsonb;checked jsonb;result jsonb;
BEGIN
 INSERT INTO auth.users(id) VALUES(actor);INSERT INTO public.user_roles VALUES(actor,'admin');
 INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','index-report','https://example.com/private') RETURNING id INTO one;
 r:=public.redirect_saved_report_resource('create',actor,NULL,p_values=>jsonb_build_object('name','Index choice','filters',jsonb_build_object('linkIds',jsonb_build_array(one))));
 plain:=public.redirect_report_share_resource('create',actor,NULL,(r->>'id')::uuid,p_values=>jsonb_build_object('title','Not indexed','reportVersion',r->>'version'));
 IF (plain->>'allowIndexing')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'Sharing enabled indexing by default';END IF;
 indexed:=public.redirect_report_share_resource('create',actor,NULL,(r->>'id')::uuid,p_values=>jsonb_build_object('title','Explicitly indexed','reportVersion',r->>'version','allowIndexing',true));
 IF (indexed->>'allowIndexing')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'Explicit indexing not persisted';END IF;
 result:=public.redirect_report_share_resource('list',actor,NULL,(r->>'id')::uuid);
 IF NOT EXISTS(SELECT FROM jsonb_array_elements(result->'data') x WHERE x->>'id'=indexed->>'id' AND (x->>'allowIndexing')::boolean) THEN RAISE EXCEPTION 'Publication list lost indexing choice';END IF;
 checked:=public.redirect_public_report_check((indexed->>'id')::uuid,repeat('a',64));
 result:=public.redirect_public_report_read((indexed->>'id')::uuid,(checked->>'version')::uuid,false);
 IF (result->>'allowIndexing')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'Live report lost indexing choice';END IF;
 BEGIN PERFORM public.redirect_report_share_resource('create',actor,NULL,(r->>'id')::uuid,p_values=>jsonb_build_object('title','Incompatible','reportVersion',r->>'version','allowIndexing',true),p_password_hash=>'{}');RAISE EXCEPTION 'Password and indexing combined';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 BEGIN UPDATE public.redirect_report_shares SET password_hash='{}' WHERE id=(indexed->>'id')::uuid;RAISE EXCEPTION 'Password/indexing constraint absent';EXCEPTION WHEN check_violation THEN NULL;END;
 PERFORM public.redirect_report_share_resource('revoke',actor,NULL,(r->>'id')::uuid,(indexed->>'id')::uuid);
 BEGIN PERFORM public.redirect_public_report_read((indexed->>'id')::uuid,(checked->>'version')::uuid,false);RAISE EXCEPTION 'Revoked report still indexed';EXCEPTION WHEN no_data_found THEN NULL;END;
END $$;
ROLLBACK;
