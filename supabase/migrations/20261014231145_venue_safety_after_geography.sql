-- The venue city/country derivation and consistency triggers run after the
-- former safety trigger, so a later country change could leave its safety flag
-- stale. Evaluate it last against the final country, city and category.
DROP TRIGGER IF EXISTS trg_venues_safety_gated ON public.venues;
DROP TRIGGER IF EXISTS zzzzzz_venues_safety_gated ON public.venues;

CREATE TRIGGER zzzzzz_venues_safety_gated
BEFORE INSERT OR UPDATE OF country_id, city_id, category, country, city, state
ON public.venues
FOR EACH ROW
EXECUTE FUNCTION public.set_venue_safety_gated();

UPDATE public.venues v
SET safety_gated = public.venue_is_safety_gated(v.country_id, v.city_id, v.category)
WHERE v.duplicate_of_id IS NULL
  AND coalesce(v.safety_gated, false)
    IS DISTINCT FROM public.venue_is_safety_gated(v.country_id, v.city_id, v.category);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.venues v
    WHERE v.duplicate_of_id IS NULL
      AND coalesce(v.safety_gated, false)
        IS DISTINCT FROM public.venue_is_safety_gated(v.country_id, v.city_id, v.category)
  ) THEN
    RAISE EXCEPTION 'venue safety gating remains inconsistent';
  END IF;
END $$;
