BEGIN;
ALTER TABLE public.redirect_link_folders DROP CONSTRAINT redirect_link_folders_pending_tenant_fence;
ALTER TABLE public.redirect_link_tags DROP CONSTRAINT redirect_link_tags_pending_tenant_fence;
ALTER TABLE public.redirect_utm_templates DROP CONSTRAINT redirect_utm_templates_pending_tenant_fence;
SET LOCAL ROLE service_role;
DO $$
DECLARE other uuid:=gen_random_uuid();kind text;table_name text;foreign_id uuid;own_id uuid;result jsonb;before_row jsonb;after_row jsonb;
BEGIN
 INSERT INTO public.redirect_workspaces(id,name,slug) VALUES(other,'Resource names fixture','resource-names-fixture');
 FOREACH kind IN ARRAY ARRAY['folders','tags','templates'] LOOP
  table_name:=CASE kind WHEN 'folders' THEN 'redirect_link_folders' WHEN 'tags' THEN 'redirect_link_tags' ELSE 'redirect_utm_templates' END;
  EXECUTE format('INSERT INTO public.%I(workspace_id,name) VALUES($1,$2) RETURNING id,to_jsonb(%I.*)',table_name,table_name) INTO foreign_id,before_row USING other,' Shared resource name ';
  result:=public.redirect_workspace_resource(kind,'create',p_values=>'{"name":"shared RESOURCE name"}');own_id:=(result->>'id')::uuid;
  IF own_id=foreign_id OR result->>'workspace_id'<>'58aa4340-8f21-4b7f-9a10-90be2da89c01' THEN RAISE EXCEPTION 'Same-name creation used foreign row';END IF;
  BEGIN PERFORM public.redirect_workspace_resource(kind,'create',p_values=>'{"name":" SHARED resource NAME "}');RAISE EXCEPTION 'Same-workspace normalized duplicate accepted';EXCEPTION WHEN unique_violation THEN NULL;END;
  BEGIN PERFORM public.redirect_workspace_resource(kind,'update',foreign_id,'{"name":"denied"}');RAISE EXCEPTION 'Same name enabled foreign mutation';EXCEPTION WHEN no_data_found THEN NULL;END;
  BEGIN EXECUTE format('INSERT INTO public.%I(workspace_id,name) VALUES($1,$2)',table_name) USING other,'shared resource name';RAISE EXCEPTION 'Foreign normalized duplicate accepted';EXCEPTION WHEN unique_violation THEN NULL;END;
  EXECUTE format('SELECT to_jsonb(r) FROM public.%I r WHERE id=$1',table_name) INTO after_row USING foreign_id;
  IF after_row<>before_row THEN RAISE EXCEPTION 'Same-name operations changed foreign row';END IF;
 END LOOP;
END $$;
ROLLBACK;
