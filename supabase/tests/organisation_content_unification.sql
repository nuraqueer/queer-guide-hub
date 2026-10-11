-- Run after the migration against an isolated database. Always rolls back fixtures.
begin;
do $$
declare
  org jsonb;
  saved jsonb;
  branch uuid;
  other_org jsonb;
  old_count int;
  new_count int;
begin
  org := public.cms_organisation_save(null,
    '{"name":"Unification test organisation","roles":["support"],"status":"draft","slug":""}', '[]', null);
  if org->>'slug' = '' or jsonb_array_length(org->'_locations') <> 0 then
    raise exception 'Locationless organisation creation failed';
  end if;
  if org->>'status' <> 'draft' then raise exception 'Draft was published'; end if;

  saved := public.cms_organisation_save((org->>'id')::uuid, '{"status":"active"}',
    '[{"name":"Unification branch one","address":"1 Example Street","city":"Zurich","country":"Switzerland","category":"bar","slug":""},
      {"name":"Unification branch two","address":"2 Example Street","city":"Bern","country":"Switzerland","category":"bar"}]',
    (org->>'updated_at')::timestamptz);
  if jsonb_array_length(saved->'_locations') <> 2 or not (saved->'roles' @> '["support","venue"]') then
    raise exception 'Multi-location save failed';
  end if;
  if saved->'_locations'->0->>'country' <> 'CH' or saved->>'country_id' is null then raise exception 'Country names did not normalize to linked ISO2'; end if;
  branch := (saved->'_locations'->0->>'id')::uuid;
  if saved->'_locations'->0->>'slug' = '' then raise exception 'Location slug was cleared'; end if;
  if public.cms_venue_organisation(branch) <> (org->>'id')::uuid then raise exception 'Identity resolution changed owner'; end if;

  -- A stale branch update rolls back the identity edit in the same transaction.
  update public.venues set updated_at = now() + interval '1 hour' where id = branch;
  begin
    perform public.cms_organisation_save((org->>'id')::uuid, '{"name":"Should roll back"}',
      jsonb_set(saved->'_locations', '{0,address}', '"Changed street"'),
      (saved->>'updated_at')::timestamptz);
    raise exception 'Stale location was accepted';
  exception when serialization_failure then null;
  end;
  if (select name from public.organizations where id=(org->>'id')::uuid) <> 'Unification test organisation' then
    raise exception 'Identity did not roll back';
  end if;

  -- Identity-only edits can ignore an unchanged branch whose timestamp has advanced.
  org := public.cms_organisation_save((org->>'id')::uuid, '{"description":"Updated identity","claim_status":"claimed","safety_gated":true}', null,
    (saved->>'updated_at')::timestamptz);
  if org->>'claim_status' <> 'unclaimed' or (org->>'safety_gated')::boolean then
    raise exception 'Protected fields were writable';
  end if;

  other_org := public.cms_organisation_save(null, '{"name":"Unification other organisation","roles":["advocacy"]}', '[]', null);
  begin
    perform public.cms_organisation_save((other_org->>'id')::uuid, '{}',
      jsonb_build_array(saved->'_locations'->0), (other_org->>'updated_at')::timestamptz);
    raise exception 'Cross-organisation branch was accepted';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.cms_organisation_save((org->>'id')::uuid, '{}', null, now() - interval '1 day');
    raise exception 'Stale organisation was accepted';
  exception when serialization_failure then null;
  end;

  -- Archival affects a location, not its owner's lifetime or other branches.
  org := public.cms_organisation_read((org->>'id')::uuid);
  org := public.cms_organisation_save((org->>'id')::uuid, '{}',
    jsonb_set(org->'_locations', '{0,review_status}', '"archived"'),
    (org->>'updated_at')::timestamptz);
  if org->>'status' <> 'active' or (org->>'is_defunct')::boolean then raise exception 'Branch archive dissolved its owner'; end if;
  if (public.get_organization(org->>'slug')->>'venue_count')::int <> 1 then raise exception 'Public identity exposed an archived location'; end if;
  if (select count(*) from public.organization_venues((org->>'id')::uuid)) <> 1 then raise exception 'Public location RPC exposed an archived location'; end if;

  -- New pipeline locations are linked automatically, with safety preserved.
  insert into public.venues(name,slug,address,category,safety_gated)
    values ('Unification imported location','unification-imported-location','Example Street','bar',true)
    returning id into branch;
  if (select organization_id from public.venues where id=branch) is null then
    raise exception 'New location lacks identity';
  end if;
  if not (select o.safety_gated from public.organizations o join public.venues v on v.organization_id=o.id where v.id=branch) then
    raise exception 'Location safety gate was lost';
  end if;
  perform public.search_documents_index_organizations((select organization_id from public.venues where id=branch));
  if exists (select 1 from public.search_documents sd join public.venues v on sd.entity_id=v.organization_id where v.id=branch and sd.entity_type='organization') then
    raise exception 'Generated venue-only identity duplicates location search';
  end if;

  -- Backfill: simulate an older unlinked location, then ensure a second run is a no-op.
  alter table public.venues disable trigger cms_location_identity_insert;
  insert into public.venues(name,slug,address,category) values ('Unification old location','unification-old-location','Example Street','bar') returning id into branch;
  alter table public.venues enable trigger cms_location_identity_insert;
  select count(*) into old_count from public.organizations;
  perform public.cms_venue_organisation(branch);
  perform public.cms_venue_organisation(branch);
  select count(*) into new_count from public.organizations;
  if new_count <> old_count + 1 then raise exception 'Backfill is not idempotent'; end if;

  -- Bounded rollout consumes only its cap and resumes from remaining locations.
  alter table public.venues disable trigger cms_location_identity_insert;
  insert into public.venues(name,slug,address,category) values
    ('Unification capped one','unification-capped-one','Example Street','bar'),
    ('Unification capped two','unification-capped-two','Example Street','bar');
  alter table public.venues enable trigger cms_location_identity_insert;
  if public.cms_backfill_venue_organisations(1) <> 1 then raise exception 'Backfill ignored batch cap'; end if;
  if public.cms_backfill_venue_organisations(1) <> 1 then raise exception 'Backfill did not resume'; end if;
  if public.cms_backfill_venue_organisations(1) <> 0 then raise exception 'Finished backfill was not a no-op'; end if;

  -- Common names must not exhaust the legacy mint helper's retry ceiling.
  for old_count in 1..25 loop
    insert into public.venues(name,slug,address,category) values
      ('Unification common name','unification-common-name-' || old_count,'Example Street','bar');
  end loop;

  -- The workflow is authoritative for publication, including privacy and restore.
  update public.cms_content_metadata set workflow_state='draft' where source_table='organizations' and source_id=(org->>'id')::uuid;
  if (select status from public.organizations where id=(org->>'id')::uuid) <> 'draft' then raise exception 'Draft workflow left identity public'; end if;
  update public.cms_content_metadata set workflow_state='published', visibility_level='public' where source_table='organizations' and source_id=(org->>'id')::uuid;
  if (select status from public.organizations where id=(org->>'id')::uuid) <> 'active' then raise exception 'Publish did not activate identity'; end if;
  update public.cms_content_metadata set visibility_level='private' where source_table='organizations' and source_id=(org->>'id')::uuid;
  if public.get_organization(org->>'slug') is not null then raise exception 'Private identity remained public'; end if;
  update public.cms_content_metadata set workflow_state='archived' where source_table='organizations' and source_id=(org->>'id')::uuid;
  if (select status from public.organizations where id=(org->>'id')::uuid) <> 'archived' then raise exception 'Workflow archive failed'; end if;
  update public.cms_content_metadata set workflow_state='published', visibility_level='public' where source_table='organizations' and source_id=(org->>'id')::uuid;
  if (select status from public.organizations where id=(org->>'id')::uuid) <> 'active' then raise exception 'Workflow restore failed'; end if;
  update public.organizations set status='draft' where id=(org->>'id')::uuid;
  if (select workflow_state from public.cms_content_metadata where source_table='organizations' and source_id=(org->>'id')::uuid) <> 'draft' then raise exception 'Status and workflow disagree'; end if;

  -- Pending content must not acquire a published identity during rollout.
  insert into public.venues(name,slug,address,category,review_status)
    values ('Unification pending location','unification-pending-location','Example Street','bar','pending') returning id into branch;
  if (select o.status from public.organizations o join public.venues v on v.organization_id=o.id where v.id=branch) <> 'draft' then
    raise exception 'Pending venue was promoted to a public identity';
  end if;

  -- The AFTER INSERT hook must preserve ordinary owner-created venue support.
  -- Its private core cannot be invoked directly through the authenticated API.
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  insert into public.venues(name,slug,address,category)
    values ('Unification owner location','unification-owner-location','Example Street','bar') returning id into branch;
  if (select o.status from public.organizations o join public.venues v on v.organization_id=o.id where v.id=branch) <> 'draft' then
    raise exception 'Unreviewed owner identity was made public';
  end if;
  perform set_config('request.jwt.claims', '', true);
  if has_function_privilege('authenticated', 'public.cms_venue_organisation_core(uuid)', 'execute') then
    raise exception 'Private owner-insert core is exposed';
  end if;

  if has_function_privilege('anon', 'public.cms_organisation_save(uuid,jsonb,jsonb,timestamptz)', 'execute')
    or has_function_privilege('authenticated', 'public.cms_organisation_patch(text,uuid,jsonb)', 'execute') then
    raise exception 'Private write helpers are publicly executable';
  end if;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  begin
    perform public.cms_organisation_read((org->>'id')::uuid);
    raise exception 'Anonymous caller read admin content';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.cms_organisation_save(null, '{"name":"Forbidden","roles":["venue"]}', '[]', null);
    raise exception 'Anonymous caller wrote admin content';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claims', '', true);
end;
$$;
rollback;
