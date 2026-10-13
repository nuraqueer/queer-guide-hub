BEGIN;
INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','throttle-fixture','https://example.com');
SET LOCAL ROLE service_role;
DO $$
DECLARE link_id uuid; n integer; retry integer;
BEGIN
 SELECT id INTO link_id FROM public.redirects WHERE slug='throttle-fixture';
 FOR n IN 1..10 LOOP
  IF public.reserve_redirect_password_attempt(link_id,repeat('a',64))<>0 THEN RAISE EXCEPTION 'Attempt denied early'; END IF;
 END LOOP;
 retry := public.reserve_redirect_password_attempt(link_id,repeat('a',64));
 IF retry NOT BETWEEN 1 AND 900 THEN RAISE EXCEPTION 'Missing bounded retry'; END IF;
 IF public.reserve_redirect_password_attempt(link_id,repeat('b',64))<>0 THEN RAISE EXCEPTION 'Different client incorrectly denied'; END IF;
 UPDATE public.redirect_password_attempts SET window_started_at=clock_timestamp()-interval '16 minutes' WHERE redirect_id=link_id;
 IF public.reserve_redirect_password_attempt(link_id,repeat('a',64))<>0 THEN RAISE EXCEPTION 'Window did not reset'; END IF;
 IF (SELECT attempts FROM public.redirect_password_attempts WHERE redirect_id=link_id AND client_hash=repeat('a',64))<>1 THEN RAISE EXCEPTION 'Reset counter wrong'; END IF;
 UPDATE public.redirect_password_attempts SET attempts=1000 WHERE redirect_id=link_id AND client_hash='*';
 IF public.reserve_redirect_password_attempt(link_id,repeat('c',64)) NOT BETWEEN 1 AND 900 THEN RAISE EXCEPTION 'Shared link limit bypassed'; END IF;
 IF EXISTS(SELECT FROM public.redirect_password_attempts WHERE redirect_id=link_id AND client_hash=repeat('c',64)) THEN RAISE EXCEPTION 'Blocked request created a client bucket'; END IF;
 UPDATE public.redirect_password_attempts SET window_started_at=clock_timestamp()-interval '2 days' WHERE redirect_id=link_id;
 PERFORM public.reserve_redirect_password_attempt(link_id,repeat('d',64));
 IF EXISTS(SELECT FROM public.redirect_password_attempts WHERE window_started_at<clock_timestamp()-interval '1 day') THEN RAISE EXCEPTION 'Old client state retained'; END IF;
 BEGIN
  PERFORM public.reserve_redirect_password_attempt(link_id,'raw ip');
  RAISE EXCEPTION 'Invalid hash accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF has_table_privilege(current_user,'public.redirect_password_attempts','select') THEN RAISE EXCEPTION 'Private limiter visible'; END IF;
 IF has_function_privilege(current_user,'public.reserve_redirect_password_attempt(uuid,text)','execute') THEN RAISE EXCEPTION 'Public limiter callable'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
