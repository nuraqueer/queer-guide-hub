-- These flags are derived, including when a caller writes safety_gated directly.
-- UPDATE OF only observes statement columns: an address-only edit can change
-- country_id inside a prior trigger without firing a country-scoped trigger.
-- Derive on every row mutation, after the current geography/address guards.
-- Keep the canonical geographic and venue-category predicates unchanged.
DROP TRIGGER IF EXISTS trg_venues_safety_gated ON public.venues;
DROP TRIGGER IF EXISTS zzzzzz_venues_safety_gated ON public.venues;
CREATE TRIGGER zzzzzz_venues_safety_gated
BEFORE INSERT OR UPDATE ON public.venues
FOR EACH ROW EXECUTE FUNCTION public.set_venue_safety_gated();

DROP TRIGGER IF EXISTS trg_organizations_safety_gated ON public.organizations;
DROP TRIGGER IF EXISTS zzzzzz_organizations_safety_gated ON public.organizations;
CREATE TRIGGER zzzzzz_organizations_safety_gated
BEFORE INSERT OR UPDATE ON public.organizations
FOR EACH ROW EXECUTE FUNCTION public.set_entity_safety_gated();

UPDATE public.venues v
SET safety_gated = public.venue_is_safety_gated(v.country_id, v.city_id, v.category)
WHERE v.duplicate_of_id IS NULL
  AND coalesce(v.safety_gated, false)
    IS DISTINCT FROM public.venue_is_safety_gated(v.country_id, v.city_id, v.category);
UPDATE public.organizations o
SET safety_gated = public.location_is_high_risk(o.country_id, o.city_id)
WHERE coalesce(o.safety_gated, false)
    IS DISTINCT FROM public.location_is_high_risk(o.country_id, o.city_id);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.venues v WHERE v.duplicate_of_id IS NULL
      AND coalesce(v.safety_gated, false)
        IS DISTINCT FROM public.venue_is_safety_gated(v.country_id, v.city_id, v.category)
  ) OR EXISTS (
    SELECT 1 FROM public.organizations o
    WHERE coalesce(o.safety_gated, false)
      IS DISTINCT FROM public.location_is_high_risk(o.country_id, o.city_id)
  ) THEN
    RAISE EXCEPTION 'venue/organization safety gating remains inconsistent';
  END IF;
END $$;
