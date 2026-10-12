-- Lock in the same order as location-to-organisation propagation.
lock table public.venues,public.hotels,public.organizations in access exclusive mode;
create or replace function public.entity_location_fingerprint(p jsonb)
returns text language sql immutable set search_path=public,pg_temp as $$
 select md5(jsonb_build_array(p->'website',p->'address',p->'city',p->'city_id',p->'country',p->'country_id',
   p->'postal_code',p->'latitude',p->'longitude',p->'timezone')::text)
$$;

create or replace function public.enqueue_entity_location()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare p jsonb:=to_jsonb(new); f text;
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
 execute format('drop trigger zz_location_enqueue on public.%I',t);
 execute format('create trigger zz_location_enqueue after insert or update of website,address,city_id,country_id,postal_code,latitude,longitude,timezone on public.%I for each row execute function public.enqueue_entity_location()',t);
 execute format('update public.entity_location_jobs j set fingerprint=public.entity_location_fingerprint(to_jsonb(t)),status=''pending'',updated_at=now() from public.%I t where j.entity_table=%L and t.id=j.entity_id',t,t);
 end loop;
end $$;

create or replace function public.inherit_primary_entity_location()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.venues;
begin
 if new.primary_venue_id is null then return new; end if;
 select * into v from venues where id=new.primary_venue_id and organization_id=new.id and duplicate_of_id is null;
 if not found then return new; end if;
 if (new.city_id is not null and v.city_id is not null and new.city_id<>v.city_id)
   or (new.country_id is not null and v.country_id is not null and new.country_id<>v.country_id)
   or (nullif(btrim(new.address),'') is not null and lower(btrim(new.address)) is distinct from lower(btrim(v.address))) then return new; end if;
 new.address:=coalesce(nullif(btrim(new.address),''),v.address);
 new.city_id:=coalesce(new.city_id,v.city_id); new.country_id:=coalesce(new.country_id,v.country_id);
 new.postal_code:=coalesce(nullif(btrim(new.postal_code),''),v.postal_code);
 if new.latitude is null and new.longitude is null then new.latitude:=v.latitude; new.longitude:=v.longitude; end if;
 new.timezone:=coalesce(nullif(btrim(new.timezone),''),v.timezone);
 return new;
end $$;
revoke all on function public.inherit_primary_entity_location() from public,anon,authenticated;
create trigger aa_location_primary before insert or update of primary_venue_id on public.organizations
for each row execute function public.inherit_primary_entity_location();

-- An explicit official domain establishes a business identity. Names alone do not.
create or replace function public.link_business_location_identity()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare p jsonb:=to_jsonb(new); domain text; site text; role_name text; ids uuid[]; org_id uuid;
begin
 if new.organization_id is not null then return new; end if;
 if tg_table_name='marketplace_brands' then site:=p->>'website'; role_name:='brand';
 else site:=p->>'shop_domain'; role_name:='seller'; end if;
 domain:=public.org_normalize_domain(site);
 if domain is null or domain not like '%.%' then return new; end if;
 perform pg_advisory_xact_lock(hashtextextended('location-domain:'||domain,0));
 select array_agg(id) into ids from organizations
 where duplicate_of_id is null and public.org_normalize_domain(coalesce(website_domain,website))=domain;
 if cardinality(ids)>1 then return new; end if;
 if cardinality(ids)=1 then org_id:=ids[1];
 else
   org_id:=gen_random_uuid();
   insert into organizations(id,name,slug,website,website_domain,roles,status,field_provenance)
   values(org_id,p->>'display_name',public.generate_slug(p->>'display_name')||'-'||org_id::text,
     case when site like '%://%' then site else 'https://'||site end,domain,array[role_name],'draft',
     jsonb_build_object('identity',jsonb_build_object('source_table',tg_table_name,'source_id',new.id,'source','explicit_business_domain','at',now())));
 end if;
 update organizations set roles=case when roles @> array[role_name] then roles else array_append(roles,role_name) end
 where id=org_id and not roles @> array[role_name];
 new.organization_id:=org_id;
 return new;
end $$;
revoke all on function public.link_business_location_identity() from public,anon,authenticated;
create trigger link_brand_location_identity before insert or update of website on public.marketplace_brands
 for each row execute function public.link_business_location_identity();
create trigger link_merchant_location_identity before insert or update of shop_domain on public.marketplace_merchants
 for each row execute function public.link_business_location_identity();

-- Internal tables intentionally have no public policies or public grants.
create policy location_jobs_service on public.entity_location_jobs to service_role using(true) with check(true);
create policy location_audit_service on public.entity_location_audit to service_role using(true) with check(true);
create policy location_lease_service on public.entity_location_worker_lease to service_role using(true) with check(true);
;
