-- organizations.completeness_score had TWO writers with DIFFERENT formulas,
-- and they overwrote each other forever (2026-10-14).
--
--   run_org_quality_recompute      (cron `50 2 * * *`)
--     completeness_score = a 9-field weighted presence formula
--     needs_attention    = score < 40
--
--   refresh_business_brand_quality (cron `11-59/15`)
--     completeness_score = pass-rate across entity_quality_findings dimensions
--     needs_attention    = score < 60
--
-- MEASURED over 3,000 organizations: the two formulas disagree on 3,000 of
-- 3,000. Means 33.6 vs 57.4. 2,566 of the 3,000 held the dimensions value and
-- would have been rewritten by the recompute RIGHT THEN — two hours after the
-- recompute had run. The thresholds disagree too, so needs_attention flips with
-- the score.
--
-- It never settles because refresh laps the corpus faster than the recompute
-- runs: 2,000 rows every 15 minutes is 192,000 writes/day over ~100k rows, so
-- by 02:50 essentially every row holds refresh's value, the recompute's
-- IS DISTINCT FROM guard matches almost everything, and it rewrites the lot.
-- Measured in organizations.updated_at on 2026-10-14: one minute at 02:50
-- carrying 85,598 rows, then exactly 2,000 at :11/:26/:41/:56.
--
-- Each of those writes fires trg_search_documents_organization (unscoped) and
-- enqueues a reindex. The queue stood at 99,985 with its oldest row stamped
-- 02:50:00.097947, 69% of it organizations; search_reindex_drain is hard-capped
-- at 400 rows/min and was running at 98 ms/row, so the nightly burst alone is
-- ~3.6 hours of catch-up during which site search is stale for everything.
--
-- WHICH WRITER WINS: run_org_quality_recompute keeps the column.
--
--   * Its formula is the documented, guarded one. 20370801100000 dropped the
--     email arm after measuring, and src/lib/__tests__/orgNeedsAttentionRule
--     .test.ts guards that decision.
--   * It already has an IS DISTINCT FROM guard, so once nothing else overwrites
--     the column it converges to ~0 writes/day.
--   * refresh CANNOT converge on this column: it stamps quality_checked_at =
--     now() unconditionally because that is its round-robin cursor (the
--     run_event_geo_fill / cities_due_for_refresh lesson — a cursor skipped on
--     a no-op write pins the queue head forever), so its UPDATE touches every
--     row it examines whether or not anything changed.
--
-- refresh keeps writing quality_dimensions and quality_checked_at. Nothing is
-- lost: the dimension detail stays on the row, it just stops being the scalar.
-- The search indexer reads completeness_score but NEITHER of those two, so the
-- sibling migration's value-scoped trigger makes refresh's remaining 192k
-- writes/day free. The two changes are only worth anything together.
--
-- NOT fixed here, named rather than smuggled in: needs_attention is true on
-- 83.6% of organizations and both candidate rules agree on that (81.2% vs
-- 84.7%), so it is still "indistinguishable from no signal" by the standard
-- 20370801100000 set when it brought it down from 88.3%. That is a question
-- about the threshold, not about who owns the column, and it is unchanged by
-- this migration in either direction.
--
-- The function is ~200 lines and is PATCHED from pg_get_functiondef rather than
-- restated (the 99991790719601 rule): a CREATE OR REPLACE built from a repo
-- file silently reverts whatever another session last string-patched into the
-- live body. The anchor was verified to occur exactly once before this was
-- written, and the patch asserts that again at apply time.

do $patch$
declare
  v_src  text;
  v_from text := 'update organizations o set quality_dimensions=d.dimensions,quality_checked_at=now(),completeness_score=coalesce(d.score,0),needs_attention=coalesce(d.score,0)<60';
  v_to   text := 'update organizations o set quality_dimensions=d.dimensions,quality_checked_at=now()';
  v_hits int;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'refresh_business_brand_quality';

  -- Soft on preconditions: a sibling session that has already made this change
  -- leaves nothing to do, and that is a no-op, not a failure.
  if v_src is null then
    raise notice 'refresh_business_brand_quality does not exist — nothing to patch';
    return;
  end if;
  if position(v_from in v_src) = 0 then
    if position(v_to || E'\n' in v_src) > 0 or position(v_to || ' ' in v_src) > 0 then
      raise notice 'already patched — refresh_business_brand_quality no longer writes completeness_score';
      return;
    end if;
    raise exception 'anchor not found in refresh_business_brand_quality: the UPDATE was rewritten, re-derive the patch from pg_get_functiondef rather than forcing this one';
  end if;

  v_hits := (length(v_src) - length(replace(v_src, v_from, ''))) / length(v_from);
  if v_hits <> 1 then
    raise exception 'anchor occurs % times, expected exactly 1 — a blind replace would hit the wrong statement', v_hits;
  end if;

  execute replace(v_src, v_from, v_to);
end
$patch$;

do $verify$
declare
  v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'refresh_business_brand_quality';
  if v_src is null then
    raise notice 'P1-P3 skipped: refresh_business_brand_quality absent';
    return;
  end if;

  -- P1: it no longer writes either column on organizations. Scoped to the
  -- organizations UPDATE, because the marketplace_brands arm of the same
  -- function legitimately keeps its own quality columns.
  if position('completeness_score' in substring(v_src from position('update organizations o set' in v_src))) > 0 then
    raise exception 'P1 failed: the organizations UPDATE still writes completeness_score';
  end if;
  if position('needs_attention' in substring(v_src from position('update organizations o set' in v_src))) > 0 then
    raise exception 'P1 failed: the organizations UPDATE still writes needs_attention';
  end if;

  -- P2: and it still writes the two columns it owns. Asserting only P1 is
  -- satisfied by a patch that deleted the whole statement.
  if position('quality_dimensions=d.dimensions' in v_src) = 0
     or position('quality_checked_at=now()' in v_src) = 0 then
    raise exception 'P2 failed: the organizations UPDATE lost quality_dimensions / quality_checked_at — the cursor and the dimension detail must survive';
  end if;

  -- P3: the marketplace_brands arm is untouched. It is a separate UPDATE in the
  -- same function and nothing here is about brands.
  if position('update marketplace_brands b set quality_dimensions=d.dimensions,quality_checked_at=now()' in v_src) = 0 then
    raise exception 'P3 failed: the marketplace_brands UPDATE was altered — this migration is only about organizations';
  end if;
end
$verify$;

do $verify2$
declare
  v_src text;
begin
  -- P4: the surviving writer still writes both columns, with its own formula
  -- and its own change guard. Without this the "one writer" claim is satisfied
  -- by there being NO writer.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'run_org_quality_recompute';
  if v_src is null then
    raise exception 'P4 failed: run_org_quality_recompute does not exist, so nothing writes organizations.completeness_score at all';
  end if;
  if position('completeness_score = s.new_completeness' in v_src) = 0 then
    raise exception 'P4 failed: run_org_quality_recompute no longer writes completeness_score';
  end if;
  if position('needs_attention    = (s.new_completeness < 40)' in v_src) = 0 then
    raise exception 'P4 failed: run_org_quality_recompute no longer writes needs_attention < 40';
  end if;
  if position('IS DISTINCT FROM' in v_src) = 0 then
    raise exception 'P4 failed: run_org_quality_recompute lost its change guard — as the sole writer it must only write rows that actually change, or this migration buys nothing';
  end if;
end
$verify2$;
