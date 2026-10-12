alter table public.entity_location_worker_lease add column claimed_at timestamptz not null default now();
create or replace function public.claim_entity_location_jobs(p_limit int default 20)
returns setof public.entity_location_jobs language plpgsql security definer set search_path=public,pg_temp as $$
declare n int;
begin
 update entity_location_worker_lease set until_at=now()+case when p_limit>20 then interval '3 minutes' else interval '60 seconds' end,
   claimed_at=now() where id and until_at<=now();
 if not found then return; end if;
 return query with pick as (
   select entity_table,entity_id from entity_location_jobs
   where (status in ('pending','error') and attempts<4 and next_attempt_at<=now())
     or (status='running' and updated_at<now()-interval '2 minutes')
   order by priority,next_attempt_at limit greatest(1,least(p_limit,50)) for update skip locked
 ) update entity_location_jobs j set status='running',updated_at=now()
 from pick p where j.entity_table=p.entity_table and j.entity_id=p.entity_id returning j.*;
 get diagnostics n=row_count;
 if n=0 then update entity_location_worker_lease set until_at=now() where id and claimed_at=now(); end if;
end $$;
revoke all on function public.claim_entity_location_jobs(int) from public,anon,authenticated;
grant execute on function public.claim_entity_location_jobs(int) to service_role;

create or replace function public.release_entity_location_lease(p_claimed_at timestamptz)
returns void language sql security definer set search_path=public,pg_temp as $$
 update entity_location_worker_lease set until_at=now() where id and claimed_at=p_claimed_at
$$;
revoke all on function public.release_entity_location_lease(timestamptz) from public,anon,authenticated;
grant execute on function public.release_entity_location_lease(timestamptz) to service_role;

