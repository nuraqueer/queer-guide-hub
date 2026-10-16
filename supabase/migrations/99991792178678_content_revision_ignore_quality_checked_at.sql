-- Second round of the content_revisions heartbeat filter (follows
-- 99991792001788). Measured over 24h on 2026-10-14, system revisions:
--   marketplace_brands  496,992 (78%)  496,899 change ONLY quality_checked_at
--   organizations       101,162 (16%)   99,500 change ONLY quality_checked_at
-- A quality sweep stamps "I looked" on rows whose content did not change; the
-- evidence of the check is the quality ledgers, not a revision. The trigger
-- already drops an UPDATE whose only changes are ignored columns, so a real
-- edit to the same row is still recorded. quality_score / trust_score are NOT
-- added: they are values that changed, not heartbeats.

BEGIN;

UPDATE public.content_versioned_tables t
   SET ignore_columns = (
     SELECT array_agg(DISTINCT c ORDER BY c)
       FROM unnest(t.ignore_columns || ARRAY['quality_checked_at']) AS c
   )
 WHERE t.table_name IN ('marketplace_brands', 'organizations');

DO $verify$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(table_name, ', ') INTO v_bad
    FROM public.content_versioned_tables
   WHERE table_name IN ('marketplace_brands', 'organizations')
     AND NOT ('quality_checked_at' = ANY (ignore_columns) AND 'updated_at' = ANY (ignore_columns));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'quality_checked_at not ignored (or updated_at lost) on: %', v_bad;
  END IF;

  -- Two rows, both still enabled: the filter must not switch a table off.
  IF (SELECT count(*) FROM public.content_versioned_tables
       WHERE table_name IN ('marketplace_brands', 'organizations') AND enabled) <> 2 THEN
    RAISE EXCEPTION 'marketplace_brands/organizations must stay enabled';
  END IF;
END $verify$;

COMMIT;
