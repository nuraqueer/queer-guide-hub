import { countryContradicts, postalContradicts, haversineKm } from '../backfill-venue-cities/geocode-guard.ts'

export interface Feature {
  geometry?: { coordinates?: number[] }
  properties?: Record<string, string>
}
export interface LocationInput {
  address?: string | null
  city?: string | null
  postal_code?: string | null
  latitude?: number | null
  longitude?: number | null
}
const norm = (s?: string | null) => (s || '').normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^\p{L}\p{N}]/gu, '')

/** Require street-level evidence and corroborate locality before storing a pin. */
export function acceptFeature(row: LocationInput, countryCode: string | null, f: Feature, reverse: boolean): boolean {
  const p = f.properties || {}
  const c = f.geometry?.coordinates
  if (!c || c.length < 2 || !c.every(Number.isFinite) || Math.abs(c[0]) > 180 || Math.abs(c[1]) > 90 || (c[0] === 0 && c[1] === 0)) return false
  if (!p.countrycode || countryContradicts(countryCode, p.countrycode) || postalContradicts(row.postal_code, p.postcode)) return false
  if (reverse) return row.latitude != null && row.longitude != null && haversineKm(Number(row.latitude), Number(row.longitude), c[1], c[0]) <= 0.25
  // Settlement and road centroids are never venue coordinates.
  if (!p.street || !p.housenumber) return false
  const street = norm(p.street)
  if (!street || !norm(row.address).includes(street)) return false
  const numbers = (row.address || '').match(/\d+[a-z]?/gi) || []
  if (!numbers.some(n => norm(n) === norm(p.housenumber))) return false
  if (row.city && ![p.city, p.district, p.name].some(s => norm(s) === norm(row.city))) return false
  // Country alone is insufficient to distinguish identically named streets.
  return !!row.city || !!row.postal_code || (!!p.city && norm(row.address).includes(norm(p.city)))
}

export function selectFeature(row: LocationInput, countryCode: string | null, features: Feature[], reverse: boolean): Feature | undefined {
  const candidates = features.filter(f => acceptFeature(row, countryCode, f, reverse))
  // A nearby waterway/road often ranks first with no postcode. Prefer a validated
  // address result carrying the missing field instead of treating that first hit as final.
  return (!row.postal_code ? candidates.find(f => f.properties?.postcode?.trim()) : undefined) || candidates[0]
}
