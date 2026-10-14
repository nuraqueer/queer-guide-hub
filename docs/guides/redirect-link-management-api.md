# Redirect link management API

Base URL: `https://queer.guide/api/redirects`. Use `Authorization: Bearer <credential>`
from server code and `Content-Type: application/json` for bodies. Admin sessions
are also accepted after live user and admin verification. Management operations
apply to manual `SHORT` links; automatic/static inventory sources remain owned by
their source systems.

## Permissions

Create a credential in conversion setup with `links:read`, `links:write`, or both.
Reading destinations/settings is distinct from reading private event analytics.
Writing does not implicitly authorize list/get. Read and write scopes are checked
at the HTTP boundary and again inside the database transaction, including current
expiry/revocation and selected link IDs. Revocation waits for in-flight transactions;
it prevents subsequent operations. A key limited to selected links can read/update/
delete those links and upsert an existing assigned slug. It cannot create a new
link or upsert an unassigned slug. Token management requires an admin session.

## Routes

| Method | Route | Behavior |
| --- | --- | --- |
| GET | `/links` | Filtered count and keyset page |
| GET | `/links/count` | Exact matching count |
| GET | `/links/:uuid` | One scoped managed link; missing/unassigned is 404 |
| POST | `/links` | Create a link; omit slug for an allocated random slug |
| PATCH | `/links/:uuid` | Update supplied fields, preserving omitted fields |
| PUT | `/links/upsert` | Update matching slug or create it atomically; target and slug required |
| DELETE | `/links/:uuid` | Permanently delete link and associated tracking history |
| POST | `/links/bulk` | Atomic mixed create/update/upsert/delete batch (1–100 operations) |

Create and upsert return 201 when created and 200 when updating. Writes return
`{operation,created,link}`; delete returns `{operation,id,deleted:true}`. Bulk returns
`{data:[...results]}` in request order. Any failed operation rolls back the complete
batch. Batches are serialized in the database to coordinate upserts. A duplicate
explicit slug returns 409; missing updates/deletes return 404; permission failures
return 403. Invalid input returns 400. Unavailable database calls return 503.

Link fields: `slug` (3–64 lowercase letters/numbers/hyphens; reserved words denied),
`target` (public HTTP(S) or site path), `statusCode` (301/302/307/308), `isEnabled`,
`queryMode` (PRESERVE/DROP/OVERRIDE), `queryOverride`, `utmDefaults`, `expiresAt`,
`folderId`, `tagIds`, `comment`. Defaults are 302, enabled and PRESERVE. Target queries
and fragments remain intact. Query maps accept at most 100 string entries, keys
≤200/value≤2,000 characters; password/attribution control parameters are denied.
UTM defaults allow only source/medium/campaign/term/content/ref. Comments are
≤10,000 characters. Credentials/local/private addresses and short-link loops are
rejected. Target and all link fields are closed to unknown properties. Passwords,
experiments, preview/domain/deep-link settings are not yet accepted by these routes.

Omitted organization/expiry/query settings remain unchanged. Explicit null clears
folder/expiry/query maps; empty tagIds clears tags; an empty comment clears it.
Changing expiry updates both the legacy window and the policy's expiry. Upsert
preserves the existing UUID, click count, policies and omitted metadata. All body
sizes are limited to 64 KiB. All credential secrets stay server-side.

Deletion cascades event/conversion/customer history, policies, attempt counters and
link organization. Existing donation records remain, with their attribution FK set
to null. Use `isEnabled:false` to disable a link while retaining history. Disabled
links are not an archive feature; archived organization will be added separately.

## List and pagination

`GET /links?limit=100&filters=<URL-encoded JSON>&cursor=<UUID>` returns
`{count,data,nextCursor}`. Follow nextCursor until null. Limit is 1–100 (default50),
and order is ascending UUID. Count covers all matching rows rather than the page
or a PostgREST response cap. Filters: literal `search` across slug/target, `ids`
(≤100), `folderId`, `tagId`, `isEnabled`. Restrictions intersect credential scope.
Pages see current data; this is not an immutable export snapshot. Concurrent changes
can alter which rows match. Detail reads expose no password hash or raw visitor data.

## Examples

Create a tracked campaign:

```json
{"target":"https://example.com/register?audience=community#form","slug":"community-launch","utmDefaults":{"utm_source":"poster","utm_campaign":"launch"},"comment":"Venue posters"}
```

Atomic batch:

```json
{"operations":[{"operation":"create","data":{"target":"/events"}},{"operation":"update","id":"YOUR_LINK_UUID","data":{"isEnabled":false}},{"operation":"upsert","data":{"slug":"community-launch","target":"/events/community"}}]}
```

Bulk folder/tag assignment uses update operations with folderId/tagIds. This endpoint
is not a compatibility alias for Dub's API; SDK wrappers will target this contract.
Folder/tag/template resource APIs and SDK wrappers are now available locally;
policy fields, archive/import/QR bulk UI, custom
domains remain in the full parity ledger.

## Verification status

Candidate implementation only. The isolated PostgreSQL suite executes actual
management functions, including a 1,101-link count/paging case, scope rechecks,
revocation, rollback after partial writes, random slugs, partial metadata updates,
expiry clearing and deletion. Source handler tests exercise HTTP authorization,
validation, methods and statuses. Production migration/deployment remains pending.
