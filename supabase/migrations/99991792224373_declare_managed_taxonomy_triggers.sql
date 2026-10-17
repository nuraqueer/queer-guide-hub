-- Write down the 29 managed-taxonomy triggers, so the schema says what
-- production runs.
--
-- These are NOT drift. Every one is created by a migration already:
--   99991792192817:332  execute format('create trigger %I … ',
--                         'validate_managed_'||spec[2], …)            -> 12
--   99991792192829:15   execute format('create trigger %I … ',
--                         'validate_managed_profile_'||field_name, …) -> 17
-- Both loops run at migration time, so a rebuild from migrations recreates all
-- 29, and the invariant check-schema-object-drift.mjs protects — "a hand-attached
-- trigger disappears on any rebuild, and the invariant it enforces goes with it"
-- — was never violated.
--
-- What IS wrong is that the schema does not say so. `grep "create trigger"` over
-- supabase/migrations/ finds none of these 29 names, because the name is
-- interpolated into the dynamic statement rather than written in it. The gate's
-- own docstring states the assumption that fails
-- (scripts/check-schema-object-drift.mjs:56-61):
--
--   "A trigger created inside a `do $$ … execute 'create trigger …' $$` block
--    still matches, because the statement text is present either way."
--
-- True when the NAME is a literal inside the dynamic SQL — which is why
-- guard_managed_taxonomy (99991792192817:288) passes — and false when the name is
-- built by concatenation. Verified by running the gate's own regex against the
-- real line: it captures nothing, because `%` is not in [a-z0-9_].
--
-- The consequence was repo-wide. The gate reads LIVE production, so the moment
-- #4440 applied, every open PR went red on a check none of them had touched.
--
-- WHY EACH CREATE IS GUARDED RATHER THAN `drop trigger if exists` + `create`,
-- which is the idiom the gate's hint names and the first draft of this file used:
-- DROP/CREATE TRIGGER takes ACCESS EXCLUSIVE on the table, and `profiles` and
-- `venues` are hot. Measured — the first draft was dry-run against production and
-- died on `55P03 canceling statement due to lock timeout` at the 5s bound. The
-- same thing at apply time aborts `db push` and blocks every queued migration,
-- which is the exact harm this file exists to remove. Guarded, the branch is
-- false on any database that already has the trigger, so the statement takes no
-- lock at all; on a rebuild from zero the loops above have already created them,
-- so it is false there too. The create is reachable only if a trigger is ever
-- genuinely missing, which is the case worth having a literal statement for.
--
-- The guard is NOT a way of smuggling a declaration past the scanner. The
-- statement is real, executable SQL that runs when the trigger is absent — not a
-- comment. Its syntax is proven by the real PG17 grammar (all 29 parse as
-- CreateTrigStmt), which is the only syntax check available for them: libpg-query
-- treats a plpgsql body as an opaque literal, and the branch does not execute
-- against a database that already has the triggers.
--
-- Editing 99991792192817 / 99991792192829 in place is NOT an option: both are
-- applied to production, `db push` matches on version and would never re-run
-- them, and the edit would desynchronise the file from recorded history.
--
-- The four managed triggers whose names ARE literal in a migration
-- (competitions.validate_managed_competition_category,
-- profiles.validate_managed_profile_flags, events.validate_managed_event_type,
-- organizations.validate_managed_organisation_roles) are deliberately untouched:
-- they already pass, and re-declaring them here would duplicate a declaration
-- that has a rightful owner. Definitions below are transcribed from production's
-- own pg_get_triggerdef output.

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'accessibility_attributes' and tg.tgname = 'validate_managed_category'
  ) then
    create trigger validate_managed_category before insert or update on public.accessibility_attributes
      for each row execute function public.validate_managed_classification('category', 'accessibility_category');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'event_amenities' and tg.tgname = 'validate_managed_category'
  ) then
    create trigger validate_managed_category before insert or update on public.event_amenities
      for each row execute function public.validate_managed_classification('category', 'service_category');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'event_services' and tg.tgname = 'validate_managed_category'
  ) then
    create trigger validate_managed_category before insert or update on public.event_services
      for each row execute function public.validate_managed_classification('category', 'service_category');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'hotels' and tg.tgname = 'validate_managed_hotel_type'
  ) then
    create trigger validate_managed_hotel_type before insert or update on public.hotels
      for each row execute function public.validate_managed_classification('hotel_type', 'hotel_type');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'milestones' and tg.tgname = 'validate_managed_category'
  ) then
    create trigger validate_managed_category before insert or update on public.milestones
      for each row execute function public.validate_managed_classification('category', 'milestone_category');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'personalities' and tg.tgname = 'validate_managed_cause_of_death'
  ) then
    create trigger validate_managed_cause_of_death before insert or update on public.personalities
      for each row execute function public.validate_managed_classification('cause_of_death', 'personality_cause_of_death');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_chosen_family_status'
  ) then
    create trigger validate_managed_chosen_family_status before insert or update on public.profiles
      for each row execute function public.validate_managed_classification('chosen_family_status', 'chosen_family');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_current_relationship_status'
  ) then
    create trigger validate_managed_current_relationship_status before insert or update on public.profiles
      for each row execute function public.validate_managed_classification('current_relationship_status', 'relationship_status');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_relationship_style'
  ) then
    create trigger validate_managed_relationship_style before insert or update on public.profiles
      for each row execute function public.validate_managed_classification('relationship_style', 'relationship_style');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'venue_services' and tg.tgname = 'validate_managed_category'
  ) then
    create trigger validate_managed_category before insert or update on public.venue_services
      for each row execute function public.validate_managed_classification('category', 'service_category');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'venues' and tg.tgname = 'validate_managed_accommodation_type'
  ) then
    create trigger validate_managed_accommodation_type before insert or update on public.venues
      for each row execute function public.validate_managed_classification('accommodation_type', 'hotel_type');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'venues' and tg.tgname = 'validate_managed_category'
  ) then
    create trigger validate_managed_category before insert or update on public.venues
      for each row execute function public.validate_managed_classification('category', 'venue_category');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_bdsm_role'
  ) then
    create trigger validate_managed_profile_bdsm_role before insert or update of bdsm_role on public.profiles
      for each row execute function public.validate_managed_classification('bdsm_role', 'profile_bdsm_role');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_communication_about_sex'
  ) then
    create trigger validate_managed_profile_communication_about_sex before insert or update of communication_about_sex on public.profiles
      for each row execute function public.validate_managed_classification('communication_about_sex', 'profile_communication_about_sex');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_disability_status'
  ) then
    create trigger validate_managed_profile_disability_status before insert or update of disability_status on public.profiles
      for each row execute function public.validate_managed_classification('disability_status', 'profile_disability_status');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_family_acceptance_level'
  ) then
    create trigger validate_managed_profile_family_acceptance_level before insert or update of family_acceptance_level on public.profiles
      for each row execute function public.validate_managed_classification('family_acceptance_level', 'profile_family_acceptance_level');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_financial_situation'
  ) then
    create trigger validate_managed_profile_financial_situation before insert or update of financial_situation on public.profiles
      for each row execute function public.validate_managed_classification('financial_situation', 'profile_financial_situation');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_housing_situation'
  ) then
    create trigger validate_managed_profile_housing_situation before insert or update of housing_situation on public.profiles
      for each row execute function public.validate_managed_classification('housing_situation', 'profile_housing_situation');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_immigration_status'
  ) then
    create trigger validate_managed_profile_immigration_status before insert or update of immigration_status on public.profiles
      for each row execute function public.validate_managed_classification('immigration_status', 'profile_immigration_status');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_jealousy_comfort_level'
  ) then
    create trigger validate_managed_profile_jealousy_comfort_level before insert or update of jealousy_comfort_level on public.profiles
      for each row execute function public.validate_managed_classification('jealousy_comfort_level', 'profile_jealousy_comfort_level');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_kink_experience_level'
  ) then
    create trigger validate_managed_profile_kink_experience_level before insert or update of kink_experience_level on public.profiles
      for each row execute function public.validate_managed_classification('kink_experience_level', 'profile_kink_experience_level');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_mental_health_openness'
  ) then
    create trigger validate_managed_profile_mental_health_openness before insert or update of mental_health_openness on public.profiles
      for each row execute function public.validate_managed_classification('mental_health_openness', 'profile_mental_health_openness');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_neurodivergent_status'
  ) then
    create trigger validate_managed_profile_neurodivergent_status before insert or update of neurodivergent_status on public.profiles
      for each row execute function public.validate_managed_classification('neurodivergent_status', 'profile_neurodivergent_status');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_physical_affection_preference'
  ) then
    create trigger validate_managed_profile_physical_affection_preference before insert or update of physical_affection_preference on public.profiles
      for each row execute function public.validate_managed_classification('physical_affection_preference', 'profile_physical_affection_preference');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_romance_style'
  ) then
    create trigger validate_managed_profile_romance_style before insert or update of romance_style on public.profiles
      for each row execute function public.validate_managed_classification('romance_style', 'profile_romance_style');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_sexual_exploration_openness'
  ) then
    create trigger validate_managed_profile_sexual_exploration_openness before insert or update of sexual_exploration_openness on public.profiles
      for each row execute function public.validate_managed_classification('sexual_exploration_openness', 'profile_sexual_exploration_openness');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_sexual_frequency_preference'
  ) then
    create trigger validate_managed_profile_sexual_frequency_preference before insert or update of sexual_frequency_preference on public.profiles
      for each row execute function public.validate_managed_classification('sexual_frequency_preference', 'profile_sexual_frequency_preference');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_sexual_health_status'
  ) then
    create trigger validate_managed_profile_sexual_health_status before insert or update of sexual_health_status on public.profiles
      for each row execute function public.validate_managed_classification('sexual_health_status', 'profile_sexual_health_status');
  end if;
end
$do$;

do $do$
begin
  if not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = 'profiles' and tg.tgname = 'validate_managed_profile_workplace_safety'
  ) then
    create trigger validate_managed_profile_workplace_safety before insert or update of workplace_safety on public.profiles
      for each row execute function public.validate_managed_classification('workplace_safety', 'profile_workplace_safety');
  end if;
end
$do$;

do $verify$
declare
  v_missing text;
  v_wrong text;
  v_total int;
begin
  -- Postconditions assert the REACHED STATE, not that this file changed
  -- anything: on production every branch above is correctly a no-op, so a
  -- "rows affected" check would be vacuous here and would only have meaning on
  -- a rebuild.
  with expected(tbl, tg, field, vocab) as (values
    ('accessibility_attributes', 'validate_managed_category', 'category', 'accessibility_category'),
    ('event_amenities', 'validate_managed_category', 'category', 'service_category'),
    ('event_services', 'validate_managed_category', 'category', 'service_category'),
    ('hotels', 'validate_managed_hotel_type', 'hotel_type', 'hotel_type'),
    ('milestones', 'validate_managed_category', 'category', 'milestone_category'),
    ('personalities', 'validate_managed_cause_of_death', 'cause_of_death', 'personality_cause_of_death'),
    ('profiles', 'validate_managed_chosen_family_status', 'chosen_family_status', 'chosen_family'),
    ('profiles', 'validate_managed_current_relationship_status', 'current_relationship_status', 'relationship_status'),
    ('profiles', 'validate_managed_relationship_style', 'relationship_style', 'relationship_style'),
    ('venue_services', 'validate_managed_category', 'category', 'service_category'),
    ('venues', 'validate_managed_accommodation_type', 'accommodation_type', 'hotel_type'),
    ('venues', 'validate_managed_category', 'category', 'venue_category'),
    ('profiles', 'validate_managed_profile_bdsm_role', 'bdsm_role', 'profile_bdsm_role'),
    ('profiles', 'validate_managed_profile_communication_about_sex', 'communication_about_sex', 'profile_communication_about_sex'),
    ('profiles', 'validate_managed_profile_disability_status', 'disability_status', 'profile_disability_status'),
    ('profiles', 'validate_managed_profile_family_acceptance_level', 'family_acceptance_level', 'profile_family_acceptance_level'),
    ('profiles', 'validate_managed_profile_financial_situation', 'financial_situation', 'profile_financial_situation'),
    ('profiles', 'validate_managed_profile_housing_situation', 'housing_situation', 'profile_housing_situation'),
    ('profiles', 'validate_managed_profile_immigration_status', 'immigration_status', 'profile_immigration_status'),
    ('profiles', 'validate_managed_profile_jealousy_comfort_level', 'jealousy_comfort_level', 'profile_jealousy_comfort_level'),
    ('profiles', 'validate_managed_profile_kink_experience_level', 'kink_experience_level', 'profile_kink_experience_level'),
    ('profiles', 'validate_managed_profile_mental_health_openness', 'mental_health_openness', 'profile_mental_health_openness'),
    ('profiles', 'validate_managed_profile_neurodivergent_status', 'neurodivergent_status', 'profile_neurodivergent_status'),
    ('profiles', 'validate_managed_profile_physical_affection_preference', 'physical_affection_preference', 'profile_physical_affection_preference'),
    ('profiles', 'validate_managed_profile_romance_style', 'romance_style', 'profile_romance_style'),
    ('profiles', 'validate_managed_profile_sexual_exploration_openness', 'sexual_exploration_openness', 'profile_sexual_exploration_openness'),
    ('profiles', 'validate_managed_profile_sexual_frequency_preference', 'sexual_frequency_preference', 'profile_sexual_frequency_preference'),
    ('profiles', 'validate_managed_profile_sexual_health_status', 'sexual_health_status', 'profile_sexual_health_status'),
    ('profiles', 'validate_managed_profile_workplace_safety', 'workplace_safety', 'profile_workplace_safety')
  )
  select string_agg(e.tbl || '.' || e.tg, ', ' order by e.tbl, e.tg) into v_missing
  from expected e
  where not exists (
    select 1 from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and not tg.tgisinternal
      and c.relname = e.tbl and tg.tgname = e.tg
  );
  if v_missing is not null then
    raise exception 'managed-taxonomy triggers missing: %', v_missing;
  end if;

  -- Attached is not the same as attached correctly. A trigger carrying the
  -- wrong vocabulary would validate every row against the wrong term list and
  -- still satisfy the check above.
  with expected(tbl, tg, field, vocab) as (values
    ('accessibility_attributes', 'validate_managed_category', 'category', 'accessibility_category'),
    ('event_amenities', 'validate_managed_category', 'category', 'service_category'),
    ('event_services', 'validate_managed_category', 'category', 'service_category'),
    ('hotels', 'validate_managed_hotel_type', 'hotel_type', 'hotel_type'),
    ('milestones', 'validate_managed_category', 'category', 'milestone_category'),
    ('personalities', 'validate_managed_cause_of_death', 'cause_of_death', 'personality_cause_of_death'),
    ('profiles', 'validate_managed_chosen_family_status', 'chosen_family_status', 'chosen_family'),
    ('profiles', 'validate_managed_current_relationship_status', 'current_relationship_status', 'relationship_status'),
    ('profiles', 'validate_managed_relationship_style', 'relationship_style', 'relationship_style'),
    ('venue_services', 'validate_managed_category', 'category', 'service_category'),
    ('venues', 'validate_managed_accommodation_type', 'accommodation_type', 'hotel_type'),
    ('venues', 'validate_managed_category', 'category', 'venue_category'),
    ('profiles', 'validate_managed_profile_bdsm_role', 'bdsm_role', 'profile_bdsm_role'),
    ('profiles', 'validate_managed_profile_communication_about_sex', 'communication_about_sex', 'profile_communication_about_sex'),
    ('profiles', 'validate_managed_profile_disability_status', 'disability_status', 'profile_disability_status'),
    ('profiles', 'validate_managed_profile_family_acceptance_level', 'family_acceptance_level', 'profile_family_acceptance_level'),
    ('profiles', 'validate_managed_profile_financial_situation', 'financial_situation', 'profile_financial_situation'),
    ('profiles', 'validate_managed_profile_housing_situation', 'housing_situation', 'profile_housing_situation'),
    ('profiles', 'validate_managed_profile_immigration_status', 'immigration_status', 'profile_immigration_status'),
    ('profiles', 'validate_managed_profile_jealousy_comfort_level', 'jealousy_comfort_level', 'profile_jealousy_comfort_level'),
    ('profiles', 'validate_managed_profile_kink_experience_level', 'kink_experience_level', 'profile_kink_experience_level'),
    ('profiles', 'validate_managed_profile_mental_health_openness', 'mental_health_openness', 'profile_mental_health_openness'),
    ('profiles', 'validate_managed_profile_neurodivergent_status', 'neurodivergent_status', 'profile_neurodivergent_status'),
    ('profiles', 'validate_managed_profile_physical_affection_preference', 'physical_affection_preference', 'profile_physical_affection_preference'),
    ('profiles', 'validate_managed_profile_romance_style', 'romance_style', 'profile_romance_style'),
    ('profiles', 'validate_managed_profile_sexual_exploration_openness', 'sexual_exploration_openness', 'profile_sexual_exploration_openness'),
    ('profiles', 'validate_managed_profile_sexual_frequency_preference', 'sexual_frequency_preference', 'profile_sexual_frequency_preference'),
    ('profiles', 'validate_managed_profile_sexual_health_status', 'sexual_health_status', 'profile_sexual_health_status'),
    ('profiles', 'validate_managed_profile_workplace_safety', 'workplace_safety', 'profile_workplace_safety')
  )
  select string_agg(e.tbl || '.' || e.tg, ', ' order by e.tbl, e.tg) into v_wrong
  from expected e
  join pg_class c on c.relname = e.tbl
  join pg_namespace ns on ns.oid = c.relnamespace and ns.nspname = 'public'
  join pg_trigger tg on tg.tgrelid = c.oid and tg.tgname = e.tg and not tg.tgisinternal
  where position('validate_managed_classification(''' || e.field || ''', ''' || e.vocab || ''')'
                 in pg_get_triggerdef(tg.oid)) = 0;
  if v_wrong is not null then
    raise exception 'managed-taxonomy triggers carry the wrong arguments: %', v_wrong;
  end if;

  -- 33 = the 29 above plus the four already declared literally elsewhere. A
  -- duplicate, or one of those four lost, shows up as a different number
  -- instead of passing silently.
  select count(*) into v_total
  from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid
  join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'public' and not tg.tgisinternal and tg.tgname like 'validate_managed%';
  if v_total <> 33 then
    raise exception 'expected 33 validate_managed* triggers, found %', v_total;
  end if;
end
$verify$;
