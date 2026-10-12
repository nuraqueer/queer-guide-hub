import { test } from 'node:test'
import assert from 'node:assert/strict'
import { extractOfficialAddress } from './official-address.ts'
const org = { '@type': 'Organization', address: { streetAddress: 'Kanzleistrasse 80', addressLocality: 'Zürich', addressCountry: 'CH', postalCode: '8004' } }
const html = (value: unknown) => `<script type="application/ld+json">${JSON.stringify(value)}</script>`
test('extracts the official organization postal address from JSON-LD', () => {
  assert.deepEqual(extractOfficialAddress(html({ '@graph': [org] })), { address: 'Kanzleistrasse 80', city: 'Zürich', country: 'CH', postal_code: '8004' })
})
test('ignores product addresses and refuses ambiguous branch addresses', () => {
  assert.equal(extractOfficialAddress(html({ ...org, '@type': 'Product' })), null)
  assert.equal(extractOfficialAddress(html([org, { ...org, address: { ...org.address, addressLocality: 'Bern' } }])), null)
})
