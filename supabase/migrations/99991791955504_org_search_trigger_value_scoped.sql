-- trg_search_documents_organization fired on EVERY write to organizations
-- (2026-10-14). `AFTER INSERT OR DELETE OR UPDATE ... FOR EACH ROW` with no
-- `UPDATE OF` and no `WHEN`, so a write that touches nothing the search index
-- reads still enqueued a reindex. Only 4 of the 22 search_documents_sync
-- triggers in this schema are scoped at all.
--
-- Measured cost on the day this was written: 68,815 of the 99,985 rows in
-- search_reindex_queue were organizations, and of 58,796 distinct queued
-- organizations exactly 2,701 (4.6%) would produce a search document at all —
-- the other 56,032 are venue-generated identities that
-- search_documents_index_organizations is written to EXCLUDE, so the drain
-- deletes a row that is not there and runs an INSERT…SELECT that returns zero
-- rows, at 98 ms each.
--
-- THE SIBLING MIGRATION IS HALF OF THIS AND NEITHER IS WORTH MUCH ALONE.
-- 99991791955502 stops completeness_score ping-ponging between two writers.
-- What it CANNOT stop is refresh_business_brand_quality's remaining 2,000 rows
-- every 15 minutes (192,000/day), because that statement must stamp
-- quality_checked_at = now() unconditionally — it is the job's round-robin
-- cursor. The search indexer reads neither quality_checked_at nor
-- quality_dimensions, so once the trigger compares VALUES those writes stop
-- enqueueing anything.
--
-- `UPDATE OF (cols)` ALONE WOULD NOT HAVE WORKED, and that is the subtle part:
-- a column-scoped trigger fires on the columns named in the STATEMENT, not on
-- what actually changed, so refresh naming completeness_score in its SET would
-- have kept firing it on every row whether or not the value moved. The WHEN
-- clause is what does the work; `UPDATE OF` is kept only so unrelated updates
-- skip evaluating it.
--
-- The column list is DERIVED, not transcribed: it is every `o.<column>` that
-- search_documents_index_organizations references, and the postcondition
-- re-derives it from the live function and fails if the trigger does not cover
-- it. Getting this list wrong in the quiet direction — omitting a column the
-- indexer reads — means changes to that column silently never reach search,
-- which is exactly the class of failure this file exists to remove.
--
-- Split into three triggers because a WHEN clause may not reference OLD on
-- INSERT or NEW on DELETE; the geo_places `_ins`/`_del` pairs are the existing
-- precedent. INSERT and DELETE stay unconditional — there is no prior value to
-- compare and both always change what search should hold.

-- THE SWAP RETRIES, AND THE REASON IS MEASURED ON THIS TABLE.
-- DROP TRIGGER takes ACCESS EXCLUSIVE, which conflicts with the ACCESS SHARE
-- every reader holds — and search_reindex_drain holds one for the whole of its
-- run, which is up to its 75s budget, EVERY MINUTE, on top of a steady stream
-- of PostgREST reads. Read off pg_locks while writing this: five granted locks
-- on organizations, the oldest a pg_cron drain 31s into its run.
--
-- Unbounded waiting is the worst option, because a pending ACCESS EXCLUSIVE
-- queues every NEW reader behind itself: the migration would not just stall,
-- it would stall the table, and `db push` holds the whole deploy there.
--
-- A bare lock_timeout is the next worst: it turns a busy minute into a failed
-- `db push`, which aborts every migration queued behind this one, repo-wide.
--
-- So: short attempts, each bounded at 2s so no reader is ever blocked for
-- longer than that, retried until a gap appears. There is always a gap — the
-- drain takes a transaction-scoped advisory lock, so a run that overruns its
-- minute makes the next tick skip rather than overlap. Worst case here is
-- ~80s of trying before the migration gives up and says to re-run.
do $swap$
declare
  v_attempt int := 0;
  v_max     int := 20;
begin
  loop
    v_attempt := v_attempt + 1;
    begin
      set local lock_timeout = '2s';

      drop trigger if exists trg_search_documents_organization on public.organizations;
      drop trigger if exists trg_search_documents_organization_ins on public.organizations;
      drop trigger if exists trg_search_documents_organization_del on public.organizations;
      drop trigger if exists trg_search_documents_organization_upd on public.organizations;

      create trigger trg_search_documents_organization_ins
        after insert on public.organizations
        for each row execute function search_documents_sync('organization');

      create trigger trg_search_documents_organization_del
        after delete on public.organizations
        for each row execute function search_documents_sync('organization');

      create trigger trg_search_documents_organization_upd
        after update of
          name, editorial_hook, description, website_domain, roles, tags,
          latitude, longitude, primary_venue_id, trust_score, is_defunct,
          completeness_score, slug, logo_url, cover_image_url,
          city_id, country_id, status, duplicate_of_id, field_provenance
        on public.organizations
        for each row
        when (
             old.name              is distinct from new.name
          or old.editorial_hook    is distinct from new.editorial_hook
          or old.description       is distinct from new.description
          or old.website_domain    is distinct from new.website_domain
          or old.roles             is distinct from new.roles
          or old.tags              is distinct from new.tags
          or old.latitude          is distinct from new.latitude
          or old.longitude         is distinct from new.longitude
          or old.primary_venue_id  is distinct from new.primary_venue_id
          or old.trust_score       is distinct from new.trust_score
          or old.is_defunct        is distinct from new.is_defunct
          or old.completeness_score is distinct from new.completeness_score
          or old.slug              is distinct from new.slug
          or old.logo_url          is distinct from new.logo_url
          or old.cover_image_url   is distinct from new.cover_image_url
          or old.city_id           is distinct from new.city_id
          or old.country_id        is distinct from new.country_id
          or old.status            is distinct from new.status
          or old.duplicate_of_id   is distinct from new.duplicate_of_id
          or old.field_provenance  is distinct from new.field_provenance
        )
        execute function search_documents_sync('organization');

      raise notice 'organization search triggers swapped on attempt %', v_attempt;
      exit;
    exception when lock_not_available then
      -- The subtransaction rolled back, so nothing is held while we wait.
      if v_attempt >= v_max then
        raise exception 'could not take ACCESS EXCLUSIVE on organizations in % attempts — search_reindex_drain is saturated and holding a read lock for most of every minute. Re-run the deploy; it succeeds as soon as a drain run finishes early.', v_max;
      end if;
      perform pg_sleep(2);
    end;
  end loop;
end
$swap$;

do $verify$
declare
  v_when    text;
  v_missing text[];
  v_col     text;
  v_n       int;
begin
  -- P1: all three triggers exist and are enabled.
  select count(*) into v_n
    from pg_trigger t
   where t.tgrelid = 'public.organizations'::regclass
     and not t.tgisinternal
     and t.tgname in ('trg_search_documents_organization_ins',
                      'trg_search_documents_organization_del',
                      'trg_search_documents_organization_upd')
     and t.tgenabled <> 'D';
  if v_n <> 3 then
    raise exception 'P1 failed: expected 3 enabled organization search triggers, found %', v_n;
  end if;

  -- P2: the old unscoped trigger is gone. Leaving it would make the whole
  -- change a no-op while every other check here still passed.
  if exists (select 1 from pg_trigger t
              where t.tgrelid = 'public.organizations'::regclass
                and not t.tgisinternal
                and t.tgname = 'trg_search_documents_organization') then
    raise exception 'P2 failed: the unscoped trg_search_documents_organization still exists';
  end if;

  select pg_get_triggerdef(t.oid) into v_when
    from pg_trigger t
   where t.tgrelid = 'public.organizations'::regclass
     and t.tgname = 'trg_search_documents_organization_upd';

  -- P3: COVERAGE, re-derived from the live indexer rather than from the list
  -- written above. A column the indexer reads but the trigger does not compare
  -- is a change that silently never reaches search.
  v_missing := '{}';
  for v_col in
    select distinct lower(substring(m[1] from 3))
      from (select pg_get_functiondef(p.oid) as def
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public'
               and p.proname = 'search_documents_index_organizations') d,
           regexp_matches(d.def, '\mo\.[a-z_]+', 'g') m
     -- `id` is the primary key: it cannot change, and the INSERT/DELETE
     -- triggers already carry every case where a row's identity appears or
     -- goes away.
     where lower(substring(m[1] from 3)) <> 'id'
  loop
    if position('new.' || v_col in v_when) = 0 then
      v_missing := v_missing || v_col;
    end if;
  end loop;
  if cardinality(v_missing) > 0 then
    raise exception 'P3 failed: the UPDATE trigger does not compare %, which search_documents_index_organizations reads — changes to it would never reach search', v_missing;
  end if;

  -- P3b: the derivation found something. An indexer that matched no `o.<col>`
  -- would make P3 pass over an empty set, which is the vacuous shape.
  select count(*) into v_n
    from (select pg_get_functiondef(p.oid) as def
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname = 'search_documents_index_organizations') d,
         regexp_matches(d.def, '\mo\.[a-z_]+', 'g') m;
  if v_n < 15 then
    raise exception 'P3b failed: only % o.<column> references found in the indexer — the coverage check above proved nothing', v_n;
  end if;

  -- P4: the UPDATE trigger really is conditional. Without this, a later
  -- CREATE OR REPLACE that drops the WHEN clause restores the original defect
  -- while P1-P3 all still pass.
  if position(' WHEN ' in v_when) = 0 then
    raise exception 'P4 failed: the UPDATE trigger has no WHEN clause — it would fire on every write again';
  end if;
  if position('IS DISTINCT FROM' in upper(v_when)) = 0 then
    raise exception 'P4 failed: the WHEN clause does not compare old to new';
  end if;
  -- …and is not short-circuited. `when (true or old.x is distinct from new.x)`
  -- keeps the keyword, the comparisons and the full column list while firing
  -- on every row again — every other check here passes over it.
  if upper(v_when) ~ '\mTRUE\M' or upper(v_when) ~ '\mFALSE\M' then
    raise exception 'P4 failed: the WHEN clause contains a bare TRUE/FALSE — it is short-circuited and fires on every write';
  end if;

  -- P5: INSERT and DELETE are NOT conditional. A WHEN on those would be either
  -- a syntax error or a silent gap, and asserting it keeps the asymmetry
  -- deliberate rather than accidental.
  if exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.organizations'::regclass
       and t.tgname in ('trg_search_documents_organization_ins',
                        'trg_search_documents_organization_del')
       and position(' WHEN ' in pg_get_triggerdef(t.oid)) > 0
  ) then
    raise exception 'P5 failed: the INSERT/DELETE triggers must stay unconditional';
  end if;
end
$verify$;
