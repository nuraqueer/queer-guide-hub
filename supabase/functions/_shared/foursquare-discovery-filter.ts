/** Search ranking and search terms are never independent discovery evidence.
 * Known canonical identities may still receive source updates. New discoveries
 * need an explicit signal before entering the independent-review workflow.
 */
export function hasFoursquareDiscoveryEvidence(place: Record<string, unknown>): boolean {
  const social = place.social_media as Record<string, unknown> | undefined
  const categories = Array.isArray(place.categories) ? place.categories.map(c => typeof c === 'string' ? c : (c as Record<string, unknown> | null)?.name) : []
  const labels = Array.isArray(place.fsq_category_labels) ? place.fsq_category_labels : []
  const tastes = Array.isArray(place.tastes) ? place.tastes : []
  const values = [place.name, place.description, place.website, place.instagram, social?.instagram, ...categories, ...labels, ...tastes]
  const explicit = /\b(lgbt(?:q(?:ia?)?|iq?)?|queer|gay|lesbian|transgender|bisexual|drag|leather\s*(bar|club))\b/i
  return values.some(value => typeof value === 'string' && explicit.test(value))
}
export function filterFoursquareDiscoveries<T extends { sourceId: string; data: Record<string, unknown> }>(items: T[], existing: ReadonlySet<string>): T[] {
  return items.filter(item => existing.has(item.sourceId) || hasFoursquareDiscoveryEvidence(item.data))
}
