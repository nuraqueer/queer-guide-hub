-- Production incident ledger. This version was applied directly on 2026-10-14
-- to reduce the postal drain from 20 to 10 records/minute while Photon slowed.
-- It was an operator throttle, not a desired baseline for a fresh database.
-- Keep the applied version/name in source control without replaying the throttle.
select 1;
