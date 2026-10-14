import { describe, it, expect } from 'vitest';
import { queryLocalRows } from '../localRows';
import {
  merchantListConfig,
  partnerListConfig,
} from '@/components/admin/business/organisationListConfigs';
const rows = [
  { id: 'a', display_name: 'Alpha', shop_domain: 'a.example', is_enabled: true, clicks: 12 },
  { id: 'b', display_name: 'Beta', shop_domain: 'b.example', is_enabled: false, clicks: 5 },
  { id: 'c', display_name: 'Gamma', shop_domain: 'c.example', is_enabled: true, clicks: 25 },
];
describe('operational list data adapters', () => {
  it('searches domains and paginates the filtered result, preserving the source', () => {
    const result = queryLocalRows(
      rows,
      merchantListConfig,
      'example',
      [{ id: 'enabled', field: 'is_enabled', op: 'is_true' }],
      [{ field: 'clicks', dir: 'desc' }],
      0,
      1,
    );
    expect(result.total).toBe(2);
    expect(result.rows.map((r) => r.id)).toEqual(['c']);
    expect(rows.map((r) => r.id)).toEqual(['a', 'b', 'c']);
  });
  it('keeps incomplete choice filters from silently hiding all rows', () => {
    expect(
      queryLocalRows(
        rows,
        merchantListConfig,
        '',
        [{ id: 'provider', field: 'provider', op: 'in', value: [] }],
        [],
        0,
        25,
      ).total,
    ).toBe(3);
  });
  it('filters partner domains using the same array operators as the CMS list', () => {
    expect(
      queryLocalRows(
        [
          { id: 'p1', domains: ['one.example', 'two.example'] },
          { id: 'p2', domains: ['three.example'] },
        ],
        partnerListConfig,
        '',
        [{ id: 'domain', field: 'domains', op: 'has_all', value: ['two.example'] }],
        [],
        0,
        25,
      ).rows.map((r) => r.id),
    ).toEqual(['p1']);
  });
  it('combines range filters with multiple sort priorities', () => {
    expect(
      queryLocalRows(
        rows,
        merchantListConfig,
        '',
        [{ id: 'clicks', field: 'clicks', op: 'between', value: { min: 5, max: 12 } }],
        [
          { field: 'is_enabled', dir: 'desc' },
          { field: 'title', dir: 'asc' },
        ],
        0,
        25,
      ).rows.map((r) => r.id),
    ).toEqual(['a', 'b']);
  });
});
