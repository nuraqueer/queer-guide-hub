-- ISOLATED EMPTY POSTGRES DATABASE ONLY. Minimal schema for the RPC contracts.
create role anon;
create role authenticated;
create role service_role;
create type public.app_role as enum ('admin','moderator','editor','user');
create function public.has_any_role_jwt(required_roles public.app_role[]) returns boolean language sql stable as $$
 select coalesce((nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'user_role')::public.app_role = any(required_roles),false)
$$;
create function public.assert_admin_or_internal() returns void language plpgsql stable as $$
declare claims jsonb := nullif(current_setting('request.jwt.claims',true),'')::jsonb;
begin
 if claims is null or claims->>'role'='service_role' or public.has_any_role_jwt(array['admin'::app_role,'moderator'::app_role]) then return; end if;
 raise exception 'unauthorized' using errcode='42501';
end $$;
create table public.organizations(id uuid primary key default gen_random_uuid(),name text not null,roles text[] not null default '{}',status text not null default 'draft',duplicate_of_id uuid,website text,website_domain text);
create function public.cms_organisation_save(p_id uuid,p_data jsonb,p_locations jsonb default null,p_expected_updated_at timestamptz default null) returns jsonb language plpgsql as $$
declare result public.organizations;
begin insert into public.organizations(name,roles,status,website,website_domain) values(p_data->>'name',array(select jsonb_array_elements_text(p_data->'roles')),p_data->>'status',p_data->>'website',p_data->>'website_domain') returning * into result; return to_jsonb(result); end $$;
create table public.news_sources(id uuid primary key default gen_random_uuid(),name text not null,url text not null,category text not null default 'general',source_type text not null default 'rss',feed_type text not null default 'news',fetch_frequency integer not null default 120,is_active boolean not null default true,auto_publish boolean not null default false,auto_publish_since timestamptz,keywords text[],organization_id uuid references public.organizations(id),auto_paused boolean not null default false,auto_paused_reason text,consecutive_failures integer not null default 0,consecutive_empty_fetches integer not null default 0,backoff_until timestamptz,status text default 'active',last_error text,updated_at timestamptz not null default now());
create table public.news_articles(id uuid primary key default gen_random_uuid(),source_id uuid references public.news_sources(id) on delete cascade,title text,published_at timestamptz,quality_status text,publisher_name text);
