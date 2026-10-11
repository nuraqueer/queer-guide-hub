-- Correct the deployed RPCs: serialize read-modify-write state with row locks.

create or replace function public.tag_image_apply(
  p_tag_id      uuid,
  p_url         text,
  p_alt         text,
  p_source      text,
  p_license     text,
  p_attribution text,
  p_explicit    boolean default false,
  p_asset_id    uuid default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_status jsonb;
begin
  -- Attributed, so log_unified_tag_change() does not refuse a human_reviewed
  -- row. Transaction-local: it must not leak to the next statement on this
  -- connection.
  perform set_config('app.actor', 'machine:tag-imagery', true);

  select coalesce(enrichment_status, '{}'::jsonb) into v_status
    from public.unified_tags where id = p_tag_id for update;

  if not found then
    raise exception 'tag % not found', p_tag_id using errcode = '22023';
  end if;

  update public.unified_tags
     set image_url         = p_url,
         image_alt         = p_alt,
         image_source      = p_source,
         image_license     = p_license,
         image_attribution = p_attribution,
         image_explicit    = coalesce(p_explicit, false),
         -- The question has been answered; drop the record of asking it.
         enrichment_status = v_status - 'tag_image'
   where id = p_tag_id;

  -- Claimed at APPROVAL/publish time, never at proposal time, so a candidate
  -- that is never published does not hold tag_cover_one_tag_uniq against every
  -- other tag forever.
  if p_asset_id is not null then
    insert into public.image_asset_links (asset_id, entity_type, entity_id, role)
    values (p_asset_id, 'tag', p_tag_id, 'cover');
  end if;
end
$fn$;

create or replace function public.tag_image_bump_miss(
  p_tag_id uuid,
  p_why    text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_status   jsonb;
  v_attempts int;
begin
  perform set_config('app.actor', 'machine:tag-imagery', true);

  select coalesce(enrichment_status, '{}'::jsonb) into v_status
    from public.unified_tags where id = p_tag_id for update;

  if not found then
    raise exception 'tag % not found', p_tag_id using errcode = '22023';
  end if;

  v_attempts := coalesce((v_status #>> '{tag_image,attempts}')::int, 0) + 1;

  update public.unified_tags
     set enrichment_status = v_status || jsonb_build_object(
           'tag_image', jsonb_build_object(
             'attempts', v_attempts,
             'last_why', p_why,
             'last_at',  now(),
             'state',    case when v_attempts >= 3 then 'data_unavailable' else 'searching' end
           )
         )
   where id = p_tag_id;

  return jsonb_build_object(
    'attempts', v_attempts,
    'state', case when v_attempts >= 3 then 'data_unavailable' else 'searching' end
  );
end
$fn$;

revoke all on function public.tag_image_apply(uuid, text, text, text, text, text, boolean, uuid) from public;
revoke all on function public.tag_image_apply(uuid, text, text, text, text, text, boolean, uuid) from anon;
revoke all on function public.tag_image_apply(uuid, text, text, text, text, text, boolean, uuid) from authenticated;
grant execute on function public.tag_image_apply(uuid, text, text, text, text, text, boolean, uuid) to service_role;

revoke all on function public.tag_image_bump_miss(uuid, text) from public;
revoke all on function public.tag_image_bump_miss(uuid, text) from anon;
revoke all on function public.tag_image_bump_miss(uuid, text) from authenticated;
grant execute on function public.tag_image_bump_miss(uuid, text) to service_role;

