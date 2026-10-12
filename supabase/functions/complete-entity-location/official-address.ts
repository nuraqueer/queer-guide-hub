import { assertPublicHttpUrl } from '../_shared/ssrf-guard.ts'
export interface OfficialAddress { address: string; city: string; country: string; postal_code: string | null }

/** Only organization-scoped JSON-LD, not addresses of products, authors or customers. */
export function extractOfficialAddress(html: string): OfficialAddress | null {
  const found: OfficialAddress[] = []
  const walk = (node: unknown) => {
    if (Array.isArray(node)) { node.forEach(walk); return }
    if (!node || typeof node !== 'object') return
    const n = node as Record<string, unknown>
    const types = [n['@type']].flat().map(String)
    if (types.some(t => ['Organization', 'LocalBusiness', 'Store', 'Hotel', 'NGO', 'Corporation'].includes(t))) {
      const a = n.address as Record<string, unknown> | undefined
      if (a && typeof a === 'object') {
        const country = typeof a.addressCountry === 'string' ? a.addressCountry : (a.addressCountry as Record<string, unknown>)?.name
        if ([a.streetAddress, a.addressLocality, country].every(v => typeof v === 'string' && v.trim())) {
          found.push({ address: String(a.streetAddress).trim(), city: String(a.addressLocality).trim(),
            country: String(country).trim(), postal_code: typeof a.postalCode === 'string' ? a.postalCode.trim() || null : null })
        }
      }
    }
    if (n['@graph']) walk(n['@graph'])
  }
  for (const match of html.matchAll(/<script\b[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    try { walk(JSON.parse(match[1])) } catch { /* malformed JSON-LD is not evidence */ }
  }
  const unique = [...new Map(found.map(a => [JSON.stringify(a), a])).values()]
  return unique.length === 1 ? unique[0] : null
}

export async function fetchOfficialAddress(website: string): Promise<OfficialAddress | null> {
  let url = assertPublicHttpUrl(website.includes('://') ? website : `https://${website}`)
  for (let i = 0; i < 3; i++) {
    const response = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(6000), headers: { 'User-Agent': 'QueerGuide/1.0 (https://queer.guide)' } })
    if (response.status >= 300 && response.status < 400 && response.headers.get('location')) {
      url = assertPublicHttpUrl(new URL(response.headers.get('location')!, url).href)
      await response.body?.cancel()
      continue
    }
    if (!response.ok) throw new Error(`official_site_${response.status}`)
    if (!response.headers.get('content-type')?.includes('text/html')) { await response.body?.cancel(); return null }
    const reader = response.body?.getReader()
    if (!reader) return null
    let bytes = 0, html = ''
    const decoder = new TextDecoder()
    try {
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        bytes += value.byteLength
        if (bytes > 1024 * 1024) return null
        html += decoder.decode(value, { stream: true })
      }
      return extractOfficialAddress(html + decoder.decode())
    } finally { await reader.cancel() }
  }
  return null
}
