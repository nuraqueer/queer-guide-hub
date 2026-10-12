#!/usr/bin/env node
// Apply only the frozen, sourced correction plan. Default is a full rollback
// rehearsal; --apply commits. merge_cities keeps source rows and an undo journal.
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const file =
  process.argv.find((x) => x.endsWith('.json')) ??
  'scripts/data-quality/out/city-settlement-audit/reviewed-plan.json';
const fullPlan = JSON.parse(readFileSync(file, 'utf8'));
const literal = (s) => `'${String(s).replaceAll("'", "''")}'`;
const batches = [];
for (const kind of ['qids', 'merges', 'flags']) {
  const size = kind === 'flags' ? 100 : 20;
  for (let i = 0; i < fullPlan[kind].length; i += size)
    batches.push({ qids: [], merges: [], flags: [], [kind]: fullPlan[kind].slice(i, i + size) });
}
let token = process.env.SUPABASE_PAT;
if (!token) {
  const raw = execFileSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], {
    encoding: 'utf8',
  }).trim();
  token = Buffer.from(raw.replace(/^go-keyring-base64:/, ''), 'base64').toString('utf8');
}
for (const plan of batches) {
  const payload = literal(JSON.stringify(plan));
  const query = `begin;
set local statement_timeout='180s';
select set_config('app.actor','city-settlement-audit:2026-10-12',true);
create temp table _city_audit_plan(data jsonb) on commit drop;
insert into _city_audit_plan values(${payload}::jsonb);
create temp table _city_audit_result(kind text,city_id uuid,details jsonb) on commit drop;
do $apply$
declare p jsonb; c public.cities; k public.cities; result jsonb; before jsonb; evidence jsonb; v_audit uuid; v_alias boolean; v_distance numeric;
begin
  -- Identifier repairs change no city name, country, or coordinates.
  for p in select value from jsonb_array_elements((select data from _city_audit_plan)->'qids') loop
    select * into strict c from public.cities where id=(p->>'id')::uuid for update;
    if c.duplicate_of_id is not null then continue; end if;
    if c.wikidata_qid=p->'correction'->>'to' then continue; end if;
    if c.updated_at is distinct from (p->>'expected_updated_at')::timestamptz
       or c.name is distinct from p->>'name' or c.country_id is distinct from (p->>'expected_country_id')::uuid
       or c.wikidata_qid is distinct from p->'correction'->>'from' then
      raise exception 'City changed since review: %', c.name;
    end if;
    if exists(select 1 from cities where duplicate_of_id is null and wikidata_qid=p->'correction'->>'to' and id<>c.id) then
      raise exception 'Target Wikidata identity already used: %', c.name;
    end if;
    before:=jsonb_build_object('wikidata_qid',c.wikidata_qid,'city_place_audit',c.field_provenance->'city_place_audit');
    update cities set wikidata_qid=p->'correction'->>'to',
      field_provenance=coalesce(field_provenance,'{}'::jsonb)||jsonb_build_object('city_place_audit',
        jsonb_build_object('at',now(),'status',p->>'status','reason',p->>'reason','classes',p->'classes','sources',p->'sources','before',before)),updated_at=now()
      where id=c.id;
    insert into _city_audit_result values('qid',c.id,jsonb_build_object('from',c.wikidata_qid,'to',p->'correction'->>'to'));
  end loop;
  for p in select value from jsonb_array_elements((select data from _city_audit_plan)->'merges') loop
    select * into strict c from cities where id=(p->>'id')::uuid for update;
    select * into strict k from cities where id=(p->'parent'->>'id')::uuid for update;
    if c.duplicate_of_id=k.id then continue; end if;
    if c.duplicate_of_id is not null or k.duplicate_of_id is not null or c.country_id<>k.country_id
       or c.name is distinct from p->>'name' or c.country_id is distinct from (p->>'expected_country_id')::uuid
       or c.updated_at is distinct from (p->>'expected_updated_at')::timestamptz then
      raise exception 'Merge changed since review: %', c.name;
    end if;
    v_distance:=public.haversine_m(c.latitude,c.longitude,k.latitude,k.longitude);
    if v_distance is null or v_distance>50000 then raise exception 'Parent too far for reviewed locality: %',c.name; end if;
    -- No broad same-country name alias: locality names collide with real towns.
    insert into city_localities(country_id,locality_name,locality_qid,kind,municipality_name,municipality_qid,anchor_lat,anchor_lng,radius_m,source,note)
      values(c.country_id,c.name,p->>'evidence_qid','quarter',k.name,k.wikidata_qid,c.latitude,c.longitude,
        least(25000,greatest(5000,ceil(v_distance+1000)::int)),
        'city-settlement-audit:2026-10-12',concat('Source city ',c.id,'; ',(p->'sources')::text)) on conflict do nothing;
    result:=public.merge_cities(k.id,c.id,false);v_audit:=(result->>'audit_id')::uuid;
    select (details->>'alias_minted')::boolean into v_alias from city_merge_audit where id=v_audit;
    if v_alias then
      delete from city_aliases where city_id=k.id and alias_key=public.city_canonical_key(c.name);
      update city_merge_audit set details=jsonb_set(details,'{alias_minted}','false'::jsonb)
        ||jsonb_build_object('city_place_audit',jsonb_build_object('sources',p->'sources','classes',p->'classes','unsafe_alias_removed',true)) where id=v_audit;
    else
      update city_merge_audit set details=details||jsonb_build_object('city_place_audit',jsonb_build_object('sources',p->'sources','classes',p->'classes')) where id=v_audit;
    end if;
    update cities set wikidata_qid=p->>'evidence_qid',field_provenance=coalesce(field_provenance,'{}'::jsonb)||jsonb_build_object('city_place_audit',
      jsonb_build_object('at',now(),'before_wikidata_qid',c.wikidata_qid,'status','subdivision','canonical_city_id',k.id,'evidence_qid',p->>'evidence_qid','sources',p->'sources','merge_audit_id',v_audit)) where id=c.id;
    -- Check the relationships the existing merge contract promises to move.
    if exists(select 1 from venues where city_id=c.id) or exists(select 1 from events where city_id=c.id)
      or exists(select 1 from hotels where city_id=c.id) or exists(select 1 from queer_villages where city_id=c.id)
      or exists(select 1 from organizations where city_id=c.id) then raise exception 'References left on merged locality: %',c.name; end if;
    insert into _city_audit_result values('merge',c.id,result);
  end loop;
  -- An unresolved external match is not evidence that a city does not exist.
  -- Keep its publication and location fields; expose an editorial review flag.
  for p in select value from jsonb_array_elements((select data from _city_audit_plan)->'flags') loop
    select * into c from cities where id=(p->>'id')::uuid for update;
    if not found or c.duplicate_of_id is not null then continue; end if;
    if c.updated_at is distinct from (p->>'expected_updated_at')::timestamptz then
      insert into _city_audit_result values('flag_skipped_changed',c.id,'{}');continue;
    end if;
    before:=jsonb_build_object('needs_attention',c.needs_attention,'city_place_audit',c.field_provenance->'city_place_audit');
    update cities set needs_attention=true,field_provenance=coalesce(field_provenance,'{}'::jsonb)||jsonb_build_object('city_place_audit',
      jsonb_build_object('at',now(),'status',p->>'status','reason',p->>'reason','classes',p->'classes','sources',p->'sources','before',before,'fingerprint',public.geo_cms_fingerprint(c.id))),updated_at=now() where id=c.id;
    insert into geo_cms_verifications(place_id,status,fingerprint,checks,sources)
      select c.id,'review',public.geo_cms_fingerprint(c.id),
        coalesce((select checks from geo_cms_verifications where place_id=c.id),'{}')||
          jsonb_build_object('identity_verified',false,'city_classification',p->>'status','reason',p->>'reason'),
        coalesce((select sources from geo_cms_verifications where place_id=c.id),'[]')||
          coalesce((select jsonb_agg(jsonb_build_object('title','City classification source','url',s)) from jsonb_array_elements_text(p->'sources')s),
          '[{"title":"GeoNames classification audit","url":"https://download.geonames.org/export/dump/"}]'::jsonb)
      where exists(select 1 from geo_places where id=c.id)
      on conflict(place_id) do update set status=excluded.status,fingerprint=excluded.fingerprint,checks=excluded.checks,sources=excluded.sources,checked_at=now();
    insert into _city_audit_result values('review_flag',c.id,'{}');
  end loop;
end $apply$;
select kind,count(*) from _city_audit_result group by kind order by kind;
${process.argv.includes('--apply') ? 'commit' : 'rollback'};`;

  const r = await fetch(
    'https://api.supabase.com/v1/projects/xqeacpakadqfxjxjcewc/database/query',
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query }),
      signal: AbortSignal.timeout(240000),
    },
  );
  if (!r.ok) throw Error(`Correction transaction ${r.status}: ${(await r.text()).slice(0, 500)}`);
  console.log(process.argv.includes('--apply') ? 'COMMITTED' : 'ROLLED BACK', await r.json());
}
