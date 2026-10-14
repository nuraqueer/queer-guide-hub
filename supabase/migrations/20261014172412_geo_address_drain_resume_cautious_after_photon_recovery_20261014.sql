-- Production incident ledger. This version resumed the postal cron at five
-- records every 15 minutes after two healthy Photon probes, and removed a
-- duplicated admin_automation_run_begin call. It records the applied version;
-- fresh installations use the canonical cron definition instead.
select 1;
