alter table public.entity_location_jobs add column priority integer not null default 0;
update public.entity_location_jobs set priority=10;
create index entity_location_jobs_due on public.entity_location_jobs(priority,next_attempt_at) where status in ('pending','running','error');
create index if not exists organizations_location_domain on public.organizations(public.org_normalize_domain(coalesce(website_domain,website))) where duplicate_of_id is null;

create or replace function public.claim_entity_location_jobs(p_limit int default 20)
returns setof public.entity_location_jobs language plpgsql security definer set search_path=public,pg_temp as $$
begin
 update entity_location_worker_lease set until_at=now()+interval '60 seconds' where id and until_at<=now();
 if not found then return; end if;
 return query with pick as (
   select entity_table,entity_id from entity_location_jobs
   where (status in ('pending','error') and attempts<4 and next_attempt_at<=now())
     or (status='running' and updated_at<now()-interval '2 minutes')
   order by priority,next_attempt_at limit greatest(1,least(p_limit,20)) for update skip locked
 ) update entity_location_jobs j set status='running',updated_at=now()
 from pick p where j.entity_table=p.entity_table and j.entity_id=p.entity_id returning j.*;
end $$;
revoke all on function public.claim_entity_location_jobs(int) from public,anon,authenticated;
grant execute on function public.claim_entity_location_jobs(int) to service_role;

create or replace function public.enqueue_entity_location()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare p jsonb:=to_jsonb(new); f text; pr int:=case when current_setting('app.location_backfill',true)='on' then 10 else 0 end;
begin
 if new.duplicate_of_id is not null then return null; end if;
 if new.city_id is not null and new.country_id is not null and nullif(btrim(new.postal_code),'') is not null
   and new.latitude is not null and new.longitude is not null and nullif(btrim(new.timezone),'') is not null then return null; end if;
 if nullif(btrim(new.address),'') is null and (new.latitude is null or new.longitude is null)
   and nullif(btrim(new.website),'') is null then return null; end if;
 if tg_table_name='organizations' then
   if new.primary_venue_id is not null then return null; end if;
 end if;
 f:=public.entity_location_fingerprint(p);
 insert into public.entity_location_jobs(entity_table,entity_id,fingerprint,priority)
 values(tg_table_name,new.id,f,pr)
 on conflict(entity_table,entity_id) do update set fingerprint=excluded.fingerprint,status='pending',attempts=0,priority=excluded.priority,
   next_attempt_at=now(),last_error=null,updated_at=now()
 where entity_location_jobs.fingerprint<>excluded.fingerprint;
 return null;
end $$;
revoke all on function public.enqueue_entity_location() from public,anon,authenticated;

create or replace function public.link_business_location_identity()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare p jsonb:=to_jsonb(new); domain text; site text; role_name text; ids uuid[]; org_id uuid; display_name text;
begin
 if new.organization_id is not null then return new; end if;
 display_name:=p->>'display_name';
 if tg_table_name='marketplace_brands' then site:=p->>'website'; role_name:='brand';
 elsif tg_table_name='marketplace_merchants' then site:=p->>'shop_domain'; role_name:='seller';
 else site:=p->'domains'->>0; role_name:='affiliate_partner'; display_name:=p->>'partner_name'; end if;
 domain:=public.org_normalize_domain(site);
 if domain is null or domain !~ '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' then return new; end if;
 perform pg_advisory_xact_lock(hashtextextended('location-domain:'||domain,0));
 select array_agg(id) into ids from organizations
 where duplicate_of_id is null and public.org_normalize_domain(coalesce(website_domain,website))=domain;
 if cardinality(ids)>1 then return new; end if;
 if cardinality(ids)=1 then org_id:=ids[1];
 else
   org_id:=gen_random_uuid();
   insert into organizations(id,name,slug,website,website_domain,roles,status,field_provenance)
   values(org_id,display_name,public.generate_slug(display_name)||'-'||org_id::text,
     case when site like '%://%' then site else 'https://'||site end,domain,array[role_name],'draft',
     jsonb_build_object('identity',jsonb_build_object('source_table',tg_table_name,'source_id',new.id,'source','explicit_business_domain','at',now())));
 end if;
 update organizations set roles=case when roles @> array[role_name] then roles else array_append(roles,role_name) end
 where id=org_id and not roles @> array[role_name];
 new.organization_id:=org_id;
 return new;
end $$;
revoke all on function public.link_business_location_identity() from public,anon,authenticated;
create trigger link_partner_location_identity before insert or update of domains on public.affiliate_partners
 for each row execute function public.link_business_location_identity();

