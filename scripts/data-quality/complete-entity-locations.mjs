#!/usr/bin/env node
// Resumable production backfill. Credentials stay in memory; no service key is logged.
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { selectFeature } from '../../supabase/functions/complete-entity-location/evidence.ts';
const require = createRequire(import.meta.url);
const tzlookup = require(process.env.LOCATION_TZ_MODULE || 'tz-lookup');
const PROJECT = 'xqeacpakadqfxjxjcewc';
const raw = process.env.SUPABASE_PAT || execFileSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8' }).trim();
const token = raw.startsWith('go-keyring-base64:') ? Buffer.from(raw.slice(18), 'base64').toString('utf8') : raw;
const q = value => `'${String(value).replaceAll("'", "''")}'`;
const sleep = ms => new Promise(r => setTimeout(r, ms));
export async function sql(query, attempt = 0) {
  let r;
  try { r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query }),
    signal: AbortSignal.timeout(120000),
  }); } catch (e) { if (attempt >= 12) throw e; console.log('SQL network retry', attempt + 1); await sleep(Math.min(30000, 2000 * 2 ** attempt)); return sql(query, attempt + 1); }
  if ((r.status === 429 || r.status >= 500) && attempt < 5) { await sleep(2000 * 2 ** attempt); return sql(query, attempt + 1); }
  if (!r.ok) {
    const message = (await r.text()).slice(0, 1000);
    if (/40P01|40001|deadlock detected/.test(message) && attempt < 5) { await sleep(2000 * 2 ** attempt); return sql(query, attempt + 1); }
    throw new Error(`SQL ${r.status}: ${message}`);
  }
  return r.json();
}
const TABLES = ['venues', 'hotels', 'organizations'];
const gaps = async () => sql(TABLES.map(t => `select ${q(t)} entity,count(*) total,
 count(*) filter(where country_id is null) country,count(*) filter(where city_id is null) city,
 count(*) filter(where nullif(trim(postal_code),'') is null) postal,
 count(*) filter(where latitude is null or longitude is null) coordinates,
 count(*) filter(where nullif(trim(timezone),'') is null) timezone
 from public.${t} where duplicate_of_id is null`).join(' union all '));
const out = process.env.LOCATION_REPORT_DIR || resolve('outputs/entity-location-completion');
mkdirSync(out, { recursive: true });

if (process.argv.includes('--country-repair')) {
  const result = [];
  const norm = s => (s || '').normalize('NFKD').replace(/\p{M}/gu,'').toLowerCase().replace(/[^\p{L}\p{N}]/gu,'');
  for (const table of ['venues','events','hotels']) {
      const rows = await sql(`select t.*,old_co.code old_country,expected.id expected_country_id,expected.code expected_code,
        c.latitude linked_city_latitude,c.longitude linked_city_longitude,
        (select iso_a2 from public.geo_country_at(t.latitude::numeric,t.longitude::numeric,0) where match_kind='contains' limit 1) point_country,
        public.entity_location_fingerprint(to_jsonb(t)) fingerprint from public.${table} t
      join public.countries old_co on old_co.id=t.country_id
      join public.countries expected on expected.code=upper(trim(t.country)) and expected.duplicate_of_id is null
      left join public.cities c on c.id=t.city_id
      where t.duplicate_of_id is null and expected.id<>t.country_id and not public.geo_countries_equivalent(old_co.code,expected.code)
      order by t.id`);
    for (const row of rows) {
      const coords = row.latitude != null && row.longitude != null;
      const url = coords ? `https://photon.komoot.io/reverse?lat=${row.latitude}&lon=${row.longitude}&lang=en&limit=5`
        : `https://photon.komoot.io/api?q=${encodeURIComponent([row.address,row.postal_code,row.city].filter(Boolean).join(', '))}&lang=en&limit=5&countrycode=${row.expected_code.toLowerCase()}`;
      let item = { table,id:row.id,name:row.name || row.title,from:row.old_country,to:row.expected_code };
      try {
        const response = await fetch(url,{ headers:{'User-Agent':'QueerGuide/1.0 (https://queer.guide)'},signal:AbortSignal.timeout(10000) });
        if (!response.ok) throw new Error(`photon_${response.status}`);
        const data = await response.json();
        let hit = coords && row.point_country && row.point_country !== row.expected_code
          ? undefined : selectFeature(row,row.expected_code,data.features || [],coords);
        // A named island polygon can be country evidence without being a street-level pin.
        if (!hit && coords) hit = (data.features || []).find(f => {
          const p=f.properties || {},ext=p.extent;
          return p.countrycode?.toUpperCase()===row.expected_code && p.osm_value==='island'
            && norm(p.name)===norm(row.name || row.title) && Array.isArray(ext) && ext.length===4
            && Number(row.longitude)>=ext[0] && Number(row.longitude)<=ext[2] && Number(row.latitude)>=ext[3] && Number(row.latitude)<=ext[1];
        });
        let derivedPinCorrection=false;
        if (!hit && coords && row.linked_city_latitude != null && row.linked_city_longitude != null
          && Math.abs(Number(row.latitude)-Number(row.linked_city_latitude))<0.002
          && Math.abs(Number(row.longitude)-Number(row.linked_city_longitude))<0.002 && row.address && /\d/.test(row.address)) {
          // This is a city-centroid pin, not a source-supplied venue position. Only a
          // verified street/house/locality match in the source country may replace it.
          const forwardUrl=`https://photon.komoot.io/api?q=${encodeURIComponent([row.address,row.postal_code,row.city].filter(Boolean).join(', '))}&lang=en&limit=5&countrycode=${row.expected_code.toLowerCase()}`;
          await sleep(1100);
          const forward=await fetch(forwardUrl,{headers:{'User-Agent':'QueerGuide/1.0 (https://queer.guide)'},signal:AbortSignal.timeout(10000)});
          if (!forward.ok) throw new Error(`photon_${forward.status}`);
          const body=await forward.json();
          hit=selectFeature(row,row.expected_code,body.features || [],false);
          if (hit) { derivedPinCorrection=true; item.evidence_url=forwardUrl; }
        }
        if (!hit) item.outcome='not_corroborated';
        else {
          const [lon,lat]=hit.geometry.coordinates;
          const targetLat=derivedPinCorrection ? lat : Number(row.latitude ?? lat),targetLon=derivedPinCorrection ? lon : Number(row.longitude ?? lon);
          const city = row.city ? await sql(`select * from public.city_resolve_or_create(p_name:=${q(row.city)},p_country_code:=${q(row.expected_code)},
            p_lat:=${targetLat},p_lng:=${targetLon},p_region_hint:=${hit.properties.state ? q(hit.properties.state) : 'null'},p_allow_create:=false,p_source_slug:='photon-country-repair',p_actor:='country-repair')`) : [];
          const cityId=city[0]?.action==='matched' ? city[0].city_id : null;
          const proof={countrycode:row.expected_code,source_url:item.evidence_url || url,source_country_text:row.country,geocoder:hit.properties,
            replace_derived_pin:derivedPinCorrection,verified_at:new Date().toISOString()};
          const timezone=tzlookup(targetLat,targetLon);
          const corrected=await sql(`select public.correct_entity_location_country(${q(table)},${q(row.id)}::uuid,${q(row.fingerprint)},
            ${q(row.country_id)}::uuid,${q(row.expected_country_id)}::uuid,${cityId ? q(cityId)+'::uuid' : 'null'},${q(JSON.stringify(proof))}::jsonb,
            ${coords && !derivedPinCorrection ? 'null' : Number(lat)},${coords && !derivedPinCorrection ? 'null' : Number(lon)},${q(timezone)}) result`);
          item={...item,...corrected[0].result,outcome:corrected[0].result.corrected ? 'corrected' : 'unchanged'};
        }
      } catch(e) { item.outcome='error'; item.error=String(e).slice(0,500); }
      result.push(item); console.log('country repair',JSON.stringify(item));
      writeFileSync(`${out}/country-repair.json`,JSON.stringify(result,null,2));
      await sleep(1100);
    }
  }
}

if (process.argv.includes('--official-evidence')) {
  const evidence = JSON.parse(readFileSync(new URL('./entity-location-official-evidence.json', import.meta.url), 'utf8'));
  for (const item of evidence) {
    const orgs = await sql(`select o.*,public.entity_location_fingerprint(to_jsonb(o)) fingerprint from public.affiliate_partners p join public.organizations o on o.id=p.organization_id
      where lower(p.partner_name)=lower(${q(item.partner)}) and o.duplicate_of_id is null`);
    if (orgs.length !== 1) { console.log('official refused ambiguous identity', item.partner); continue; }
    const org = orgs[0];
    const countries = await sql(`select id from public.countries where code=${q(item.country)} and duplicate_of_id is null`);
    if (countries.length !== 1 || org.country_id && org.country_id !== countries[0].id
      || org.address?.trim() && org.address.trim().toLowerCase() !== item.address.toLowerCase()) {
      console.log('official refused conflicting address', item.partner); continue;
    }
    const resolved = await sql(`select * from public.city_resolve_or_create(p_name:=${q(item.city)},p_country_code:=${q(item.country)},p_source_slug:='official-company-address',p_actor:='entity-location-backfill')`);
    const cityId = resolved[0]?.action !== 'refused' ? resolved[0]?.city_id : null;
    if (org.city_id && cityId && org.city_id !== cityId) { console.log('official refused conflicting city', item.partner); continue; }
    const patch = { address: item.address, country_id: countries[0].id, postal_code: item.postal_code };
    if (cityId) patch.city_id = cityId;
    const result = await sql(`select public.apply_entity_location('organizations',${q(org.id)}::uuid,${q(org.fingerprint)},${q(JSON.stringify(patch))}::jsonb,${q(item.source)}) result`);
    console.log('official', item.partner, JSON.stringify(result.map(r => ({ filled: r.result.filled, stale: r.result.stale }))));
  }
}

if (process.argv.includes('--prepare')) {
  const before = await gaps();
  writeFileSync(`${out}/before-${Date.now()}.json`, JSON.stringify(before, null, 2));
  console.log('before', JSON.stringify(before));
  // Touch only timezone: does not fire the old address/coordinate geocoder.
  // The new source sync trigger also fills the associated organisation immediately.
  for (const table of TABLES) {
    let cursor = table === 'venues' ? (process.env.LOCATION_VENUE_CURSOR || '00000000-0000-0000-0000-000000000000') : '00000000-0000-0000-0000-000000000000', processed = 0;
    for (;;) {
      const rows = await sql(`select id,latitude,longitude,city_id from public.${table}
        where duplicate_of_id is null and id>${q(cursor)}::uuid
        ${table === 'organizations' ? "and nullif(trim(timezone),'') is null and (latitude is not null or exists(select 1 from public.cities c where c.id=city_id and c.timezone is not null))" : ''}
        order by id limit 500`);
      if (!rows.length) break;
      const values = rows.map(r => {
        let tz = null;
        if (r.latitude != null && r.longitude != null && !(Number(r.latitude) === 0 && Number(r.longitude) === 0)) {
          try { tz = tzlookup(Number(r.latitude), Number(r.longitude)); } catch { /* malformed coordinates stay unfilled */ }
        }
        return `(${q(r.id)}::uuid,${tz ? q(tz) : 'null'}::text)`;
      }).join(',');
      await sql(`begin; select set_config('app.location_backfill','on',true); with batch(id,tz) as(values ${values}) update public.${table} t
        set timezone=coalesce(nullif(trim(t.timezone),''),b.tz,(select nullif(timezone,'') from public.cities where id=t.city_id))
        from batch b where t.id=b.id; commit;`);
      cursor = rows.at(-1).id; processed += rows.length;
      console.log('inherit/timezone', table, processed, cursor);
    }
  }
  // Direct queue seeding avoids updating address and firing thousands of legacy HTTP webhooks.
  for (const table of TABLES) {
    const seeded = await sql(`insert into public.entity_location_jobs(entity_table,entity_id,fingerprint,priority)
      select ${q(table)},id,public.entity_location_fingerprint(to_jsonb(t)),${table === 'venues' ? 10 : 5} from public.${table} t
      where duplicate_of_id is null ${table === 'organizations' ? 'and primary_venue_id is null' : ''}
        and (country_id is null or city_id is null or nullif(trim(postal_code),'') is null or latitude is null or longitude is null or nullif(trim(timezone),'') is null)
        and (nullif(trim(address),'') is not null or (latitude is not null and longitude is not null) or nullif(trim(website),'') is not null)
      on conflict(entity_table,entity_id) do nothing returning entity_id`);
    console.log('seeded', table, seeded.length);
  }
  const after = await gaps();
  writeFileSync(`${out}/after-inheritance.json`, JSON.stringify(after, null, 2));
  console.log('after inheritance', JSON.stringify(after));
}
if (process.argv.includes('--timezone-residue')) {
  for (const table of TABLES) {
    let cursor = '00000000-0000-0000-0000-000000000000', filled = 0;
    for (;;) {
      const rows = await sql(`select t.id,case when t.latitude is not null and t.longitude is not null then t.latitude else c.latitude end latitude,
        case when t.latitude is not null and t.longitude is not null then t.longitude else c.longitude end longitude
        from public.${table} t left join public.cities c on c.id=t.city_id
        where t.duplicate_of_id is null and t.id>${q(cursor)}::uuid and nullif(trim(t.timezone),'') is null
        and ((t.latitude is not null and t.longitude is not null) or (c.latitude is not null and c.longitude is not null))
        order by t.id limit 500`);
      if (!rows.length) break;
      const values = rows.flatMap(r => {
        try { if (Number(r.latitude) === 0 && Number(r.longitude) === 0) return [];
          return [`(${q(r.id)}::uuid,${q(tzlookup(Number(r.latitude),Number(r.longitude)))}::text)`];
        } catch { return []; }
      });
      if (values.length) await sql(`begin; select set_config('app.location_backfill','on',true);
        with batch(id,tz) as(values ${values.join(',')}) update public.${table} t set timezone=b.tz from batch b
        where t.id=b.id and nullif(trim(t.timezone),'') is null; commit;`);
      cursor = rows.at(-1).id; filled += values.length;
      console.log('timezone residue', table, filled, cursor);
    }
  }
  // These cannot pass the street-and-house-number guard. Remember the outcome rather than
  // making thousands of calls that could only return a city/street centroid.
  for (const table of TABLES) {
    const result = await sql(`with parked as(update public.entity_location_jobs j set status='no_match',last_error='insufficient_street_address',updated_at=now()
      from public.${table} t where j.entity_table=${q(table)} and j.entity_id=t.id and j.status='pending'
      and (t.latitude is null or t.longitude is null) and nullif(trim(t.address),'') is not null and t.address !~ '[0-9]'
      and t.country_id is not null and t.city_id is not null and nullif(trim(t.timezone),'') is not null returning j.entity_id)
      select count(*) parked from parked`);
    console.log('insufficient street address',table,result[0].parked);
  }
}
if (process.argv.includes('--drain')) {
  const [{ secret }] = await sql("select decrypted_secret secret from vault.decrypted_secrets where name='WEBHOOK_SECRET'");
  if (!secret) throw new Error('Missing webhook secret');
  for (;;) {
    const [state] = await sql(`select count(*) filter(where status in ('pending','running') or (status='error' and attempts<4)) remaining,
      count(*) filter(where status='no_match') no_match,count(*) filter(where status='done') done,
      count(*) filter(where status='error' and attempts>=4) failed from public.entity_location_jobs`);
    console.log('queue', JSON.stringify(state));
    if (!Number(state.remaining)) break;
    try {
      const r = await fetch(`https://${PROJECT}.supabase.co/functions/v1/complete-entity-location`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'x-webhook-secret': secret }, body: '{"bulk":true}', signal: AbortSignal.timeout(140000),
      });
      const body = await r.text();
      if (!r.ok) throw new Error(`Worker ${r.status}: ${body.slice(0, 200)}`);
      const response = JSON.parse(body);
      console.log('worker', JSON.stringify(response));
      await sleep(response.processed ? 1500 : 15000);
    } catch (error) {
      console.log('worker retry', String(error).slice(0, 250));
      await sleep(30000);
    }
  }
}
console.log('gaps', JSON.stringify(await gaps()));
