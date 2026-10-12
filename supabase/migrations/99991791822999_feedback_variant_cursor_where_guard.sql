-- Keep singleton cursor writes compatible with PostgREST safe-update guards.
CREATE OR REPLACE FUNCTION public.marketplace_claim_variant_extract(
  p_limit integer DEFAULT 50, p_claim_token uuid DEFAULT gen_random_uuid()
) RETURNS TABLE(id uuid) LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_cursor private.marketplace_variant_scan_cursor;
  v_ids uuid[];
  v_extracted timestamptz;
  v_updated timestamptz;
  v_id uuid;
BEGIN
  -- Never wait behind another claim invocation. Other writers keep SKIP LOCKED.
  IF NOT pg_try_advisory_xact_lock(721,411) THEN RETURN; END IF;
  DELETE FROM public.marketplace_variant_extract_claims WHERE claimed_at<now()-interval '20 minutes';
  SELECT * INTO v_cursor FROM private.marketplace_variant_scan_cursor WHERE singleton;

  WITH scanned AS MATERIALIZED (
    SELECT l.id,l.attributes_extracted_at,l.updated_at
    FROM public.marketplace_listings l WHERE l.status='active'
      AND (NOT v_cursor.has_cursor OR
        (COALESCE(l.attributes_extracted_at,'-infinity'::timestamptz),l.updated_at,l.id) >
        (COALESCE(v_cursor.extracted_at,'-infinity'::timestamptz),v_cursor.updated_at,v_cursor.listing_id))
    ORDER BY l.attributes_extracted_at ASC NULLS FIRST,l.updated_at,l.id LIMIT 500
  ) SELECT array_agg(s.id),
    (array_agg(s.attributes_extracted_at ORDER BY s.attributes_extracted_at DESC NULLS LAST,s.updated_at DESC,s.id DESC))[1],
    (array_agg(s.updated_at ORDER BY s.attributes_extracted_at DESC NULLS LAST,s.updated_at DESC,s.id DESC))[1],
    (array_agg(s.id ORDER BY s.attributes_extracted_at DESC NULLS LAST,s.updated_at DESC,s.id DESC))[1]
    INTO v_ids,v_extracted,v_updated,v_id FROM scanned s;

  IF v_id IS NULL THEN
    UPDATE private.marketplace_variant_scan_cursor SET has_cursor=false,extracted_at=NULL,updated_at=NULL,listing_id=NULL WHERE singleton;
    RETURN;
  END IF;
  UPDATE private.marketplace_variant_scan_cursor SET has_cursor=true,extracted_at=v_extracted,updated_at=v_updated,listing_id=v_id WHERE singleton;

  RETURN QUERY
  WITH candidates AS MATERIALIZED (
    SELECT l.id FROM public.marketplace_listings l WHERE l.id=ANY(v_ids)
      AND l.status='active'
      AND NOT EXISTS(SELECT 1 FROM public.marketplace_variant_extract_claims c WHERE c.listing_id=l.id)
      AND (l.attributes_extracted_at IS NULL OR EXISTS(
        SELECT 1 FROM public.marketplace_listing_sources s WHERE s.listing_id=l.id AND s.last_seen_at>l.attributes_extracted_at))
    ORDER BY l.attributes_extracted_at ASC NULLS FIRST,l.updated_at,l.id
    LIMIT GREATEST(1,LEAST(p_limit,125)) FOR UPDATE OF l SKIP LOCKED
  ), claimed AS (
    INSERT INTO public.marketplace_variant_extract_claims(listing_id,claim_token)
    SELECT c.id,p_claim_token FROM candidates c ON CONFLICT(listing_id) DO NOTHING RETURNING listing_id
  ) SELECT c.listing_id FROM claimed c;
END $$;
REVOKE ALL ON FUNCTION public.marketplace_claim_variant_extract(integer,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketplace_claim_variant_extract(integer,uuid) TO service_role;


