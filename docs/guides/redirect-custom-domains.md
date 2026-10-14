# Custom redirect domain setup

The Link workspace has owner-only domain registration, ownership checks, durable
Cloudflare hostname/TLS setup and an explicit branded routing check. Managed
links have separate hostname namespaces; the default remains
`https://queer.guide/go/<slug>`. Root, not-found and default expiry destinations
are resolved on branded hosts. The domain picker and primary-domain preference
are still pending. This implementation is local; provisioning a production
hostname and deploying the dedicated relay remain release work.

## Registration and ownership

Hostnames normalize case, trailing dots and IDNs to ASCII. Schemes, ports, paths,
credentials, IP addresses, malformed/private/reserved suffixes and Queer Guide or
hosting infrastructure domains are rejected. The hostname limit leaves room for
the DNS challenge prefix. Each registration gets a distinct cryptographic TXT
challenge at `_qg-redirect.<hostname>`, with value `qg-redirect=<token>`.

Only verified owner account sessions can manage the registry. SQL rechecks the
current admin role; editable user metadata and cached client state do not grant
access. Ordinary members, API keys and anonymous callers cannot read challenges
or change domains. Tables and RPCs remain private to the service role with RLS.
Account-keyed UI state prevents a subsequent account inheriting the previous UI.

Checking DNS reserves an attempt before the external lookup: one check/domain/
minute, 30 checks/owner/hour and 100 globally/hour. The actual lookup always goes
to Cloudflare's fixed HTTPS DNS endpoint. It never fetches the submitted hostname,
follows redirects or sends the token to the resolver. Responses are streamed with
a 64 KiB cap and eight-second timeout. Only a matching question/name, TXT type,
successful DNS status and exact complete token pass. Multiple quoted TXT chunks
are supported. Redirects, malformed/truncated/oversized responses and transient
failures do not become successful proof.

Fresh proof lasts 24 hours. A definite missing record clears it; a transient
failure preserves only the existing expiry, never extends it. Replacement rotates
the challenge and immediately clears ownership proof. The result must match the
current domain version, a single-use attempt nonce and the one-minute observation
window. Concurrent edits, rotation, disable/removal or lost owner rights prevent
an old in-flight observation being applied.

## Stored defaults and lifecycle

Root, not-found and expired-link destinations accept public HTTP(S) URLs, including
public IPv4 destinations. Private addresses, credentials, relative paths and known
short-link-domain loops are rejected. Edits preserve omitted fields and use an
optimistic version. Disabling a domain blocks new ownership checks. Removal and
challenge replacement require review; removal refuses a record with a provider
hostname ID, reserving provider cleanup for the provisioning stage. Settings and
proof refreshes keep expanded setup panels open.

These defaults are stored, not served yet. Durable Cloudflare lifecycle and
certificate status checks are implemented locally as described below. The next
stages must implement actual routing readiness, independent hostname/slug
namespaces, signed public hostname relay, root/not-found/expiry behavior, primary
selection, domain archive/transfer/subpath workflows and integration into
CRUD/bulk, five SDKs, builder/QR and the all-source inventory. Provider-authorized
DNS auto-configuration and forwarding setup instructions remain additional domain
workflow requirements. Existing `/go/:slug` behavior remains the resolver path.

## HTTP contract

Registered owner sessions use `/api/redirects` (or the existing direct edge API):

- `GET /domains?limit=50&cursor=<UUID>`: owner-only keyset list and exact count.
- `POST /domains`: hostname and optional stored defaults.
- `GET /domains/:id`: current setup/proof metadata.
- `PATCH /domains/:id`: version plus changed defaults/disabled state.
- `POST /domains/:id/verify`: version; reserve, check real DNS, apply current result.
- `POST /domains/:id/rotate`: version; replace challenge and clear proof.
- `DELETE /domains/:id`: JSON version; reject a provisioned hostname.

The branded proxy forwards DELETE bodies so guarded removal works there too.
The schema rejects unknown fields; callers cannot set ownership, provider IDs,
challenge tokens or readiness. API keys deliberately do not manage this account-
owner registry; later scoped domain SDK/API work remains pending.

## Evidence and release

Migrated PostgreSQL verifies owner rights, distinct tokens, paging/counts,
normalization constraints, defaults/loop/private-address checks, stale writes,
nonce replay, stale observations, rotation, proof expiry/loss, transient failures,
disabled checks, provider removal guards and private grants. The actual HTTP
handler additionally runs create/verify/defaults/lost-proof/delete and API-key
rejection against that database with an isolated DNS response. Five SDKs and
examples retain their existing HTTP tests; they do not yet expose domain methods.
UI and helper tests cover instructions, explicit review, exact DNS parsing,
stream bounds, IDNs and keeping the expanded panel open after a new server version.

Native desktop/mobile screenshots use `domain-registry-*` under the existing
outputs directory. Registrations/DNS results are explicitly simulated and all
production fetches blocked. At 390 pixels client and scroll widths are both 390.
No production DNS changes, provider provisioning, live registry writes or deployment
were performed. Live controlled-domain/TLS evidence is still required for parity.

References: [Dub custom domains](https://dub.co/help/article/how-to-add-custom-domain),
[Cloudflare SaaS setup](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/start/getting-started/),
[Cloudflare DNS JSON](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/dns-json/).

## Durable hostname and certificate lifecycle

Configure the dedicated server secrets `REDIRECT_CF_ZONE_ID`,
`REDIRECT_CF_API_TOKEN` and `REDIRECT_CNAME_TARGET` for a Cloudflare for SaaS zone.
Use a zone-scoped token with SSL and Certificates Write permission, not an account
API key or the existing general Cloudflare admin tooling credentials. The CNAME
target/fallback origin and eventual Worker routing must be set up and verified by
the operator; this implementation does not silently change DNS or zone routes.
The owner API reports configuration presence and the target, never the token.
Missing/invalid configuration leaves the worker idle before claiming any work.

Connect and disconnect require explicit UI review. Connection needs fresh TXT
proof, an enabled domain and current owner permission. It queues a private job;
the API request does not provision inline. The worker leases up to three jobs for
two minutes and uses bounded, eight-second Cloudflare requests. Responses are
streamed with a 128 KiB cap. Candidate IDs, statuses and matching TXT validation
records are allowlisted; certificates/private keys and raw provider error bodies
are not returned or logged. Existing objects are checked for an exact hostname
match before binding or deletion. The stored zone and target cannot change while
provider resources or uncertain work remain. A fully disconnected registration
can bind a new configuration on its next reviewed connection.

A preflight exact-hostname lookup runs before creation. A durable single-use create
intent is recorded before POST. The adapter makes that POST once; GET and DELETE
can retry, while an uncertain create response enters review. Successful creation
receipts remain recordable after lease expiry or cancellation so an external
object cannot disappear from tracking. Cancelling makes readiness false first,
then the worker removes the known object. A confirmed delete/404 clears only the
same binding, even if another owner action raced it. Registry removal is blocked
while resources, uncertain creation or unfinished work remain.

An owner can review a matching existing provider candidate and explicitly adopt
it. Connecting adoption requires fresh ownership; cleanup-only adoption with
connection disabled can revoke an old object even after TXT ownership was lost.
The worker rechecks the exact hostname and current owner permission. Nothing is
silently adopted by hostname. This does not require the separately restricted
Cloudflare Custom Metadata feature.

For an uncertain creation with zero catalog matches, automatic creation remains
blocked. The owner must inspect Cloudflare, wait at least 15 minutes from the
recorded intent, refresh candidates within the last five minutes, and explicitly
attest absence. This clears the uncertain intent and leaves the job disconnected;
a new connection still requires separate review. Catalog lookup alone does not
claim certainty about a previously timed-out write.

Readiness requires both Cloudflare hostname and certificate statuses to be
`active`, a provider binding, fresh checks (15 minutes), enabled/current ownership,
a connection still requested, and a requester who remains a workspace owner.
Proof rotation/expiry/loss, disablement, owner-role loss and disconnect close that
flag immediately. Healthy/status-pending reads schedule another check after five
minutes; transient failures preserve the old timestamp and back off, respecting
bounded Retry-After. Twelve consecutive failures stop automatic attempts until
owner review/retry. Queue/scheduler capacity must be verified for the deployed
number of domains so checks do not age out under backlog. Certificate readiness
is not a public routing health check; primary URLs are still unavailable.

The internal/admin-authorized `redirect-domain-provisioner` function consumes the
queue. Its minute cron uses the established project-local Vault `supabase_url`
and `internal_invoke_secret`. Without either, the schedule makes no HTTP call;
without dedicated provider config, the worker claims no work. Worker calls and
provider snapshots are isolated in tests; no scheduled production run is claimed.

Owner endpoints (all require the current domain version):

- `POST /domains/:id/provider/connect`: reviewed connection request.
- `POST /domains/:id/provider/refresh`: queue current status/reconciliation checks.
- `POST /domains/:id/provider/disconnect`: disable readiness, queue cleanup.
- `POST /domains/:id/provider/adopt`: reviewed `candidateId` from current results.
- `POST /domains/:id/provider/confirm-absence`: explicit `confirmedAbsent: true`.

Validation: real migrated SQL covers create-intent single use, stale leases and
operations, late receipts/cancellation cleanup, reviewed adoption/absence, changed
configuration, permission/ownership loss, private grants and removal guards.
Seventeen focused UI/adapter/worker authorization tests pass. The HTTP harness
queues through the actual handler, runs the actual adapter against an isolated
Cloudflare API and the migrated database, and proves exactly one create, pending
versus active TLS, refresh and asynchronous deletion. All five SDKs/examples keep
passing. Native `domain-provider-*` screenshots show reviewed requests, pending
and active TLS, immediate readiness loss and completed cleanup in labelled fixtures
with production requests blocked. The mobile page fits 390 pixels. TLS/provider
resources on a real controlled domain, public Worker routing, DNS target checks,
provider validation restart, domain SDKs and deployment remain open.

References: [Cloudflare activation and certificate states](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/domain-support/hostname-validation/validation-status/),
[Custom hostname API](https://developers.cloudflare.com/api/resources/custom_hostnames/methods/create/),
[Workers as fallback origin](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/start/advanced-settings/worker-as-origin/).

## Hostname namespaces and authenticated routing

`domainId` on link create, update, upsert and bulk operations selects the domain.
Explicit `null` selects the built-in namespace; an omitted update preserves the
current binding, while an omitted create/upsert selects the built-in namespace.
List/count `filters.domainId` uses the same UUID/null semantics. API responses
include `domainId`, `domainHostname` and the canonical `shortUrl`. Existing ID,
folder and token permissions still apply. A new/moved binding needs current
ownership, TLS and routing proof. Existing unavailable links can still be edited
or removed. Domain deletion is restricted while links reference it.

Managed CSV includes `domainId` and roundtrips bindings. Blank update cells preserve
the binding; `null` explicitly returns it to the built-in namespace. Duplicate
checks use domain plus slug. The all-source inventory displays branded URLs and
its QR export preserves QR attribution on managed links. Ordinary external URLs
remain unannotated. Builder domain selection and primary preferences remain open.

The dedicated `workers/redirect-domains` relay derives scope from the actual HTTPS
request URL. It forwards neither customer credentials/cookies nor customer-supplied
internal headers. Its domain-separated HMAC covers protocol, method, hostname,
path, canonical query, visitor IP and timestamp. The resolver rejects bad/old MACs,
altered routing parameters and unknown/unready domains without trying the built-in
namespace. The built-in resolver explicitly selects a null domain binding.

Every branded request rechecks current provider requester authority, enabled
state, 24-hour ownership proof and provider hostname/TLS observations no older
than 15 minutes. Click recording checks domain state again before consuming quota.
Public previews, password gates, targeting, conversions, cloaking and QR visits
continue through the same resolver. Root/not-found/expired fallbacks never count
as visits. Runtime destination checks reject registered redirect-domain loops.
Advanced managed root-link policies are a separate remaining requirement.

The owner uses **Check branded routing** after DNS and TLS setup. The browser makes
an explicit, cookie-free GET with no referrer to
`https://<hostname>/.well-known/qg-redirect`. A valid signed request records routing
proof tied to the current provider ID and protocol. It returns only readiness
and protocol; CORS permits the configured application origins without credentials.
The UI refreshes authoritative registry status and never treats an arbitrary
customer-host response as database proof. Routing proof lasts 24 hours; actual
signed traffic refreshes it after six hours. Dormant domains need a fresh check
before they can receive new link bindings. No server fetch to an arbitrary
customer hostname is introduced.

Known-provider polling renews previously owner-verified DNS proof when fewer than
six hours remain, including recovery of expired previous proof. It uses the same
bounded DNS verifier, per-domain cooldown, global/actor budgets, observation nonce,
version checks and current owner authority. Missing TXT clears readiness;
transient DNS failure never extends proof. A rotated/unverified challenge is
never verified automatically. Provider cleanup remains available independently.

## Release order and verification

1. Apply the namespace/routing migration before deploying clients that select the
   new columns, then release the redirect API, resolver and domain provisioner.
2. Configure the dedicated SaaS fallback Worker with the intended `SUPABASE_URL`,
   public `SUPABASE_ANON_KEY` and a sufficiently long `REDIRECT_RELAY_SECRET`
   matching the resolver. The committed configuration has no production URL,
   credentials, custom-host routes or workers.dev exposure. The ignored local
   fixture variables are not production credentials.
3. Review the dedicated SaaS fallback zone and Worker routing using the
   [Cloudflare Worker-as-origin setup](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/start/advanced-settings/worker-as-origin/).
   Do not apply a wildcard route to the main application zone as a shortcut.
4. Provision one controlled hostname, verify TXT/TLS, run the browser routing
   check, and verify real DNS/Worker/backend traffic before moving live links.
   Exercise same-slug isolation, root/not-found/expiry defaults, password and QR
   visits, disablement, missing DNS proof, requester revocation and cleanup.

Local SQL, actual HTTP/SDK integration and Worker/resolver fixtures verify the
implementation. They do not establish real DNS, certificate issuance, deployed
routing, cron scheduling or production migration success.
