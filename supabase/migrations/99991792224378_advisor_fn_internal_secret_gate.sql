-- sync-supabase-advisors: send X-Internal-Secret so the function can stop
-- trusting a JWT that proves nothing.
--
-- WHY
--
-- The function ran with `verify_jwt = true` and no gate of its own. The
-- gateway's verify_jwt checks only that a JWT is VALID, never what role it
-- carries, and the publishable anon key is public — it ships in the client
-- bundle (src/integrations/supabase/client.ts). Measured on prod 2026-10-16: a
-- plain curl with that key ran the function. It is not read-only; it writes
-- api_error rows through upsert_api_error and auto-resolves others, so any
-- visitor could flood the triage board or force repeated Management-API
-- advisor pulls. The companion commit moves it to the posture the pipeline-*
-- and source-* functions already use: verify_jwt = false plus
-- requireInternalOrAdmin in the body, which accepts X-Internal-Secret (Vault,
-- so it never leaves the database), a service-role bearer, or an admin JWT.
--
-- THE AUTHORIZATION HEADER IS KEPT ON PURPOSE
--
-- The command sends BOTH the existing legacy_anon_key bearer and the new
-- X-Internal-Secret. That is what makes the rollout window-free in either
-- order: deploy-supabase-functions runs `db push` BEFORE `functions deploy`,
-- so this command is briefly live against the OLD function, which still
-- demands a JWT and simply ignores the extra header; once the new function
-- deploys, requireInternalOrAdmin short-circuits on the secret before it ever
-- reads the bearer. Dropping the bearer here would break the cron for the
-- length of that gap.
--
-- BOTH LAYERS, DELIBERATELY
--
-- The registry (admin_automations.action.command) is canonical and
-- admin_automation_effective_command() derives the wrapped pg_cron form from
-- it, so in principle updating the registry alone is enough. But that is only
-- applied by the nightly automation_cron_sync at 05:10, and this job fires at
-- 03:17 — i.e. one run would go out with the old command and no secret, fail
-- against the new gate, and tick consecutive_failures. So the live cron.job is
-- repointed in the same transaction (the 20260820191944 precedent). The two
-- agree afterwards, so the reconciler has no drift to correct and cannot
-- fight this. This is NOT the detect_stale_venues mistake: that was a
-- cron.schedule() a later reconciler pass undid because the registry still
-- disagreed.
--
-- Prerequisites verified on prod before writing this:
--   vault.decrypted_secrets 'internal_invoke_secret' present (64 chars)
--   function secret INTERNAL_INVOKE_SECRET set (hasInternalSecret reads it)
-- Without either, the gate would reject the cron and the job would go dark.

do $$
declare
  v_cmd      text;
  v_jobid    bigint;
  v_live     text;
  v_secret   text;
begin
  -- Precondition, soft: report rather than abort. A concurrent session may
  -- legitimately have moved this row, and an exact-match premise here would
  -- abort db push for the whole repo.
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'internal_invoke_secret';
  if v_secret is null or length(v_secret) = 0 then
    raise exception 'ABORT: vault secret internal_invoke_secret is missing — the gate would lock the cron out';
  end if;

  v_cmd := $cmd$
  SELECT net.http_post(
    url := 'https://xqeacpakadqfxjxjcewc.supabase.co/functions/v1/sync-supabase-advisors',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'legacy_anon_key'),
      'X-Internal-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'internal_invoke_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  ) AS request_id;
  $cmd$;

  -- 1. Registry (canonical).
  update public.admin_automations
  set action = jsonb_set(action, '{command}', to_jsonb(v_cmd), true),
      updated_at = now()
  where slug = 'sync_supabase_advisors_hourly';

  if not found then
    raise warning 'registry row sync_supabase_advisors_hourly not found — skipping registry update';
  end if;

  -- 2. Live cron, via the same derivation the reconciler uses, so the two
  --    agree and command-drift finds nothing to do.
  select jobid, command into v_jobid, v_live
  from cron.job where jobname = 'sync-supabase-advisors-hourly';

  if v_jobid is null then
    raise warning 'cron job sync-supabase-advisors-hourly not found — registry updated, nightly sync will create it';
  else
    -- Two-arg form, exactly as sync_automations_to_cron calls it
    -- (slug, action->>'command'). The one-arg form does not exist; guessing it
    -- is a 42883 at apply time, which would abort db push for the whole repo.
    perform cron.alter_job(
      v_jobid,
      command := public.admin_automation_effective_command(
        'sync_supabase_advisors_hourly',
        v_cmd
      )
    );
  end if;
end $$;

-- Postconditions: assert the REACHED STATE, not that an UPDATE matched rows.
do $verify$
declare
  v_reg  text;
  v_live text;
begin
  select action->>'command' into v_reg
  from public.admin_automations where slug = 'sync_supabase_advisors_hourly';
  select command into v_live
  from cron.job where jobname = 'sync-supabase-advisors-hourly';

  if v_reg is null or position('X-Internal-Secret' in v_reg) = 0 then
    raise exception 'P1 failed: registry command does not send X-Internal-Secret';
  end if;
  if position('internal_invoke_secret' in v_reg) = 0 then
    raise exception 'P1b failed: registry command does not read the vault secret';
  end if;
  -- The bearer must SURVIVE; dropping it reopens the deploy-order window.
  if position('legacy_anon_key' in v_reg) = 0 then
    raise exception 'P2 failed: registry command lost the Authorization bearer';
  end if;

  if v_live is null then
    raise warning 'P3 skipped: no live cron row';
  else
    if position('X-Internal-Secret' in v_live) = 0 then
      raise exception 'P3 failed: live cron command does not send X-Internal-Secret';
    end if;
    -- A re-wrap that fell back to a raw net.http_post gives a job that works
    -- and records no runs — a failing cron that reads healthy.
    if position('automation_http_post' in v_live) = 0
       or position('admin_automation_run_begin' in v_live) = 0 then
      raise exception 'P4 failed: live cron lost its run-tracking wrapper';
    end if;
  end if;

  raise notice 'advisor cron now sends X-Internal-Secret (registry + live cron agree)';
end $verify$;
