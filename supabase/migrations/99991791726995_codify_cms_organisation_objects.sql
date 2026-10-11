-- Codify the CMS organisation feature, which runs in production and is created
-- by NO migration.
--
-- `check-schema-object-drift.mjs` reported THREE triggers. Its scope is
-- TRIGGERS ONLY, deliberately, so that was the visible tip. Reading the catalog
-- found NINE `cms_*` functions absent from every migration as well, including
-- `cms_venue_organisation_core`, which `cms_location_identity_insert()` calls —
-- so codifying the triggers alone would have committed a trigger whose function
-- calls something that does not exist on a rebuild.
--
-- Everything here is `pg_get_functiondef` / `pg_get_triggerdef` output read off
-- prod, not reconstructed. The precedent is `99991791049075`, which codified
-- the `cultural_updated_at` triggers the same way and for the same reason: a
-- hand-attached object disappears on any rebuild from migrations, and the
-- invariant it enforces goes with it.
--
-- IDEMPOTENT IN BOTH DIRECTIONS. Every function is `create or replace` and
-- every trigger is `drop trigger if exists` + `create trigger`, so on prod this
-- is a no-op that changes nothing, and on a rebuild it creates the feature. If
-- whoever attached these commits their own migration too, both apply harmlessly
-- — only a version collision would have mattered, and this file's version was
-- allocated by scripts/next-migration-version.mjs and checked against every
-- open PR.
--
-- THE REVOKES ARE LOAD-BEARING AND ARE NOT COSMETIC. `CREATE FUNCTION` grants
-- EXECUTE to PUBLIC by default in this database, and prod has PUBLIC revoked on
-- all nine (measured: no `-` grantee on any of them). Without these revokes a
-- rebuilt database would be MORE permissive than production — nine SECURITY
-- DEFINER functions that write data, callable by anon. The grants below
-- reproduce prod exactly, including `cms_organisation_patch`, which carries no
-- API grant at all.
--
-- SIGNATURES COME FROM `pg_get_function_identity_arguments`, NOT FROM GUESSES.
-- My first draft invented them and got two of nine wrong —
-- `cms_organisation_patch` takes three arguments and `cms_organisation_save`
-- four, where I had assumed two and one. Those revokes would have failed
-- 42883 at apply time and aborted `db push` for the whole repo, which is
-- exactly what #4291 had to repair this morning. `check-migration-sql` could
-- not have caught it: the syntax is valid and only execution resolves a
-- function signature.

set local statement_timeout = '120s';

-- ── the nine functions, verbatim from prod ──
CREATE OR REPLACE FUNCTION public.cms_backfill_venue_organisations(p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.cms_organisation_patch(p_table text, p_id uuid, p_data jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.cms_organisation_read(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.cms_organisation_save(p_id uuid, p_data jsonb, p_locations jsonb DEFAULT NULL::jsonb, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.cms_venue_organisation(p_venue_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public.assert_admin_or_internal();
  return public.cms_venue_organisation_core(p_venue_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cms_venue_organisation_core(p_venue_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.cms_location_identity_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.organization_id is null and new.duplicate_of_id is null then
    perform public.cms_venue_organisation_core(new.id);
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cms_organisation_status_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.cms_organisation_workflow_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

-- ── PUBLIC is revoked on all nine in prod; reproduce that ──
revoke all on function public.cms_backfill_venue_organisations(p_limit integer) from public;
revoke all on function public.cms_location_identity_insert() from public;
revoke all on function public.cms_organisation_patch(p_table text, p_id uuid, p_data jsonb) from public;
revoke all on function public.cms_organisation_read(p_id uuid) from public;
revoke all on function public.cms_organisation_save(p_id uuid, p_data jsonb, p_locations jsonb, p_expected_updated_at timestamp with time zone) from public;
revoke all on function public.cms_organisation_status_sync() from public;
revoke all on function public.cms_organisation_workflow_sync() from public;
revoke all on function public.cms_venue_organisation(p_venue_id uuid) from public;
revoke all on function public.cms_venue_organisation_core(p_venue_id uuid) from public;

-- ── grants, matching prod exactly ──
grant execute on function public.cms_backfill_venue_organisations(p_limit integer) to service_role;
grant execute on function public.cms_organisation_read(p_id uuid) to authenticated;
grant execute on function public.cms_organisation_read(p_id uuid) to service_role;
grant execute on function public.cms_organisation_save(p_id uuid, p_data jsonb, p_locations jsonb, p_expected_updated_at timestamp with time zone) to authenticated;
grant execute on function public.cms_organisation_save(p_id uuid, p_data jsonb, p_locations jsonb, p_expected_updated_at timestamp with time zone) to service_role;
grant execute on function public.cms_venue_organisation(p_venue_id uuid) to authenticated;
grant execute on function public.cms_venue_organisation(p_venue_id uuid) to service_role;

-- ── the three triggers ──
drop trigger if exists cms_location_identity_insert on public.venues;
CREATE TRIGGER cms_location_identity_insert AFTER INSERT ON public.venues FOR EACH ROW EXECUTE FUNCTION cms_location_identity_insert();

drop trigger if exists cms_organisation_status_sync on public.organizations;
CREATE TRIGGER cms_organisation_status_sync AFTER INSERT OR UPDATE OF status ON public.organizations FOR EACH ROW EXECUTE FUNCTION cms_organisation_status_sync();

drop trigger if exists cms_organisation_workflow_sync on public.cms_content_metadata;
CREATE TRIGGER cms_organisation_workflow_sync AFTER INSERT OR UPDATE OF workflow_state, visibility_level ON public.cms_content_metadata FOR EACH ROW EXECUTE FUNCTION cms_organisation_workflow_sync();

do $verify$
declare v_fn int; v_trg int; v_pub int;
begin
  -- P1. All nine functions exist.
  select count(*) into v_fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in (
     'cms_backfill_venue_organisations','cms_location_identity_insert','cms_organisation_patch',
     'cms_organisation_read','cms_organisation_save','cms_organisation_status_sync',
     'cms_organisation_workflow_sync','cms_venue_organisation','cms_venue_organisation_core');
  if v_fn <> 9 then raise exception 'P1 failed: % of 9 cms functions present', v_fn; end if;

  -- P2. All three triggers are attached.
  select count(*) into v_trg from pg_trigger t join pg_class c on c.oid=t.tgrelid
       join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and not t.tgisinternal
     and t.tgname in ('cms_location_identity_insert','cms_organisation_status_sync','cms_organisation_workflow_sync');
  if v_trg <> 3 then raise exception 'P2 failed: % of 3 cms triggers attached', v_trg; end if;

  -- P3. NOT the inverse of P1/P2: no PUBLIC or anon execute survived. This is
  --     the assertion the revokes exist for, and it is what a rebuild would
  --     otherwise get wrong rather than anything prod has wrong today.
  select count(*) into v_pub from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       cross join aclexplode(coalesce(p.proacl,'{}')) a
   where n.nspname='public' and p.proname like 'cms\_%'
     and a.privilege_type='EXECUTE' and a.grantee::regrole::text in ('-','anon','PUBLIC');
  if v_pub <> 0 then raise exception 'P3 failed: % cms function grant(s) reach PUBLIC or anon', v_pub; end if;

  raise notice 'cms organisation feature codified: 9 functions, 3 triggers, 0 public/anon execute';
end $verify$;
