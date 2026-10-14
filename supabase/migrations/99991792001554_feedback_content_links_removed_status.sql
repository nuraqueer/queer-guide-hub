BEGIN;
SET LOCAL lock_timeout = '3s';

-- The worker uses AUTO_REMOVED after repeated confirmed 404/410 checks.
ALTER TABLE public.content_links DROP CONSTRAINT content_links_status_check;
ALTER TABLE public.content_links ADD CONSTRAINT content_links_status_check CHECK (status IN ('PENDING','OK','REDIRECT','BROKEN','BLOCKED','TIMEOUT','DISMISSED','AUTO_REMOVED'));

-- A historical link record must not clear a URL that has since been replaced.
CREATE OR REPLACE FUNCTION public.auto_remove_broken_link(link_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _link content_links%ROWTYPE;
BEGIN
  SELECT * INTO _link FROM content_links WHERE id = link_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- Null-out the URL field on the source content table
  EXECUTE format(
    'UPDATE public.%I SET %I = NULL WHERE id = $1 AND %I = $2',
    _link.content_type, _link.field_name, _link.field_name
  ) USING _link.content_id, _link.original_url;

  -- Mark the content_link as auto-removed
  UPDATE content_links
  SET status = 'AUTO_REMOVED',
      auto_removed_at = NOW(),
      check_count = check_count + 1
  WHERE id = link_id;
END;
$function$
;

-- Preserve the existing service-only boundary on the privileged write RPC.
REVOKE ALL ON FUNCTION public.auto_remove_broken_link(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auto_remove_broken_link(uuid) TO service_role;

-- Previous counters mixed dead responses with timeouts/5xx. Only the latest
-- recorded dead response is confirmed, so restart its sequence conservatively.
UPDATE public.content_links SET check_count = 1
WHERE status = 'BROKEN' AND check_count > 1;

-- Retained timeouts and bot walls must remain eligible for later recovery.
CREATE OR REPLACE FUNCTION public.get_links_due_for_recheck(batch_limit integer DEFAULT 50)
RETURNS SETOF public.content_links
LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  SELECT * FROM public.content_links
  WHERE status IN ('BROKEN', 'TIMEOUT', 'BLOCKED')
    AND check_count >= 1
    AND last_checked_at IS NOT NULL
    AND (
      (check_count = 1 AND last_checked_at < NOW() - INTERVAL '1 day')
      OR (check_count = 2 AND last_checked_at < NOW() - INTERVAL '1 week')
      OR (check_count >= 3 AND last_checked_at < NOW() - INTERVAL '1 month')
    )
  ORDER BY last_checked_at ASC
  LIMIT greatest(1, least(coalesce(batch_limit, 50), 50));
$function$;

COMMIT;
