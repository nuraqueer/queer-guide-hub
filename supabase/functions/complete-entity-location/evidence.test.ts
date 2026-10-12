import { test } from 'node:test'
import assert from 'node:assert/strict'
import { acceptFeature, selectFeature } from './evidence.ts'

const feature = (properties = {}, coordinates = [8.53, 47.37]) => ({ geometry: { coordinates }, properties: {
  countrycode: 'CH', city: 'Zürich', street: 'Kanzleistrasse', housenumber: '80', postcode: '8004', ...properties,
} })
test('accepts a matching street, house number, city and country', () => {
  assert.equal(acceptFeature({ address: 'Kanzleistrasse 80', city: 'Zürich' }, 'CH', feature(), false), true)
})
test('refuses country, city, house number and postcode contradictions', () => {
  for (const row of [
    { address: 'Kanzleistrasse 81', city: 'Zürich' },
    { address: 'Kanzleistrasse 80', city: 'Bern' },
    { address: 'Kanzleistrasse 80', city: 'Zürich', postal_code: '3000' },
  ]) assert.equal(acceptFeature(row, 'CH', feature(), false), false)
  assert.equal(acceptFeature({ address: 'Kanzleistrasse 80', city: 'Zürich' }, 'DE', feature(), false), false)
})
test('does not turn a city or street centroid into a precise location', () => {
  assert.equal(acceptFeature({ address: 'Kanzleistrasse 80', city: 'Zürich' }, 'CH', feature({ housenumber: '' }), false), false)
  assert.equal(acceptFeature({ address: 'Kanzleistrasse 80' }, 'CH', feature(), false), false)
})
test('reverse evidence must be within 250 metres and agree with known country/postcode', () => {
  const row = { latitude: 47.37, longitude: 8.53, postal_code: '8004' }
  assert.equal(acceptFeature(row, 'CH', feature(), true), true)
  assert.equal(acceptFeature(row, 'CH', feature({}, [8.6, 47.4]), true), false)
  assert.equal(acceptFeature(row, 'DE', feature(), true), false)
  assert.equal(acceptFeature(row, 'CH', feature({ postcode: '3000' }), true), false)
})
test('rejects null island and coordinates outside bounds', () => {
  for (const coords of [[0, 0], [181, 40], [8, 91], [NaN, 40]]) {
    assert.equal(acceptFeature({ address: 'Kanzleistrasse 80', city: 'Zürich' }, 'CH', feature({}, coords), false), false)
  }
})
test('uses a validated nearby postcode even when a waterway without one ranks first', () => {
  const row = { latitude: 47.37, longitude: 8.53 }
  const waterway = feature({ postcode: '', housenumber: '', street: '' })
  const address = feature()
  assert.equal(selectFeature(row, 'CH', [waterway, address], true), address)
  assert.equal(selectFeature(row, 'CH', [waterway, feature({ countrycode: 'DE' })], true), waterway)
})
