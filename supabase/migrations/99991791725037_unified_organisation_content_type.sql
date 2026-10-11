-- RECOVERED FROM PROD BY scripts/recover-migration-drift.mjs.
--
-- Applied to prod as version 99991791725037 with no repo file — the signature of
-- MCP `apply_migration`, which stamps a version and commits nothing. An applied
-- version with no file fails migration-versions on every PR in the repo and
-- makes `db push` refuse to run.
--
-- Reconstructed from `schema_migrations.statements`, which holds the PARSED
-- statements: trailing semicolons are stripped (re-added here) and any original
-- comment header is NOT recorded, so the reasoning that accompanied this
-- migration is lost. Verified by md5 against a server-computed digest.
--
-- Never re-run: `db push` matches on version and skips an applied one. The file
-- exists so history is complete and a rebuild from zero works.
-- Approved design: docs/plans/2026-10-11-unified-organisation-content-type-design.md
-- Organizations are identities; venues remain internal, independently addressable locations.
-- Apply, drain cms_backfill_venue_organisations in bounded batches, then release the CMS.

-- All write entry points retain the existing elevated-role gate. Helpers are not exposed.
create or replace function public.cms_venue_organisation_core(p_venue_id uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v public.venues;
  org_id uuid;
  candidates uuid[];
  claims jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  trusted_actor boolean;
begin
  trusted_actor := claims is null or coalesce(claims->>'role', '') = 'service_role'
    or public.has_any_role_jwt(array['admin'::public.app_role, 'moderator'::public.app_role]);
  select * into v from public.venues where id = p_venue_id for update;
  if not found then raise exception 'Location not found'; end if;
  if v.duplicate_of_id is not null then
    raise exception 'Location was merged; open its surviving location';
  end if;
  if v.organization_id is not null then return v.organization_id; end if;

  -- Shared domain alone is not identity evidence. A unique name/domain/geo match
  -- adopts an existing party; ambiguity gets its own auditable identity for review.
  if trusted_actor and nullif(public.org_normalize_domain(v.website), '') is not null
     and v.city_id is not null and v.country_id is not null then
    select array_agg(o.id) into candidates from public.organizations o
    where o.duplicate_of_id is null
      and lower(btrim(o.name)) = lower(btrim(v.name))
      and public.org_normalize_domain(o.website) = public.org_normalize_domain(v.website)
      and o.city_id = v.city_id and o.country_id = v.country_id
      and (o.status = 'active' or v.review_status = 'archived');
  end if;
  if cardinality(candidates) = 1 then
    org_id := candidates[1];
  else
    -- A deterministic location suffix avoids the legacy mint helper's 20-name
    -- retry ceiling for chains and common venue names during the large backfill.
    insert into public.organizations (name, slug, website, website_domain, city_id,
      country_id, logo_url, roles, field_provenance, status, description, email,
      phone, images, tags, target_groups, safety_gated, primary_venue_id, needs_attention)
    values (v.name, public.generate_slug(v.name) || '-location-' || v.id::text,
      v.website, public.org_normalize_domain(v.website), v.city_id, v.country_id,
      v.logo_url, array['venue'], jsonb_build_object('identity', jsonb_build_object(
        'source', 'unified_location', 'venue_id', v.id, 'at', now(),
        'ambiguous_candidates', coalesce(to_jsonb(candidates), '[]'::jsonb))),
      case when v.review_status = 'archived' then 'archived'
        when trusted_actor and v.review_status = 'approved' then 'active' else 'draft' end,
      v.description, v.email, v.phone, coalesce(v.images, '{}'), coalesce(v.tags, '{}'),
      coalesce(v.target_groups, '{}'), v.safety_gated, v.id,
      coalesce(cardinality(candidates) > 1, false)) returning id into org_id;
  end if;
  update public.venues set organization_id = org_id where id = v.id;
  update public.organizations set
    roles = case when roles @> array['venue'] then roles else array_append(roles, 'venue') end,
    primary_venue_id = coalesce(primary_venue_id, v.id)
  where id = org_id and (not roles @> array['venue'] or primary_venue_id is null);
  return org_id;
end;
$$;

revoke all on function public.cms_venue_organisation_core(uuid) from public, anon, authenticated, service_role;

-- Explicit legacy-editor resolution remains elevated; the private core is only
-- callable by trusted database functions after the original INSERT passed RLS.
create or replace function public.cms_venue_organisation(p_venue_id uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.assert_admin_or_internal();
  return public.cms_venue_organisation_core(p_venue_id);
end;
$$;

revoke all on function public.cms_venue_organisation(uuid) from public, anon;

grant execute on function public.cms_venue_organisation(uuid) to authenticated, service_role;

create or replace function public.cms_organisation_read(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare result jsonb;
begin
  perform public.assert_admin_or_internal();
  select to_jsonb(o) || jsonb_build_object('_cms_metadata',
    (select to_jsonb(m) from public.cms_content_metadata m where m.source_table = 'organizations' and m.source_id = o.id), '_locations', coalesce((
    select jsonb_agg(to_jsonb(v) order by v.created_at, v.id)
    from public.venues v where v.organization_id = o.id and v.duplicate_of_id is null
  ), '[]'::jsonb)) into result from public.organizations o where o.id = p_id;
  return result;
end;
$$;

revoke all on function public.cms_organisation_read(uuid) from public, anon;

grant execute on function public.cms_organisation_read(uuid) to authenticated, service_role;

-- Closed allowlists preserve claims, safety, provenance, quality and external IDs.
-- jsonb_populate_record supplies the actual column types, including arrays/JSON.
create or replace function public.cms_organisation_patch(p_table text, p_id uuid, p_data jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  allowed text[];
  assignments text;
  country_code text;
  country_ref uuid;
begin
  if p_table = 'organizations' then
    allowed := array['name','legal_name','slug','description','editorial_hook','editorial_long',
      'website','website_domain','email','phone','social','roles','tags','target_groups',
      'logo_url','cover_image_url','images','status','founded_at','dissolved_at','is_defunct'];
  elsif p_table = 'venues' then
    if p_data ? 'country' and nullif(p_data->>'country', '') is not null then
      -- Country autocomplete emits a name; the storage contract is ISO2.
      select c.code, c.id into country_code, country_ref from public.countries c
        where c.id = coalesce(nullif(p_data->>'country_id', '')::uuid,
          (select country_id from public.venues where id = p_id));
      if country_code is null then
        select c.code, c.id into country_code, country_ref from public.countries c
          where lower(c.name) = lower(btrim(p_data->>'country'))
             or c.code = upper(btrim(p_data->>'country')) limit 1;
      end if;
      if country_code is null then raise exception 'Select a recognised country for this location'; end if;
      p_data := jsonb_set(p_data, '{country}', to_jsonb(country_code));
      p_data := jsonb_set(p_data, '{country_id}', to_jsonb(country_ref));
    end if;
    allowed := array['name','slug','description','category','accommodation_type','address',
      'city','state','country','postal_code','latitude','longitude','city_id','country_id',
      'queer_village_id','phone','email','website','instagram','price_range','hours','amenities',
      'services','tags','accessibility_attributes','target_groups','accessibility_notes',
      'booking_url','venue_subtype','is_organizer','organizer_handles','content_language',
      'images','logo_url','is_featured','verification_source','verification_evidence',
      'verified','star_rating','closed_at','review_status'];
  else raise exception 'Unsupported table'; end if;
  select string_agg(format('%I = (jsonb_populate_record(null::public.%I, $1)).%I', key, p_table, key), ', ')
    into assignments from jsonb_object_keys(p_data) key where key = any(allowed);
  if assignments is not null then
    execute format('update public.%I set %s, updated_at = now() where id = $2', p_table, assignments)
      using p_data, p_id;
  end if;
end;
$$;

revoke all on function public.cms_organisation_patch(text,uuid,jsonb) from public, anon, authenticated, service_role;

create or replace function public.cms_organisation_save(
  p_id uuid, p_data jsonb, p_locations jsonb default null,
  p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  org_id uuid := p_id;
  o public.organizations;
  v public.venues;
  loc jsonb;
  patch jsonb;
  location_id uuid;
  supplied_ids uuid[] := '{}';
begin
  perform public.assert_admin_or_internal();
  if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Identity must be an object'; end if;
  if p_locations is not null and jsonb_typeof(p_locations) <> 'array' then raise exception 'Locations must be an array'; end if;
  if p_id is null then
    if nullif(btrim(p_data->>'name'), '') is null then raise exception 'Name is required'; end if;
    if jsonb_typeof(p_data->'roles') is distinct from 'array' or jsonb_array_length(p_data->'roles') = 0 then
      raise exception 'Choose at least one role';
    end if;
    org_id := gen_random_uuid();
    insert into public.organizations (id, name, slug, roles, field_provenance, status)
    values (org_id, btrim(p_data->>'name'),
      coalesce(nullif(p_data->>'slug', ''), public.generate_slug(p_data->>'name') || '-' || org_id::text),
      array(select jsonb_array_elements_text(p_data->'roles')),
      jsonb_build_object('identity', jsonb_build_object('source', 'cms', 'at', now())),
      coalesce(p_data->>'status', 'draft'));
  else
    select * into o from public.organizations where id = p_id for update;
    if not found or o.duplicate_of_id is not null then raise exception 'Organisation not found or merged'; end if;
    if p_expected_updated_at is null or o.updated_at is distinct from p_expected_updated_at then
      raise exception 'This organisation was modified by someone else. Reload before saving.' using errcode = '40001';
    end if;
  end if;
  if p_data ? 'roles' and (jsonb_typeof(p_data->'roles') is distinct from 'array' or jsonb_array_length(p_data->'roles') = 0) then
    raise exception 'Choose at least one role';
  end if;
  if p_data->>'slug' = '' then p_data := p_data - 'slug'; end if;
  p_data := p_data || (select coalesce(jsonb_object_agg(key, 'null'::jsonb), '{}') from jsonb_each(p_data) where key in ('founded_at', 'dissolved_at') and value = '""'::jsonb);
  perform public.cms_organisation_patch('organizations', org_id, p_data);

  if p_locations is not null then
    for loc in select value from jsonb_array_elements(p_locations) loop
      if jsonb_typeof(loc) <> 'object' then raise exception 'Invalid location'; end if;
      location_id := nullif(loc->>'id', '')::uuid;
      if location_id is null then
        if nullif(btrim(loc->>'name'), '') is null or nullif(btrim(loc->>'address'), '') is null
           or nullif(btrim(loc->>'city'), '') is null or nullif(btrim(loc->>'country'), '') is null then
          raise exception 'New locations require name, address, city and country';
        end if;
        insert into public.venues (name, slug, address, category, organization_id, created_by)
        values (loc->>'name', coalesce(nullif(loc->>'slug', ''), public.generate_slug(loc->>'name') || '-' || substr(gen_random_uuid()::text, 1, 8)),
          loc->>'address', coalesce(nullif(loc->>'category', ''), 'other'), org_id, auth.uid()) returning * into v;
        location_id := v.id;
        patch := loc;
      else
        if location_id = any(supplied_ids) then raise exception 'Duplicate location in save'; end if;
        select * into v from public.venues where id = location_id for update;
        if not found or v.organization_id is distinct from org_id or v.duplicate_of_id is not null then
          raise exception 'Location does not belong to this organisation' using errcode = '42501';
        end if;
        -- Ignore readonly/system fields. Only changed editable values need a lock check.
        select coalesce(jsonb_object_agg(key, value), '{}') into patch from jsonb_each(loc)
        where key not in ('id','created_at','created_by','updated_at','organization_id',
          'quality_score','needs_attention','verified_at','verified_by','duplicate_of_id')
          and value is distinct from to_jsonb(v)->key;
        if patch <> '{}'::jsonb and (nullif(loc->>'updated_at', '')::timestamptz is distinct from v.updated_at) then
          raise exception 'A location was modified by someone else. Reload before saving.' using errcode = '40001';
        end if;
      end if;
      supplied_ids := array_append(supplied_ids, location_id);
      patch := patch || (select coalesce(jsonb_object_agg(key, 'null'::jsonb), '{}') from jsonb_each(patch) where key in ('closed_at', 'city_id', 'country_id', 'queer_village_id', 'accommodation_type') and value = '""'::jsonb);
      if patch->>'slug' = '' then patch := patch - 'slug'; end if;
      perform public.cms_organisation_patch('venues', location_id, patch);
    end loop;
  end if;
  -- Location omission never deletes/unlinks a branch. Closure and archival are explicit.
  if exists (select 1 from public.venues where organization_id = org_id and duplicate_of_id is null) then
    update public.organizations set roles = case when roles @> array['venue'] then roles else array_append(roles, 'venue') end,
      primary_venue_id = coalesce(primary_venue_id, (select id from public.venues where organization_id = org_id and duplicate_of_id is null order by created_at, id limit 1)),
      city_id = coalesce(city_id, (select city_id from public.venues where organization_id = org_id and duplicate_of_id is null order by created_at, id limit 1)),
      country_id = coalesce(country_id, (select country_id from public.venues where organization_id = org_id and duplicate_of_id is null order by created_at, id limit 1)),
      updated_at = now() where id = org_id;
  end if;
  insert into public.cms_content_metadata(source_table, source_id, workflow_state, visibility_level, last_edited_by, last_edited_at)
    select 'organizations', id, (case status when 'active' then 'published' when 'archived' then 'archived' else 'draft' end)::public.cms_workflow_state, 'public'::public.cms_visibility_level, auth.uid(), now()
    from public.organizations where id = org_id
    on conflict (source_table, source_id) do nothing;
  return public.cms_organisation_read(org_id);
end;
$$;

revoke all on function public.cms_organisation_save(uuid,jsonb,jsonb,timestamptz) from public, anon;

grant execute on function public.cms_organisation_save(uuid,jsonb,jsonb,timestamptz) to authenticated, service_role;

create or replace function public.cms_backfill_venue_organisations(p_limit int default 100)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare location_id uuid; processed int := 0;
begin
  perform public.assert_admin_or_internal();
  for location_id in select id from public.venues
    where organization_id is null and duplicate_of_id is null
    order by id limit greatest(1, least(p_limit, 500)) for update skip locked
  loop
    perform public.cms_venue_organisation(location_id);
    processed := processed + 1;
  end loop;
  return processed;
end;
$$;

revoke all on function public.cms_backfill_venue_organisations(int) from public, anon, authenticated;

grant execute on function public.cms_backfill_venue_organisations(int) to service_role;

-- New locations written by the existing import/submission pipeline acquire an identity.
-- Skip already-linked nested-editor inserts and duplicate tombstones.
create or replace function public.cms_location_identity_insert()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.organization_id is null and new.duplicate_of_id is null then
    perform public.cms_venue_organisation_core(new.id);
  end if;
  return new;
end;
$$;

revoke all on function public.cms_location_identity_insert() from public, anon, authenticated, service_role;

drop trigger if exists cms_location_identity_insert on public.venues;

create trigger cms_location_identity_insert after insert on public.venues
  for each row execute function public.cms_location_identity_insert();

-- No mass writes or unmanaged cron in a migration: rollout drains the bounded RPC.
CREATE OR REPLACE FUNCTION public.search_documents_index_organizations(p_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  -- Generated venue-only identities are represented by their location documents.
  -- Other roles, including support and historical advocacy, keep identity results.
  delete from public.search_documents sd using public.organizations o
  where sd.entity_type = 'organization' and sd.entity_id = o.id
    and (p_id is null or o.id = p_id)
    and o.field_provenance->'identity'->>'source' = 'unified_location'
    and o.roles <@ array['venue'];

  insert into public.search_documents
    (doc_id, entity_type, entity_id, title, description, search_tsv, facets, geog,
     trust_score, liveness_status, is_featured, quality_score, closed_at,
     start_date, end_date, is_free, price_min, price_max, slug, image_url, city, country, content_language, updated_at)
  select 'organization:'||o.id, 'organization', o.id, o.name,
       coalesce(o.editorial_hook, o.description),
       setweight(to_tsvector('simple', unaccent(coalesce(o.name,''))),'A')
    || setweight(to_tsvector('simple', unaccent(coalesce(o.website_domain,''))),'B')
    || setweight(to_tsvector('simple', unaccent(array_to_string(o.roles,' '))),'C')
    || setweight(to_tsvector('simple', unaccent(array_to_string(o.tags,' '))),'C')
    || setweight(to_tsvector('simple', unaccent(coalesce(cp.name,''))),'C')
    || setweight(to_tsvector('simple', unaccent(coalesce(o.editorial_hook, o.description, ''))),'D'),
    jsonb_strip_nulls(jsonb_build_object(
      'roles', to_jsonb(o.roles), 'tags', to_jsonb(o.tags), 'entity_kind', 'organization',
      -- Always present (true/false, never null) so it is filterable both ways.
      'defunct', o.is_defunct)),
    coalesce(
      -- The org's own point, when it is itself a place.
      case
        when o.latitude is not null and o.longitude is not null
          then st_setsrid(st_makepoint(o.longitude::float8, o.latitude::float8), 4326)::geography
      end,
      -- Otherwise the linked venue, exactly as before this migration.
      (select st_setsrid(st_makepoint(v.longitude::float8, v.latitude::float8), 4326)::geography
         from public.venues v
        where v.id = o.primary_venue_id and v.longitude is not null and v.latitude is not null)
    ),
    o.trust_score::smallint,
    -- A defunct organization is deranked, never excluded. See the header.
    case when o.is_defunct then 'dead_link' else 'live' end,
    false, o.completeness_score::smallint, null::timestamptz,
    null::timestamptz, null::timestamptz, null::boolean, null::numeric, null::numeric,
    o.slug, coalesce(o.logo_url, o.cover_image_url),
    cp.name, up.code, null::text, now()
  from public.organizations o
  left join public.geo_places cp on cp.id = o.city_id
  left join public.geo_places up on up.id = o.country_id
  where o.status = 'active' and o.duplicate_of_id is null and (p_id is null or o.id = p_id)
    and not (coalesce(o.field_provenance->'identity'->>'source', '') = 'unified_location'
      and o.roles <@ array['venue'])
  on conflict (entity_type, entity_id) do update set title=excluded.title, description=excluded.description, search_tsv=excluded.search_tsv, facets=excluded.facets, geog=excluded.geog, trust_score=excluded.trust_score, liveness_status=excluded.liveness_status, is_featured=excluded.is_featured, quality_score=excluded.quality_score, closed_at=excluded.closed_at, start_date=excluded.start_date, end_date=excluded.end_date, is_free=excluded.is_free, price_min=excluded.price_min, price_max=excluded.price_max, slug=excluded.slug, image_url=excluded.image_url, city=excluded.city, country=excluded.country, content_language=excluded.content_language, updated_at=now();
$function$;

create index if not exists venues_unlinked_organisation_idx on public.venues(id)
  where organization_id is null and duplicate_of_id is null;

-- Public identity pages respect each internal location's archive state.
create or replace function public.get_organization(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select to_jsonb(o) || jsonb_build_object(
    'article_count', (select count(*) from news_articles a join news_sources s on s.id = a.source_id
                      where s.organization_id = o.id and a.duplicate_of_id is null),
    'product_count', (select count(*) from marketplace_listings l
                      where o.website_domain is not null and lower(l.merchant_domain) = lower(o.website_domain)
                        and l.status = 'active'),
    -- The nested venue list is gated independently of the org. A non-gated org
    -- can own a venue in a criminalising country, and enumerating it here would
    -- leak the venue through the org page even though /venues/:slug hides it.
    'venue_count', (select count(*) from venues v where v.organization_id = o.id and v.duplicate_of_id is null and v.review_status is distinct from 'archived'
                      and ((select auth.uid()) is not null or v.safety_gated is not true)),
    'venues', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', v.id, 'slug', v.slug, 'name', v.name, 'city', v.city,
                  'latitude', v.latitude, 'longitude', v.longitude, 'image_url',
                  case when array_length(v.images,1) > 0 then v.images[1] else v.logo_url end)
                  order by (v.id = o.primary_venue_id) desc, v.name)
                from venues v where v.organization_id = o.id and v.duplicate_of_id is null and v.review_status is distinct from 'archived'
                  and ((select auth.uid()) is not null or v.safety_gated is not true)), '[]'::jsonb)
  )
  from organizations o
  where o.slug = p_slug and o.status = 'active' and o.duplicate_of_id is null
    and ((select auth.uid()) is not null or o.safety_gated is not true);
$function$;

create or replace function public.organization_venues(p_org_id uuid)
returns setof public.venues language sql stable security definer set search_path = public, pg_temp as $$
  select v.* from public.venues v join public.organizations o on o.id = v.organization_id
  where o.id = p_org_id and o.status = 'active' and o.duplicate_of_id is null
    and v.duplicate_of_id is null and v.review_status is distinct from 'archived'
    and ((select auth.uid()) is not null or (o.safety_gated is not true and v.safety_gated is not true))
  order by (v.id = o.primary_venue_id) desc, v.name;
$$;

-- The unified identity's workflow and public status must agree. Private/restricted
-- workflow visibility never publishes a public organization row.
create or replace function public.cms_organisation_workflow_sync()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare desired text;
begin
  if new.source_table is distinct from 'organizations' then return new; end if;
  perform public.assert_admin_or_internal();
  desired := case
    when new.workflow_state = 'archived' then 'archived'
    when new.workflow_state = 'published' and new.visibility_level = 'public' then 'active'
    else 'draft' end;
  update public.organizations set status = desired where id = new.source_id and status is distinct from desired;
  return new;
end;
$$;

revoke all on function public.cms_organisation_workflow_sync() from public, anon, authenticated, service_role;

drop trigger if exists cms_organisation_workflow_sync on public.cms_content_metadata;

create trigger cms_organisation_workflow_sync after insert or update of workflow_state, visibility_level on public.cms_content_metadata
  for each row execute function public.cms_organisation_workflow_sync();

create or replace function public.cms_organisation_status_sync()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- Metadata already owns the decision when this is a nested workflow update.
  if pg_trigger_depth() > 1 then return new; end if;
  insert into public.cms_content_metadata(source_table, source_id, workflow_state,
    visibility_level, last_edited_by, last_edited_at)
  values ('organizations', new.id, (case new.status when 'active' then 'published'
    when 'archived' then 'archived' else 'draft' end)::public.cms_workflow_state, 'public'::public.cms_visibility_level, auth.uid(), now())
  on conflict (source_table, source_id) do update set workflow_state = excluded.workflow_state,
    last_edited_by = excluded.last_edited_by, last_edited_at = excluded.last_edited_at, updated_at = now()
  where cms_content_metadata.workflow_state is distinct from excluded.workflow_state;
  return new;
end;
$$;

revoke all on function public.cms_organisation_status_sync() from public, anon, authenticated, service_role;

drop trigger if exists cms_organisation_status_sync on public.organizations;

create trigger cms_organisation_status_sync after insert or update of status on public.organizations
  for each row execute function public.cms_organisation_status_sync();

-- Bound adopt-before-create lookups as the identity corpus grows during rollout.
create index if not exists organizations_location_identity_match_idx
  on public.organizations(city_id, country_id, lower(btrim(name)))
  where duplicate_of_id is null;
