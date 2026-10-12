-- Recovered from the already-applied production migration history.
-- Original version retained; do not reapply this migration.
-- Temporary PostgREST schema-cache 500s auto-paused this durable backfill.
-- The worker now treats that specific transient as retryable; re-arm its cron
-- and allow a longer outage before the circuit breaker pauses it again.
update public.admin_automations
set enabled=true,lifecycle_state='active',consecutive_failures=0,
    auto_pause_threshold=20,updated_at=now()
where slug='entity_location_completion';
select public.sync_automations_to_cron(true);
;
