create or replace function public.apply_entity_location(p_table text,p_id uuid,p_fingerprint text,p_patch jsonb,p_source text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r jsonb; after_row jsonb; patch jsonb:='{}'; actual_patch jsonb:='{}'; k text; v jsonb; assignments text;
begin
 if p_table not in ('organizations','venues','hotels') then raise exception 'Unsupported entity'; end if;
 execute format('select to_jsonb(t) from public.%I t where id=$1 for update',p_table) into r using p_id;
 if r is null or r->>'duplicate_of_id' is not null or public.entity_location_fingerprint(r)<>p_fingerprint then
   return jsonb_build_object('stale',true,'filled',0);
 end if;
 for k,v in select key,value from jsonb_each(p_patch) loop
   if k=any(array['address','city_id','country_id','postal_code','latitude','longitude','timezone','state'])
      and v<>'null'::jsonb and nullif(btrim(v#>>'{}'),'') is not null
      and nullif(btrim(r->>k),'') is null then patch:=patch||jsonb_build_object(k,v); end if;
 end loop;
 if patch='{}'::jsonb then return jsonb_build_object('filled',0,'fingerprint',public.entity_location_fingerprint(r),'row',r); end if;
 select string_agg(format('%I=p.%I',key,key),',') into assignments from jsonb_each(patch);
 execute format('update public.%I t set %s,updated_at=now() from jsonb_populate_record(null::public.%I,$1) p where t.id=$2 returning to_jsonb(t)',p_table,assignments,p_table)
 into after_row using patch,p_id;
 if after_row is null then
   insert into public.entity_location_audit(entity_table,entity_id,source,before_data,patch)
   values(p_table,p_id,p_source||':blocked_by_location_policy',r,'{}');
   return jsonb_build_object('filled',0,'blocked',true,'fingerprint',public.entity_location_fingerprint(r),'row',r);
 end if;
 for k,v in select key,value from jsonb_each(patch) loop
   if nullif(btrim(after_row->>k),'') is not null then actual_patch:=actual_patch||jsonb_build_object(k,after_row->k); end if;
 end loop;
 insert into public.entity_location_audit(entity_table,entity_id,source,before_data,patch) values(p_table,p_id,p_source,r,actual_patch);
 return jsonb_build_object('filled',(select count(*) from jsonb_object_keys(actual_patch)),'patch',actual_patch,
   'fingerprint',public.entity_location_fingerprint(after_row),'row',after_row);
end $$;
revoke all on function public.apply_entity_location(text,uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.apply_entity_location(text,uuid,text,jsonb,text) to service_role;
