do $$
declare j record;
begin
  select jobid, command, schedule, active into j from cron.job where jobname='geo_address_drain';
  if not found or j.active or j.schedule <> '*/15 * * * *'
     or j.command not like '%''batch_size'', 5%'
     or j.command not like 'SELECT public.admin_automation_run_begin(''geo_address_drain'', 1); SELECT public.admin_automation_run_begin(''geo_address_drain'', 1);%' then
    raise exception 'Unexpected postal cron state; refusing cautious resume';
  end if;
  perform cron.alter_job(
    job_id := j.jobid,
    command := replace(j.command,
      'SELECT public.admin_automation_run_begin(''geo_address_drain'', 1); SELECT public.admin_automation_run_begin(''geo_address_drain'', 1);',
      'SELECT public.admin_automation_run_begin(''geo_address_drain'', 1);'),
    active := true
  );
  update public.admin_automations
  set enabled=true, schedule='*/15 * * * *'
  where slug='geo_address_drain' and enabled=false and lifecycle_state='paused';
  if not found then raise exception 'Unexpected postal automation state'; end if;
end $$;
