-- Country and coordinate checks do not prove that a place is a city.
-- A reviewed classification issue survives point checks until identity inputs change.
create or replace function public.geo_cms_classification_issue(p_id uuid)
returns jsonb language sql stable set search_path=public,pg_temp as $fn$
select c.field_provenance->'city_place_audit'
from public.cities c
where c.id=p_id and c.duplicate_of_id is null
  and c.field_provenance->'city_place_audit'->>'status' in ('non_city','review','unresolved')
  and c.field_provenance->'city_place_audit'->>'fingerprint'=public.geo_cms_fingerprint(p_id);
$fn$;
revoke all on function public.geo_cms_classification_issue(uuid) from public,anon,authenticated;
grant execute on function public.geo_cms_classification_issue(uuid) to service_role;

do $patch$
declare definition text; anchor text;
begin
 definition:=pg_get_functiondef('public.geo_cms_verify(uuid)'::regprocedure);
 anchor:='  insert into geo_cms_verifications(place_id,status,fingerprint,checks,sources)';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'geo_cms_verify evidence anchor changed';
 end if;
 definition:=replace(definition,anchor,$guard$  if public.geo_cms_classification_issue(p_id) is not null then
    v_status:='review';
    v_checks:=v_checks||jsonb_build_object('geographic_reason',v_checks->>'reason',
      'city_classification',public.geo_cms_classification_issue(p_id)->>'status',
      'identity_verified',false,'reason',public.geo_cms_classification_issue(p_id)->>'reason');
    v_sources:=v_sources||coalesce((select jsonb_agg(jsonb_build_object('title','City classification source','url',s))
      from jsonb_array_elements_text(public.geo_cms_classification_issue(p_id)->'sources') s),
      '[{"title":"GeoNames classification audit","url":"https://download.geonames.org/export/dump/"}]'::jsonb);
  end if;
$guard$||anchor);
 execute definition;

 definition:=pg_get_functiondef('public.geo_cms_record_evidence(uuid,text,jsonb,jsonb)'::regprocedure);
 anchor:='  v_status:=case when p_checks->>''country_match''=''true''';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'geo_cms_record_evidence status anchor changed';
 end if;
 definition:=replace(definition,anchor,$guard$  if public.geo_cms_classification_issue(p_id) is not null then
    p_checks:=p_checks||jsonb_build_object('geographic_reason',p_checks->>'reason',
      'city_classification',public.geo_cms_classification_issue(p_id)->>'status',
      'identity_verified',false,'reason',public.geo_cms_classification_issue(p_id)->>'reason');
    p_sources:=p_sources||coalesce((select jsonb_agg(jsonb_build_object('title','City classification source','url',s))
      from jsonb_array_elements_text(public.geo_cms_classification_issue(p_id)->'sources') s),
      '[{"title":"GeoNames classification audit","url":"https://download.geonames.org/export/dump/"}]'::jsonb);
  end if;
$guard$||anchor);
 execute definition;
end $patch$;
