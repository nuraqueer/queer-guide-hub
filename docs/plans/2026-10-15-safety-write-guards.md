# Final safety flag write guards

The Redirects follow-up's production quality gate reports six venue and nine
organization rows with stored safety_gated=true while the current canonical
predicates return false. Read-only inspection confirmed that venue/org triggers
omit direct flag writes. The organization trigger also sorts before the address
country guard. PostgreSQL UPDATE OF matches the statement's columns, not columns
changed by earlier triggers. Reconciliation alone would allow drift to recur;
adding just safety_gated to the trigger still misses address-only writes.

Under the approved request to finish the release work, retain the current shared
predicate functions and derive both flags on every INSERT/UPDATE, with the final
trigger ordered after current geography/address guards. Reconcile canonical
venues and organizations only where the derived value differs, then assert no
drift remains. Do not alter legal-risk thresholds, cruising gating, RLS, release
checks or production data outside applying the reviewed migration.

An isolated PostgreSQL regression fixture must reproduce the old direct-write
and late-address failures, execute the real migration, and prove insertion,
direct flag edits, address/geography changes, nullable category, cruising, city
fallback, unrelated updates, both drift directions and idempotence. No production
migration application or reconciliation is part of local verification.
