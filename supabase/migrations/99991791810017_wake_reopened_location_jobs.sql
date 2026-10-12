-- New evidence often reopens an existing no_match job through ON CONFLICT UPDATE.
-- Wake the worker for that path too; the lease function debounces dispatches.
create trigger wake_reopened_location_worker
after update of fingerprint,status on public.entity_location_jobs
for each row
when (new.status='pending' and
  (old.status is distinct from new.status or old.fingerprint is distinct from new.fingerprint))
execute function public.wake_entity_location_worker();

