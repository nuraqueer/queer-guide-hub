-- Metadata edits must not require changing an existing feed schedule.
create or replace function public.admin_news_source_save(p_id uuid,p_data jsonb,p_expected_updated_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare old_row public.news_sources; saved public.news_sources; publisher_id uuid;
  source_name text := btrim(p_data->>'name'); source_url text := btrim(p_data->>'url');
  source_category text := btrim(p_data->>'category'); source_kind text := p_data->>'source_type';
  feed_kind text := coalesce(p_data->>'feed_type','news'); frequency integer;
  source_keywords text[];
begin
  perform public.assert_admin_or_internal();
  if jsonb_typeof(p_data) is distinct from 'object'
    or jsonb_typeof(p_data->'name') is distinct from 'string'
    or jsonb_typeof(p_data->'url') is distinct from 'string'
    or jsonb_typeof(p_data->'category') is distinct from 'string'
    or not (p_data ? 'organization_id') or length(source_name) not between 2 and 255
    or source_name is null or source_url is null or source_url !~ '^https?://[^[:space:]/?#@]+([/?#]|$)'
    or source_url ~ '[[:space:]]' or length(source_url)>2048
    or source_category is null or length(source_category) not between 1 and 100
    or source_kind is null or source_kind not in ('rss','api','news_api','wikimedia','social','manual')
    or feed_kind not in ('news','podcast')
    or jsonb_typeof(p_data->'is_active') is distinct from 'boolean'
    or jsonb_typeof(p_data->'auto_publish') is distinct from 'boolean'
    or jsonb_typeof(p_data->'keywords') is distinct from 'array' then
    raise exception 'Check the source name, HTTP(S) URL, category, type and settings.' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements(p_data->'keywords') k where jsonb_typeof(k) <> 'string') then
    raise exception 'Keywords must be text values.' using errcode='22023';
  end if;
  begin
    frequency := (p_data->>'fetch_frequency')::integer;
    publisher_id := nullif(p_data->>'organization_id','')::uuid;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Invalid frequency or publisher.' using errcode='22023';
  end;
  if p_id is not null then
    select * into old_row from public.news_sources where id=p_id for update;
    if not found then raise exception 'Source no longer exists. Refresh the list.' using errcode='22023'; end if;
    if p_expected_updated_at is null or old_row.updated_at is distinct from p_expected_updated_at then
      raise exception 'Source changed. Close the editor and refresh before saving.' using errcode='40001';
    end if;
  end if;
  -- Preserve a positive legacy cadence while editing other source metadata.
  -- New sources and deliberate cadence changes keep the existing limits.
  if frequency is null or (frequency not between 30 and 10080 and not (
    p_id is not null and frequency > 0 and frequency is not distinct from old_row.fetch_frequency
  )) then
    raise exception 'New or changed fetch frequencies must be between 30 and 10080 minutes. Keep the existing cadence to edit other settings.' using errcode='22023';
  end if;
  if publisher_id is distinct from old_row.organization_id then
    perform public.assert_news_source_admin();
  end if;
  if publisher_id is not null and (p_id is null or publisher_id is distinct from old_row.organization_id) then
    perform 1 from public.organizations where id=publisher_id and 'publisher'=any(roles)
      and duplicate_of_id is null and status <> 'archived' for share;
    if not found then
      raise exception 'Choose an existing, non-archived Organisation with the Publisher role.' using errcode='22023';
    end if;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(source_url,0));
  if (p_id is null or source_url is distinct from old_row.url) and exists(
    select 1 from public.news_sources where btrim(url)=source_url and (p_id is null or id<>p_id)
  ) then raise exception 'That feed URL already exists. Edit its existing source.' using errcode='23505'; end if;
  select coalesce(array_agg(distinct btrim(v)) filter(where btrim(v)<>''),'{}'::text[])
    into source_keywords from jsonb_array_elements_text(p_data->'keywords') v;
  if p_id is null then
    insert into public.news_sources(name,url,category,source_type,feed_type,fetch_frequency,is_active,auto_publish,keywords,organization_id,auto_publish_since)
    values(source_name,source_url,source_category,source_kind,feed_kind,frequency,(p_data->>'is_active')::boolean,
      (p_data->>'auto_publish')::boolean,source_keywords,publisher_id,case when (p_data->>'auto_publish')::boolean then clock_timestamp() else null end) returning * into saved;
  else
    update public.news_sources set name=source_name,url=source_url,category=source_category,source_type=source_kind,
      feed_type=feed_kind,fetch_frequency=frequency,is_active=(p_data->>'is_active')::boolean,
      auto_publish=(p_data->>'auto_publish')::boolean,keywords=source_keywords,organization_id=publisher_id,updated_at=clock_timestamp()
    where id=p_id returning * into saved;
  end if;
  return to_jsonb(saved);
end $$;
