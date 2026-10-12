-- Append-only queue: nonunique indexes preserve enqueue concurrency.
CREATE INDEX IF NOT EXISTS search_reindex_queue_entity_lookup_idx ON public.search_reindex_queue(entity_type,entity_id);
CREATE INDEX IF NOT EXISTS search_reindex_queue_expiry_idx ON public.search_reindex_queue(created_at,id);

CREATE OR REPLACE FUNCTION public.search_reindex_drain(p_limit integer DEFAULT 1000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  r record;
  v_started_at timestamptz := clock_timestamp();
  v_claimed integer := 0;
  v_done integer := 0;
  v_failed integer := 0;
  v_gc integer := 0;
  v_remaining integer := 0;
  v_elapsed_ms integer := 0;
  v_oldest_pending_seconds integer;
  v_stopped_for_budget boolean := false;
begin
  if not pg_try_advisory_xact_lock(hashtext('search_reindex_drain')) then
    return jsonb_build_object('skipped', true, 'reason', 'already_running');
  end if;

  loop
    exit when v_claimed >= least(greatest(coalesce(p_limit, 1), 1), 400);

    v_elapsed_ms := floor(extract(epoch from (clock_timestamp() - v_started_at)) * 1000)::integer;
    if v_elapsed_ms >= 75000 then
      v_stopped_for_budget := true;
      exit;
    end if;

    with target as (
      select entity_type, entity_id
      from public.search_reindex_queue
      order by id
      limit 1
      for update skip locked
    ), claimed as (
      delete from public.search_reindex_queue q
      using target t
      where q.entity_type = t.entity_type and q.entity_id = t.entity_id
      returning q.entity_type, q.entity_id
    )
    select entity_type, entity_id into r
    from claimed
    limit 1;

    exit when not found;
    v_claimed := v_claimed + 1;

    begin
      delete from public.search_documents
      where entity_type = r.entity_type and entity_id = r.entity_id;

      case r.entity_type
        when 'venue' then perform public.search_documents_index_venues(r.entity_id);
        when 'event' then perform public.search_documents_index_events(r.entity_id);
        when 'city' then perform public.search_documents_index_cities(r.entity_id);
        when 'country' then perform public.search_documents_index_countries(r.entity_id);
        when 'news' then perform public.search_documents_index_news(r.entity_id);
        when 'marketplace' then perform public.search_documents_index_marketplace(r.entity_id);
        when 'personality' then perform public.search_documents_index_personalities(r.entity_id);
        when 'tag' then perform public.search_documents_index_tags(r.entity_id);
        when 'queer_village' then perform public.search_documents_index_villages(r.entity_id);
        when 'group' then perform public.search_documents_index_groups(r.entity_id);
        when 'organization' then perform public.search_documents_index_organizations(r.entity_id);
        when 'milestone' then perform public.search_documents_index_milestones(r.entity_id);
        when 'guide' then perform public.search_documents_index_guides(r.entity_id);
        else null;
      end case;
      v_done := v_done + 1;
    exception when others then
      v_failed := v_failed + 1;
      insert into public.search_reindex_queue (entity_type, entity_id)
      values (r.entity_type, r.entity_id);
    end;
  end loop;

  with expired as materialized (
    select id from public.search_reindex_queue
    where created_at < now() - interval '7 days'
    order by created_at,id limit 500 for update skip locked
  )
  delete from public.search_reindex_queue q using expired e where q.id=e.id;
  get diagnostics v_gc = row_count;

  select count(*),
         extract(epoch from (now() - min(created_at)))::integer
  into v_remaining, v_oldest_pending_seconds
  from public.search_reindex_queue;

  v_elapsed_ms := floor(extract(epoch from (clock_timestamp() - v_started_at)) * 1000)::integer;

  insert into public.search_reindex_drain_stats as s (
    singleton, ran_at, claimed, reindexed, failed, gc, remaining,
    total_claimed, total_failed, elapsed_ms, stopped_for_budget,
    oldest_pending_seconds, total_budget_stops
  ) values (
    true, now(), v_claimed, v_done, v_failed, v_gc, v_remaining,
    v_claimed, v_failed, v_elapsed_ms, v_stopped_for_budget,
    v_oldest_pending_seconds, case when v_stopped_for_budget then 1 else 0 end
  )
  on conflict (singleton) do update
  set ran_at = excluded.ran_at,
      claimed = excluded.claimed,
      reindexed = excluded.reindexed,
      failed = excluded.failed,
      gc = excluded.gc,
      remaining = excluded.remaining,
      total_claimed = s.total_claimed + excluded.claimed,
      total_failed = s.total_failed + excluded.failed,
      elapsed_ms = excluded.elapsed_ms,
      stopped_for_budget = excluded.stopped_for_budget,
      oldest_pending_seconds = excluded.oldest_pending_seconds,
      total_budget_stops = s.total_budget_stops + excluded.total_budget_stops;

  return jsonb_build_object(
    'claimed', v_claimed,
    'reindexed', v_done,
    'failed', v_failed,
    'gc', v_gc,
    'remaining', v_remaining,
    'elapsed_ms', v_elapsed_ms,
    'stopped_for_budget', v_stopped_for_budget,
    'oldest_pending_seconds', v_oldest_pending_seconds
  );
end;
$function$;

