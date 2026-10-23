-- 99991792747676_org_safety_gate_follows_venue_merge
--
-- organizations.safety_gated is decided by trg_organizations_safety_gated
-- (set_org_safety_gated): location_is_high_risk(...) OR the org's primary venue
-- is live (duplicate_of_id IS NULL) AND safety_gated. The org trigger fires only
-- when the ORG row is written, so 99991792403561 added zzz_venue_gate_to_org on
-- venues to re-decide the org when the venue's safety_gated flips.
--
-- The gap: the predicate ALSO reads venues.duplicate_of_id, and nothing re-decided
-- the org when that moved. 2026-10-23 06:30 the venue dedup sweep merged
-- 'El Gremio' (cruising, gated) into another row; org 0250db11-... kept
-- safety_gated=true while the rule now said false, and
-- release_gate_checks().city_safety_gate_drift (critical, organizations arm)
-- went red on every open PR until fixed by hand.
--
-- Fix: the existing propagation trigger now also fires on duplicate_of_id, with a
-- WHEN so the hot venues table pays nothing for writes that change neither.
-- It also stops skipping merged organizations: the gate arm counts EVERY org
-- (647 merged orgs carry a primary_venue_id), so propagation must cover the
-- same set or a merged org drifts the same way.
--
-- Repointing primary_venue_id to the merge survivor is NOT done here; that is
-- repoint_merged_primary_venues()'s job, and when it writes primary_venue_id the
-- org trigger re-decides anyway.

create or replace function public.propagate_venue_gate_to_organization()
returns trigger language plpgsql security definer
set search_path to 'public', 'pg_temp' as $fn$
begin
  update public.organizations o
     set primary_venue_id = o.primary_venue_id
   where o.primary_venue_id = new.id;
  return null;
end $fn$;

drop trigger if exists zzz_venue_gate_to_org on public.venues;
create trigger zzz_venue_gate_to_org
  after update of safety_gated, duplicate_of_id on public.venues
  for each row
  when (old.safety_gated is distinct from new.safety_gated
        or old.duplicate_of_id is distinct from new.duplicate_of_id)
  execute function public.propagate_venue_gate_to_organization();

-- Heal anything already drifted, through the seal (writes no answer itself).
-- The join is materialized first so location_is_high_risk runs on the handful
-- of candidates, not on all ~38k gated orgs (that form hit the 2 min timeout).
with c as materialized (
  select o.id, o.country_id, o.city_id
    from public.organizations o
    join public.venues v on v.id = o.primary_venue_id
   where v.duplicate_of_id is not null and o.safety_gated is true
)
update public.organizations o
   set primary_venue_id = o.primary_venue_id
  from c
 where o.id = c.id
   and not public.location_is_high_risk(c.country_id, c.city_id);

do $verify$
declare v_def text; v_bad bigint;
begin
  select pg_get_triggerdef(t.oid) into v_def
    from pg_trigger t
   where t.tgrelid = 'public.venues'::regclass and t.tgname = 'zzz_venue_gate_to_org';
  if v_def is null or position('duplicate_of_id' in v_def) = 0 then
    raise exception 'P1 failed: zzz_venue_gate_to_org does not fire on duplicate_of_id: %', v_def;
  end if;

  if position('o.duplicate_of_id is null' in
       pg_get_functiondef('public.propagate_venue_gate_to_organization'::regproc)) > 0 then
    raise exception 'P2 failed: propagation still skips merged organizations';
  end if;

  with c as materialized (
    select o.country_id, o.city_id
      from public.organizations o
      join public.venues v on v.id = o.primary_venue_id
     where v.duplicate_of_id is not null and o.safety_gated is true
  )
  select count(*) into v_bad from c
   where not public.location_is_high_risk(c.country_id, c.city_id);
  if v_bad <> 0 then
    raise exception 'P3 failed: % orgs still gated by a merged-away primary venue', v_bad;
  end if;
end $verify$;
