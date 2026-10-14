-- Execute after redirect_link_workspace. Fixtures are rolled back.
BEGIN;
INSERT INTO auth.users(id) VALUES('00000000-0000-4000-8000-000000000001');
INSERT INTO public.user_roles VALUES('00000000-0000-4000-8000-000000000001','admin');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"role":"authenticated","user_role":"admin","sub":"00000000-0000-4000-8000-000000000001"}';
DO $$
DECLARE f uuid; t uuid; saved jsonb; n bigint; unknown_tag uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.redirect_link_folders(name) VALUES ('__workspace_fixture') RETURNING id INTO f;
  INSERT INTO public.redirect_link_tags(name,color) VALUES ('__tag_fixture','pink') RETURNING id INTO t;
  INSERT INTO public.redirect_utm_templates(name,parameters) VALUES ('__template_fixture','{"utm_source":"qr","ref":"team"}');
  SELECT public.create_redirect_campaign_link('workspace-fixture-link','/tags',f,ARRAY[t,t]) INTO saved;
  IF (SELECT count(*) FROM public.redirect_link_tag_assignments WHERE redirect_key='redirects:' || (saved->>'id')) <> 1 THEN
    RAISE EXCEPTION 'Tags were not deduplicated/assigned';
  END IF;
  PERFORM public.set_redirect_link_metadata('redirects:' || (saved->>'id'),f,ARRAY[t],'See https://queer.guide');
  IF (SELECT comment FROM public.redirect_link_metadata WHERE redirect_key='redirects:' || (saved->>'id')) <> 'See https://queer.guide' THEN
    RAISE EXCEPTION 'Comment not persisted';
  END IF;
  SELECT count(*) INTO n FROM public.redirects;
  BEGIN
    PERFORM public.create_redirect_campaign_link('workspace-invalid-tag','/tags',f,ARRAY[unknown_tag]);
    RAISE EXCEPTION 'Unknown tag unexpectedly accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  IF (SELECT count(*) FROM public.redirects) <> n THEN RAISE EXCEPTION 'Failed assignment left an orphan link'; END IF;
  BEGIN
    INSERT INTO public.redirect_utm_templates(name,parameters) VALUES ('__invalid_template','{"utm_source":{"bad":true}}');
    RAISE EXCEPTION 'Non-string template value accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  DELETE FROM public.redirect_link_tags WHERE id=t;
  IF EXISTS (SELECT FROM public.redirect_link_tag_assignments WHERE tag_id=t) THEN RAISE EXCEPTION 'Tag deletion left assignments'; END IF;
  DELETE FROM public.redirect_link_folders WHERE id=f;
  IF EXISTS (SELECT FROM public.redirect_link_metadata WHERE folder_id=f) THEN RAISE EXCEPTION 'Folder deletion did not unfile links'; END IF;
END $$;
SET LOCAL request.jwt.claims = '{"role":"authenticated","user_role":"user"}';
DO $$
BEGIN
  IF EXISTS (SELECT FROM public.redirect_link_metadata) OR EXISTS (SELECT FROM public.redirect_utm_templates) THEN
    RAISE EXCEPTION 'Private workspace metadata visible to ordinary users';
  END IF;
  BEGIN
    PERFORM public.set_redirect_link_metadata('forbidden',NULL,ARRAY[]::uuid[],'private');
    RAISE EXCEPTION 'Ordinary member modified workspace';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
ROLLBACK;
