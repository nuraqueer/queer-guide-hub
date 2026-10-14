do $$
declare j record;
begin
  select jobid,schedule,active,command into j from cron.job where jobname='geo_address_drain';
  if not found or not j.active or j.schedule <> '*/15 * * * *' or j.command not like '%''batch_size'', 5%' then
    raise exception 'Unexpected postal cron state; refusing pause';
  end if;
  perform cron.alter_job(job_id := j.jobid, active := false);
  update public.admin_automations set enabled=false
  where slug='geo_address_drain' and enabled=true and lifecycle_state='active';
  if not found then raise exception 'Unexpected postal automation state'; end if;
end $$;
