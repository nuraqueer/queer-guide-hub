BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT set_config('email_template_test.id', gen_random_uuid()::text, true);
INSERT INTO public.email_templates(id, template_key, name, subject, html_content, is_active)
VALUES (current_setting('email_template_test.id')::uuid,
 'rls_email_template_probe_' || current_setting('email_template_test.id'),
 'Transactional email policy probe', 'Original subject', '<p>Probe</p>', false);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"role":"authenticated","user_role":"admin"}', true);
DO $$ DECLARE affected integer; BEGIN
 UPDATE public.email_templates SET subject = 'Admin update confirmed'
 WHERE id = current_setting('email_template_test.id')::uuid;
 GET DIAGNOSTICS affected = ROW_COUNT;
 IF affected <> 1 THEN RAISE EXCEPTION 'Admin update affected % rows', affected; END IF;
END $$;
DO $$ DECLARE staff_role text; affected integer; BEGIN
 FOREACH staff_role IN ARRAY ARRAY['moderator', 'editor', 'user'] LOOP
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role','authenticated','user_role',staff_role)::text, true);
  UPDATE public.email_templates SET subject = 'Denied update'
  WHERE id = current_setting('email_template_test.id')::uuid;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 0 THEN RAISE EXCEPTION 'Role % unexpectedly updated a template', staff_role; END IF;
 END LOOP;
END $$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claims', '{"role":"anon","user_role":"admin"}', true);
DO $$ DECLARE affected integer; BEGIN
 BEGIN
  UPDATE public.email_templates SET subject = 'Denied anonymous update'
  WHERE id = current_setting('email_template_test.id')::uuid;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 0 THEN RAISE EXCEPTION 'Anonymous role unexpectedly updated a template'; END IF;
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END $$;
RESET ROLE;
SELECT 'admin update confirmed; moderator/editor/member/anonymous updates denied' AS verification;
ROLLBACK;
