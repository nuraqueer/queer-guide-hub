-- Ten events are published on a city more than 250 km from their own
-- coordinates. Three remedies, because the evidence differs per row.
--
-- THIS IS A REGRESSION, NOT A NEW CLASS. 99991789886174 swept exactly this
-- shape and its postcondition P4 asserted corpus-wide zero; 99970901120000
-- repaired the Atlanta Dream row by name. Measured 2026-10-17 it is wrong
-- again, and all ten are `seo_indexable = true`, i.e. published on the wrong
-- city's page.
--
-- WHY A PURE UNLINK WOULD HAVE BEEN UNDONE WITHIN THE HOUR, which is the one
-- thing to know before touching these rows: `geo-link-content` runs hourly and
-- "only reprocesses rows with a NULL city_id/country_id" (its own comment), so
-- nulling the link is exactly what makes a row eligible for the re-linker that
-- produced the defect. It refuses only when it finds a standing quarantine —
-- `enrichment_status.event_city_link.blocked`, read as `priorLink?.blocked`,
-- "otherwise this hourly job would undo that runner's decision one row at a
-- time". So every blocked row here is stamped, and the stamp is the durable
-- part of the repair rather than the NULL.
--
-- THE DISTANCE DOES NOT DECIDE — the rule 99991789886174 already recorded, and
-- two rows here prove it again. The second signal is the event's OWN `state`
-- text, never proximity alone.
--
--   RELINK (4) — a same-name row exists whose region_name matches the event's
--   own state, 1-4 km from its coordinates:
--     BERTHA: Grateful Drag        state Maine          -> Portland, Maine    (1 km)
--     National Tryout Day          state CA             -> San Marcos, CA     (4 km)
--     QCC Meet Up - North City     state CA             -> San Marcos, CA     (2 km)
--     SC Pride Aftermath - 21+     state South Carolina -> Columbia, SC       (1 km)
--
--   BLOCK (4) — no same-name row matches the state, so the correct city is not
--   representable (`cities` holds at most one row per (name, country)) and a
--   null is recoverable where a guess is not:
--     Flip Phone: Dolly Parton Drag Brunch  state Texas -> no Arlington, Texas
--     Flip Phone: Hocus Pocus Drag Brunch   state Texas -> no Arlington, Texas
--     Loon Mountain Weekend 2026-27         state NH    -> no Lincoln, New Hampshire
--     Atlanta Dream v Washington Mystics    state Georgia -> no College Park, Georgia
--   The Atlanta Dream row's only same-name candidate is College Park, MARYLAND,
--   whose slug is itself a `tmp-` placeholder.
--
--   GEO (2) — the LINK is correct and the COORDINATES are junk, so the
--   coordinates are retracted and the city is KEPT, which is the opposite of
--   what the distance argued for:
--     Mardi XKX / XK10 Midweek Power — both sit on 46.00000000 / 2.00000000,
--     the centroid-of-France placeholder. City text Paris, state Ile-de-France,
--     postal 75011 (Paris 11e), venue XK Boys Cruising Bar, and Paris,
--     Île-de-France is their ONLY same-name candidate.
--
-- SOFT ON PRECONDITIONS, HARD ON POSTCONDITIONS. Every statement is guarded on
-- the wrong state it is correcting, so a row another session has already fixed
-- is skipped rather than clobbered and this file cannot abort `db push` for the
-- whole repo. The postconditions assert the END STATE, including the
-- corpus-wide claim rather than only these ten ids.
--
-- Batch size is not a concern at ten rows; `trg_search_documents_event` makes a
-- 300-row events UPDATE cost ~14.6s, which is why the sweeps are capped, but
-- ten is nothing.

begin;

-- ── RELINK ──────────────────────────────────────────────────────────────────
-- Frozen (event, city) pairs, each verified above. Pinned rather than derived
-- at apply time so the file cannot resolve a different answer later; the
-- `city_id = <wrong>` guard is what keeps it safe if a row has since moved.
update events e
set city_id = v.right_city,
    needs_attention = true,
    enrichment_status = coalesce(e.enrichment_status, '{}'::jsonb)
      || jsonb_build_object(
           'event_city_link',
           coalesce(e.enrichment_status -> 'event_city_link', '{}'::jsonb)
             || jsonb_build_object(
                  'relinked_at', now(),
                  'relinked_by', 'migration:99991792224387',
                  'relinked_from', v.wrong_city::text,
                  'evidence', 'event.state matches the target city region_name'
                )
         )
from (values
  ('317e54a0-0790-4248-bd87-625ce381f16e'::uuid, '9132a8ab-1245-4607-848d-4374e157d7a0'::uuid, '80a6d7af-1b67-44fd-8377-6388e9c46cae'::uuid),
  ('3014376d-aa8c-41e4-8224-b8bbf014935b'::uuid, 'e5ec8840-4d69-4cdc-b87e-f16e026581ed'::uuid, 'daeb0508-b150-43b3-ae2d-23182ef5cdcc'::uuid),
  ('f4e39750-3429-4217-93d8-a5afc401d1a7'::uuid, 'e5ec8840-4d69-4cdc-b87e-f16e026581ed'::uuid, 'daeb0508-b150-43b3-ae2d-23182ef5cdcc'::uuid),
  ('3099ef9b-5eb7-42a8-934c-6ca4a795e86a'::uuid, 'b362b7ce-2ec0-4aba-aa6f-25564a5d73de'::uuid, '8c0d2732-e24a-49f9-8201-bbc7873274e0'::uuid)
) as v(event_id, wrong_city, right_city)
where e.id = v.event_id
  and e.city_id = v.wrong_city;

-- ── BLOCK ───────────────────────────────────────────────────────────────────
-- The NULL is the visible half; the `blocked` stamp is the half that makes it
-- stick against the hourly re-linker.
update events e
set city_id = null,
    needs_attention = true,
    enrichment_status = coalesce(e.enrichment_status, '{}'::jsonb)
      || jsonb_build_object(
           'event_city_link',
           coalesce(e.enrichment_status -> 'event_city_link', '{}'::jsonb)
             || jsonb_build_object(
                  'blocked', v.reason,
                  'blocked_at', now(),
                  'blocked_by', 'migration:99991792224387'
                )
         )
from (values
  ('77bcbdab-b20d-4f7d-a87e-de14f05bd18a'::uuid, '9c4c13e8-8858-4496-92f1-66f1262e1b0c'::uuid,
   'same-name collision: event state Texas, no Arlington, Texas row exists'),
  ('911bda75-0c62-45f9-8c68-f19446aaf3c6'::uuid, '9c4c13e8-8858-4496-92f1-66f1262e1b0c'::uuid,
   'same-name collision: event state Texas, no Arlington, Texas row exists'),
  ('c620921c-ca27-408c-b535-24ada837d104'::uuid, '6ba4087b-b6a2-4ff9-9ea3-a91c748c1da7'::uuid,
   'same-name collision: event state NH, no Lincoln, New Hampshire row exists'),
  ('baee1b62-2b7b-4dde-9816-e927f6d5d6d2'::uuid, '43f48339-2eb4-4def-811c-5bd8b235929d'::uuid,
   'same-name collision: event state Georgia, no College Park, Georgia row exists')
) as v(event_id, wrong_city, reason)
where e.id = v.event_id
  and e.city_id = v.wrong_city;

-- ── GEO ─────────────────────────────────────────────────────────────────────
-- Retract the placeholder coordinates and KEEP the city. Guarded on the exact
-- placeholder so a row that has since been geocoded properly is left alone.
update events e
set latitude = null,
    longitude = null,
    needs_attention = true,
    enrichment_status = coalesce(e.enrichment_status, '{}'::jsonb)
      || jsonb_build_object(
           'event_city_link',
           coalesce(e.enrichment_status -> 'event_city_link', '{}'::jsonb)
             || jsonb_build_object(
                  'coords_retracted_at', now(),
                  'coords_retracted_by', 'migration:99991792224387',
                  'reason', 'coordinates were the 46.0/2.0 centroid-of-France placeholder; city link corroborated by state and postal 75011'
                )
         )
where e.id in (
    'e58e1413-9910-49c5-a9c2-cb068fbffdfb'::uuid,
    'cdfac8f4-fdbb-4f42-814c-f5167b140ba9'::uuid
  )
  and e.latitude = 46.0
  and e.longitude = 2.0;

do $verify$
declare
  v_far int;
  v_blocked int;
  v_relinked int;
  v_geo int;
begin
  -- P1. THE CORPUS-WIDE CLAIM, not just these ten ids: no live event anywhere
  -- sits over 250 km from the city it is linked to. This is postcondition P4 of
  -- 99991789886174, restated because that is the invariant that regressed.
  select count(*) into v_far
  from events e join cities c on c.id = e.city_id
  where e.latitude is not null and c.latitude is not null
    and public.haversine_m(e.latitude::numeric, e.longitude::numeric,
                           c.latitude::numeric, c.longitude::numeric) > 250000;
  if v_far <> 0 then
    raise exception 'P1: % event(s) still over 250 km from their linked city', v_far;
  end if;

  -- P2. The four blocked rows are unlinked AND carry the standing quarantine.
  -- The stamp is asserted separately from the NULL because the NULL alone is
  -- what the hourly re-linker treats as an invitation.
  select count(*) into v_blocked
  from events
  where id in ('77bcbdab-b20d-4f7d-a87e-de14f05bd18a','911bda75-0c62-45f9-8c68-f19446aaf3c6',
               'c620921c-ca27-408c-b535-24ada837d104','baee1b62-2b7b-4dde-9816-e927f6d5d6d2')
    and city_id is null
    and coalesce(enrichment_status -> 'event_city_link' ->> 'blocked', '') <> '';
  if v_blocked <> 4 then
    raise exception 'P2: % of 4 blocked rows are unlinked and quarantined', v_blocked;
  end if;

  -- P3. The four relinked rows point at the city their own state corroborates.
  select count(*) into v_relinked
  from events e
  join (values
    ('317e54a0-0790-4248-bd87-625ce381f16e'::uuid, '80a6d7af-1b67-44fd-8377-6388e9c46cae'::uuid),
    ('3014376d-aa8c-41e4-8224-b8bbf014935b'::uuid, 'daeb0508-b150-43b3-ae2d-23182ef5cdcc'::uuid),
    ('f4e39750-3429-4217-93d8-a5afc401d1a7'::uuid, 'daeb0508-b150-43b3-ae2d-23182ef5cdcc'::uuid),
    ('3099ef9b-5eb7-42a8-934c-6ca4a795e86a'::uuid, '8c0d2732-e24a-49f9-8201-bbc7873274e0'::uuid)
  ) as v(event_id, right_city) on v.event_id = e.id and e.city_id = v.right_city;
  if v_relinked <> 4 then
    raise exception 'P3: % of 4 relinked rows point at the corroborated city', v_relinked;
  end if;

  -- P4. The two geo rows KEPT their city and lost only the placeholder
  -- coordinates. Asserted in both directions: a sweep that nulled the city too
  -- would satisfy P1 and is the over-reach this remedy exists to avoid.
  select count(*) into v_geo
  from events
  where id in ('e58e1413-9910-49c5-a9c2-cb068fbffdfb','cdfac8f4-fdbb-4f42-814c-f5167b140ba9')
    and latitude is null and longitude is null
    and city_id = 'b46a28a1-5c7a-41ac-a2cc-5b03448f6f69';
  if v_geo <> 2 then
    raise exception 'P4: % of 2 geo rows kept Paris and dropped the placeholder coords', v_geo;
  end if;

  raise notice 'ok: 4 relinked, 4 blocked+quarantined, 2 coords retracted, 0 events over 250 km';
end
$verify$;

commit;
