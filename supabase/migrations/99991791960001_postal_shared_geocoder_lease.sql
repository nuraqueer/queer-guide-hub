-- The postal drain and entity-location worker both use Photon. Claim the same
-- lease before a postal batch so their paced requests cannot overlap.
create or replace function public.claim_postal_geocoder_lease()
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_claimed_at timestamptz;
begin
  update public.entity_location_worker_lease
     set until_at = clock_timestamp() + interval '150 seconds',
         claimed_at = clock_timestamp()
   where id = true and until_at <= clock_timestamp()
   returning claimed_at into v_claimed_at;
  return v_claimed_at;
end;
$$;

revoke all on function public.claim_postal_geocoder_lease() from public, anon, authenticated;
grant execute on function public.claim_postal_geocoder_lease() to service_role;
