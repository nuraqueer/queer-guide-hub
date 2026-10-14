-- Production incident ledger. This version paused the postal cron and its
-- admin registry row while Photon requests exceeded the worker timeout.
-- Replaying that pause on a fresh database would strand its postal queue.
select 1;
