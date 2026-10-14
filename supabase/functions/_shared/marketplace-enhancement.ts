import { extractJsonCandidates, parseJsonObject } from './json-extract.ts'

// Workers AI's native endpoint takes the schema directly (no OpenAI name/schema envelope).
export function descriptionResponseFormat(model: string) {
  if (!['@cf/meta/llama-3.1-8b-instruct-fast', '@cf/meta/llama-3.3-70b-instruct-fp8-fast'].includes(model)) return undefined
  return { type: 'json_schema', json_schema: {
    type: 'object', properties: {
      description: { type: 'string' },
      source_lang: { type: 'string', enum: ['de', 'en', 'fr', 'other'] },
    }, required: ['description', 'source_lang'], additionalProperties: false,
  } }
}

export function parseMarketplaceEnhancement(raw: string): { description: string; source_lang: string } {
  for (const candidate of extractJsonCandidates(raw)) {
    const parsed = parseJsonObject(candidate)
    if (!parsed || typeof parsed.description !== 'string' || typeof parsed.source_lang !== 'string') continue
    const description = parsed.description.trim()
    const source_lang = parsed.source_lang.toLowerCase()
    if (description.length < 25 || description.length > 900 || !['de', 'en', 'fr', 'other'].includes(source_lang)) continue
    return { description, source_lang }
  }
  // Never coerce a malformed result into product copy or overwrite the source description.
  throw new Error('Invalid marketplace description output')
}
