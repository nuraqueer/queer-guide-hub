-- Production incident ledger. This version paused the postal cron again after
-- two test batches had repeated eight-second Photon aborts. The live queue and
-- retry backoff were preserved. A fresh database must not inherit the pause.
select 1;
