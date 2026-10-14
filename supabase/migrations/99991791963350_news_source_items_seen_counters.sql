-- news_sources.articles_fetched / avg_articles_per_fetch had ONE writer and it has
-- had no caller for as long as the current ingest path has existed.
--
-- `public.news_source_record_outcome` (baseline.sql:9200) is the writer. Measured
-- 2026-10-14: it appears nowhere in supabase/functions, nowhere in src/ except the
-- generated types.ts, and in no migration but its own definition. `source-rss-news`
-- writes last_fetched_at / last_successful_fetch / consecutive_empty_fetches /
-- consecutive_failures DIRECTLY (index.ts:228-232) and never touches these two.
--
-- Measured cost of that: 376 of 397 sources read articles_fetched = 0, and
-- avg_articles_per_fetch reads 0.00 on 382 of 397 -- while being RENDERED as
-- "Avg articles" at /admin/pipelines?tab=news (NewsTab.tsx:106). The zeros are not
-- a feed problem: gay-it read 0 against 874 articles all-time and 10 in the
-- trailing 24h, the-advocate 0 against 737 and 9. The 21 positive values are
-- frozen legacy -- washington-blade reads 5,970 against 827 real articles and
-- produced 0 articles in 24h, so it looked the HEALTHIEST of the four while
-- actually being the idle one. A dead gauge inverted the health ordering.
--
-- SEMANTICS ARE THE OLD ONES, DELIBERATELY: items SEEN per fetch, cumulative.
-- That is what the old column meant (pink-news 9,910 counted against 1,777 real
-- articles -- it counted feed items pre-dedup, not commits) and what was asked
-- for. The two numbers are different on purpose and a reader comparing them to
-- news_articles will find them larger.
--
-- WHY AN RPC RATHER THAN A WIDER UPDATE PAYLOAD. `articles_fetched = articles_fetched
-- + N` is not expressible in a PostgREST update body, so the alternative is
-- read-modify-write in the edge function -- which races two runs into the same
-- value and costs the same round trip. This computes both columns from the stored
-- value in one statement, so concurrent runs cannot lose a fetch.
--
-- NOT `news_source_record_outcome` ITSELF: that function also rewrites status,
-- last_error, last_successful_fetch, backoff_until AND reliability_score
-- (+0.05/-0.1 per outcome). The current path does not move reliability_score at
-- all, and `news_sources_eligible()` multiplies the wait by it, so adopting that
-- function would silently change which feeds are eligible when. It stays
-- uncalled; this touches two columns and nothing else.
--
-- SECURITY INVOKER, not DEFINER. The only caller is the service client, which
-- bypasses RLS already, so there is nothing to elevate -- and a VOLATILE DEFINER
-- is exactly what check-anon-function-grants.mjs exists to police. Grants are
-- service_role only and the postcondition asserts anon/authenticated cannot
-- execute it (20290601120731: a function was DEFINER by reflex and leaked).
--
-- `updated_at` is deliberately NOT written, though the old function wrote it: the
-- other per-fetch updates on this path do not, so writing it here only on the
-- counter leg would make the column mean two different things row to row.
--
-- Writing these columns fires NOTHING: read off pg_trigger, every trigger on
-- news_sources is column-scoped to organization_id or auto_publish, or INSERT-only.
-- No search fan-out, so a per-fetch counter write costs one statement.

create or replace function public.news_source_record_items_seen(
  p_source_id uuid,
  p_items_seen integer
) returns void
  language sql
  security invoker
  set search_path to 'public'
as $fn$
  update public.news_sources
     set articles_fetched = coalesce(articles_fetched, 0)
                          + greatest(0, coalesce(p_items_seen, 0)),
         -- Byte-for-byte the old EWMA from news_source_record_outcome: an empty
         -- fetch decays the average toward 0 rather than leaving it stale.
         avg_articles_per_fetch = (coalesce(avg_articles_per_fetch, 0) * 0.8)
                                + (greatest(0, coalesce(p_items_seen, 0)) * 0.2)
   where id = p_source_id;
$fn$;

revoke all on function public.news_source_record_items_seen(uuid, integer) from public;
grant execute on function public.news_source_record_items_seen(uuid, integer) to service_role;

do $verify$
declare
  v_id          uuid;
  v_before_cnt  integer;
  v_before_avg  numeric;
  v_after_cnt   integer;
  v_after_avg   numeric;
  v_expect_avg  numeric;
begin
  -- P1: the function exists and is INVOKER, not DEFINER.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'news_source_record_items_seen'
       and p.prosecdef = false
  ) then
    raise exception 'P1 failed: news_source_record_items_seen missing or SECURITY DEFINER';
  end if;

  -- P2: anon and authenticated cannot execute it; service_role can.
  if has_function_privilege('anon',
       'public.news_source_record_items_seen(uuid, integer)', 'EXECUTE')
  or has_function_privilege('authenticated',
       'public.news_source_record_items_seen(uuid, integer)', 'EXECUTE') then
    raise exception 'P2 failed: anon or authenticated can execute the counter RPC';
  end if;
  if not has_function_privilege('service_role',
       'public.news_source_record_items_seen(uuid, integer)', 'EXECUTE') then
    raise exception 'P2 failed: service_role cannot execute the counter RPC';
  end if;

  -- P3: BEHAVIOURAL, not a text check -- a source-text postcondition cannot tell
  -- a live function from a dead one, which is the whole defect this repairs. Runs
  -- inside a subtransaction that raises on purpose, so the probe writes nothing.
  select id, coalesce(articles_fetched, 0), coalesce(avg_articles_per_fetch, 0)
    into v_id, v_before_cnt, v_before_avg
    from public.news_sources
   order by id
   limit 1;
  if v_id is null then
    raise exception 'P3 failed: no news_sources row to probe (cannot verify behaviour)';
  end if;
  v_expect_avg := round(v_before_avg * 0.8 + 7 * 0.2, 2);

  begin
    perform public.news_source_record_items_seen(v_id, 7);
    select articles_fetched, avg_articles_per_fetch
      into v_after_cnt, v_after_avg
      from public.news_sources where id = v_id;

    if v_after_cnt <> v_before_cnt + 7 then
      raise exception 'P3 failed: articles_fetched % -> %, expected %',
        v_before_cnt, v_after_cnt, v_before_cnt + 7;
    end if;
    if v_after_avg <> v_expect_avg then
      raise exception 'P3 failed: avg_articles_per_fetch % -> %, expected %',
        v_before_avg, v_after_avg, v_expect_avg;
    end if;

    -- P4: a negative or null count is clamped, never allowed to decrement a total.
    perform public.news_source_record_items_seen(v_id, -5);
    select articles_fetched into v_after_cnt
      from public.news_sources where id = v_id;
    if v_after_cnt <> v_before_cnt + 7 then
      raise exception 'P4 failed: a negative count moved articles_fetched to %', v_after_cnt;
    end if;

    raise exception 'rollback_counter_probe';
  exception when others then
    if sqlerrm <> 'rollback_counter_probe' then
      raise;
    end if;
  end;

  -- P5: the probe left nothing behind.
  select coalesce(articles_fetched, 0), coalesce(avg_articles_per_fetch, 0)
    into v_after_cnt, v_after_avg
    from public.news_sources where id = v_id;
  if v_after_cnt <> v_before_cnt or v_after_avg <> v_before_avg then
    raise exception 'P5 failed: probe was not rolled back (% / %)', v_after_cnt, v_after_avg;
  end if;
end
$verify$;
