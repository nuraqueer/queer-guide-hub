-- Resolve a pending bookmark even when it is outside the current list page.
create or replace function public.get_admin_review_item(p_queue_type text,p_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare r public.admin_review_sources; v_item jsonb;
begin
 if not public.has_any_role_jwt(array['admin','moderator','editor']::public.app_role[]) then
  raise exception 'Review queue requires a staff account' using errcode='42501'; end if;
 select * into r from public.admin_review_sources where queue_key=p_queue_type and active;
 if not found or not(public.has_role_jwt('admin'::public.app_role) or
  (r.min_role='moderator' and public.has_role_jwt('moderator'::public.app_role)) or
  (r.min_role='editor' and public.has_any_role_jwt(array['moderator','editor']::public.app_role[]))) then return null; end if;
 v_item:=public.admin_review_item(p_queue_type,p_item_id);
 if v_item is null then return null; end if;
 return v_item||jsonb_build_object('source_label',r.label,'risk',coalesce(v_item->'risk_flags'->>'risk',r.risk),
  'overdue',coalesce(r.sla_hours is not null and (v_item->>'created_at')::timestamptz<now()-make_interval(hours=>r.sla_hours),false),
  'sla_hours',r.sla_hours,'can_reopen',r.can_reopen,'public_impact',r.public_impact);
end $$;
revoke all on function public.get_admin_review_item(text,uuid) from public,anon;
grant execute on function public.get_admin_review_item(text,uuid) to authenticated;
