-- Fill gaps only; locations stay independent from an organisation's other branches.
alter table public.organizations add column if not exists timezone text;
alter table public.venues add column if not exists timezone text;
alter table public.hotels add column if not exists timezone text;

create table public.entity_location_jobs (
  entity_table text not null check(entity_table in ('organizations','venues','hotels')),
  entity_id uuid not null,
  fingerprint text not null,
  status text not null default 'pending' check(status in ('pending','running','done','no_match','error')),
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  updated_at timestamptz not null default now(),
  primary key(entity_table,entity_id)
);
alter table public.entity_location_jobs enable row level security;
revoke all on public.entity_location_jobs from public,anon,authenticated;
grant all on public.entity_location_jobs to service_role;

create table public.entity_location_audit (
  id bigint generated always as identity primary key,
  entity_table text not null,
  entity_id uuid not null,
  source text not null,
  before_data jsonb not null,
  patch jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.entity_location_audit enable row level security;
revoke all on public.entity_location_audit from public,anon,authenticated;
grant select,insert on public.entity_location_audit to service_role;
grant usage,select on sequence public.entity_location_audit_id_seq to service_role;

create or replace function public.entity_location_fingerprint(p jsonb)
returns text language sql immutable set search_path=public,pg_temp as $$
 select md5(jsonb_build_array(p->'address',p->'city',p->'city_id',p->'country',p->'country_id',
   p->'postal_code',p->'latitude',p->'longitude',p->'timezone')::text)
$$;

create or replace function public.entity_location_timezone()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if nullif(btrim(new.timezone),'') is null and new.city_id is not null then
   select nullif(timezone,'') into new.timezone from public.cities where id=new.city_id;
 end if;
 return new;
end $$;

create or replace function public.sync_entity_location_to_organization()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if new.organization_id is null or new.duplicate_of_id is not null then return null; end if;
 update public.organizations o set
   address=coalesce(nullif(btrim(o.address),''),nullif(btrim(new.address),'')),
   country_id=coalesce(o.country_id,new.country_id),
   city_id=coalesce(o.city_id,new.city_id),
   postal_code=coalesce(nullif(btrim(o.postal_code),''),nullif(btrim(new.postal_code),'')),
   latitude=coalesce(o.latitude,new.latitude),longitude=coalesce(o.longitude,new.longitude),
   timezone=coalesce(nullif(btrim(o.timezone),''),nullif(btrim(new.timezone),'')),
   updated_at=now(),
   field_provenance=coalesce(o.field_provenance,'{}') || jsonb_build_object('location_inheritance',
     jsonb_build_object('source_table',tg_table_name,'source_id',new.id,'at',now()))
 where o.id=new.organization_id and o.duplicate_of_id is null
   and (o.primary_venue_id=new.id or (o.primary_venue_id is null
     and not exists(select 1 from public.venues v where v.organization_id=o.id and v.id<>new.id and v.duplicate_of_id is null)
     and not exists(select 1 from public.hotels h where h.organization_id=o.id and h.id<>new.id and h.duplicate_of_id is null)))
   and (o.city_id is null or new.city_id is null or o.city_id=new.city_id)
   and (o.country_id is null or new.country_id is null or o.country_id=new.country_id)
   and (nullif(btrim(o.address),'') is null or lower(btrim(o.address))=lower(btrim(new.address)))
   and ((nullif(btrim(o.address),'') is null and nullif(btrim(new.address),'') is not null)
     or (o.country_id is null and new.country_id is not null) or (o.city_id is null and new.city_id is not null)
     or (nullif(btrim(o.postal_code),'') is null and nullif(btrim(new.postal_code),'') is not null)
     or (o.latitude is null and new.latitude is not null) or (o.longitude is null and new.longitude is not null)
     or (nullif(btrim(o.timezone),'') is null and nullif(btrim(new.timezone),'') is not null));
 return null;
end $$;
revoke all on function public.sync_entity_location_to_organization() from public,anon,authenticated;

create or replace function public.enqueue_entity_location()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare p jsonb:=to_jsonb(new); f text;
begin
 if new.duplicate_of_id is not null then return null; end if;
 if new.city_id is not null and new.country_id is not null and nullif(btrim(new.postal_code),'') is not null
   and new.latitude is not null and new.longitude is not null and nullif(btrim(new.timezone),'') is not null then return null; end if;
 if nullif(btrim(new.address),'') is null and (new.latitude is null or new.longitude is null) then return null; end if;
 -- A linked organisation receives the result from its location. Do not geocode twice.
 if tg_table_name='organizations' then
   if new.primary_venue_id is not null then return null; end if;
 end if;
 f:=public.entity_location_fingerprint(p);
 insert into public.entity_location_jobs(entity_table,entity_id,fingerprint)
 values(tg_table_name,new.id,f)
 on conflict(entity_table,entity_id) do update set fingerprint=excluded.fingerprint,status='pending',attempts=0,
   next_attempt_at=now(),last_error=null,updated_at=now()
 where entity_location_jobs.fingerprint<>excluded.fingerprint;
 return null;
end $$;
revoke all on function public.enqueue_entity_location() from public,anon,authenticated;

do $$ declare t text; begin
 foreach t in array array['organizations','venues','hotels'] loop
 execute format('create trigger zz_location_timezone before insert or update of city_id,timezone on public.%I for each row execute function public.entity_location_timezone()',t);
 execute format('create trigger zz_location_enqueue after insert or update of address,city_id,country_id,postal_code,latitude,longitude,timezone on public.%I for each row execute function public.enqueue_entity_location()',t);
 end loop;
 foreach t in array array['venues','hotels'] loop
 execute format('create trigger zz_location_org_sync after insert or update of organization_id,address,city_id,country_id,postal_code,latitude,longitude,timezone on public.%I for each row execute function public.sync_entity_location_to_organization()',t);
 end loop;
end $$;

-- Apply external evidence atomically against the exact location snapshot it came from.
create or replace function public.apply_entity_location(p_table text,p_id uuid,p_fingerprint text,p_patch jsonb,p_source text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r jsonb; after_row jsonb; patch jsonb:='{}'; k text; v jsonb; assignments text;
begin
 if p_table not in ('organizations','venues','hotels') then raise exception 'Unsupported entity'; end if;
 execute format('select to_jsonb(t) from public.%I t where id=$1 for update',p_table) into r using p_id;
 if r is null or r->>'duplicate_of_id' is not null or public.entity_location_fingerprint(r)<>p_fingerprint then
   return jsonb_build_object('stale',true,'filled',0);
 end if;
 for k,v in select key,value from jsonb_each(p_patch) loop
   if k=any(array['address','city_id','country_id','postal_code','latitude','longitude','timezone','state'])
      and v<>'null'::jsonb and nullif(btrim(v#>>'{}'),'') is not null
      and nullif(btrim(r->>k),'') is null then patch:=patch||jsonb_build_object(k,v); end if;
 end loop;
 if patch='{}'::jsonb then return jsonb_build_object('filled',0,'fingerprint',public.entity_location_fingerprint(r),'row',r); end if;
 select string_agg(format('%I=p.%I',key,key),',') into assignments from jsonb_each(patch);
 execute format('update public.%I t set %s,updated_at=now() from jsonb_populate_record(null::public.%I,$1) p where t.id=$2 returning to_jsonb(t)',p_table,assignments,p_table)
 into after_row using patch,p_id;
 insert into public.entity_location_audit(entity_table,entity_id,source,before_data,patch) values(p_table,p_id,p_source,r,patch);
 return jsonb_build_object('filled',(select count(*) from jsonb_object_keys(patch)),'patch',patch,
   'fingerprint',public.entity_location_fingerprint(after_row),'row',after_row);
end $$;
revoke all on function public.apply_entity_location(text,uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.apply_entity_location(text,uuid,text,jsonb,text) to service_role;

-- One global geocoder lease prevents trigger/cron/backfill concurrency from flooding the provider.
create table public.entity_location_worker_lease(id boolean primary key default true check(id),until_at timestamptz not null default now(),dispatched_at timestamptz not null default '-infinity');
insert into public.entity_location_worker_lease(id) values(true);
alter table public.entity_location_worker_lease enable row level security;
revoke all on public.entity_location_worker_lease from public,anon,authenticated;
create or replace function public.claim_entity_location_jobs(p_limit int default 20)
returns setof public.entity_location_jobs language plpgsql security definer set search_path=public,pg_temp as $$
begin
 update entity_location_worker_lease set until_at=now()+interval '60 seconds' where id and until_at<=now();
 if not found then return; end if;
 return query with pick as (
   select entity_table,entity_id from entity_location_jobs
   where (status in ('pending','error') and attempts<4 and next_attempt_at<=now())
     or (status='running' and updated_at<now()-interval '2 minutes')
   order by next_attempt_at limit greatest(1,least(p_limit,20)) for update skip locked
 ) update entity_location_jobs j set status='running',updated_at=now()
 from pick p where j.entity_table=p.entity_table and j.entity_id=p.entity_id returning j.*;
end $$;
revoke all on function public.claim_entity_location_jobs(int) from public,anon,authenticated;
grant execute on function public.claim_entity_location_jobs(int) to service_role;

-- A statement-level wakeup is debounced by the global lease. Cron retries failed deliveries.
create or replace function public.wake_entity_location_worker()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 update entity_location_worker_lease set dispatched_at=now()
   where id and until_at<=now() and dispatched_at<now()-interval '60 seconds';
 if found then
   perform net.http_post(url:='https://xqeacpakadqfxjxjcewc.supabase.co/functions/v1/complete-entity-location',
     headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',
       (select decrypted_secret from vault.decrypted_secrets where name='WEBHOOK_SECRET')),
     body:='{}'::jsonb,timeout_milliseconds:=55000);
 end if;
 return null;
end $$;
revoke all on function public.wake_entity_location_worker() from public,anon,authenticated;
create trigger wake_location_worker after insert on public.entity_location_jobs for each statement execute function public.wake_entity_location_worker();

select cron.schedule('entity_location_completion','* * * * *',$cmd$
 select net.http_post(url:='https://xqeacpakadqfxjxjcewc.supabase.co/functions/v1/complete-entity-location',
 headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',(select decrypted_secret from vault.decrypted_secrets where name='WEBHOOK_SECRET')),
 body:='{}'::jsonb,timeout_milliseconds:=55000);
$cmd$);
insert into public.admin_automations(slug,name,description,managed_by,enabled,trigger,conditions,action,schedule)
values('entity_location_completion','Entity location completion','Fill missing location fields from external address evidence; immediate wakeup and retry queue.',
 'system',true,'{"type":"schedule"}','[]',jsonb_build_object('type','cron','jobname','entity_location_completion','command',
 (select command from cron.job where jobname='entity_location_completion')),'* * * * *');
