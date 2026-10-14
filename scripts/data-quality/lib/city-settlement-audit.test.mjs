import test from 'node:test';
import assert from 'node:assert/strict';
import { classifyEvidence, normalizePlaceName, distanceMeters } from './city-settlement-audit.mjs';
test('protects independent Culver City despite a PPLX classification', () => {
  assert.equal(
    classifyEvidence({
      classes: ['city of California', 'charter city'],
      geonames: [{ code: 'PPLX' }],
    }).status,
    'municipality',
  );
});
test('does not collapse independent German cities that also have district status', () => {
  assert.equal(
    classifyEvidence({ classes: ['urban municipality in Germany', 'urban district of Bavaria'] })
      .status,
    'municipality',
  );
});
test('identifies Vienna districts and London areas without treating city words as evidence', () => {
  assert.equal(classifyEvidence({ classes: ['district of Vienna'] }).status, 'non_city');
  assert.equal(
    classifyEvidence({
      classes: ['human settlement', 'area of London'],
      geonames: [{ code: 'PPLX' }],
    }).status,
    'non_city',
  );
});
test('refuses to demote places from one gazetteer code or a bad identifier', () => {
  assert.equal(classifyEvidence({ geonames: [{ code: 'PPLX' }] }).status, 'review');
  assert.equal(
    classifyEvidence({ classes: ['gymnasium'], geonames: [{ code: 'PPL' }] }).status,
    'review',
  );
});
test('retains independent US boroughs and highlights ambiguous administrative units', () => {
  assert.equal(classifyEvidence({ classes: ['borough of Pennsylvania'] }).status, 'municipality');
  assert.equal(classifyEvidence({ classes: ['local municipality'] }).status, 'review');
});
test('handles coordinates and multilingual comparison without treating missing pins as zero', () => {
  assert.equal(distanceMeters(null, 0, 0, 0), null);
  assert.equal(distanceMeters(48.2, 16.3, 48.2, 16.3), 0);
  assert.equal(normalizePlaceName('São Paulo'), normalizePlaceName('Sao Paulo'));
  assert.notEqual(normalizePlaceName('東京'), normalizePlaceName('京都'));
});
test('same-name districts and local government areas cannot prove a town is a neighbourhood', () => {
  for (const label of ['district of India', 'district of Bangladesh', 'district of the Czech Republic', 'district of Costa Rica', 'district of Peru', 'local government area of South Australia']) {
    assert.equal(classifyEvidence({ classes: [label], geonames: [{ code: 'PPLA' }] }).status, 'review', label);
  }
  assert.equal(classifyEvidence({ classes: ['district of India', 'city'] }).status, 'municipality');
});
