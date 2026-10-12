#!/usr/bin/env node
// Read-only corpus audit. Inputs are frozen DB rows, a full GeoNames dump match,
// its hierarchy, and cached Wikidata claims. Corrections require reviewed IDs.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  normalizePlaceName as norm,
  distanceMeters,
  classifyClasses,
  classifyEvidence,
  usableMatches,
  SETTLEMENT_CODES,
} from './lib/city-settlement-audit.mjs';
const dir = process.argv[2];
if (!dir)
  throw Error('Usage: node scripts/data-quality/audit-city-settlements.mjs <input-directory>');
const read = (n) => JSON.parse(readFileSync(join(dir, n), 'utf8'));
const cities = read('cities.json').filter((c) => !c.duplicate_of_id);
const geo = new Map(read('geonames-audit.json').map((x) => [x.id, x]));
const raw = read('wikidata.json'),
  classLabels = read('wikidata-classes.json'),
  mapped = read('geonames-wikidata.json');
const entities = new Map();
for (const [id, e] of Object.entries(raw))
  entities.set(id, {
    ...e,
    classes: e.classes.map((q) => classLabels[q]?.label ?? q),
    points: e.coords.map((c) => [c.latitude, c.longitude]),
  });
for (const es of Object.values(mapped))
  for (const e of es) {
    if (!entities.has(e.id))
      entities.set(e.id, {
        ...e,
        classes: e.classes.map((c) => c.label ?? c.id),
        points: e.points
          .map((p) => {
            const m = p.match(/Point\(([-\d.]+) ([-\d.]+)\)/);
            return m ? [Number(m[2]), Number(m[1])] : null;
          })
          .filter(Boolean),
      });
  }
const names = (c) =>
  [c.name, c.name_en, c.name_de, c.name_local, ...Object.values(c.name_i18n ?? {})]
    .filter((x) => typeof x === 'string')
    .map(norm);
const known = new Map(cities.filter((c) => c.wikidata_qid).map((c) => [c.wikidata_qid, c]));
const kind = (e) => classifyClasses(e?.classes ?? [], e?.description ?? '');
const audit = [];
for (const c of cities) {
  const g = usableMatches(geo.get(c.id) ?? { matches: [] }),
    existing = entities.get(c.wikidata_qid),
    keys = names(c);
  const distances = (e, lat = c.latitude, lng = c.longitude) =>
    e?.points?.map((p) => distanceMeters(lat, lng, ...p)).filter((x) => x !== null) ?? [];
  const pin = existing ? distances(existing) : [];
  const labelMatch =
    existing &&
    [existing.label, ...Object.values(existing.labels ?? {})]
      .filter((x) => typeof x === 'string')
      .some((n) => keys.includes(norm(n)));
  const oldLinked = existing && g.some((x) => existing.geonames?.includes(x.id));
  const oldIdentity =
    existing && (labelMatch || oldLinked) && (!pin.length || Math.min(...pin) <= 25000);
  const candidates = [];
  for (const match of g)
    for (const item of mapped[match.id] ?? []) {
      const e = entities.get(item.id);
      const ds = distances(e, match.lat, match.lng);
      if (ds.length && Math.min(...ds) > 15000) continue;
      if (![match.name, match.ascii].some((n) => keys.includes(norm(n)))) continue;
      candidates.push({ entity: e, match });
    }
  // A current legal municipality overrides a gazetteer PPLX code. Other ambiguous
  // identities require an exact gazetteer ID plus an independent coordinate.
  const municipal = candidates.filter((x) => kind(x.entity) === 'municipality');
  const uniqueMunicipal = [...new Map(municipal.map((x) => [x.entity.id, x])).values()];
  let chosen = oldIdentity ? existing : null,
    via = null;
  if (
    uniqueMunicipal.length === 1 &&
    (!chosen ||
      ['subdivision', 'mixed_subdivision', 'administrative_area', 'nonplace'].includes(
        kind(chosen),
      ))
  ) {
    chosen = uniqueMunicipal[0].entity;
    via = uniqueMunicipal[0].match;
  }
  if (!chosen) {
    const plausible = candidates.filter((x) =>
      ['subdivision', 'mixed_subdivision', 'settlement'].includes(kind(x.entity)),
    );
    const uniq = [...new Map(plausible.map((x) => [x.entity.id, x])).values()];
    if (uniq.length === 1) {
      chosen = uniq[0].entity;
      via = uniq[0].match;
    }
  }
  const decision = classifyEvidence({
    classes: chosen?.classes,
    description: chosen?.description,
    geonames: g,
  });
  const identityIssue = !!existing && !oldIdentity;
  let correction = null;
  if (
    chosen &&
    chosen.id !== c.wikidata_qid &&
    c.wikidata_qid &&
    ['municipality', 'settlement'].includes(kind(chosen)) &&
    via
  )
    correction = { type: 'qid', from: c.wikidata_qid, to: chosen.id, geonames_id: via.id };
  let parent = null;
  const sources = g.slice(0, 3).map((x) => `https://www.geonames.org/${x.id}`);
  if (chosen) sources.push(`https://www.wikidata.org/wiki/${chosen.id}`);
  audit.push({
    id: c.id,
    name: c.name,
    country: c.country_code,
    status: decision.status,
    reason: decision.reason,
    identity_issue: identityIssue,
    qid: c.wikidata_qid,
    evidence_qid: chosen?.id ?? null,
    classes: chosen?.classes ?? [],
    geonames: g.map((x) => ({ id: x.id, code: x.code, distance_m: Math.round(x.distance_m) })),
    parent,
    correction,
    sources,
  });
}
// Resolve parent cities only after every record has been classified. This also
// discovers canonical parents whose original row had no Wikidata ID.
const cityById = new Map(cities.map((c) => [c.id, c]));
// A municipality seat and its municipality may have separate Wikidata items
// but the same public name. Correct the identifier rather than removing the city.
for (const x of audit)
  if (x.status === 'non_city') {
    const c = cityById.get(x.id),
      e = entities.get(x.evidence_qid);
    const parents = (e?.parents ?? []).map((q) => entities.get(q)).filter(Boolean);
    const sameName = parents.filter(
      (p) =>
        kind(p) === 'municipality' &&
        [p.label, ...Object.values(p.labels ?? {})].some((n) => names(c).includes(norm(n))) &&
        p.points.some((point) => {
          const d = distanceMeters(c.latitude, c.longitude, ...point);
          return d !== null && d <= 25000;
        }),
    );
    if (sameName.length === 1) {
      const p = sameName[0];
      x.status = 'municipality';
      x.reason =
        'Municipality seat and municipality share the name; canonical municipality identifier corrected';
      x.evidence_qid = p.id;
      x.classes = p.classes;
      x.correction = {
        type: 'qid',
        from: c.wikidata_qid,
        to: p.id,
        via: x.qid,
        geonames_id: x.geonames[0]?.id,
      };
      x.sources.push(`https://www.wikidata.org/wiki/${p.id}`);
    }
  }
const inferred = new Map();
for (const x of audit)
  if (x.evidence_qid && ['municipality', 'settlement'].includes(x.status)) {
    const a = inferred.get(x.evidence_qid) ?? [];
    a.push(cityById.get(x.id));
    inferred.set(x.evidence_qid, a);
  }
for (const x of audit)
  if (x.status === 'non_city') {
    const c = cityById.get(x.id),
      e = entities.get(x.evidence_qid);
    if (!e) continue;
    let frontier = e.parents ?? [];
    const visited = new Set();
    for (let level = 0; level < 4 && !x.parent; level++) {
      const options = [],
        next = [];
      for (const q of frontier) {
        if (visited.has(q)) continue;
        visited.add(q);
        const parent = entities.get(q);
        if (!parent) continue;
        const k = kind(parent),
          existing = known.get(q),
          isCanonical = existing && audit.find((a) => a.id === existing.id)?.evidence_qid === q;
        const candidates = isCanonical ? [existing] : (inferred.get(q) ?? []);
        const eligible = candidates.filter((a) => a.country_id === c.country_id && a.id !== c.id);
        if (k === 'municipality' && eligible.length === 1)
          options.push({ id: eligible[0].id, name: eligible[0].name, qid: q, level: level + 1 });
        else if (!['municipality', 'settlement'].includes(k)) next.push(...(parent.parents ?? []));
      }
      const uniq = [...new Map(options.map((a) => [a.id, a])).values()];
      if (uniq.length === 1) x.parent = uniq[0];
      else if (uniq.length > 1) break;
      frontier = next;
    }
  }
// GeoNames records an explicit populated-place hierarchy where Wikidata uses
// administrative containers (London borough -> Greater London, not London city).
const hierarchyCandidates = read('pplx-candidates.json');
const hierarchy = new Map(hierarchyCandidates.map((x) => [x.id, x]));
for (const x of audit)
  if (x.status === 'non_city' && !x.parent) {
    const c = cityById.get(x.id),
      h = hierarchy.get(x.id);
    if (!h) continue;
    const options = [];
    for (const g of h.matches)
      for (const gp of g.parents ?? []) {
        if (!SETTLEMENT_CODES.has(gp.code) || gp.country !== c.country_code) continue;
        const matches = audit.filter(
          (a) => a.id !== x.id && a.country === x.country && a.geonames.some((n) => n.id === gp.id),
        );
        for (const parent of matches) {
          if (parent.status === 'municipality')
            options.push({
              id: parent.id,
              name: parent.name,
              qid: parent.evidence_qid,
              level: 1,
              geonames_parent: gp.id,
            });
          else if (parent.status === 'non_city' && parent.parent)
            options.push({ ...parent.parent, geonames_parent: gp.id });
        }
      }
    const unique = [...new Map(options.map((p) => [p.id, p])).values()];
    if (unique.length === 1) {
      const p = unique[0],
        e = entities.get(x.evidence_qid);
      const context = [e?.description, ...(e?.classes ?? [])].join(' ').toLowerCase();
      if (context.includes(p.name.toLowerCase())) x.parent = p;
    }
  }
writeFileSync(join(dir, 'city-classification-audit.json'), JSON.stringify(audit, null, 2));
const counts = {};
for (const x of audit) counts[x.status] = (counts[x.status] ?? 0) + 1;
console.log(
  JSON.stringify(
    {
      total: audit.length,
      statuses: counts,
      noncity: audit.filter((x) => x.status === 'non_city').length,
      parented: audit.filter((x) => x.parent).length,
      qid_repairs: audit.filter((x) => x.correction).length,
      identity_issues: audit.filter((x) => x.identity_issue).length,
    },
    null,
    2,
  ),
);
console.log(
  audit
    .filter((x) => x.parent)
    .map((x) => `${x.country}: ${x.name} → ${x.parent.name}`)
    .slice(0, 70)
    .join('\n'),
);
const quote = (x) => '"' + String(x ?? '').replaceAll('"', '""') + '"';
const header = [
  'id',
  'name',
  'country',
  'status',
  'reason',
  'wikidata_qid',
  'evidence_qid',
  'classes',
  'parent_city',
  'sources',
];
writeFileSync(
  join(dir, 'city-classification-audit.csv'),
  [
    header.map(quote).join(','),
    ...audit.map((x) =>
      [
        x.id,
        x.name,
        x.country,
        x.status,
        x.reason,
        x.qid,
        x.evidence_qid,
        x.classes.join('; '),
        x.parent?.name,
        x.sources.join('; '),
      ]
        .map(quote)
        .join(','),
    ),
  ].join('\n'),
);
