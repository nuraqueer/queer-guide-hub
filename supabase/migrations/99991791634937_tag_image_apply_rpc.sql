-- tag-imagery could not write to unified_tags at all, and running it once is
-- what found both reasons.
--
-- The function deployed clean, reported ACTIVE, and 500'd on every call:
--
--     {"error":"column unified_tags.enrichment_status does not exist"}
--
-- (1) THE COLUMN DOES NOT EXIST. The approved plan specified a terminal
-- sentinel -- `enrichment_status.tag_image.state='data_unavailable'` after 3
-- attempts, so an unresolvable tag leaves the pool instead of being re-probed
-- nightly forever -- and assumed `unified_tags` carried the jsonb column its
-- `cities`/`venues`/`events` siblings do. It does not. Measured: the six image
-- columns exist (the contract trigger's exact set) plus `image_prompt` and the
-- i18n twins, and there is no `enrichment_status` anywhere on the table.
--
-- (2) A PLAIN PostgREST UPDATE CANNOT WRITE A `human_reviewed` TAG.
-- `log_unified_tag_change()` RAISEs `human_reviewed tag % cannot be modified
-- by %` when an UNDECLARED actor (`system:%`, the default when nothing calls
-- set_config) changes any column outside its `v_derived` exemption -- and 79%
-- of prose-bearing active tags carry that flag. The function wrote through
-- `supabase.from('unified_tags').update(...)` at both of its write sites, so
-- every publish and every miss-stamp on a reviewed tag would have failed. This
-- is the same wall `tag_prose_apply()` was built against, and this file copies
-- that precedent rather than inventing a second shape.
--
-- WHY THE TWO FIXES ARE DIFFERENT, which is the part worth keeping:
--
--   * `enrichment_status` JOINS `v_derived`. The attempt stamp is machine
--     bookkeeping recomputed by a sweep -- exactly what `prose_reviewed_at` is
--     in there for -- so a scheduled job writing it must not read as a human
--     edit, and must not be refused on a reviewed row.
--
--   * THE SIX IMAGE COLUMNS DO NOT, AND MUST NOT. An image is CONTENT: it
--     renders, it carries a licence, and it is exactly the kind of write a
--     human's `human_reviewed` flag is meant to protect. Exempting them would
--     let any undeclared `system:` caller overwrite a curated photograph in
--     silence. So the RPC declares a real actor instead, which bypasses the
--     RAISE for the right reason -- the write is attributed -- rather than by
--     widening the hole for everyone.
--
-- THE RPCs DELIBERATELY DO NOT BYPASS `enforce_tag_image_contract`. They are
-- SECURITY DEFINER for the actor declaration and nothing else; the BEFORE
-- trigger still fires on their UPDATE, so an unlicensed or non-https or
-- stock-on-adult write is still refused with a check_violation. That is the
-- point: the guard is the authority, and a write the guard rejects is a BUG in
-- the guard that must be loud. The verify block proves it by pushing an
-- unlicensed publish through the RPC and expecting the refusal.
--
-- Two smaller corrections ride along, both cheap because the work moved
-- server-side:
--
--   * ATTEMPTS ARE INCREMENTED IN SQL. The TypeScript version did a
--     read-modify-write (`select enrichment_status` ... `attempts + 1` ...
--     `update`), which loses a count whenever two batches touch one tag.
--   * A SUCCESSFUL PUBLISH CLEARS THE ATTEMPT STATE. Without that, a tag that
--     resolved on attempt 2 keeps `state:'searching'` forever, which is a
--     record of a question that has since been answered.
--
-- Guarded by src/lib/__tests__/tagImageApplyRpc.test.ts.

-- ---------------------------------------------------------------------------
-- 1. The column.
-- ---------------------------------------------------------------------------

alter table public.unified_tags
  add column if not exists enrichment_status jsonb;

comment on column public.unified_tags.enrichment_status is
  'Per-enrichment machine bookkeeping, same shape as cities/venues/events. '
  'tag_image.{attempts,last_why,last_at,state} is written by tag-imagery via '
  'tag_image_bump_miss(); state=''data_unavailable'' after 3 attempts is '
  'TERMINAL and removes the tag from the acquisition pool. Listed in '
  'log_unified_tag_change()''s v_derived exemption because it is recomputed by '
  'a sweep and is never human-curated. NOT in trg_search_documents_tag''s '
  'column list, so stamping it causes no search churn.';

-- ---------------------------------------------------------------------------
-- 2. Join the audit trigger's derived-column exemption.
--
-- PATCHED from pg_get_functiondef rather than restated. The function is short
-- today, but restating is how one session silently reverts another's narrowing
-- (the 99991790719601 lesson), and the anchor is asserted exactly-once so a
-- body that has moved fails loudly instead of being half-patched.
-- ---------------------------------------------------------------------------

do $patch$
declare
  v_src  text;
  v_from text := E'''prose_reviewed_at''\n  ];';
  v_to   text := E'''prose_reviewed_at'', ''enrichment_status''\n  ];';
  v_hits int;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'log_unified_tag_change';

  if v_src is null then
    raise exception 'log_unified_tag_change() not found -- cannot patch v_derived';
  end if;

  -- Already done (a re-run, or another session got there first).
  if position('''enrichment_status''' in v_src) > 0 then
    raise notice 'v_derived already carries enrichment_status -- no patch needed';
    return;
  end if;

  v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
  if v_hits <> 1 then
    raise exception
      'v_derived anchor found % times, expected exactly 1 -- the function body moved', v_hits;
  end if;

  execute replace(v_src, v_from, v_to);
end
$patch$;

-- ---------------------------------------------------------------------------
-- 3. Publish. Declares the actor; the contract trigger still gates the values.
-- ---------------------------------------------------------------------------

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
    from public.unified_tags where id = p_tag_id;

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

-- ---------------------------------------------------------------------------
-- 4. Record a miss. Increments server-side.
-- ---------------------------------------------------------------------------

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
    from public.unified_tags where id = p_tag_id;

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

-- ---------------------------------------------------------------------------
-- 5. Grants. service_role only.
--
-- CREATE FUNCTION grants EXECUTE to PUBLIC by default, so the revoke is the
-- load-bearing statement and the grant alone would change nothing.
-- ---------------------------------------------------------------------------

revoke all on function public.tag_image_apply(uuid, text, text, text, text, text, boolean, uuid) from public;
revoke all on function public.tag_image_apply(uuid, text, text, text, text, text, boolean, uuid) from anon;
revoke all on function public.tag_image_apply(uuid, text, text, text, text, text, boolean, uuid) from authenticated;
grant execute on function public.tag_image_apply(uuid, text, text, text, text, text, boolean, uuid) to service_role;

revoke all on function public.tag_image_bump_miss(uuid, text) from public;
revoke all on function public.tag_image_bump_miss(uuid, text) from anon;
revoke all on function public.tag_image_bump_miss(uuid, text) from authenticated;
grant execute on function public.tag_image_bump_miss(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Postconditions. Assert the REACHED state, and assert the behaviour rather
-- than the source text -- a text check cannot tell a live guard from a dead
-- one.
-- ---------------------------------------------------------------------------

do $verify$
declare
  v_probe   uuid;
  v_src     text;
  v_bad     int;
  v_raised  boolean;
  v_state   text;
  v_leaked  int;
begin
  -- P1: the column exists and is jsonb.
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'unified_tags'
       and column_name = 'enrichment_status' and data_type = 'jsonb'
  ) then
    raise exception 'P1 failed: unified_tags.enrichment_status is missing or not jsonb';
  end if;

  -- P2: the audit trigger exempts it.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'log_unified_tag_change';
  if position('''enrichment_status''' in v_src) = 0 then
    raise exception 'P2 failed: v_derived does not carry enrichment_status';
  end if;
  -- ...and still exempts what it did before. A patch that replaced the array
  -- rather than extending it would satisfy P2 alone.
  if position('''prose_reviewed_at''' in v_src) = 0
     or position('''usage_count''' in v_src) = 0 then
    raise exception 'P2 failed: the patch dropped a pre-existing v_derived entry';
  end if;

  -- P3: both functions are SECURITY DEFINER and reachable by service_role only.
  select count(*) into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('tag_image_apply', 'tag_image_bump_miss')
     and (p.prosecdef is not true
          or has_function_privilege('anon', p.oid, 'EXECUTE')
          or has_function_privilege('authenticated', p.oid, 'EXECUTE')
          or not has_function_privilege('service_role', p.oid, 'EXECUTE'));
  if v_bad <> 0 then
    raise exception 'P3 failed: % of the two RPCs are not definer+service_role-only', v_bad;
  end if;

  -- A probe tag. publication_role is NOT NULL with no default (the documented
  -- trap), and no category_id is set so the AFTER-insert junction trigger has
  -- nothing to write.
  insert into public.unified_tags (name, slug, status, publication_role, human_reviewed)
  values ('Zz Tag Image Rpc Probe', 'zz-tag-image-rpc-probe', 'active', 'utility', true)
  returning id into v_probe;

  -- P4: THE WHOLE POINT. A human_reviewed row can be stamped through the RPC.
  perform public.tag_image_bump_miss(v_probe, 'probe_no_p18');
  select enrichment_status #>> '{tag_image,state}' into v_state
    from public.unified_tags where id = v_probe;
  if v_state is distinct from 'searching' then
    raise exception 'P4 failed: bump_miss on a human_reviewed tag left state %', v_state;
  end if;

  -- P5: and the undeclared path is still refused, so P4 is evidence about the
  -- actor declaration rather than about a trigger that stopped firing.
  --
  -- THE PROBE MUST BE THE REAL PUBLISH SHAPE, and the first draft of this
  -- check was a single `set image_alt = 'probe'` which FAILED against correct
  -- code. Measured on prod: that write does not persist at all (image_alt
  -- reads back NULL), because zz_enforce_tag_image_contract is a BEFORE
  -- trigger that clears the whole sidecar when image_url IS NULL. So NEW
  -- equalled OLD, nothing changed, and unified_tags_audit was RIGHT not to
  -- raise -- the probe was testing a write that reverts itself, which is
  -- indistinguishable from a guard that has stopped firing. Writing all six
  -- columns at once is the shape the edge function actually used, and it
  -- raises: `human_reviewed tag <id> cannot be modified by system:trigger`.
  v_raised := false;
  begin
    perform set_config('app.actor', 'system:trigger', true);
    update public.unified_tags
       set image_url         = 'https://upload.wikimedia.org/probe-undeclared.jpg',
           image_alt         = 'probe alt',
           image_source      = 'wikimedia',
           image_license     = 'CC BY-SA 4.0',
           image_attribution = 'Someone',
           image_explicit    = false
     where id = v_probe;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'P5 failed: an undeclared system actor was allowed to write a human_reviewed tag';
  end if;

  -- P6: three strikes is terminal.
  perform set_config('app.actor', null, true);
  perform public.tag_image_bump_miss(v_probe, 'probe_no_p18');
  perform public.tag_image_bump_miss(v_probe, 'probe_no_p18');
  select enrichment_status #>> '{tag_image,state}' into v_state
    from public.unified_tags where id = v_probe;
  if v_state is distinct from 'data_unavailable' then
    raise exception 'P6 failed: after 3 attempts state is %, not data_unavailable', v_state;
  end if;

  -- P7: the RPC does NOT bypass enforce_tag_image_contract. An unlicensed
  -- publish must still be refused.
  v_raised := false;
  begin
    perform public.tag_image_apply(
      v_probe, 'https://upload.wikimedia.org/probe.jpg', 'probe alt',
      'wikimedia', null, 'Someone', false, null);
  exception when check_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'P7 failed: the RPC published an image with no licence -- the contract was bypassed';
  end if;

  -- P8: a well-formed publish succeeds AND clears the attempt state, so a tag
  -- that resolved on attempt 3 does not keep a terminal stamp.
  perform public.tag_image_apply(
    v_probe, 'https://upload.wikimedia.org/probe.jpg', 'probe alt',
    'wikimedia', 'CC BY-SA 4.0', 'Someone', false, null);
  select enrichment_status #>> '{tag_image,state}' into v_state
    from public.unified_tags where id = v_probe;
  if v_state is not null then
    raise exception 'P8 failed: a successful publish left state %', v_state;
  end if;
  if not exists (
    select 1 from public.unified_tags
     where id = v_probe and image_url = 'https://upload.wikimedia.org/probe.jpg'
       and image_license = 'CC BY-SA 4.0'
  ) then
    raise exception 'P8 failed: the publish did not land';
  end if;

  delete from public.unified_tags where id = v_probe;

  -- P9: no probe row survives. A migration that leaves scratch rows in a
  -- content table is worse than one that fails.
  select count(*) into v_leaked
    from public.unified_tags where slug like 'zz-tag-image-rpc-probe%';
  if v_leaked <> 0 then
    raise exception 'P9 failed: % probe rows left behind', v_leaked;
  end if;

  raise notice 'tag_image_apply_rpc: P1-P9 passed';
end
$verify$;
