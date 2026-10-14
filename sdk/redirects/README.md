# Redirects server SDKs

Local SDK sources for TypeScript, Python, Go, Ruby and PHP. Each client targets
queer.guide's Redirects API contract; these are not Dub SDK aliases. They cover
managed link CRUD/upsert/count/list/bulk, folder/tag/template CRUD/list, private
analytics and event pages, lead/sale tracking, and presentation/image-upload methods. Link iterators follow keyset
pages and reject repeated cursors. Resource and event pages expose their cursors
for explicit iteration.

Use server credentials from **API and conversion setup**. Scopes are independent:
`links:read`, `links:write`, `workspace:read`, `workspace:write`, `events:read`,
`conversions:write`. Workspace scopes require unrestricted credentials; keys limited
to selected link IDs cannot change or read shared resources. Keep credentials in
server environment variables. No SDK performs token creation or privilege changes.

Clients use HTTPS by default (`https://queer.guide/api/redirects`), reject credentials
in base URLs, and allow plain HTTP only on loopback for development. Requests have
10-second transport timeouts, refuse redirects and cap responses at 8 MiB. Go additionally
accepts request contexts; TypeScript's generic request accepts an AbortSignal.
HTTP failures raise API errors carrying status and Retry-After. There are no
automatic retries, especially for create/update/delete. Retry conversion ingestion
with a stable event ID; pass money as decimal strings to preserve all six supported
decimal places. Revenue responses remain exact strings by currency.

## Local usage

These sources have not been published to package registries. Copy the relevant
source into server code or use the local package/module. No third-party runtime
libraries are required. TypeScript compilation uses the repository's TypeScript.

| Language | Source | Minimum runtime | Example command (from repository root) |
| --- | --- | --- | --- |
| TypeScript/JavaScript | `typescript/index.ts` | Node 22+ | `npx tsc -p sdk/redirects/typescript/tsconfig.json` then `node sdk/redirects/typescript/example.mjs` |
| Python | `python/redirects.py` | Python 3.8+ | `python3 sdk/redirects/python/example.py` |
| Go | `go/redirects.go` | Go 1.23+ | From `sdk/redirects/go`: `go run ./cmd/example` |
| Ruby | `ruby/redirects.rb` | Ruby 2.6+ | `ruby sdk/redirects/ruby/example.rb` |
| PHP | `php/RedirectsClient.php` | PHP 8.1+, HTTPS streams | `php sdk/redirects/php/example.php` |

Set `REDIRECT_API_TOKEN` and optionally `REDIRECT_API_BASE` and `REDIRECT_TARGET`.
Each example creates a random short link and prints its short URL. To exercise
tracking, supply an existing recorded `REDIRECT_CLICK_ID`, `REDIRECT_CUSTOMER_ID`
and stable `REDIRECT_EVENT_ID`. Optional `REDIRECT_AMOUNT` plus `REDIRECT_CURRENCY`
sends a sale; its event ID appends `:sale` to the supplied lead event ID. Creation
needs workspace-wide `links:write`; tracking also needs `conversions:write`.

Python example in server code:

```python
from redirects import RedirectsClient
client = RedirectsClient(token)
link = client.create_link({"target": "https://example.com/register"})["link"]
for record in client.iterate_links({"isEnabled": True}):
    print(record["shortUrl"])
client.track_sale({"clickId": click_id, "customerExternalId": customer_id,
                   "eventId": invoice_id, "amount": "49.900001", "currency": "CHF"})
```

Equivalent method names follow each language's conventions (`createLink` / `CreateLink`
/ `create_link`). `request` / `Request` exposes the owned API path for additional
supported endpoints. See `docs/guides/redirect-link-management-api.md` and
`docs/guides/redirect-workspace-api.md` for fields, permissions and semantics.

## Verification

`npm run test:redirect-sdks` starts a loopback HTTP server, loads the actual edge
handler and uses the real migrations in isolated PGlite PostgreSQL. It runs all
five native runtimes, creates and edits shared resources and assigned links,
updates/upserts/deletes, writes lead/sale events with deduplicated retries, reads
analytics/events, follows a 101-row paged list, refuses redirects and preserves
429 retry headers without automatic retries. Final SQL checks prove five leads,
five sales and exact `249.500005` total. All five runnable examples are then
executed against that same isolated API with tracked leads/sales, producing a
verified ten-sale total of `254.500010`. No production API, credentials, payment
provider or schema is touched.

Go must be available on PATH or configured via `REDIRECT_GO_BIN`; the local agent's
verified vendor runtime was kept under ignored `tmp/go-runtime`. The test command
does not download runtimes. Production migrations/release, package publication,
policy/domain/deep-link fields, webhooks and external integrations remain pending.

Presentation APIs are documented in `docs/guides/redirect-presentations.md`.
The SDK integration suite checks all five presentation/upload wrappers with real
encoded raster bytes; file storage uses a fixture adapter.


Policy management is available through getPolicy/updatePolicy (TypeScript/PHP),
get_policy/update_policy (Python/Ruby), and GetPolicy/UpdatePolicy (Go). Use
links:read for reads and links:write for patches. The response exposes policy and
hasPassword only; top-level null policy fields remove a setting, and password:null
removes protection. See [the policy API guide](../../docs/guides/redirect-policy-api.md)
for fields, complete examples, hash limits and expiry/merge semantics.

## Branded hostname namespaces

Pass `domainId` (a registered domain UUID) in link create/upsert/update or bulk
input. Pass `null` to select the built-in `/go/` namespace. Omitted updates preserve
the current binding; omitted create/upsert selects the built-in namespace. The
same slug can exist on different domains. List/count filters accept the same
UUID/null `domainId`. Responses include the canonical `shortUrl`, `domainId` and
`domainHostname`; use `shortUrl` instead of constructing a URL from the slug.

A new or moved binding requires current ownership, TLS and signed public-routing
proof. Existing folder/member/token permissions still apply. Domain registration,
provider setup and routing checks are owner-session controls; these SDKs do not
acquire those privileges. Python/Ruby/PHP dictionaries and Go `Object` pass the
same fields as TypeScript `LinkInput`. The implementation and SDKs remain local
sources awaiting production rollout/publication.

Ready domain choices are available through `listDomainChoices(limit, cursor)` in
TypeScript/PHP, `list_domain_choices` in Python/Ruby and `ListDomainChoices(ctx,
limit, cursor)` in Go. The page includes public ID/hostname fields, count, cursor
and primary availability. Read scope and current link/member restrictions apply.
Primary preference writes require an owner account session; keys do not gain
registry or primary-setting privileges. Interactive builders use the saved
primary initially, while API omission remains the built-in namespace.

Managed link input/response includes nullable `startsAt`, `clickLimit` and `notes`.
Dates normalize to UTC; a submitted start/end range must be ordered. Visit limits
are positive 32-bit integers; null removes the limit. Notes accept up to 10,000
characters. Omitted update fields are preserved. All five native HTTP test clients
exercise these fields. Manual CMS type/source conversions are a separate owner-
session endpoint and are not granted to server keys.


Linked-domain management facets are available through `listLinkedDomains(limit,
cursor)` (TypeScript/PHP), `list_linked_domains` (Python/Ruby), and
`ListLinkedDomains(ctx, limit, cursor)` (Go). Pages contain accessible domain
ID/hostname/linkCount entries, custom-domain count, builtinCount, nextCursor and
revision. They include inactive domains used by visible SHORT links and exclude
inaccessible folders/IDs. These facets do not establish creation readiness; use
listDomainChoices for that. When combining pages, reject a changed revision and
restart the read. Domain UUID/null filters on list/count continue to apply.


For a managed domain homepage, create/upsert with `isDomainRoot: true`, a ready
custom `domainId` and `target`. Root upsert identifies the existing root by domain
and does not require a slug. There is one root per domain; normal slug upserts
exclude it. Responses expose `isDomainRoot` and canonical `shortUrl` ending in `/`.
Use that URL for sharing/QR. The returned storage slug is not a public root alias.
Omitted update flags preserve the current value. All normal policies, scoped
permissions, metadata, analytics and conversion APIs apply to the same link ID.
Five native integration tests create, upsert and delete a managed root through
the actual HTTP API against an isolated ready-domain fixture.

Effective saved QR appearance is available through `getQrStyle(id)` in
TypeScript/PHP, `get_qr_style(id)` in Python/Ruby and `GetQRStyle(ctx, id)` in Go.
Responses contain id, the resolved shape/colors and source
(default/workspace/domain), plus effectiveLogo and logoSource. A present logo
contains only public raster metadata and its fixed-project hosted URL. Current links:read, folder and ID restrictions apply;
owner preference endpoints remain unavailable to keys. All five native tests
exercise these getters. See [saved QR styles](../../docs/guides/redirect-qr-branding.md)
for precedence, batching, versions and remaining hosted-logo/image work.


## Live QR image links

Create an explicitly shared image for a managed link using `createQrImage(data)`
(TypeScript/PHP), `create_qr_image(data)` (Python/Ruby), or
`CreateQRImage(ctx, data)` (Go). Data requires `linkId` and can include `label`,
`expiresAt` (null for no expiry), partial `style` and `logoMode: inherit | none`.
Defaults follow current workspace/domain branding. Creation requires links:read
and current folder/ID access. Explicit arbitrary URL publication is restricted to
an owner account session, rather than server keys.

The creation response contains id/version/metadata plus `imageUrls.png`, `.jpg`
and `.svg`. Each URL contains a random bearer capability, returned once; save the
URL if you intend to embed it. The list API does not return the bearer or hash.
Default lifetime is until revoked. Public retrieval rechecks current creator and
link access, resolves the canonical short URL (including managed domain roots),
and never fetches the destination or records a click. Only output format/size may
be changed on a shared URL. Workspace/domain appearance and logo changes affect
future image requests; explicit appearance overrides and hidden logos remain.

List with `listQrImages(limit, cursor)` / `list_qr_images` /
`ListQRImages(ctx, limit, cursor)`. Revoke with `revokeQrImage(id, version)` /
`revoke_qr_image` / `RevokeQRImage(ctx, id, version)`. Lists contain own publications;
workspace owners can manage all. Revocation closes future image retrieval; it
does not erase downloaded images or revoke the ordinary redirect encoded inside.

Creation limits are 100 active image links and 60 creations/hour per principal,
600 creations/hour globally, with 429/Retry-After 3600. Deleting redirects cannot
erase the short-lived creation ledger. Clients do not automatically retry writes.
All five native SDK tests exercise creation, list and versioned revocation against
the actual API/migrated database. Separate full-path HTTP/Wasm tests verify live
branding changes and independently decode generated PNG/JPG images.

These endpoints and wrappers are local implementation, not a released package or
production endpoint. Durable per-export custom-artwork attachment, UI authoring
and controlled deployment remain required.
