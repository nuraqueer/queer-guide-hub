BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE actor uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();member uuid;key uuid;domain uuid;visible uuid;hidden uuid;folder uuid;d jsonb;r jsonb;image jsonb;second jsonb;profile jsonb;count_before bigint;clicks_before bigint;w jsonb;
BEGIN
 INSERT INTO auth.users(id) VALUES(actor),(outsider);INSERT INTO public.user_roles VALUES(actor,'admin');
 d:=public.redirect_domain_resource('create',actor,p_values=>'{"hostname":"qr-images.example.com"}');domain:=(d->>'id')::uuid;
 UPDATE public.redirect_domains SET ownership_state='verified',verified_until=now()+interval '1 day',provider_id='fixture-image',routing_provider_id='fixture-image',routing_protocol=1,routing_seen_at=now() WHERE id=domain;
 INSERT INTO public.redirect_domain_jobs(domain_id,zone_id,cname_target,requested_by,state,provider_status,ssl_status,checked_at) VALUES(domain,repeat('a',32),'links.queer.guide',actor,'ready','active','active',now());
 r:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('target','/private-destination','domainId',domain,'isDomainRoot',true))));visible:=(r#>>'{0,link,id}')::uuid;
 INSERT INTO public.redirect_link_folders(name,default_permission) VALUES('Hidden images','none') RETURNING id INTO folder;
 r:=public.redirect_management_mutate(jsonb_build_array(jsonb_build_object('operation','create','data',jsonb_build_object('target','/private-secret','folderId',folder))));hidden:=(r#>>'{0,link,id}')::uuid;
 INSERT INTO public.redirect_workspace_members(user_id,kind,role,label) VALUES(outsider,'user','viewer','Image viewer') RETURNING id INTO member;
 INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,redirect_ids,member_id,created_by,expires_at) VALUES('Image key',repeat('e',64),'fixture',ARRAY['links:read'],ARRAY[visible],member,actor,now()+interval '1 day') RETURNING id INTO key;
 image:=public.redirect_qr_image_resource('create',actor,p_values=>jsonb_build_object('linkId',visible),p_hash=>repeat('a',64));
 IF image?'token_hash' OR image?'principal_key' OR image->>'expiresAt' IS NOT NULL THEN RAISE EXCEPTION 'Private hash/principal exposed or default expiry changed';END IF;
 SELECT count(*) INTO count_before FROM public.redirect_events;SELECT click_count INTO clicks_before FROM public.redirects WHERE id=visible;
 profile:=public.redirect_public_qr_image(repeat('a',64));
 IF profile->>'url'<>'https://qr-images.example.com/' OR NOT(profile->>'tracked')::boolean OR profile-ARRAY['url','tracked','style','effectiveLogo','logoSource']::text[]<>'{}' OR profile::text LIKE '%private-destination%' THEN RAISE EXCEPTION 'Public image profile leaked details or lost canonical domain root';END IF;
 IF (SELECT count(*) FROM public.redirect_events)<>count_before OR (SELECT click_count FROM public.redirects WHERE id=visible)<>clicks_before THEN RAISE EXCEPTION 'Image read consumed a click';END IF;
 w:=public.redirect_qr_style_resource(actor,p_values=>'{"version":null,"style":{"dots":"joined"}}');
 IF public.redirect_public_qr_image(repeat('a',64))#>>'{style,dots}'<>'joined' THEN RAISE EXCEPTION 'Image failed to follow workspace appearance';END IF;
 d:=public.redirect_qr_style_resource(actor,domain,'{"version":null,"style":{"border":"rounded"},"logoMode":"none"}');
 IF public.redirect_public_qr_image(repeat('a',64))#>>'{style,border}'<>'rounded' OR public.redirect_public_qr_image(repeat('a',64))->>'logoSource'<>'hidden' THEN RAISE EXCEPTION 'Image failed to follow domain appearance/hide';END IF;
 second:=public.redirect_qr_image_resource('create',p_principal=>key,p_values=>jsonb_build_object('linkId',visible,'style','{"dots":"circle"}'::jsonb,'logoMode','none'),p_hash=>repeat('b',64));
 IF public.redirect_public_qr_image(repeat('b',64))#>>'{style,dots}'<>'circle' THEN RAISE EXCEPTION 'Explicit appearance override lost';END IF;
 BEGIN PERFORM public.redirect_qr_image_resource('create',p_principal=>key,p_values=>jsonb_build_object('linkId',hidden),p_hash=>repeat('c',64));RAISE EXCEPTION 'Scoped key exposed hidden link';EXCEPTION WHEN no_data_found THEN NULL;END;
 BEGIN PERFORM public.redirect_qr_image_resource('create',p_principal=>key,p_values=>'{"url":"https://example.com/"}',p_hash=>repeat('c',64));RAISE EXCEPTION 'Key created unbound explicit URL';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.redirect_qr_image_resource('create',outsider,p_values=>jsonb_build_object('linkId',visible),p_hash=>repeat('c',64));RAISE EXCEPTION 'Unprivileged owner bypass';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.redirect_qr_image_resource('create',actor,member,p_values=>jsonb_build_object('linkId',visible),p_hash=>repeat('c',64));RAISE EXCEPTION 'Session impersonated another member';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 r:=public.redirect_qr_image_resource('list',p_principal=>key,p_limit=>1);
 IF jsonb_array_length(r->'data')<>1 OR r#>>'{data,0,id}'<>second->>'id' OR r->>'nextCursor' IS NOT NULL THEN RAISE EXCEPTION 'Key list escaped author scope';END IF;
 r:=public.redirect_qr_image_resource('list',actor,p_limit=>1);
 IF r->>'nextCursor' IS NULL THEN RAISE EXCEPTION 'Owner image page omitted cursor';END IF;
 r:=public.redirect_qr_image_resource('list',actor,p_limit=>1,p_after=>(r->>'nextCursor')::uuid);
 IF jsonb_array_length(r->'data')<>1 OR r->>'nextCursor' IS NOT NULL THEN RAISE EXCEPTION 'Image page cursor incorrect';END IF;
 BEGIN PERFORM public.redirect_qr_image_resource('revoke',p_principal=>key,p_id=>(image->>'id')::uuid,p_values=>jsonb_build_object('version',image->>'version'));RAISE EXCEPTION 'Key revoked another creator image';EXCEPTION WHEN no_data_found THEN NULL;END;
 UPDATE public.redirect_api_tokens SET redirect_ids=ARRAY[hidden] WHERE id=key;
 IF public.redirect_public_qr_image(repeat('b',64)) IS NOT NULL THEN RAISE EXCEPTION 'Narrowed key kept public image access';END IF;
 UPDATE public.redirect_api_tokens SET redirect_ids=ARRAY[visible],revoked_at=now() WHERE id=key;
 IF public.redirect_public_qr_image(repeat('b',64)) IS NOT NULL THEN RAISE EXCEPTION 'Revoked key kept image';END IF;
 UPDATE public.redirect_api_tokens SET revoked_at=NULL WHERE id=key;
 UPDATE public.redirect_workspace_members SET active=false WHERE id=member;
 IF public.redirect_public_qr_image(repeat('b',64)) IS NOT NULL THEN RAISE EXCEPTION 'Inactive member key kept image';END IF;
 UPDATE public.redirect_workspace_members SET active=true WHERE id=member;
 r:=public.redirect_qr_image_resource('create',outsider,member,p_values=>jsonb_build_object('linkId',visible),p_hash=>repeat('c',64));
 INSERT INTO public.redirect_link_metadata(redirect_key,folder_id) VALUES('redirects:'||visible,folder) ON CONFLICT(redirect_key) DO UPDATE SET folder_id=excluded.folder_id;
 IF public.redirect_public_qr_image(repeat('b',64)) IS NOT NULL OR public.redirect_public_qr_image(repeat('c',64)) IS NOT NULL THEN RAISE EXCEPTION 'Folder denial did not close image';END IF;
 DELETE FROM public.redirect_link_metadata WHERE redirect_key='redirects:'||visible;
 BEGIN PERFORM public.redirect_qr_image_resource('revoke',actor,p_id=>(image->>'id')::uuid,p_values=>jsonb_build_object('version',gen_random_uuid()));RAISE EXCEPTION 'Stale image version accepted';EXCEPTION WHEN unique_violation THEN NULL;END;
 PERFORM public.redirect_qr_image_resource('revoke',actor,p_id=>(image->>'id')::uuid,p_values=>jsonb_build_object('version',image->>'version'));
 IF public.redirect_public_qr_image(repeat('a',64)) IS NOT NULL THEN RAISE EXCEPTION 'Explicitly revoked image survived';END IF;
 r:=public.redirect_qr_image_resource('create',actor,p_values=>'{"url":"https://example.com/path?q=1","expiresAt":null}',p_hash=>repeat('d',64));
 IF public.redirect_public_qr_image(repeat('d',64))->>'url'<>'https://example.com/path?q=1' OR (public.redirect_public_qr_image(repeat('d',64))->>'tracked')::boolean THEN RAISE EXCEPTION 'Explicit URL changed or was marked managed';END IF;
 DELETE FROM public.user_roles WHERE user_id=actor AND role='admin';
 IF public.redirect_public_qr_image(repeat('d',64)) IS NOT NULL THEN RAISE EXCEPTION 'Former owner retained public branding access';END IF;
 INSERT INTO public.user_roles VALUES(actor,'admin');
 UPDATE public.redirect_qr_image_links SET created_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE id=(r->>'id')::uuid;
 IF public.redirect_public_qr_image(repeat('d',64)) IS NOT NULL THEN RAISE EXCEPTION 'Expired image survived';END IF;
 BEGIN PERFORM public.redirect_qr_image_resource('create',actor,p_values=>'{"url":"https://user:password@example.com/"}',p_hash=>repeat('f',64));RAISE EXCEPTION 'URL credentials accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 BEGIN PERFORM public.redirect_qr_image_resource('create',actor,p_values=>jsonb_build_object('linkId',visible,'style','{"unknown":null}'::jsonb),p_hash=>repeat('f',64));RAISE EXCEPTION 'Unknown nullable branding accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 DELETE FROM public.redirects WHERE id=visible;
 IF public.redirect_public_qr_image(repeat('b',64)) IS NOT NULL OR EXISTS(SELECT FROM public.redirect_qr_image_links WHERE link_id=visible) THEN RAISE EXCEPTION 'Deleted link retained capability';END IF;
 IF has_table_privilege('authenticated','public.redirect_qr_image_links','SELECT') OR has_function_privilege('anon','public.redirect_public_qr_image(text)','execute') THEN RAISE EXCEPTION 'Private image API exposed through Data API';END IF;
END $$;
DO $$
DECLARE actor uuid:=gen_random_uuid();other uuid:=gen_random_uuid();fresh uuid:=gen_random_uuid();r jsonb;
BEGIN
 INSERT INTO auth.users(id) VALUES(actor),(other),(fresh);INSERT INTO public.user_roles VALUES(actor,'admin'),(other,'admin'),(fresh,'admin');
 INSERT INTO public.redirect_qr_image_links(token_hash,creator_user_id,principal_key,encoded_url,created_at)
 SELECT md5('active'||i)||md5('active-hash'||i),actor,'owner:'||actor::text,'https://example.com/',clock_timestamp()-interval '2 hours' FROM generate_series(1,100) i;
 r:=public.redirect_qr_image_resource('create',actor,p_values=>'{"url":"https://example.com/"}',p_hash=>repeat('1',64));
 IF r->>'retryAfter'<>'3600' THEN RAISE EXCEPTION 'Active image budget not enforced';END IF;
 UPDATE public.redirect_qr_image_links SET revoked_at=clock_timestamp() WHERE creator_user_id=actor;
 INSERT INTO public.redirect_qr_image_links(token_hash,creator_user_id,principal_key,encoded_url,revoked_at)
 SELECT md5('hour'||i)||md5('hour-hash'||i),actor,'owner:'||actor::text,'https://example.com/',clock_timestamp() FROM generate_series(1,60) i;
 r:=public.redirect_qr_image_resource('create',actor,p_values=>'{"url":"https://example.com/"}',p_hash=>repeat('2',64));
 IF r->>'retryAfter'<>'3600' THEN RAISE EXCEPTION 'Hourly image budget not enforced';END IF;
 DELETE FROM public.redirect_qr_image_links WHERE creator_user_id=actor;
 r:=public.redirect_qr_image_resource('create',actor,p_values=>'{"url":"https://example.com/"}',p_hash=>repeat('2',64));
 IF r->>'retryAfter'<>'3600' THEN RAISE EXCEPTION 'Deleted records erased hourly image budget';END IF;
 INSERT INTO public.redirect_qr_image_links(token_hash,creator_user_id,principal_key,encoded_url,revoked_at)
 SELECT md5('global'||i)||md5('global-hash'||i),other,'owner:'||other::text,'https://example.com/',clock_timestamp() FROM generate_series(1,540) i;
 r:=public.redirect_qr_image_resource('create',fresh,p_values=>'{"url":"https://example.com/"}',p_hash=>repeat('3',64));
 IF r->>'retryAfter'<>'3600' THEN RAISE EXCEPTION 'Global image budget not enforced';END IF;
END $$;
DO $$
DECLARE actor uuid:=gen_random_uuid();old_id uuid;active_id uuid;r jsonb;
BEGIN
 INSERT INTO auth.users(id) VALUES(actor);INSERT INTO public.user_roles VALUES(actor,'admin');
 INSERT INTO public.redirect_qr_image_links(token_hash,creator_user_id,principal_key,encoded_url,created_at,revoked_at)
 VALUES(repeat('4',64),actor,'owner:'||actor::text,'https://example.com/',now()-interval '100 days',now()-interval '95 days') RETURNING id INTO old_id;
 INSERT INTO public.redirect_qr_image_links(token_hash,creator_user_id,principal_key,encoded_url,created_at)
 VALUES(repeat('5',64),actor,'owner:'||actor::text,'https://example.com/',now()-interval '100 days') RETURNING id INTO active_id;
 r:=public.prune_redirect_qr_image_history(1);
 IF r->>'events'<>'1' OR r->>'images'<>'1' OR EXISTS(SELECT FROM public.redirect_qr_image_links WHERE id=old_id) OR NOT EXISTS(SELECT FROM public.redirect_qr_image_links WHERE id=active_id) THEN RAISE EXCEPTION 'Retention removed active image or ignored batch/grace';END IF;
 IF has_table_privilege('authenticated','public.redirect_qr_image_creation_log','SELECT') OR has_function_privilege('anon','public.prune_redirect_qr_image_history(integer)','execute') THEN RAISE EXCEPTION 'Private budget/retention exposed';END IF;
END $$;
ROLLBACK;
