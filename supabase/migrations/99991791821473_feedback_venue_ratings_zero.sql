-- Recovery record: already applied in production. Do not re-run.
-- Recovered verbatim from supabase_migrations.schema_migrations.statements.
-- Recorded SQL MD5: 977495caf0eaf199fad1c33c17d5bd56

-- Reuse venue_reviews: one public rating per member and venue, including zero.
ALTER TABLE public.venue_reviews DROP CONSTRAINT venue_reviews_rating_check;
ALTER TABLE public.venue_reviews ADD CONSTRAINT venue_reviews_rating_check CHECK (rating BETWEEN 0 AND 5);
COMMENT ON COLUMN public.venue_reviews.rating IS 'Public venue rating from 0 to 5; one per member and venue.';
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.venue_reviews WHERE rating NOT BETWEEN 0 AND 5) THEN
    RAISE EXCEPTION 'Venue rating range invariant failed';
  END IF;
END $$;

