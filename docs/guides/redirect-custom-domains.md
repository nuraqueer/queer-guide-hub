# Custom redirect domain setup

The Link workspace dialog has owner-only custom-domain setup controls. This first
stage registers multiple domains, verifies ownership and stores root, not-found
and expired-link destinations. It does not yet connect provider hostnames, TLS or
public branded routing. A successful TXT check must never be presented as a live
short-link domain. No primary-domain choice or branded URL is emitted yet.

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

These defaults are stored, not served yet. The next stages must implement durable
Cloudflare lifecycle and TLS/routing readiness, independent hostname/slug
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
No DNS changes, provider provisioning, live registry writes or deployment were
performed. Live controlled-domain/TLS evidence is still required for parity.

References: [Dub custom domains](https://dub.co/help/article/how-to-add-custom-domain),
[Cloudflare SaaS setup](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/start/getting-started/),
[Cloudflare DNS JSON](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/dns-json/).
