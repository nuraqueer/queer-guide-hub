# Redirects workspace access

Local candidate; migration and production release are pending.

App administrators remain workspace owners. Other accounts must be explicitly
added through **Link workspace → Manage members**. This does not grant an app
admin/editor role. Accounts must already exist; adding a membership does not send
an invitation. Machine identities have no login and act through bound API keys.

Folders default to edit access for workspace members. Administrators or folder
owners can choose edit, view, or no access and set individual overrides: owner,
editor, viewer, no access, or inherit. A workspace viewer is always read only,
even with an owner override. Unfiled managed links are editable by members and
readable by viewers. Ordinary authenticated accounts have no implicit access.

The admin access editor, membership controls and API credential binding are
implemented. A separate member workspace page, edit-access requests and owner
notifications remain unfinished. Ordinary members cannot enter the admin console.

## Endpoints

All paths below are relative to `https://queer.guide/api/redirects`. Use a verified
session bearer token, or an API credential where specified. Responses are private
and must not be cached.

- `GET /members?offset=0`: administrator session only; `{data,count}`, 100 rows
  per page ordered by ID. Continue until the returned count is reached.
- `POST /members`: administrator session only; `{label,kind,role?,active?,userId?}`.
  `kind` is `user` or `machine`; existing account UUID required for user and
  forbidden for machine. `role` is `member` (default) or `viewer`.
- `PATCH /members/{id}`: administrator session only; any of `label,role,active`.
  Identity bindings cannot be edited. Inactive members lose API/session access.
- `DELETE /members/{id}`: administrator session only. Removes membership, folder
  overrides and all bound credentials. Deleting the Auth account also cascades
  these records; credentials never become unrestricted through deletion.
- `GET /folders/{id}/access`: owner access to the folder, with `workspace:read`
  when using a credential. Returns folder default and membership overrides.
- `PATCH /folders/{id}/access`: owner access, with `workspace:write` for keys.
  Body: `{defaultPermission?: "none"|"view"|"edit", overrides?: [{memberId,
  permission: "none"|"view"|"edit"|"owner"|null}]}`. Null removes the override.
  Omitted overrides remain unchanged. Changes are atomic; at most 100 per call.

API keys with selected-link scope cannot use workspace endpoints. Bind a key on
creation with optional `memberId` in `POST /tokens`. Bound keys intersect their
explicit scopes, selected-link IDs and the member's current folder access.
Unbound keys retain workspace administrator access within their explicit scopes.
Keys cannot create or modify workspace memberships or other keys.

## Enforcement

The verified Auth user ID is resolved to a private membership principal on the
server. Clients cannot choose that principal. SQL checks current membership and
folder access for each request, including policy/presentation APIs, analytics,
events and conversion writes. Session members cannot ingest server conversions;
that still requires a scoped server key or the existing trusted native flow.

Members may create folders (becoming owner), and owners may rename/delete them.
Member deletion of a nonempty folder is rejected: move its links first. Only
workspace administrators manage global tags/templates. Folder moves require edit
access to both source and destination. Readable list rows include `canEdit`.

ACL reads/writes coordinate through a transaction advisory lock. Management
writers acquire it before link/batch row locks. Private membership tables and
principal functions are unavailable to anon/authenticated Data API callers.
Existing admin-only table access is preserved. Other inventory sources remain
source-managed; the member management API currently covers managed short links.

## Verification

`npm run test:redirect-sql` runs the actual migration and rolled-back permission
fixtures in isolated PostgreSQL, including hidden folders, viewer caps, moves,
creator ownership, private-RPC grants, current token binding/downgrades, policy
reads, real click analytics and conversion rejection, and Auth-delete cascades.
API and component tests cover verified-principal forwarding, absent membership,
scoped access management, explicit override removal, denied-save recovery,
membership removal confirmation, machine creation and credential binding.
No production memberships or credentials are created by these tests.
