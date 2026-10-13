import { describe, expect, it } from 'vitest';
import { commentSegments, filterWorkspaceLinks } from '../workspace';
import { parseClientRedirects, parseStaticRedirects } from '../inventory';
import { targetWithoutCampaign, buildCampaignDestination } from '../linkTools';

describe('shared link workspace', () => {
  it('applies a standardized template without retaining old campaign tags or removing other parameters/fragments', () => {
    const target = targetWithoutCampaign('/events?view=calendar&utm_medium=old&ref=old#dates');
    expect(buildCampaignDestination(target, { utm_source: 'qr', ref: 'team' }, [])).toBe(
      '/events?view=calendar&utm_source=qr&ref=team#dates',
    );
  });
  it('keeps static metadata identifiers stable when comments/rule order change', () => {
    const first = parseStaticRedirects('/old /new 301\n/other /target 302');
    const second = parseStaticRedirects('# inserted comment\n/other /target 302\n/old /new 301');
    expect(first[0].id).toBe(second[1].id);
  });
  it('keeps client alias identifiers stable when imports/comments change', () => {
    const route = '<Route path="old" element={<Navigate to="/new" replace />} />';
    expect(parseClientRedirects(route)[0].id).toBe(
      parseClientRedirects('// new import\n' + route)[0].id,
    );
  });
  it('filters folder/tag intersections across all redirect sources without duplicating links', () => {
    const rows = parseStaticRedirects('/old /new 301\n/other /target 302');
    const metadata = new Map([
      [
        rows[0].id,
        { redirect_key: rows[0].id, folder_id: 'folder', tagIds: ['tag-a', 'tag-b'], comment: '' },
      ],
    ]);
    expect(filterWorkspaceLinks(rows, metadata, 'folder', 'tag-b')).toEqual([rows[0]]);
    expect(filterWorkspaceLinks(rows, metadata, 'unfiled', '')).toEqual([rows[1]]);
    expect(filterWorkspaceLinks(rows, metadata, 'folder', 'missing')).toEqual([]);
  });
  it('renders comment links as safe HTTP URLs and retains unsupported schemes as text', () => {
    const segments = commentSegments('See https://queer.guide/help and javascript:alert(1)');
    expect(segments.filter((segment) => segment.url)).toEqual([
      { text: 'https://queer.guide/help', url: 'https://queer.guide/help' },
    ]);
  });
});
