import { describe, it, expect } from 'vitest';
import { parseRedirectCsv, managedImportCsv, managedLinksCsv, IMPORT_HEADERS } from '../importCsv';
const id = '00000000-0000-4000-8000-000000000001';
describe('managed CSV import and export', () => {
  it('handles BOM, CRLF, commas, escaped quotes and multiline comments', () => {
    const csv =
      '\uFEFFslug,target,comment\r\nPRIDE,https://example.com,"Community, ""welcome""\nMore text"\r\n';
    expect(managedImportCsv(csv, 'create')).toEqual([
      {
        operation: 'create',
        data: {
          slug: 'pride',
          target: 'https://example.com',
          comment: 'Community, "welcome"\nMore text',
        },
      },
    ]);
  });
  it('supports update IDs, typed metadata, nullable clearing and omitted blanks', () => {
    expect(
      managedImportCsv(
        'id,target,is_archived,folder_id,tag_ids,expires_at\n' + id + ',,false,null,[],null',
        'update',
      ),
    ).toEqual([
      {
        operation: 'update',
        id,
        data: { isArchived: false, folderId: null, tagIds: [], expiresAt: null },
      },
    ]);
    expect(managedImportCsv('slug,target,comment\npride,/events,', 'upsert')).toEqual([
      { operation: 'upsert', data: { slug: 'pride', target: '/events' } },
    ]);
  });
  it('roundtrips supported fields and comments through spreadsheet-safe commentJson', () => {
    const link = {
      id,
      slug: 'pride',
      target: 'https://example.com/?x=1,2#details',
      statusCode: 302,
      isEnabled: true,
      isArchived: false,
      queryMode: 'PRESERVE',
      queryOverride: null,
      utmDefaults: { utm_source: 'community' },
      expiresAt: null,
      folderId: null,
      tagIds: [],
      comment: '=HYPERLINK("https://example.com")\nquoted, text',
    };
    const csv = managedLinksCsv([link]);
    expect(csv).toContain('commentJson');
    const { id: unused, ...data } = link;
    expect(unused).toBe(id);
    expect(managedImportCsv(csv, 'update')).toEqual([{ operation: 'update', id, data }]);
    expect(
      managedImportCsv(managedLinksCsv([{ ...link, comment: '' }]), 'update')[0].data.comment,
    ).toBe('');
  });
  it.each([
    'slug,target\npride,"unfinished',
    'slug,target\npride,"/events"bad',
    'slug,target\npride,/events,extra',
    'slug,slug,target\npride,pride,/events',
    'slug,target,extra\npride,/events,x',
    'slug,target\npride,',
    'slug,target\npride,http://127.0.0.1',
    'slug,target,isEnabled\npride,/events,maybe',
    'id,target\nnot-uuid,/events',
  ])('rejects malformed or invalid rows before writes', (csv) => {
    expect(() => managedImportCsv(csv, csv.startsWith('id') ? 'update' : 'create')).toThrow();
  });
  it('rejects duplicate identities, oversized files/batches and rows silently skipped by the legacy parser', () => {
    expect(() => managedImportCsv('slug,target\npride,/one\npride,/two', 'upsert')).toThrow(
      'Duplicate',
    );
    expect(() => managedImportCsv('id,target\n,/events', 'update')).toThrow('requires a link ID');
    expect(() => parseRedirectCsv('slug,target\n' + 'x'.repeat(2100000))).toThrow('2.1 MB');
    expect(() =>
      parseRedirectCsv('slug,target\n' + Array(101).fill('pride,/events').join('\n')),
    ).toThrow('100 rows');
    expect(() => managedImportCsv('slug,target\npride,/events\nmissing,', 'create')).toThrow(
      'Row 3',
    );
    const template =
      IMPORT_HEADERS.join(',') +
      '\r\n,pride-campaign,https://example.com/events,302,true,false,PRESERVE,,,,,,\r\n';
    expect(managedImportCsv(template, 'create')).toHaveLength(1);
  });
});
