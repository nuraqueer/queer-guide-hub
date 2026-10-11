-- The nightly dedup pipeline merged two DIFFERENT US cities with no human,
-- and labelled the evidence it ignored as missing.
--
-- WHAT HAPPENED (measured on prod, 2026-10-11)
--   run_dedup_truth_sweep('city') name_exact arm queued Winterhaven, California
--   and Winter Haven, Florida (3,185 km apart), and Rockport (2,208 km apart),
--   at confidence 0.85 with reason 'name_exact_no_geo'. Both pairs HAD
--   coordinates: the reason CASE says "no_geo" for anything that is not under
--   10 km, so "far apart" and "no coordinates" were the same word -- the label
--   defect the venue sweep already had and fixed in 20330101100000.
--   Then run_dedup_review_autoapprove(), whose default floor is 0.80, approved
--   both at 06:30 with no reviewer. Both were unmerged 2026-10-11 via
--   unmerge_cities and their queue rows set to rejected.
--
-- FIX, two halves, both needed
--   1. Sweep, name_exact arm: a pair whose coordinates are both known and more
--      than 50 km apart is not a candidate at all. Same 50 km bound as the
--      city cluster finder (99991791721662): across the 452 standing city
--      merges every wrong one sits 134+ km apart and every legitimate one under
--      25 km. A pair with a coordinate missing still queues as
--      'name_exact_no_geo', which is now the truth.
--   2. Auto-approve: a city pair below 0.95 is never approved without a human.
--      For cities 0.95+ means qid_exact / name_exact_geo / name_qualifier --
--      each corroborated by an identifier, distance or qualifier. 0.85 is a
--      name and nothing else, and cities cannot represent two same-name places
--      apart (one row per name+country for new rows), so a name match is not
--      evidence. Other entity types keep their current floor; the venue/event
--      bands below 0.95 are a separate decision.
--
-- HOW
--   Both functions are patched from pg_get_functiondef() with exactly-once
--   anchors checked on a comment-stripped copy; neither body is restated.

do $patch$
declare
  v_src  text;
  v_code text;
  -- sweep: insert the distance veto after the existing Wikidata veto in the
  -- name_exact arm (the qid_exact arm does not carry this line)
  s_old constant text := E'        and not (a.qid is not null and b.qid is not null and a.qid <> b.qid)\n';
  s_new constant text := E'        and not (a.qid is not null and b.qid is not null and a.qid <> b.qid)\n'
                      || E'        and not coalesce(public.haversine_m(a.lat,a.lng,b.lat,b.lng) > 50000, false)\n';
  -- auto-approve: city pairs need >= 0.95
  q_old constant text := E'      AND q.entity_type <> ''personality''\n';
  q_new constant text := E'      AND q.entity_type <> ''personality''\n'
                      || E'      AND NOT (q.entity_type = ''city'' AND q.confidence < 0.95)\n';
begin
  -- sweep ---------------------------------------------------------------
  v_code := regexp_replace(
    pg_get_functiondef('public.run_dedup_truth_sweep(text,text,integer)'::regprocedure),
    '--[^' || chr(10) || ']*', '', 'g');

  if position('haversine_m(a.lat,a.lng,b.lat,b.lng) > 50000' in v_code) > 0 then
    raise notice 'run_dedup_truth_sweep already patched; skipping';
  else
    if (length(v_code) - length(replace(v_code, s_old, ''))) / length(s_old) <> 1 then
      raise exception 'sweep anchor not found exactly once';
    end if;
    v_src := pg_get_functiondef('public.run_dedup_truth_sweep(text,text,integer)'::regprocedure);
    execute replace(v_src, s_old, s_new);
  end if;

  -- auto-approve --------------------------------------------------------
  v_code := regexp_replace(
    pg_get_functiondef('public.run_dedup_review_autoapprove(numeric,integer)'::regprocedure),
    '--[^' || chr(10) || ']*', '', 'g');

  if position('q.entity_type = ''city'' AND q.confidence < 0.95' in v_code) > 0 then
    raise notice 'run_dedup_review_autoapprove already patched; skipping';
  else
    if (length(v_code) - length(replace(v_code, q_old, ''))) / length(q_old) <> 1 then
      raise exception 'auto-approve anchor not found exactly once';
    end if;
    v_src := pg_get_functiondef('public.run_dedup_review_autoapprove(numeric,integer)'::regprocedure);
    execute replace(v_src, q_old, q_new);
  end if;
end
$patch$;

do $verify$
declare
  v_sweep text;
  v_auto  text;
begin
  v_sweep := regexp_replace(
    pg_get_functiondef('public.run_dedup_truth_sweep(text,text,integer)'::regprocedure),
    '--[^' || chr(10) || ']*', '', 'g');
  v_auto := regexp_replace(
    pg_get_functiondef('public.run_dedup_review_autoapprove(numeric,integer)'::regprocedure),
    '--[^' || chr(10) || ']*', '', 'g');

  if position('and not coalesce(public.haversine_m(a.lat,a.lng,b.lat,b.lng) > 50000, false)' in v_sweep) = 0 then
    raise exception 'postcondition: sweep city arm has no distance veto';
  end if;
  if position('AND NOT (q.entity_type = ''city'' AND q.confidence < 0.95)' in v_auto) = 0 then
    raise exception 'postcondition: auto-approve still approves name-only city pairs';
  end if;
end
$verify$;
