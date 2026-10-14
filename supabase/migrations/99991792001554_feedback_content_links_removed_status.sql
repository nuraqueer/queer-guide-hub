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
