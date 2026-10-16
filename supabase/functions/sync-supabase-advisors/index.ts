/**
 * sync-supabase-advisors — pulls Security + Performance advisor findings from
 * the Supabase Management API and surfaces them as `api_error` rows so they
 * show up alongside runtime errors in /admin/feedback → API Errors kanban.
 *
 * Policy (the board is for actionable tickets, not the full lint backlog):
 *   - INFO: never surfaced (both types).
 *   - Performance: only ERROR. WARN (multiple_permissive_policies,
 *     auth_rls_initplan, duplicate_index, …) is optimization backlog, not a
 *     runtime error — it flooded the board, so it's dropped here.
 *   - Security ERROR: always surfaced.
 *   - Security WARN: surfaced EXCEPT a denylist of known false-positive floods
 *     for this project — our SECURITY DEFINER RPCs deliberately self-gate
 *     (requireInternalOrAdmin / has_role / RLS-aware bodies) and search_path is
 *     bulk-managed, so the advisor flags ~370 of them without any being
 *     actionable. Everything else (rls_policy_always_true, security_definer_view,
 *     auth_insufficient_mfa_options, …) still surfaces.
 *
 * Each finding uses the advisor's stable `cache_key` as the fingerprint so
 * repeat runs deduplicate. Findings that disappear between runs auto-resolve
 * (feedback_status='done', resolution='fixed'), closing the loop without a
 * manual admin click.
 *
 * Scheduled hourly via pg_cron — see the migration alongside this function.
 *
 * Required env:
 *   MANAGEMENT_ACCESS_TOKEN  Personal Access Token with project:read (the
 *                            Supabase secret store blocks the SUPABASE_
 *                            prefix for user-defined secrets, so we drop it)
 *   SUPABASE_URL             (auto — used to derive project ref)
 *   SUPABASE_SERVICE_ROLE_KEY (auto)
 *   INTERNAL_INVOKE_SECRET   (the real gate — see AUTH below)
 *
 * AUTH (changed 2026-10-16). This ran with `verify_jwt = true` and NO gate of
 * its own, which is weaker than it looks: the gateway's verify_jwt checks only
 * that the JWT is VALID, never what role it carries. The publishable anon key
 * ships in the client bundle (src/integrations/supabase/client.ts) and is
 * therefore public, so it was enough to invoke this. Measured on prod: a plain
 * curl with that key ran the function. And it is not read-only — it writes
 * `api_error` rows via `upsert_api_error` and auto-resolves others — so any
 * visitor could flood the triage board or force repeated Management-API
 * advisor pulls against an already strained project.
 *
 * It now uses the posture the pipeline-* and source-* functions already use:
 * `verify_jwt = false` at the gateway plus `requireInternalOrAdmin` in the
 * body, which accepts X-Internal-Secret (held in Vault, so it never leaves the
 * database), a service-role bearer, or an admin JWT — and refuses the anon key.
 *
 * The cron deliberately keeps sending its `Authorization: Bearer
 * <legacy_anon_key>` header ALONGSIDE the new X-Internal-Secret. That is what
 * makes the rollout window-free in BOTH orders: the deploy workflow runs
 * `db push` before `functions deploy`, so the new cron command is briefly live
 * against the OLD function (which still demands a JWT and ignores the extra
 * header), and after the deploy the new function short-circuits on the secret
 * before it ever looks at the bearer.
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.50.5';
import { requireInternalOrAdmin } from '../_shared/supabase-client.ts';

interface AdvisorLint {
  name: string;
  title: string;
  level: 'ERROR' | 'WARN' | 'INFO';
  facing: string;
  categories: string[];
  description: string;
  detail: string;
  remediation: string;
  metadata: Record<string, unknown>;
  cache_key: string;
}

interface AdvisorResponse {
  lints: AdvisorLint[];
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function projectRefFromUrl(supabaseUrl: string): string | null {
  // https://<ref>.supabase.co → <ref>
  const m = supabaseUrl.match(/https?:\/\/([a-z0-9]+)\.supabase\.co/i);
  return m ? m[1] : null;
}

async function fetchAdvisors(
  ref: string,
  pat: string,
  type: 'security' | 'performance',
): Promise<AdvisorLint[]> {
  const url = `https://api.supabase.com/v1/projects/${ref}/advisors/${type}`;
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${pat}`,
      'Content-Type': 'application/json',
    },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`advisors/${type} ${res.status}: ${body.slice(0, 200)}`);
  }
  const body = (await res.json()) as AdvisorResponse;
  return body.lints ?? [];
}

Deno.serve(async (req) => {
  if (req.method !== 'POST' && req.method !== 'GET') {
    return json({ error: 'Method not allowed' }, 405);
  }

  const pat = Deno.env.get('MANAGEMENT_ACCESS_TOKEN');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!pat) return json({ error: 'MANAGEMENT_ACCESS_TOKEN not set' }, 500);
  if (!supabaseUrl || !serviceKey) return json({ error: 'Supabase env missing' }, 500);

  const ref = projectRefFromUrl(supabaseUrl);
  if (!ref) return json({ error: 'Cannot derive project ref from SUPABASE_URL' }, 500);

  const svc = createClient(supabaseUrl, serviceKey);

  // 0. Gate. MUST come before the Management-API pull and before any write:
  //    an unauthorised caller should cost nothing, not an advisor fetch. The
  //    service client is built first only because the gate needs it to resolve
  //    an admin JWT; it is not used for anything until the gate passes.
  const auth = await requireInternalOrAdmin(req, svc);
  if (auth instanceof Response) return auth;

  // 1. Pull advisor findings.
  let security: AdvisorLint[];
  let performance: AdvisorLint[];
  try {
    [security, performance] = await Promise.all([
      fetchAdvisors(ref, pat, 'security'),
      fetchAdvisors(ref, pat, 'performance'),
    ]);
  } catch (err) {
    return json({ error: (err as Error).message }, 502);
  }

  // 2. Filter to high-signal findings only (see policy in the file header).
  //    Known false-positive security WARN floods for this project — our
  //    SECURITY DEFINER RPCs self-gate and search_path is bulk-managed.
  const SECURITY_WARN_NOISE = new Set([
    'authenticated_security_definer_function_executable',
    'anon_security_definer_function_executable',
    'function_search_path_mutable',
  ]);
  const keepLint = (l: AdvisorLint, type: 'security' | 'performance'): boolean => {
    if (l.level === 'INFO') return false;
    if (type === 'performance') return l.level === 'ERROR';
    if (l.level === 'ERROR') return true; // always surface security errors
    return !SECURITY_WARN_NOISE.has(l.name); // security WARN: drop known floods
  };
  const kept = [
    ...security.map((l) => ({ lint: l, type: 'security' as const })),
    ...performance.map((l) => ({ lint: l, type: 'performance' as const })),
  ].filter(({ lint, type }) => keepLint(lint, type));

  // 3. Upsert each finding as an api_error row.
  const liveFingerprints = new Set<string>();
  let upserted = 0;
  for (const { lint, type } of kept) {
    const fingerprint = `advisor:${lint.cache_key}`;
    liveFingerprints.add(fingerprint);

    const data = {
      service: 'supabase-advisor',
      function_name: lint.name,
      message: `[${type}/${lint.level}] ${lint.title}: ${lint.detail}`,
      status_code: null,
      endpoint: `advisor/${type}`,
      metadata: {
        source: 'supabase-advisor',
        advisor_type: type,
        severity: lint.level,
        rule: lint.name,
        title: lint.title,
        detail: lint.detail,
        remediation_url: lint.remediation,
        categories: lint.categories,
        advisor_metadata: lint.metadata,
        cache_key: lint.cache_key,
      },
      reported_at: new Date().toISOString(),
    };

    const { error } = await svc.rpc('upsert_api_error', {
      p_fingerprint: fingerprint,
      p_data: data,
      p_source: 'sync-supabase-advisors',
    });
    if (error) {
      console.error(`upsert failed for ${fingerprint}:`, error.message);
      continue;
    }
    upserted += 1;
  }

  // 4. Auto-resolve rows whose finding has been remediated (no longer in the
  //    advisor output). Only touch advisor-sourced rows — runtime api_error
  //    rows manage their own lifecycle elsewhere.
  const { data: openAdvisorRows, error: fetchErr } = await svc
    .from('community_submissions')
    .select('id,fingerprint')
    .eq('content_type', 'api_error')
    .neq('feedback_status', 'done')
    .like('fingerprint', 'advisor:%');
  if (fetchErr) {
    return json({ error: `read open advisors: ${fetchErr.message}` }, 500);
  }

  const toResolve = (openAdvisorRows ?? []).filter(
    (r) => !liveFingerprints.has(r.fingerprint as string),
  );
  let resolved = 0;
  if (toResolve.length > 0) {
    const now = new Date().toISOString();
    const { error: updErr } = await svc
      .from('community_submissions')
      .update({
        feedback_status: 'done',
        resolution: 'fixed',
        resolved_at: now,
      })
      .in(
        'id',
        toResolve.map((r) => r.id),
      );
    if (updErr) {
      return json({ error: `auto-resolve: ${updErr.message}` }, 500);
    }
    resolved = toResolve.length;
  }

  return json({
    success: true,
    scanned: {
      security: security.length,
      performance: performance.length,
      kept: kept.length,
    },
    upserted,
    auto_resolved: resolved,
  });
});
