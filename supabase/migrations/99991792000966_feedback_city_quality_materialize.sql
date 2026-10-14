-- Evaluate the city-quality view once before resolving cleared review signals,
-- rather than re-running its correlated checks for every pending review row.
CREATE OR REPLACE FUNCTION public.run_city_quality_issue_sync(p_limit integer DEFAULT 1000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_automation_id uuid;
  v_run_id bigint;
  v_started timestamptz := now();
  v_inserted integer := 0;
  v_resolved integer := 0;
  v_scorecard jsonb;
begin
  perform public.run_city_category_review_sync(p_limit);
  select id into v_automation_id from public.admin_automations where slug = 'city_quality_issue_sync';
  insert into public.admin_automation_runs
    (automation_id, automation_slug, started_at, status, items_examined, items_changed)
  values (v_automation_id, 'city_quality_issue_sync', v_started, 'success', 0, 0)
  returning id into v_run_id;

  with actionable as (
    select q.id, q.name, q.slug, code, q.publication_ready,
           code = any(q.blockers) as hard_blocker
    from public.city_quality_profile q
    cross join lateral unnest(q.issue_codes) code
    where code in (
      'CITY_IDENTITY_AMBIGUOUS', 'CITY_DESCRIPTION_WRONG_SUBJECT',
      'CITY_DESCRIPTION_REUSED', 'CITY_IMAGE_REUSED', 'CITY_IMAGE_FLAGGED',
      'CITY_IMAGE_AMBIGUOUS',
      'CITY_LINK_NAMESAKE', 'CITY_LINK_COUNTRY_MISMATCH',
      'CITY_DUPLICATE_UNRESOLVED', 'CITY_CATEGORY_UNCLASSIFIED',
      'CITY_LINK_UNRESOLVED', 'CITY_LIFECYCLE_UNRESOLVED',
      'CITY_GHOST_EXPOSED', 'CITY_GHOST_HAS_LIVE_CHILDREN', 'CITY_PLACEHOLDER_EXPOSED',
      'CITY_DESCRIPTION_PROVENANCE_MISSING', 'CITY_TRANSLATION_STALE'
    )
    order by (code = any(q.blockers)) desc, q.seo_indexable desc, q.name
    limit greatest(coalesce(p_limit, 1000), 1)
  )
  insert into public.review_queue(entity_type, entity_id, review_type, status, details)
  select 'city', a.id, a.code, 'pending', jsonb_build_object(
    'city_name', a.name, 'city_slug', a.slug, 'hard_blocker', a.hard_blocker,
    'publication_ready', a.publication_ready, 'source', 'city_quality_profile',
    'observed_at', now())
  from actionable a
  on conflict (entity_type, entity_id, review_type)
    where entity_type = 'city' and status = 'pending' and left(review_type, 5) = 'CITY_'
  do update set details = excluded.details;
  get diagnostics v_inserted = row_count;

  with current_quality as materialized (select id, issue_codes from public.city_quality_profile)
  update public.review_queue r
  set status = 'resolved', resolved_at = now(),
      details = coalesce(r.details, '{}'::jsonb) || jsonb_build_object(
        'resolution', 'quality_signal_cleared', 'resolved_automatically', true)
  where r.entity_type = 'city' and r.status = 'pending' and left(r.review_type, 5) = 'CITY_'
    and not exists (
      select 1 from current_quality q
      where q.id = r.entity_id and r.review_type = any(q.issue_codes)
    );
  get diagnostics v_resolved = row_count;

  v_scorecard := public._city_quality_scorecard();
  insert into public.city_quality_snapshots(snapshot_date, captured_at, scorecard)
  values (current_date, now(), v_scorecard)
  on conflict (snapshot_date) do update
    set captured_at = excluded.captured_at, scorecard = excluded.scorecard;

  update public.admin_automation_runs
  set finished_at = now(), items_examined = (v_scorecard#>>'{totals,canonical}')::integer,
      items_changed = v_inserted + v_resolved,
      summary = jsonb_build_object('queued_or_refreshed', v_inserted, 'resolved', v_resolved,
                                   'probe_ok', true)
  where id = v_run_id;
  update public.admin_automations
  set last_run_at = v_started, last_run_status = 'success' where id = v_automation_id;

  return jsonb_build_object('probe_ok', true, 'queued_or_refreshed', v_inserted,
                            'resolved', v_resolved, 'scorecard', v_scorecard);
exception when others then
  if v_run_id is not null then
    update public.admin_automation_runs set finished_at = now(), status = 'error', error = sqlerrm
    where id = v_run_id;
  end if;
  if v_automation_id is not null then
    update public.admin_automations set last_run_at = v_started, last_run_status = 'error'
    where id = v_automation_id;
  end if;
  raise;
end
$function$
;
