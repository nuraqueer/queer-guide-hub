/**
 * One classification of "the gate did not run", shared by the gate scripts that
 * retry on it.
 *
 * A gate script has THREE outcomes and only two of them are about the gate: it
 * passed, it was breached, or IT WAS NEVER EVALUATED. The third must read as
 * neither of the others — that is the whole reasoning already written out in
 * check-trust-safety-gates.mjs, and this module exists so the four scripts
 * cannot drift apart on what counts as the third (the scripts/lib/
 * remote-migrations.mjs precedent: one fetch so two callers cannot disagree
 * about what "applied" means).
 *
 * WHY A SECOND NON-EVALUATION EXISTS, measured 2026-10-14. Those scripts gated
 * their retry on a Postgres 57014 in the RESPONSE BODY, which can only be read
 * once a response exists. `fetch` does not always produce one: on a transport
 * stall it THROWS, so the 57014 branch is structurally unreachable and the
 * script dies on an unhandled rejection with a raw stack trace. Observed on
 * #4404's head 09fdf873f — `Trust & safety gates` at check-trust-safety-gates
 * .mjs:32 (18:26:19 -> 18:31:21) and `Critical data-quality gates` at
 * check-data-quality-gates.mjs:34 (18:26:22 -> 18:31:25): two different
 * scripts, two different jobs, two different runners, both the FIRST RPC call,
 * both dead at exactly five minutes (undici's default headers timeout) and
 * ending four seconds apart. In the same job `check-definer-view-grants.mjs`
 * then took 3m41s for three checks that normally take about a second, and
 * everything after 18:35:07 ran at normal speed. That is one prod stall
 * spanning ~18:26-18:35, not two script bugs, and the PR's diff was one
 * documentation file.
 *
 * SO A THROW AND A 57014 ARE THE SAME CONDITION HERE, and the difference is
 * only WHERE the clock ran out: undici gave up client-side at 300s, or Postgres
 * gave up server-side at the 8s `authenticator` ceiling. Neither evaluated a
 * gate. Both get the one delayed retry; neither may be mistaken for a breach.
 *
 * WHAT THIS DELIBERATELY DOES NOT DO: it never converts a non-evaluation into a
 * pass. A gate that could not run must still fail its check — these are
 * trust-&-safety and data-quality gates, and "we could not look" reading as
 * "nothing found" is the vacuous-green failure this repo keeps recording. The
 * improvement is that the run now says which of the three happened instead of
 * printing a stack trace.
 */

/**
 * `status` for a call that produced no HTTP response at all. Zero is chosen
 * because no real HTTP status is 0, so `status === 0` cannot collide with a
 * server answer, and the scripts' existing `HTTP ${status}` logging still
 * prints something truthful.
 */
export const NO_RESPONSE = 0

/** Pull a usable short cause out of whatever `fetch` threw. */
function causeOf(err) {
  return (
    err?.cause?.code ??
    err?.code ??
    err?.cause?.name ??
    err?.name ??
    'unknown'
  )
}

/**
 * Call a PostgREST RPC and NEVER throw.
 *
 * Returns `{ ok, status, body, data }`:
 *   - ok    — the response was 2xx AND its JSON parsed
 *   - status— the HTTP status, or NO_RESPONSE when there was no response
 *   - body  — the error text (null when ok), always a string when not ok, so a
 *             caller's `body?.includes(...)` keeps working unchanged
 *   - data  — the parsed JSON when ok, else null
 *
 * The three failure shapes are reported apart in `body` because they need
 * different fixes: no response at all (transport), a non-2xx (the server
 * answered, and 57014 lives here), and a 2xx whose body would not parse.
 */
export async function callRpc(url, init) {
  let res
  try {
    res = await fetch(url, init)
  } catch (err) {
    return {
      ok: false,
      status: NO_RESPONSE,
      body: `fetch failed before any HTTP response (${causeOf(err)}: ${err?.message ?? err})`,
      data: null,
    }
  }

  if (!res.ok) {
    let body
    try {
      body = await res.text()
    } catch (err) {
      // The status is real and is the thing worth reporting; losing the body is
      // not worth losing the status over.
      body = `<response body unreadable: ${causeOf(err)}>`
    }
    return { ok: false, status: res.status, body, data: null }
  }

  try {
    return { ok: true, status: res.status, body: null, data: await res.json() }
  } catch (err) {
    // A 2xx the caller cannot parse evaluated no gate either, but it is NOT a
    // transport stall and must not claim to be one.
    return {
      ok: false,
      status: res.status,
      body: `response was HTTP ${res.status} but its body did not parse as JSON (${causeOf(err)})`,
      data: null,
    }
  }
}

/**
 * Did this call fail to EVALUATE the gate, as opposed to finding it breached?
 *
 * Only these three, and the narrowness is the point: anything else — a 403, a
 * 404, a 500 naming a real error — is the server answering, and retrying it
 * would retry a genuine breach into silence.
 *
 * THE THIRD WAS MEASURED 2026-10-17. PostgREST answers
 *   503 {"code":"PGRST002","message":"Could not query the database for the
 *        schema cache. Retrying."}
 * when it cannot reach Postgres at all — it could not even load the schema to
 * route the call, so it evaluated nothing. Observed failing `No API-role
 * writes on SECURITY DEFINER views` on #4470 during one of that day's
 * saturation stalls, i.e. reporting a security gate it never ran as a security
 * FAILURE. That is the same category error as the 57014 and the transport
 * throw, one layer further out.
 *
 * Matched on the PGRST002 CODE, not on a bare 503: a 503 carrying some other
 * body is not necessarily PostgREST declining to serve, and widening this is
 * exactly how a real breach gets retried into silence.
 */
export function notEvaluated(result) {
  if (!result || result.ok) return false
  if (result.status === NO_RESPONSE) return true
  if (result.body?.includes('PGRST002')) return true
  return Boolean(result.body?.includes('57014'))
}

/** Human-readable reason, for a log line that has to name which happened. */
export function stallReason(result) {
  if (!notEvaluated(result)) return null
  if (result.status === NO_RESPONSE) return 'no HTTP response (transport stall)'
  if (result.body?.includes('PGRST002')) return 'PostgREST could not reach Postgres (PGRST002)'
  return 'Postgres statement_timeout (57014)'
}
