# Adult access account restoration

## Problem

The shared 18+ confirmation is durable in browser storage, but the Tags index
still treats the transient `?adult=1` query parameter as its source of truth.
A confirmed reader therefore returns to Tags with adult terms hidden and is
asked to include them again.

For signed-in readers, the age gate also starts from a two-state boolean before
Supabase has restored the account record. That allows the modal to render while
the session/profile lookup is still in flight. Account persistence currently
uses best-effort parallel writes and discards their results, so a failed profile
write can silently turn into another prompt on the next browser or device.

## Approved behavior

- A signed-in reader confirms 18+ access once per account.
- `profiles.age_confirmed_at` is the canonical durable account record.
- Browser storage remains a fast cache and preserves signed-out behavior on the
  same origin.
- Adult gates use an explicit `checking | affirmed | unaffirmed` lifecycle and
  never show the modal while account confirmation is still being resolved.
- Tags considers a durable affirmation an active 18+ opt-in. Returning to the
  index shows the permitted terms without requiring `?adult=1` or another
  click.
- Existing `adult=1` links and the legacy Marketplace storage key continue to
  work during migration.
- Account persistence errors are not silently mistaken for success. The local
  confirmation remains usable, while the durable write is surfaced to the hook
  and retried when an authenticated session is available.

## State and data flow

1. Read the canonical browser cache synchronously.
2. If it is present, render as affirmed immediately and reconcile the signed-in
   profile in the background.
3. If it is absent, resolve the current Supabase session before deciding whether
   the reader is unconfirmed.
4. For an authenticated session, read `profiles.age_confirmed_at`. Auth signup
   metadata may seed older/missing profile rows, but it is not the canonical
   authorization or consent source.
5. While steps 3–4 are running, gates render their neutral placeholder without
   opening the modal.
6. On confirmation, update browser state immediately, persist the profile
   timestamp, and synchronize sibling hooks/tabs.
7. Tags shows adult entries when either the account/browser affirmation is true
   or the legacy URL opt-in is present.

## Verification

- Hook tests for initial checking state, profile restoration, failed persistence,
  session changes, legacy-key migration, and cross-tab synchronization.
- Tags tests for previously affirmed readers without `adult=1` and for a first
  opt-in that remains effective after navigating away and returning.
- Gate tests proving the modal does not flash during account restoration.
- Focused browser tests with a cleared browser cache and a mocked/restored signed-
  in profile, plus the anonymous production flow.
- Build, typecheck, lint, relevant unit tests, CI, guarded deployment, and live
  production verification.
