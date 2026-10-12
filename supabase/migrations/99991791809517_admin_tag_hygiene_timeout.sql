-- The admin-only hygiene diagnostic measured 10.8 seconds during release checks,
-- exceeding PostgREST's inherited 8-second budget. Keep every counter and the
-- existing authorization guard; extend only this function's bounded runtime.
ALTER FUNCTION public.tag_hygiene_stats() SET statement_timeout TO '30s';
NOTIFY pgrst, 'reload schema';

