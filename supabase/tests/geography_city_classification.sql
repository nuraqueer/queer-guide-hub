-- Run through a database connection as an internal operator. Always rolls back.
begin;
do $test$
declare v_test_id uuid;
begin
 select c.id into strict v_test_id from cities c join geo_places g on g.id=c.id
  where c.duplicate_of_id is null and c.latitude is not null limit 1;
 update cities set field_provenance=coalesce(field_provenance,'{}')||jsonb_build_object('city_place_audit',
  jsonb_build_object('status','review','reason','Classification test','sources',jsonb_build_array('https://www.geonames.org/'),
    'fingerprint',geo_cms_fingerprint(v_test_id))) where id=v_test_id;
 perform geo_cms_verify(v_test_id);
 if (select status from geo_cms_verifications where place_id=v_test_id)<>'review' then
  raise exception 'country check cleared classification issue';
 end if;
 perform geo_cms_record_evidence(v_test_id,geo_cms_fingerprint(v_test_id),
  '{"identity_verified":true,"country_match":true,"coordinates_verified":true,"parent_verified":true}',
  '[{"title":"Test","url":"https://www.wikidata.org/"}]');
 if (select status from geo_cms_verifications where place_id=v_test_id)<>'review' then
  raise exception 'external point check cleared classification issue';
 end if;
 update cities set name=name||' classification test' where id=v_test_id;
 if geo_cms_classification_issue(v_test_id) is not null then
  raise exception 'classification did not become stale after identity change';
 end if;
 if has_function_privilege('anon','public.geo_cms_classification_issue(uuid)','execute')
   or has_function_privilege('authenticated','public.geo_cms_classification_issue(uuid)','execute') then
  raise exception 'classification helper is callable by ordinary clients';
 end if;
end $test$;
rollback;
